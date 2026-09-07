;;; Exact host regressions for finish-delivery -> fresh done -> EOF ordering.
(use-modules (guest-virtio-book-ui)
             (ice-9 rdelim)
             (private-control)
             (rnrs bytevectors)
             ((rnrs io ports) #:select (put-bytevector))
             (srfi srfi-64))

(let ((test-module (current-module)))
  (primitive-load (search-path %load-path "guest-book-protocol.scm"))
  (primitive-load (search-path %load-path "guest-book-interaction.scm"))
  (set-current-module test-module))

(define wait-for-ui-completion!
  (module-ref (resolve-module '(guest-book-interaction))
              'wait-for-ui-completion!))
(define write-attempt (@@ (guest-virtio-book-ui) write-attempt))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (lookup snapshot name)
  (cdr (assq name snapshot)))

(define (close-port-quietly! port)
  (when (and (port? port) (not (port-closed? port)))
    (catch 'system-error
      (lambda () (close-port port))
      (lambda arguments #f))))

(define (make-control-pair)
  (let* ((pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
         (control (adopt-book-ui-control-port! (car pair)
                                               #:require-character? #f)))
    (cons control (cdr pair))))

(define (completion-error? thunk)
  (catch 'book-execution-reader-interaction-error
    (lambda () (thunk) #f)
    (lambda arguments #t)))

(define (send-done-and-half-close! peer)
  (put-bytevector peer
                  (encode-control-line 'done 1 "ok" reader-event-kinds))
  (force-output peer)
  (shutdown peer 1))

(define (close-pair! pair)
  (close-book-ui-control! (car pair))
  (close-port-quietly! (cdr pair)))

(define (run-fresh-done-peer-case eagain-count)
  (let* ((pair (socketpair AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))
         (authority-port (car pair))
         (peer (cdr pair)))
    (force-output (current-output-port))
    (force-output (current-error-port))
    (let ((pid (primitive-fork)))
      (if (zero? pid)
        (begin
          (close-port-quietly! authority-port)
          (let ((line (read-line peer)))
            (unless (and (string? line) (string=? line "finish|1|"))
              (primitive-exit 2)))
          (send-done-and-half-close! peer)
          (close-port-quietly! peer)
          (primitive-exit 0))
        (let ((control #f)
              (attempts 0)
              (completed? #f)
              (real-write (write-attempt)))
          (close-port-quietly! peer)
          (dynamic-wind
            (lambda ()
              (set! control
                    (adopt-book-ui-control-port!
                     authority-port #:require-character? #f)))
            (lambda ()
              (parameterize
                  ((write-attempt
                    (lambda arguments
                      (set! attempts (+ attempts 1))
                      (if (<= attempts eagain-count)
                          (values -1 EAGAIN)
                          (apply real-write arguments)))))
                (set! completed?
                      (wait-for-ui-completion!
                       control (+ (now-seconds) 2.0)))))
            (lambda () (close-book-ui-control! control)))
          (let ((status (cdr (waitpid pid))))
            (and completed?
                 (= (status:exit-val status) 0)
                 (> attempts eagain-count))))))))

(test-begin "guest-book-interaction-completion")

(let* ((pair (make-control-pair))
       (control (car pair))
       (peer (cdr pair)))
  ;; Exact reviewer reproduction: DONE and EOF are already readable while
  ;; every FINISH write would block.
  (send-done-and-half-close! peer)
  (test-assert "prequeued done plus EOF cannot erase an EAGAIN-blocked finish"
    (parameterize ((write-attempt (lambda arguments (values -1 EAGAIN))))
      (completion-error?
       (lambda ()
         (wait-for-ui-completion! control (+ (now-seconds) 1.0))))))
  (test-equal "prequeued done leaves the finish ticket undelivered"
    '(1 0 1)
    (let ((snapshot (book-ui-control-snapshot control)))
      (list (lookup snapshot 'enqueued-frames)
            (lookup snapshot 'delivered-frames)
            (lookup snapshot 'queued-frames))))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (peer (cdr pair))
       (written 0)
       (attempts 0))
  (send-done-and-half-close! peer)
  (test-assert "done plus EOF after a partial finish write is rejected"
    (parameterize
        ((write-attempt
          (lambda (_fd _source _offset count)
            (set! attempts (+ attempts 1))
            (if (= attempts 1)
                (let ((amount (min count 2)))
                  (set! written (+ written amount))
                  (values amount 0))
                (values -1 EAGAIN)))))
      (completion-error?
       (lambda ()
         (wait-for-ui-completion! control (+ (now-seconds) 1.0))))))
  (test-assert "partial finish bytes are not full-frame delivery"
    (and (= written 2)
         (not (book-ui-command-delivered? control 1))))
  (close-pair! pair))

(let* ((pair (make-control-pair))
       (control (car pair))
       (peer (cdr pair)))
  ;; No DONE is present: EOF itself must not turn queue invalidation into proof.
  (shutdown peer 1)
  (test-assert "EOF with an unsent finish is rejected"
    (parameterize ((write-attempt (lambda arguments (values -1 EAGAIN))))
      (completion-error?
       (lambda ()
         (wait-for-ui-completion! control (+ (now-seconds) 1.0))))))
  (test-equal "EOF may clear bytes but cannot advance delivered-frame count"
    '(#f #t 0 1 0)
    (let ((snapshot (book-ui-control-snapshot control)))
      (list (lookup snapshot 'open)
            (lookup snapshot 'eof)
            (lookup snapshot 'queued-frames)
            (lookup snapshot 'enqueued-frames)
            (lookup snapshot 'delivered-frames))))
  (close-pair! pair))

(test-assert "fully written finish followed by fresh done and EOF passes"
  (run-fresh-done-peer-case 0))

(test-assert "would-block without EOF may flush, then fresh done and EOF pass"
  (run-fresh-done-peer-case 2))

(let ((runner (test-runner-current)))
  (test-end "guest-book-interaction-completion")
  (exit (zero? (test-runner-fail-count runner))))
