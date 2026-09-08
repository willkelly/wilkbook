;;; Finite Book State extension over the accepted disposable-QEMU guardians.
(define-module (guardian-integration successor-state-guardian)
  #:use-module (book-state-qemu state-volume)
  #:use-module (disposable-qemu)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (process-instance-live?
            read-process-identity
            make-process-record-observer
            run-owned-process-with-state-handoff))

(define %outer-module (resolve-module '(disposable-qemu)))
(define (outer-private name) (module-ref %outer-module name))

(define (integration-error message . arguments)
  (throw 'book-state-qemu-guardian-integration-error
         (apply format #f message arguments)))

(define (read-proc-start-time pid)
  ;; /proc/PID/stat field 2 is parenthesized and may contain spaces or `)`.
  ;; Everything after the final `)` starts at field 3; starttime is field 22.
  (let ((path (format #f "/proc/~a/stat" pid)))
    (catch 'system-error
      (lambda ()
        (let* ((line (call-with-input-file path read-line))
               (close (string-rindex line #\)))
               (tail (and close
                          (string-tokenize
                           (substring line (+ close 1))))))
          (and tail (> (length tail) 19) (list-ref tail 19))))
      (lambda arguments
        (if (= ENOENT (system-error-errno arguments))
            #f
            (apply throw 'system-error arguments))))))

(define (process-instance-live? pid start-time)
  (and (integer? pid)
       (> pid 0)
       (string? start-time)
       (let ((observed (read-proc-start-time pid)))
         (and observed (string=? observed start-time)))))

(define (await-process-start-time pid)
  (let ((deadline (+ ((outer-private 'monotonic-seconds)) 1.0)))
    (let loop ()
      (let ((value (read-proc-start-time pid)))
        (cond
         (value value)
         ((>= ((outer-private 'monotonic-seconds)) deadline)
          (integration-error "process ~a lacked a stable /proc start time" pid))
         (else (usleep 10000) (loop)))))))

(define (write-exclusive-datum! path value)
  (let ((fd (open-fdes path
                       (logior O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_CLOEXEC)
                       #o600))
        (port #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (chmod fd #o600)
        (set! port (fdopen fd "w"))
        (write value port)
        (newline port)
        (force-output port)
        (fsync fd))
      (lambda ()
        (if port (close-port port) (close-fdes fd))))))

(define (read-process-identity path)
  (let ((value (call-with-input-file path read)))
    (unless (and (list? value)
                 (assq 'role value)
                 (assq 'pid value)
                 (assq 'start-time value))
      (integration-error "invalid process identity record: ~a" path))
    value))

(define (record-process-observer path role)
  (lambda (pid)
    (write-exclusive-datum!
     path
     `((schema . 1)
       (role . ,role)
       (pid . ,pid)
       (start-time . ,(await-process-start-time pid))))))

(define make-process-record-observer record-process-observer)

(define (same-state-identity? expected info)
  (and (eq? (stat:type info) 'regular)
       (= (assoc-ref expected 'device) (stat:dev info))
       (= (assoc-ref expected 'inode) (stat:ino info))
       (= (assoc-ref expected 'size) (stat:size info))
       (= (assoc-ref expected 'uid) (stat:uid info))
       (= (assoc-ref expected 'mode) (logand (stat:mode info) #o7777))
       (= (assoc-ref expected 'links) (stat:nlink info))))

(define (descriptor-flags fd label)
  (catch 'system-error
    (lambda () (fcntl fd F_GETFD))
    (lambda arguments
      (integration-error "~a descriptor ~a is not open: ~a"
                         label fd
                         (strerror (system-error-errno arguments))))))

(define (non-cloexec-descriptors-above-stderr)
  (sort
   (filter-map
    (lambda (name)
      (let ((fd (string->number name)))
        (and fd (> fd 2)
             (catch 'system-error
               (lambda ()
                 (and (zero? (logand (fcntl fd F_GETFD) FD_CLOEXEC)) fd))
               (lambda arguments
                 (if (= EBADF (system-error-errno arguments))
                     #f
                     (apply throw 'system-error arguments)))))))
    (scandir "/proc/self/fd"
             (lambda (name) (and (string->number name) #t))))
   <))

(define (state-exec-extension handoff expected-state run-root run-identity
                              qmp-path exec-record)
  ;; The public accessor performs the frozen v3 token/thread/identity/CLOEXEC
  ;; checks and KCMP_FILE comparison before any guardian is forked.
  (let* ((file-name (state-volume-qemu-handoff-file-name handoff))
         (prefix "/proc/self/fd/")
         (handoff-fd
          (and (string-prefix? prefix file-name)
               (string->number
                (substring file-name (string-length prefix)))))
         (writer
          ((@@ (book-state-qemu state-volume) handoff-writer) handoff))
         (anchor-fd
          ((@@ (book-state-qemu state-volume) writer-image-fd) writer))
         (same-ofd?
          (@@ (book-state-qemu state-volume) same-open-file-description?)))
    (unless (and handoff-fd (> handoff-fd 2)
                 (not (= handoff-fd anchor-fd))
                 (same-state-identity? expected-state (stat handoff-fd))
                 (same-state-identity? expected-state (stat anchor-fd))
                 (same-ofd? anchor-fd handoff-fd)
                 (zero? (logand (descriptor-flags handoff-fd "handoff")
                                FD_CLOEXEC))
                 (positive? (logand (descriptor-flags anchor-fd "anchor")
                                    FD_CLOEXEC)))
      (integration-error "state handoff failed parent-side OFD validation"))
    (lambda ()
      ;; disposable-qemu has just applied its deny-all CLOEXEC sweep.  Recheck
      ;; the exact retained inode and exact open-file description in the exec
      ;; child, then clear CLOEXEC on this one duplicate only.
      (unless (and (same-state-identity? expected-state (stat handoff-fd))
                   (same-state-identity? expected-state (stat anchor-fd))
                   (same-ofd? anchor-fd handoff-fd)
                   (positive? (logand (descriptor-flags handoff-fd "handoff")
                                      FD_CLOEXEC))
                   (positive? (logand (descriptor-flags anchor-fd "anchor")
                                      FD_CLOEXEC)))
        (integration-error "state handoff failed child-side OFD validation"))
      (fcntl handoff-fd F_SETFD
             (logand (descriptor-flags handoff-fd "handoff")
                     (lognot FD_CLOEXEC)))
      (unless (and (zero? (logand (descriptor-flags handoff-fd "handoff")
                                  FD_CLOEXEC))
                   (positive? (logand (descriptor-flags anchor-fd "anchor")
                                      FD_CLOEXEC))
                   (equal? (non-cloexec-descriptors-above-stderr)
                           (list handoff-fd)))
        (integration-error "exec allowlist is not exactly the handoff FD"))
      (let ((current-root (lstat run-root)))
        (unless (and (eq? (stat:type current-root) 'directory)
                     (= (stat:dev current-root) (stat:dev run-identity))
                     (= (stat:ino current-root) (stat:ino run-identity)))
          (integration-error "run root identity changed before QEMU exec")))
      (write-exclusive-datum!
       exec-record
       `((schema . 1)
         (role . qemu-exec-child)
         (pid . ,(getpid))
         (start-time . ,(await-process-start-time (getpid)))
         (process-group . ,(getpgrp))
         (run-root . ,run-root)
         (run-root-device . ,(stat:dev run-identity))
         (run-root-inode . ,(stat:ino run-identity))
         (qmp-path . ,qmp-path)
         (state-proc-file . ,file-name)
         (state-fd . ,handoff-fd)
         (state-device . ,(assoc-ref expected-state 'device))
         (state-inode . ,(assoc-ref expected-state 'inode))
         (state-size . ,(assoc-ref expected-state 'size))
         (anchor-fd . ,anchor-fd)
         (anchor-cloexec . #t)
         (non-cloexec-above-stderr . (,handoff-fd))))
      #t)))

(define (run-owned-process-with-state-handoff
         argv environment cwd stdout-path stderr-path timeout grace
         root-liveness-port handoff expected-state run-root run-identity qmp-path
         guardian-record child-record exec-record)
  (unless (and (list? argv) (every string? argv))
    (integration-error "QEMU argv must be a list of strings"))
  (let ((extension
         (state-exec-extension handoff expected-state run-root run-identity
                               qmp-path exec-record)))
    ((outer-private 'run-owned-process)
     argv environment cwd stdout-path stderr-path timeout grace
     root-liveness-port
     #:exec-extension extension
     #:guardian-observer
     (record-process-observer guardian-record 'process-guardian)
     #:child-observer
     (record-process-observer child-record 'qemu-direct-child))))
