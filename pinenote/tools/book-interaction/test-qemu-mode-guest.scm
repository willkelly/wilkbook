;;; Trusted host-only mock of the guest Guile UI-control authority.
;;; It never models Book Session authority; it only drives the native UI seam.
(use-modules (private-control)
             (ice-9 ftw)
             (ice-9 match)
             (rnrs bytevectors)
             (srfi srfi-1)
             (system foreign))

(define max-input-bytes (+ max-control-line-bytes 4096))
(define c-connect
  (pointer->procedure int (dynamic-func "connect" (dynamic-link))
                      (list int '* uint32) #:return-errno? #t))

(define (fail message . arguments)
  (format (current-error-port) "FAKE-QEMU-GUEST: FAIL:~a~%"
          (apply format #f message arguments))
  (force-output (current-error-port))
  (primitive-exit 1))

(define (value-after option arguments)
  (match (member option arguments string=?)
    ((_ value . _) value)
    (_ (fail "missing QEMU option ~a" option))))

(define (chardev-path arguments)
  (let* ((entries
          (let loop ((rest arguments) (result '()))
            (match rest
              (() (reverse result))
              (("-chardev" value tail ...)
               (loop tail (cons value result)))
              ((_ tail ...) (loop tail result)))))
         (ui (find (lambda (value)
                     (string-prefix? "socket,id=bookui0,path=" value))
                   entries)))
    (unless ui (fail "missing bookui0 chardev"))
    (let* ((prefix "socket,id=bookui0,path=")
           (start (string-length prefix))
           (comma (string-index ui #\, start)))
      (unless comma (fail "malformed bookui0 chardev"))
      (substring ui start comma))))

(define (send-command! socket kind generation value)
  (let ((frame
         (encode-control-line kind generation value reader-command-kinds)))
    (let loop ((offset 0))
      (when (< offset (bytevector-length frame))
        (let ((sent (send socket
                          (let* ((remaining (- (bytevector-length frame) offset))
                                 (part (make-bytevector remaining)))
                            (bytevector-copy! frame offset part 0 remaining)
                            part))))
          (unless (positive? sent) (fail "private command write failed"))
          (loop (+ offset sent)))))))

(define (send-raw! socket text)
  (let ((bytes (string->utf8 text)))
    (unless (= (send socket bytes) (bytevector-length bytes))
      (fail "raw private command write failed"))))

(define (newline-index bytes)
  (let loop ((index 0))
    (and (< index (bytevector-length bytes))
         (if (= (bytevector-u8-ref bytes index) 10)
             index
             (loop (+ index 1))))))

(define (bytevector-slice source start end)
  (let ((result (make-bytevector (- end start))))
    (bytevector-copy! source start result 0 (- end start))
    result))

(define (bytevector-append left right)
  (let* ((left-length (bytevector-length left))
         (right-length (bytevector-length right))
         (result (make-bytevector (+ left-length right-length))))
    (bytevector-copy! left 0 result 0 left-length)
    (bytevector-copy! right 0 result left-length right-length)
    result))

(define (make-reader socket)
  (let ((buffer (make-bytevector 0)))
    (lambda ()
      (let loop ()
        (let ((newline (newline-index buffer)))
          (if newline
              (let ((line (bytevector-slice buffer 0 newline)))
                (set! buffer
                      (bytevector-slice buffer (+ newline 1)
                                        (bytevector-length buffer)))
                (decode-control-line line reader-event-kinds))
              (let* ((input (make-bytevector 4096))
                     (count (recv! socket input)))
                (when (zero? count) (fail "native reader closed early"))
                (set! buffer
                      (bytevector-append
                       buffer (bytevector-slice input 0 count)))
                (when (> (bytevector-length buffer) max-input-bytes)
                  (fail "private event input exceeded its bound"))
                (loop))))))))

(define guile-inputs
  '("Ada|nonce=g-aB3dE5fG7hJ9kL2m"
    "élan λ|nonce=g-N4pQ6rS8tV0xY2zA"))
(define python-inputs
  '("Grace|nonce=p-bC4eF6gH8jK0mN2q"
    "東京|nonce=p-R5tU7wX9yZ1aB3dE"))

(define (guile-result value)
  (format #f "GUILE[~a]:~a" (string-length value) (string-upcase value)))

(define (python-result value)
  (format #f "PYTHON[~a]:~a" (string-length value)
          (list->string (reverse (string->list value)))))

(define actions
  (append (map (lambda (input) (cons input (guile-result input))) guile-inputs)
          (map (lambda (input) (cons input (python-result input)))
               python-inputs)))

(define (require-event read-event expected-kind expected-value)
  (match (read-event)
    ((kind 1 value)
     (unless (and (eq? kind expected-kind)
                  (string=? value expected-value))
       (fail "expected ~s/~s, got ~s/~s"
             expected-kind expected-value kind value)))
    (event (fail "unexpected private event: ~s" event))))

(define* (run-positive socket #:optional hardcoded-result)
  (let ((read-event (make-reader socket)))
    (require-event read-event 'ready "dialog")
    (for-each
     (lambda (action index)
       (send-command! socket 'input-update 1 (car action))
       (require-event read-event 'submit (car action))
       (require-event read-event 'tick (format #f "qemu-~a" index))
       (let ((result (or hardcoded-result (cdr action))))
         (send-command! socket 'present 1 result)
         (require-event read-event 'applied result)))
     actions '(1 2 3 4))
    (send-command! socket 'finish 1 "")
    (require-event read-event 'done "ok")))

(define (run-mutation socket mode)
  (let ((read-event (make-reader socket)))
    (require-event read-event 'ready "dialog")
    (cond
     ((string=? mode "wrong-generation")
      (send-command! socket 'input-update 2 (caar actions)))
     ((string=? mode "wrong-routing")
      (send-command! socket 'present 1 (cdar actions)))
     ((string=? mode "malformed-frame")
      (send-raw! socket "input-update 1 4A\n"))
     ((string=? mode "early-eof") #t)
     (else (fail "unknown fake-QEMU mode ~s" mode)))
    (usleep 300000)))

(define (make-unix-address path)
  (let* ((path-bytes (string->utf8 path))
         (path-length (bytevector-length path-bytes))
         (address (make-bytevector (+ 3 path-length) 0)))
    (bytevector-u16-set! address 0 AF_UNIX (native-endianness))
    (bytevector-copy! path-bytes 0 address 2 path-length)
    address))

(define (make-full-backlog! path)
  ;; Reproduce the Linux condition from the independent review exactly: a
  ;; listen backlog of zero with one queued client.  A second nonblocking
  ;; connect is EAGAIN even though select says writable and SO_ERROR is zero;
  ;; getpeername remains the decisive ENOTCONN observation.
  (let ((filler (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
        (probe
         (socket AF_UNIX
                 (logior SOCK_STREAM SOCK_CLOEXEC SOCK_NONBLOCK) 0)))
    (connect filler AF_UNIX path)
    (let ((address (make-unix-address path)))
      (call-with-values
          (lambda ()
            (c-connect (fileno probe) (bytevector->pointer address)
                       (bytevector-length address)))
        (lambda (result error-number)
          (unless (and (= result -1)
                       (memv error-number (list EAGAIN EWOULDBLOCK)))
            (fail "full-backlog probe was not EAGAIN: ~a/~a"
                  result error-number)))))
    (unless (zero? (getsockopt probe SOL_SOCKET SO_ERROR))
      (fail "full-backlog probe unexpectedly had SO_ERROR"))
    (match (select (list probe) (list probe) '() 0 0)
      ((_ writable ())
       (unless (memq probe writable)
         (fail "full-backlog probe was not reported writable"))))
    (catch 'system-error
      (lambda ()
        (getpeername probe)
        (fail "full-backlog probe was falsely connected"))
      (lambda arguments
        (unless (= ENOTCONN (system-error-errno arguments))
          (apply throw 'system-error arguments))))
    (close-port probe)
    (format #t
            "FAKE-QEMU-GUEST: full-backlog:EAGAIN;writable;SO_ERROR=0;peer=ENOTCONN~%")
    (force-output)
    filler))

(define (main arguments)
  (match arguments
    ((mode qemu-arguments ...)
     (when (string=? mode "exit-before-socket")
       (primitive-exit 17))
      (let* ((path (chardev-path qemu-arguments))
             (listener (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
             (connection #f))
       (dynamic-wind
         (lambda () #t)
          (lambda ()
            (bind listener AF_UNIX path)
            (cond
             ((string=? mode "full-backlog")
              (listen listener 0)
              (let ((filler (make-full-backlog! path)))
                ;; Keep the listener and queued filler open without accepting.
                (sleep 30)
                (close-port filler)))
             ((string=? mode "full-backlog-drain")
              (listen listener 0)
              (let ((filler (make-full-backlog! path)))
                (usleep 250000)
                (let ((filler-server
                       (car (accept listener (logior SOCK_CLOEXEC)))))
                  (close-port filler-server))
                (close-port filler)
                (format #t "FAKE-QEMU-GUEST: full-backlog:drained~%")
                (force-output)
                (set! connection
                      (car (accept listener (logior SOCK_CLOEXEC))))
                (setvbuf connection 'none)
                (run-positive connection)))
             (else
              (listen listener 1)
              (set! connection
                    (car (accept listener (logior SOCK_CLOEXEC))))
              (setvbuf connection 'none)
              (cond
               ((member mode
                        '("hold-resistant" "early-eof-resistant")
                        string=?)
                (let ((read-event (make-reader connection)))
                  (require-event read-event 'ready "dialog")
                  (sigaction SIGTERM SIG_IGN)
                  (when (string=? mode "early-eof-resistant")
                    (close-port connection)
                    (set! connection #f))
                  (sleep 30)))
               ((string=? mode "positive")
                (run-positive connection))
               ((string=? mode "hardcoded-present")
                (run-positive connection "Book result: ADA"))
               ((string=? mode "positive-qemu-nonzero")
                (run-positive connection))
               (else (run-mutation connection mode))))))
         (lambda ()
           (when connection (close-port connection))
           (close-port listener)
           (when (file-exists? path) (delete-file path))))
       (if (string=? mode "positive-qemu-nonzero") 19 0)))
    (_ (fail "expected MODE QEMU-ARGUMENT..."))))

(exit
 (catch #t
   (lambda () (main (cdr (command-line))))
   (lambda (key . arguments)
     (fail "~s ~s" key arguments))))
