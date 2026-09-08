;;; Bounded nonblocking guest side of the one fixed KOReader virtio-serial
;;; control stream.  This is trusted fixture plumbing, not Book Protocol and
;;; never a book-visible module.
(define-module (guest-virtio-book-ui)
  #:use-module (ice-9 match)
  #:use-module (private-control)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-9)
  #:use-module (system foreign)
  #:export (book-ui-port-name
            book-ui-port-path
            book-ui-control?
            open-book-ui-control!
            adopt-book-ui-control-port!
            close-book-ui-control!
            book-ui-control-open?
            book-ui-control-eof?
            book-ui-control-fd
             book-ui-control-identity
             queue-book-ui-command!
             book-ui-command-delivered?
             pump-book-ui-input!
            pump-book-ui-output!
            book-ui-control-snapshot))

(define book-ui-port-name "org.wilkbook.book-interaction")
(define book-ui-port-path
  (string-append "/dev/virtio-ports/" book-ui-port-name))
(define read-budget-bytes 4096)
(define write-budget-bytes 4096)
(define write-budget-frames 4)
(define wait-sleep-microseconds 20000)

(define-record-type <book-ui-control>
  (%make-book-ui-control port identity input queue queued-bytes
                         enqueued-frames delivered-frames open? eof?)
  book-ui-control?
  (port book-ui-control-port)
  (identity book-ui-control-identity)
  (input book-ui-control-input set-book-ui-control-input!)
  (queue book-ui-control-queue set-book-ui-control-queue!)
  (queued-bytes book-ui-control-queued-bytes
                 set-book-ui-control-queued-bytes!)
  (enqueued-frames book-ui-control-enqueued-frames
                   set-book-ui-control-enqueued-frames!)
  (delivered-frames book-ui-control-delivered-frames
                    set-book-ui-control-delivered-frames!)
  (open? book-ui-control-open? set-book-ui-control-open?!)
  (eof? book-ui-control-eof? set-book-ui-control-eof?!))

