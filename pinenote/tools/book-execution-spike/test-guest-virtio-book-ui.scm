(use-modules (guest-virtio-book-ui)
             (private-control)
             (rnrs bytevectors)
             (srfi srfi-64))

(define read-attempt (@@ (guest-virtio-book-ui) read-attempt))
(define write-attempt (@@ (guest-virtio-book-ui) write-attempt))

(define (bytevector-slice source start end)
  (let* ((length (- end start))
         (result (make-bytevector length)))
    (bytevector-copy! source start result 0 length)
    result))

(define (bytevector-append . values)
  (let* ((length (apply + (map bytevector-length values)))
         (result (make-bytevector length)))
    (let loop ((remaining values) (offset 0))
      (unless (null? remaining)
        (let* ((value (car remaining))
               (count (bytevector-length value)))
          (bytevector-copy! value 0 result offset count)
          (loop (cdr remaining) (+ offset count)))))
    result))

(define (make-control-pair)
  (let* ((pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
         (control (adopt-book-ui-control-port! (car pair)
                                               #:require-character? #f)))
    (cons control (cdr pair))))

(define (close-pair! pair)
  (close-book-ui-control! (car pair))
  (let ((peer (cdr pair)))
    (unless (port-closed? peer) (close-port peer))))

(define (lookup snapshot name)
  (cdr (assq name snapshot)))

(define (channel-error? thunk)
  (catch #t
    (lambda () (thunk) #f)
    (lambda (key . arguments)
      (memq key '(book-interaction-ui-channel-error
                  book-interaction-control-error)))))

(define (scripted-reader chunks)
  (let ((remaining chunks))
    (lambda (_fd target count)
      (if (null? remaining)
          (values -1 EAGAIN)
          (let ((item (car remaining)))
            (set! remaining (cdr remaining))
            (if (pair? item)
                (values (car item) (cdr item))
                (let ((length (bytevector-length item)))
                  (when (> length count)
                    (error "scripted read exceeds requested allowance"))
                  (bytevector-copy! item 0 target 0 length)
                  (values length 0))))))))

(test-begin "guest-virtio-book-ui")

(test-equal "fixed named port"
  '("org.wilkbook.book-interaction"
    "/dev/virtio-ports/org.wilkbook.book-interaction")
  (list book-ui-port-name book-ui-port-path))

(let* ((pair (make-control-pair))
       (control (car pair))
       (fd (book-ui-control-fd control)))
  (test-assert "adopted descriptor is nonblocking and close-on-exec"
    (and (= (logand (fcntl fd F_GETFL) O_NONBLOCK) O_NONBLOCK)
         (= (logand (fcntl fd F_GETFD) FD_CLOEXEC) FD_CLOEXEC)))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (ready (encode-control-line 'ready 1 "dialog" reader-event-kinds))
       (submit (encode-control-line 'submit 1 "élan λ" reader-event-kinds))
       (both (bytevector-append ready submit)))
  (parameterize
      ((read-attempt
        (scripted-reader
         (list (bytevector-slice both 0 3)
               (bytevector-slice both 3 (bytevector-length both))))))
    (test-equal "fragment before a line makes bounded progress"
      'progress (pump-book-ui-input! control))
    (test-equal "fragmented first frame decodes"
      '(ready 1 "dialog") (pump-book-ui-input! control))
    (test-equal "coalesced second frame remains for the next pump"
      '(submit 1 "élan λ") (pump-book-ui-input! control)))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (sink (make-bytevector 0))
       (first-ticket #f)
       (second-ticket #f)
       (expected
        (bytevector-append
         (encode-control-line 'input-update 1 "Ada" reader-command-kinds)
         (encode-control-line 'present 1 "GUILE[3]:ADA"
                              reader-command-kinds))))
  (set! first-ticket
        (queue-book-ui-command! control 'input-update 1 "Ada"))
  (set! second-ticket
        (queue-book-ui-command! control 'present 1 "GUILE[3]:ADA"))
  (test-equal "queued commands receive monotonic delivery tickets"
    '(1 2) (list first-ticket second-ticket))
  (parameterize
      ((write-attempt
        (lambda (_fd source offset count)
          (let* ((written (min count 2))
                 (piece (bytevector-slice source offset (+ offset written))))
            (set! sink (bytevector-append sink piece))
            (values written 0)))))
    (let loop ()
      (unless (eq? (car (pump-book-ui-output! control)) 'drained)
        (loop))))
  (test-equal "partial writes preserve every exact encoded byte" expected sink)
  (test-equal "partial-write drain clears both queue bounds"
    '(0 0)
    (let ((snapshot (book-ui-control-snapshot control)))
      (list (lookup snapshot 'queued-frames)
            (lookup snapshot 'queued-bytes))))
  (test-assert "delivery tickets advance only through complete frame writes"
    (and (book-ui-command-delivered? control first-ticket)
         (book-ui-command-delivered? control second-ticket)
         (= (lookup (book-ui-control-snapshot control) 'delivered-frames) 2)))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (attempts 0))
  (queue-book-ui-command! control 'finish 1 "")
  (parameterize
      ((write-attempt
        (lambda arguments
          (set! attempts (+ attempts 1))
          (if (= attempts 1)
              (values -1 EINTR)
              (values -1 EAGAIN)))))
    (test-equal "write EINTR is finite and preserves the queue"
      'interrupted (car (pump-book-ui-output! control)))
    (test-equal "write EAGAIN is finite and preserves the queue"
      'would-block (car (pump-book-ui-output! control))))
  (test-equal "interrupted/would-block output retained"
    1 (lookup (book-ui-control-snapshot control) 'queued-frames))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (attempts 0))
  (parameterize
      ((read-attempt
        (lambda arguments
          (set! attempts (+ attempts 1))
          (case attempts
            ((1) (values -1 EINTR))
            ((2) (values -1 EAGAIN))
            (else (values 0 0))))))
    (test-equal "read EINTR is finite" 'interrupted
      (pump-book-ui-input! control))
    (test-equal "read EAGAIN is finite" 'would-block
      (pump-book-ui-input! control))
    (test-equal "clean EOF is explicit" 'eof
      (pump-book-ui-input! control)))
  (test-assert "EOF invalidates and clears the exact control owner"
    (let ((snapshot (book-ui-control-snapshot control)))
      (and (not (lookup snapshot 'open))
           (lookup snapshot 'eof)
           (zero? (lookup snapshot 'input-bytes))
           (zero? (lookup snapshot 'queued-frames)))))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair)))
  (test-assert "malformed control frame fails closed"
    (parameterize
        ((read-attempt
          (scripted-reader (list (string->utf8 "ready|1|GG\n")))))
      (channel-error? (lambda () (pump-book-ui-input! control)))))
  (test-assert "malformed control frame invalidates channel"
    (not (book-ui-control-open? control)))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (overlong (make-bytevector (+ max-control-line-bytes 1) 97))
       (chunks (list (bytevector-slice overlong 0 4096)
                     (bytevector-slice overlong 4096 8192)
                     (bytevector-slice overlong 8192
                                       (bytevector-length overlong)))))
  (test-assert "unterminated overlong control frame fails closed"
    (parameterize ((read-attempt (scripted-reader chunks)))
      (pump-book-ui-input! control)
      (pump-book-ui-input! control)
      (channel-error? (lambda () (pump-book-ui-input! control)))))
  (test-assert "overlong control frame invalidates channel"
    (not (book-ui-control-open? control)))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair)))
  (do ((index 0 (+ index 1)))
      ((= index max-control-queue-frames))
    (queue-book-ui-command! control 'finish 1 ""))
  (test-assert "ninth output frame is rejected at the queue bound"
    (channel-error?
     (lambda () (queue-book-ui-command! control 'finish 1 ""))))
  (test-equal "queue rejection preserves the bounded eight frames"
    max-control-queue-frames
    (lookup (book-ui-control-snapshot control) 'queued-frames))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (written 0))
  (queue-book-ui-command! control 'present 1 (make-string 4096 #\x))
  (parameterize
      ((write-attempt
        (lambda (_fd _source _offset count)
          (set! written (+ written count))
          (values count 0))))
    (test-equal "one output pump stops at its byte budget"
      'budget (car (pump-book-ui-output! control))))
  (test-equal "one output pump writes exactly 4096 bytes" 4096 written)
  (close-pair! pair))

(let ((runner (test-runner-current)))
  (test-end "guest-virtio-book-ui")
  (exit (zero? (test-runner-fail-count runner))))
