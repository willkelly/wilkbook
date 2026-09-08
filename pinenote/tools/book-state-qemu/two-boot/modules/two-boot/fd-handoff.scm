;;; Descriptor continuation for the accepted disposable-QEMU exec hook.
;;; This is not a process guardian.  The accepted guardian owns every process;
;;; this module only validates and re-enables one already-owned state OFD after
;;; the guardian's deny-all FD_CLOEXEC sweep.
(define-module (two-boot fd-handoff)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (system foreign)
  #:export (state-image-size
            capture-state-fd-identity
            assert-state-fd-identity!
            call-with-state-fd-anchor
            make-state-fd-exec-extension
            make-process-record-observer
            read-process-identity
            process-instance-live?
            non-cloexec-descriptors-above-stderr))

(define state-image-size (* 64 1024 1024))
(define linux-f-dupfd-cloexec 1030)
(define kcmp-file 0)
(define kcmp-syscall-number
  (let ((machine (utsname:machine (uname))))
    (cond ((string=? machine "x86_64") 312)
          ((string=? machine "aarch64") 272)
          (else #f))))
(define libc (dynamic-link))
(define c-syscall
  (pointer->procedure long (dynamic-func "syscall" libc)
                      (list long int int int unsigned-long unsigned-long)
                      #:return-errno? #t))

(define (handoff-error message . arguments)
  (throw 'book-state-two-boot-fd-error
         (apply format #f message arguments)))

(define (capture-state-fd-identity fd)
  (let ((info
         (catch 'system-error
           (lambda () (stat fd))
           (lambda arguments
             (handoff-error "state descriptor ~a is not open: ~a" fd
                            (strerror (system-error-errno arguments)))))))
    (unless (and (integer? fd) (> fd 2)
                 (eq? (stat:type info) 'regular)
                 (= (stat:uid info) (getuid))
                 (= (stat:nlink info) 1)
                 (= (logand (stat:mode info) #o7777) #o600)
                 (= (stat:size info) state-image-size))
      (handoff-error
       "state descriptor is not the owned mode-0600 single-link 64 MiB file"))
    `((device . ,(stat:dev info))
      (inode . ,(stat:ino info))
      (uid . ,(stat:uid info))
      (mode . ,(logand (stat:mode info) #o7777))
      (links . ,(stat:nlink info))
      (size . ,(stat:size info)))))

(define (assert-state-fd-identity! fd expected)
  (unless (and (list? expected)
               (equal? (capture-state-fd-identity fd) expected))
    (handoff-error "state descriptor identity changed"))
  #t)

(define (same-open-file-description? left right)
  (unless kcmp-syscall-number
    (handoff-error "KCMP_FILE is unavailable on ~a" (utsname:machine (uname))))
  (call-with-values
      (lambda ()
        (c-syscall kcmp-syscall-number (getpid) (getpid) kcmp-file left right))
    (lambda (result errno)
      (cond ((zero? result) #t)
            ((positive? result) #f)
            (else (handoff-error "KCMP_FILE failed: ~a" (strerror errno)))))))

(define (descriptor-flags fd)
  (catch 'system-error
    (lambda () (fcntl fd F_GETFD))
    (lambda arguments
      (handoff-error "descriptor ~a disappeared: ~a" fd
                     (strerror (system-error-errno arguments))))))

(define (non-cloexec-descriptors-above-stderr)
  (sort
   (filter-map
    (lambda (name)
      (let ((fd (string->number name 10)))
        (and fd (> fd 2)
             (catch 'system-error
               (lambda ()
                 (and (zero? (logand (fcntl fd F_GETFD) FD_CLOEXEC)) fd))
               (lambda arguments
                 (if (= EBADF (system-error-errno arguments))
                     #f
                     (apply throw 'system-error arguments)))))))
    (scandir "/proc/self/fd" (lambda (name) (and (string->number name 10) #t))))
   <))

(define (call-with-state-fd-anchor fd proc)
  (unless (procedure? proc) (handoff-error "anchor callback is not a procedure"))
  (let* ((expected (capture-state-fd-identity fd))
         (anchor (fcntl fd linux-f-dupfd-cloexec 3)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (unless (and (> anchor 2) (not (= anchor fd))
                     (positive? (logand (descriptor-flags anchor) FD_CLOEXEC))
                     (same-open-file-description? fd anchor))
          (handoff-error "could not establish a private CLOEXEC OFD anchor"))
        (proc anchor expected))
      (lambda () (false-if-exception (close-fdes anchor))))))

(define (same-directory? expected info)
  (and (eq? (stat:type info) 'directory)
       (= (stat:dev expected) (stat:dev info))
       (= (stat:ino expected) (stat:ino info))))

(define (read-proc-start-time pid)
  (catch 'system-error
    (lambda ()
      (let* ((line (call-with-input-file (format #f "/proc/~a/stat" pid)
                     read-line))
             (close (string-rindex line #\)))
             (tail (and close (string-tokenize (substring line (+ close 1))))))
        (and tail (> (length tail) 19) (list-ref tail 19))))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (process-instance-live? pid start-time)
  (and (integer? pid) (> pid 0) (string? start-time)
       (let ((observed (read-proc-start-time pid)))
         (and observed (string=? observed start-time)))))

(define (await-process-start-time pid)
  (let ((limit (+ (get-internal-real-time) internal-time-units-per-second)))
    (let loop ()
      (let ((value (read-proc-start-time pid)))
        (cond (value value)
              ((>= (get-internal-real-time) limit)
               (handoff-error "process ~a lacked a stable start time" pid))
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
        (if port (close-port port) (false-if-exception (close-fdes fd)))))))

(define (make-process-record-observer path role)
  (lambda (pid)
    (write-exclusive-datum!
     path
     `((schema . 1) (role . ,role) (pid . ,pid)
       (start-time . ,(await-process-start-time pid))))))

(define (read-process-identity path)
  (let* ((info (lstat path))
         (value
          (call-with-input-file path
            (lambda (port)
              (let ((record (read port)) (tail (read port)))
                (unless (eof-object? tail)
                  (handoff-error "process identity has trailing data: ~a" path))
                record)))))
    (unless (and (eq? (stat:type info) 'regular)
                 (= (stat:uid info) (getuid))
                 (= (stat:nlink info) 1)
                 (list? value)
                 (= (length value) 4)
                 (= (assoc-ref value 'schema) 1)
                 (symbol? (assoc-ref value 'role))
                 (integer? (assoc-ref value 'pid))
                 (> (assoc-ref value 'pid) 0)
                 (string? (assoc-ref value 'start-time))
                 (string-every char-numeric?
                               (assoc-ref value 'start-time))
                 (= (length (delete-duplicates (map car value))) 4))
      (handoff-error "invalid process identity record: ~a" path))
    value))

(define (make-state-fd-exec-extension fd anchor expected record-path role
                                      guarded-root guarded-root-identity)
  ;; Called after disposable-qemu's deny-all sweep in the guarded exec child.
  (unless (and (integer? fd) (> fd 2) (integer? anchor) (> anchor 2)
               (not (= fd anchor)) (string? record-path) (symbol? role))
    (handoff-error "invalid state exec-extension inputs"))
  (assert-state-fd-identity! fd expected)
  (assert-state-fd-identity! anchor expected)
  (unless (same-open-file-description? fd anchor)
    (handoff-error "state descriptor and anchor are different OFDs"))
  (lambda ()
    (assert-state-fd-identity! fd expected)
    (assert-state-fd-identity! anchor expected)
    (unless (and (same-open-file-description? fd anchor)
                 (positive? (logand (descriptor-flags fd) FD_CLOEXEC))
                 (positive? (logand (descriptor-flags anchor) FD_CLOEXEC)))
      (handoff-error "deny-all sweep did not leave both state descriptors sealed"))
    (fcntl fd F_SETFD (logand (descriptor-flags fd) (lognot FD_CLOEXEC)))
    (unless (and (zero? (logand (descriptor-flags fd) FD_CLOEXEC))
                 (positive? (logand (descriptor-flags anchor) FD_CLOEXEC))
                 (equal? (non-cloexec-descriptors-above-stderr) (list fd)))
      (handoff-error "exec allowlist is not exactly the state descriptor"))
    (let ((current (lstat guarded-root)))
      (unless (same-directory? guarded-root-identity current)
        (handoff-error "guarded root identity changed before exec")))
    (write-exclusive-datum!
     record-path
     `((schema . 1) (role . ,role) (pid . ,(getpid))
       (start-time . ,(await-process-start-time (getpid)))
       (process-group . ,(getpgrp))
       (guarded-root . ,guarded-root)
       (guarded-root-device . ,(stat:dev guarded-root-identity))
       (guarded-root-inode . ,(stat:ino guarded-root-identity))
       (state-proc-file . ,(format #f "/proc/self/fd/~a" fd))
       (state-fd . ,fd)
       (state-device . ,(assoc-ref expected 'device))
       (state-inode . ,(assoc-ref expected 'inode))
       (state-size . ,(assoc-ref expected 'size))
       (anchor-fd . ,anchor)
       (anchor-cloexec . #t)
       (non-cloexec-above-stderr . (,fd))))
    #t))
