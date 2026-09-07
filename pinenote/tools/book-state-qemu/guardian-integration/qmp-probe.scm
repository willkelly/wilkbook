;;; Bounded Unix-QMP and /proc evidence for a paused actual QEMU process.
(define-module (guardian-integration qmp-probe)
  #:use-module (guardian-integration successor-state-guardian)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (probe-paused-qemu!
            qmp-quit!))

(define max-qmp-line-bytes (* 512 1024))
(define qmp-connect-timeout-seconds 5.0)
(define qmp-command-timeout-seconds 5.0)

(define (probe-error message . arguments)
  (throw 'book-state-qemu-guardian-integration-error
         (apply format #f message arguments)))

(define (now)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          #f
          (apply throw 'system-error arguments)))))

(define (wait-private-socket path expected-root)
  (let ((deadline (+ (now) qmp-connect-timeout-seconds)))
    (let loop ()
      (let ((info (lstat-or-false path))
            (root (lstat expected-root)))
        (cond
         ((and info
               (eq? (stat:type info) 'socket)
               (= (stat:uid info) (getuid))
               (= (stat:uid root) (getuid)))
          info)
         ((>= (now) deadline)
          (probe-error "private QMP socket did not appear: ~a" path))
         (else (usleep 10000) (loop)))))))

(define (connect-private-qmp path expected-root)
  (wait-private-socket path expected-root)
  (let ((deadline (+ (now) qmp-connect-timeout-seconds)))
    (let loop ()
      (let ((port (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
        (catch 'system-error
          (lambda ()
            (connect port AF_UNIX path)
            (setvbuf port 'none)
            port)
          (lambda arguments
            (close-port port)
            (if (and (< (now) deadline)
                     (member (system-error-errno arguments)
                             (list ENOENT ECONNREFUSED EINTR)))
                (begin (usleep 10000) (loop))
                (apply throw 'system-error arguments))))))))

(define (read-qmp-line port)
  (let ((deadline (+ (now) qmp-command-timeout-seconds))
        (output (open-output-string)))
    (let loop ((count 0))
      (when (>= count max-qmp-line-bytes)
        (probe-error "QMP line exceeded the fixed ~a-byte bound"
                     max-qmp-line-bytes))
      (let ((remaining (- deadline (now))))
        (when (<= remaining 0)
          (probe-error "QMP response exceeded its fixed timeout"))
        (match (select (list port) '() '()
                       (inexact->exact (floor remaining))
                       (inexact->exact
                        (round (* 1000000
                                  (- remaining (floor remaining))))))
          ((() () ()) (loop count))
          ((_ () ())
           (let ((character (read-char port)))
             (cond
              ((eof-object? character)
               (probe-error "QMP closed before a complete response"))
              ((char=? character #\newline) (get-output-string output))
              (else
               (write-char character output)
                (loop (+ count 1)))))))))))

(define (compact-qmp-json text)
  ;; QEMU controls this fixed local transport.  This normalization is used only
  ;; for finite field/name assertions; the unmodified line is retained.
  (string-delete char-whitespace? text))

(define (qmp-command! port command id transcript)
  (let ((request
         (format #f "{\"execute\":\"~a\",\"id\":\"~a\"}" command id)))
    (display request port)
    (display "\r\n" port)
    (force-output port)
    (let loop ((remaining 32))
      (when (zero? remaining)
        (probe-error "QMP emitted too many asynchronous records before ~a" id))
      (let ((line (read-qmp-line port)))
        (set-car! transcript (cons line (car transcript)))
        (if (string-contains (compact-qmp-json line)
                             (string-append "\"id\":\"" id "\""))
            line
            (loop (- remaining 1)))))))

(define (read-null-separated path)
  (filter (lambda (value) (not (string-null? value)))
          (string-split (call-with-input-file path get-string-all) #\nul)))

(define (same-object? info device inode)
  (and (= (stat:dev info) device) (= (stat:ino info) inode)))

(define (proc-fd-inventory pid)
  (let ((root (format #f "/proc/~a/fd" pid)))
    (map
     (lambda (name)
       (let* ((fd (string->number name))
              (path (string-append root "/" name))
              (target (readlink path))
              (info (stat path)))
         `((fd . ,fd)
           (target . ,target)
           (type . ,(stat:type info))
           (device . ,(stat:dev info))
           (inode . ,(stat:ino info)))))
     (sort
      (scandir root (lambda (name) (string->number name)))
      (lambda (left right)
        (< (string->number left) (string->number right)))))))

(define (inventory-has-object? inventory device inode)
  (any (lambda (entry)
         (and (= (assoc-ref entry 'device) device)
              (= (assoc-ref entry 'inode) inode)))
       inventory))

(define (write-exclusive-record! path value)
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

(define (probe-paused-qemu! qmp-path run-root qemu-identity expected-argv
                            state-identity owner-lock-info campaign-root-info
                            record-path)
  (let* ((pid (assoc-ref qemu-identity 'pid))
         (start-time (assoc-ref qemu-identity 'start-time))
         (state-fd (assoc-ref qemu-identity 'state-fd))
         (transcript (list '()))
         (socket-info #f)
         (status-response #f)
         (nodes-response #f)
         (blocks-response #f)
         (inventory #f)
         (state-fd-info #f)
         (cmdline #f))
    (unless (process-instance-live? pid start-time)
      (probe-error "recorded QEMU process instance is not live"))
    (set! socket-info (wait-private-socket qmp-path run-root))
    (let ((port (connect-private-qmp qmp-path run-root)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (let ((greeting (read-qmp-line port)))
            (set-car! transcript (cons greeting (car transcript)))
            (unless (string-contains greeting "\"QMP\"")
              (probe-error "QMP greeting is missing")))
          (let ((capabilities
                 (qmp-command! port "qmp_capabilities" "caps" transcript)))
            (unless (string-contains capabilities "\"return\"")
              (probe-error "QMP capabilities negotiation failed")))
          (set! status-response
                (qmp-command! port "query-status" "status" transcript))
          (set! nodes-response
                (qmp-command! port "query-named-block-nodes" "nodes"
                              transcript))
          (set! blocks-response
                (qmp-command! port "query-block" "blocks" transcript)))
        (lambda () (close-port port))))
    (let ((status-json (compact-qmp-json status-response))
          (nodes-json (compact-qmp-json nodes-response))
          (blocks-json (compact-qmp-json blocks-response)))
      (unless (and (string-contains status-json "\"status\":\"prelaunch\"")
                   (string-contains nodes-json "\"node-name\":\"book-state\"")
                   (string-contains nodes-json
                                  "\"node-name\":\"book-state-file\"")
                   (string-contains nodes-json
                                  "\"node-name\":\"rootfs-overlay\"")
                   (string-contains
                    blocks-json
                    "\"qdev\":\"/machine/peripheral/book-state-disk/virtio-backend\""))
        (write-exclusive-record!
         record-path
         `((schema . 1)
           (state . qmp-graph-mismatch)
           (status-response . ,status-response)
           (nodes-response . ,nodes-response)
           (blocks-response . ,blocks-response)
           (qmp-transcript . ,(reverse (car transcript)))))
        (probe-error "QMP did not report the paused reader/state block graph")))
    (set! cmdline (read-null-separated (format #f "/proc/~a/cmdline" pid)))
    (unless (equal? cmdline expected-argv)
      (probe-error "QEMU /proc cmdline differs from the exact reviewed vector"))
    (let ((path (format #f "/proc/~a/fd/~a" pid state-fd)))
      (set! state-fd-info (stat path))
      (unless (and (eq? (stat:type state-fd-info) 'regular)
                   (same-object? state-fd-info
                                 (assoc-ref state-identity 'device)
                                 (assoc-ref state-identity 'inode))
                   (= (stat:size state-fd-info)
                      (assoc-ref state-identity 'size)))
        (probe-error "QEMU's inherited /proc/self/fd/N is not the retained image")))
    (set! inventory (proc-fd-inventory pid))
    (unless (inventory-has-object? inventory
                                   (assoc-ref state-identity 'device)
                                   (assoc-ref state-identity 'inode))
      (probe-error "QEMU has no open descriptor for the retained state image"))
    (when (inventory-has-object? inventory
                                 (stat:dev owner-lock-info)
                                 (stat:ino owner-lock-info))
      (probe-error "owner.lock leaked through QEMU exec"))
    (when (inventory-has-object? inventory
                                 (stat:dev campaign-root-info)
                                 (stat:ino campaign-root-info))
      (probe-error "campaign directory authority leaked through QEMU exec"))
    (write-exclusive-record!
     record-path
     `((schema . 1)
       (pid . ,pid)
       (start-time . ,start-time)
       (qmp-socket
        (path . ,qmp-path)
        (device . ,(stat:dev socket-info))
        (inode . ,(stat:ino socket-info))
        (uid . ,(stat:uid socket-info))
        (mode . ,(logand (stat:mode socket-info) #o7777)))
       (exact-cmdline . ,cmdline)
       (inherited-state-fd . ,state-fd)
       (inherited-state-target
        . ,(readlink (format #f "/proc/~a/fd/~a" pid state-fd)))
       (fd-inventory . ,inventory)
       (qmp-transcript . ,(reverse (car transcript)))))
    #t))

(define (qmp-quit! qmp-path run-root transcript-path)
  (let ((transcript (list '()))
        (port (connect-private-qmp qmp-path run-root)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((greeting (read-qmp-line port)))
          (set-car! transcript (cons greeting (car transcript))))
        (let ((capabilities
               (qmp-command! port "qmp_capabilities" "caps" transcript)))
          (unless (string-contains capabilities "\"return\"")
            (probe-error "QMP capabilities negotiation failed before quit")))
        (let ((response (qmp-command! port "quit" "quit" transcript)))
          (unless (string-contains response "\"return\"")
            (probe-error "QMP quit was not acknowledged"))))
      (lambda () (close-port port)))
    (write-exclusive-record!
     transcript-path
     `((schema . 1) (qmp-quit-transcript . ,(reverse (car transcript)))))
    #t))