(define libc (dynamic-link))
(define c-read
  (pointer->procedure ssize_t (dynamic-func "read" libc)
                      (list int '* size_t) #:return-errno? #t))
(define c-write
  (pointer->procedure ssize_t (dynamic-func "write" libc)
                      (list int '* size_t) #:return-errno? #t))

;; Kept private but parameterized so host regressions can deterministically
;; force EINTR, EAGAIN, and short transfers around the real state machine.
(define read-attempt
  (make-parameter
   (lambda (fd target count)
     (c-read fd (bytevector->pointer target) count))))
(define write-attempt
  (make-parameter
   (lambda (fd source offset count)
     (let* ((base (bytevector->pointer source))
            (pointer (make-pointer (+ (pointer-address base) offset))))
       (c-write fd pointer count)))))

(define (ui-error kind message . arguments)
  (throw 'book-interaction-ui-channel-error kind
         (apply format #f message arguments)))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (lstat-or-false path)
  (catch 'system-error
    (lambda () (lstat path))
    (lambda arguments
      (if (= (system-error-errno arguments) ENOENT)
          #f
          (apply throw 'system-error arguments)))))

(define (same-identity? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (bytevector-slice source start end)
  (let* ((length (- end start))
         (result (make-bytevector length)))
    (bytevector-copy! source start result 0 length)
    result))

(define (bytevector-append left right)
  (let* ((left-length (bytevector-length left))
         (right-length (bytevector-length right))
         (result (make-bytevector (+ left-length right-length))))
    (bytevector-copy! left 0 result 0 left-length)
    (bytevector-copy! right 0 result left-length right-length)
    result))

(define (newline-index bytes)
  (let ((length (bytevector-length bytes)))
    (let loop ((index 0))
      (and (< index length)
           (if (= (bytevector-u8-ref bytes index) 10)
               index
               (loop (+ index 1)))))))

(define (require-effective-flags! port)
  (let* ((fd (fileno port))
         (status-flags (fcntl fd F_GETFL))
         (descriptor-flags (fcntl fd F_GETFD)))
    (unless (= (logand status-flags O_NONBLOCK) O_NONBLOCK)
      (ui-error 'flags "named virtio port is not O_NONBLOCK"))
    (unless (= (logand descriptor-flags FD_CLOEXEC) FD_CLOEXEC)
      (ui-error 'flags "named virtio port is not FD_CLOEXEC"))))

(define* (adopt-book-ui-control-port! port #:key (require-character? #t))
  ;; PORT ownership transfers to the returned control.  The test-only socket
  ;; path sets REQUIRE-CHARACTER? false; the guest entry never does.
  (unless (and (port? port) (not (port-closed? port)))
    (ui-error 'type "book UI control requires one open port"))
  (let* ((fd (fileno port))
         (info (stat fd))
         (status-flags (fcntl fd F_GETFL))
         (descriptor-flags (fcntl fd F_GETFD)))
    (when (and require-character?
               (not (eq? (stat:type info) 'char-special)))
      (ui-error 'type "named virtio target is not a character device"))
    (unless (zero? (fcntl fd F_SETFL (logior status-flags O_NONBLOCK)))
      (ui-error 'flags "could not set O_NONBLOCK on named virtio port"))
    (unless (zero? (fcntl fd F_SETFD
                         (logior descriptor-flags FD_CLOEXEC)))
      (ui-error 'flags "could not set FD_CLOEXEC on named virtio port"))
    (setvbuf port 'none)
    (require-effective-flags! port)
    (%make-book-ui-control port info (make-bytevector 0) '() 0 0 0 #t #f)))

(define* (open-book-ui-control! deadline #:key (path book-ui-port-path))
  (unless (and (number? deadline) (> deadline (now-seconds)))
    (ui-error 'deadline "named virtio port deadline is not in the future"))
  (let wait ()
    (let ((link-before (lstat-or-false path)))
      (cond
       ((not link-before)
        (if (>= (now-seconds) deadline)
            (ui-error 'deadline "named virtio port did not appear: ~a" path)
            (begin (usleep wait-sleep-microseconds) (wait))))
       ((not (eq? (stat:type link-before) 'symlink))
        (ui-error 'type "named virtio port path is not a udev symlink: ~a" path))
       (else
        (let* ((target
                (catch 'system-error
                  (lambda () (canonicalize-path path))
                  (lambda arguments
                    (ui-error 'identity
                              "named virtio port link could not be resolved: ~a"
                              path))))
               (target-info (lstat target)))
          (unless (eq? (stat:type target-info) 'char-special)
            (ui-error 'type
                      "named virtio port link target is not a character device"))
          (let ((fd #f) (port #f) (published? #f))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (set! fd
                      (open-fdes path
                                 (logior O_RDWR O_NOCTTY O_NONBLOCK O_CLOEXEC)))
                (set! port (fdopen fd "r+b0"))
                (set! fd #f)
                (let ((link-after (lstat-or-false path))
                      (opened (stat (fileno port))))
                  (unless (and link-after
                               (eq? (stat:type link-after) 'symlink)
                               (same-identity? link-before link-after)
                               (string=? target (canonicalize-path path))
                               (same-identity? target-info opened)
                               (eq? (stat:type opened) 'char-special))
                    (ui-error 'identity
                              "named virtio port identity changed while opening")))
                (let ((control (adopt-book-ui-control-port! port)))
                  (set! published? #t)
                  control))
              (lambda ()
                (when fd (close-fdes fd))
                (unless published? (close-port-quietly! port)))))))))))

(define (book-ui-control-fd control)
  (unless (book-ui-control? control)
    (ui-error 'type "book UI control record required"))
  (fileno (book-ui-control-port control)))

(define (invalidate-control! control eof?)
  (set-book-ui-control-open?! control #f)
  (set-book-ui-control-eof?! control eof?)
  (set-book-ui-control-input! control (make-bytevector 0))
  (set-book-ui-control-queue! control '())
  (set-book-ui-control-queued-bytes! control 0))

(define (close-book-ui-control! control)
  (when (book-ui-control? control)
    (when (book-ui-control-open? control)
      (invalidate-control! control #f))
    (close-port-quietly! (book-ui-control-port control))))

(define (queue-book-ui-command! control kind generation value)
  (unless (and (book-ui-control? control) (book-ui-control-open? control))
    (ui-error 'closed "book UI control is closed"))
  (let* ((frame (encode-control-line kind generation value reader-command-kinds))
         (frame-length (bytevector-length frame))
         (queue (book-ui-control-queue control)))
    (when (or (>= (length queue) max-control-queue-frames)
              (> (+ (book-ui-control-queued-bytes control) frame-length)
                 max-control-queue-bytes))
      (ui-error 'backpressure "book UI output queue reached its bound"))
    (set-book-ui-control-queue! control
                                (append queue (list (cons frame 0))))
    (set-book-ui-control-queued-bytes!
     control (+ (book-ui-control-queued-bytes control) frame-length))
    (set-book-ui-control-enqueued-frames!
     control (+ (book-ui-control-enqueued-frames control) 1))
    ;; This monotonically increasing ticket is completed only by the exact
    ;; full-frame write path below.  EOF invalidation deliberately clears the
    ;; mutable queue but does not forge delivery of an unsent ticket.
    (book-ui-control-enqueued-frames control)))

(define (book-ui-command-delivered? control ticket)
  (unless (and (book-ui-control? control)
               (integer? ticket)
               (exact? ticket)
               (> ticket 0)
               (<= ticket (book-ui-control-enqueued-frames control)))
    (ui-error 'type "valid book UI command delivery ticket required"))
  (>= (book-ui-control-delivered-frames control) ticket))

(define (attempt-result thunk)
  (call-with-values thunk cons))

(define (would-block-errno? value)
  (memv value (list EAGAIN EWOULDBLOCK)))

(define (pump-book-ui-output! control)
  ;; One scheduler turn writes at most 4 KiB and completes at most four frames.
  (unless (book-ui-control? control)
    (ui-error 'type "book UI control record required"))
  (if (not (book-ui-control-open? control))
      'closed
      (let loop ((bytes 0) (frames 0))
        (cond
         ((null? (book-ui-control-queue control))
          (list 'drained bytes frames))
         ((or (>= bytes write-budget-bytes)
              (>= frames write-budget-frames))
          (list 'budget bytes frames))
         (else
          (let* ((head (car (book-ui-control-queue control)))
                 (frame (car head))
                 (offset (cdr head))
                 (allowance
                  (min (- (bytevector-length frame) offset)
                       (- write-budget-bytes bytes)))
                 (attempt
                  (attempt-result
                   (lambda ()
                     ((write-attempt) (book-ui-control-fd control)
                                      frame offset allowance))))
                 (written (car attempt))
                 (errno (cdr attempt)))
            (cond
             ((and (= written -1) (would-block-errno? errno))
              (list 'would-block bytes frames))
             ((and (= written -1) (= errno EINTR))
              (list 'interrupted bytes frames))
             ((or (<= written 0) (> written allowance))
              (invalidate-control! control #f)
              (ui-error 'write "named virtio port write failed: ~a" errno))
             (else
              (let ((next (+ offset written)))
                (set-book-ui-control-queued-bytes!
                 control (- (book-ui-control-queued-bytes control) written))
                (if (= next (bytevector-length frame))
                    (begin
                      (set-book-ui-control-queue!
                       control (cdr (book-ui-control-queue control)))
                      (set-book-ui-control-delivered-frames!
                       control
                       (+ (book-ui-control-delivered-frames control) 1))
                      (loop (+ bytes written) (+ frames 1)))
                    (begin
                      (set-book-ui-control-queue!
                       control
                       (cons (cons frame next)
                             (cdr (book-ui-control-queue control))))
                      (loop (+ bytes written) frames))))))))))))

(define (take-input-event! control)
  (let* ((input (book-ui-control-input control))
         (newline (newline-index input)))
    (and newline
         (let ((line (bytevector-slice input 0 newline)))
           (set-book-ui-control-input!
            control
            (bytevector-slice input (+ newline 1)
                              (bytevector-length input)))
           (catch #t
             (lambda () (decode-control-line line reader-event-kinds))
             (lambda arguments
               (invalidate-control! control #f)
               (apply throw arguments)))))))

(define (pump-book-ui-input! control)
  ;; Return at most one event and issue at most one bounded read per turn.
  (unless (book-ui-control? control)
    (ui-error 'type "book UI control record required"))
  (or (take-input-event! control)
      (if (not (book-ui-control-open? control))
          (if (book-ui-control-eof? control) 'eof 'closed)
          (let* ((buffer (make-bytevector read-budget-bytes))
                 (attempt
                  (attempt-result
                   (lambda ()
                     ((read-attempt) (book-ui-control-fd control)
                                     buffer read-budget-bytes))))
                 (received (car attempt))
                 (errno (cdr attempt)))
            (cond
             ((and (= received -1) (would-block-errno? errno)) 'would-block)
             ((and (= received -1) (= errno EINTR)) 'interrupted)
             ((negative? received)
              (invalidate-control! control #f)
              (ui-error 'read "named virtio port read failed: ~a" errno))
             ((zero? received)
              (if (zero? (bytevector-length (book-ui-control-input control)))
                  (begin (invalidate-control! control #t) 'eof)
                  (begin
                    (invalidate-control! control #t)
                    (ui-error 'protocol
                              "EOF truncated a private UI control frame"))))
             ((> received read-budget-bytes)
              (invalidate-control! control #f)
              (ui-error 'read "named virtio port read exceeded its allowance"))
             (else
              (let ((input
                     (bytevector-append
                      (book-ui-control-input control)
                      (bytevector-slice buffer 0 received))))
                (when (> (bytevector-length input)
                         (+ max-control-line-bytes read-budget-bytes))
                  (invalidate-control! control #f)
                  (ui-error 'bounds "private UI input buffer reached its bound"))
                (set-book-ui-control-input! control input)
                (let ((event (take-input-event! control)))
                  (when (and (not event)
                             (> (bytevector-length input)
                                max-control-line-bytes))
                    (invalidate-control! control #f)
                    (ui-error 'bounds
                              "private UI control line reached its bound"))
                  (or event 'progress)))))))))

(define (book-ui-control-snapshot control)
  (unless (book-ui-control? control)
    (ui-error 'type "book UI control record required"))
  `((open . ,(book-ui-control-open? control))
    (eof . ,(book-ui-control-eof? control))
    (input-bytes . ,(bytevector-length (book-ui-control-input control)))
    (queued-frames . ,(length (book-ui-control-queue control)))
    (queued-bytes . ,(book-ui-control-queued-bytes control))
    (enqueued-frames . ,(book-ui-control-enqueued-frames control))
    (delivered-frames . ,(book-ui-control-delivered-frames control))
    (read-budget . ,read-budget-bytes)
    (write-budget . ,write-budget-bytes)
    (write-frame-budget . ,write-budget-frames)))
