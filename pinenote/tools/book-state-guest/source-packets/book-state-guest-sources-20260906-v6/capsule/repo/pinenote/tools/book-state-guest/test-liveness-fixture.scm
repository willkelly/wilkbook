;;; Host-only blocking fixtures executed beneath the accepted outer process
;;; guardian.  None of these modes is guest production code.
(use-modules (book-state-guest-authority)
             (book-state-protocol)
             (book-state-session-delegate)
             (ice-9 match)
             (ice-9 threads))

(define (die message . arguments)
  (format (current-error-port) "fixture failure: ~a~%"
          (apply format #f message arguments))
  (force-output (current-error-port))
  (exit 2))

(define (emit line)
  (display line)
  (newline)
  (force-output))

(define (now-seconds)
  (/ (get-internal-real-time) internal-time-units-per-second 1.0))

(define (write-process-record path descendants)
  (call-with-output-file path
    (lambda (port)
      (write `((process-group . ,(getpgrp))
               (direct-process . ,(getpid))
               (descendants . ,descendants))
             port)
      (newline port)))
  (chmod path #o600))

(define (ignore-outer-term!)
  ;; Force the accepted guardian through TERM grace to SIGKILL.  This is a
  ;; process-local test fixture, never a guest/service signal policy.
  (sigaction SIGTERM SIG_IGN))

(define (loop-forever)
  (let loop () (sleep 60) (loop)))

(define (run-never-stop record)
  (write-process-record record '())
  (emit "NEVER-STOP-CHILD-ENTERED")
  (loop-forever))

(define (run-blocking-waitpid record)
  (ignore-outer-term!)
  (let ((child (primitive-fork)))
    (if (zero? child)
        (begin (ignore-outer-term!) (loop-forever))
        (begin
          (write-process-record record (list child))
          (emit "INTENTIONAL-BLOCKING-WAITPID-ENTERED")
          ;; Deliberately model the exact v2 class which no in-process clock can
          ;; preempt.  The tested outer guardian must terminate this whole group.
          (waitpid child WUNTRACED)
          (emit "FORBIDDEN-WAITPID-RETURN")))))

(define (run-blocked-delegate-close record close-mode)
  (ignore-outer-term!)
  (let ((storage-mutex (make-mutex))
        (entered-mutex (make-mutex))
        (entered-condition (make-condition-variable))
        (entered? #f))
    (define (note-entered!)
      (with-mutex entered-mutex
        (set! entered? #t)
        (broadcast-condition-variable entered-condition)))
    (define (wait-entered!)
      (with-mutex entered-mutex
        (let loop ()
          (unless entered?
            (wait-condition-variable entered-condition entered-mutex)
            (loop)))))
    (define (open-binding owner)
      (make-state-endpoint-binding
       owner (vector 'blocking-fixture-grant)
       "blocking_fixture_grant" 1 'read-write))
    (define (run-operation operation)
      ;; The worker owns the mock backend mutex exactly as an arbitrary blocked
      ;; storage callback can own the real store mutex.
      (lock-mutex storage-mutex)
      (note-entered!)
      (loop-forever))
    (define (revoke-binding binding)
      (if (eq? close-mode 'revoke)
          (begin
            (emit "DELEGATE-REVOKE-WAIT-ENTERED")
            (lock-mutex storage-mutex)
            (unlock-mutex storage-mutex)
            'revoked)
          (begin
            (emit "DELEGATE-REVOKE-RETURNED")
            'revoked)))
    (let* ((factory
            (make-book-state-delegate-factory
             open-binding run-operation revoke-binding))
           (delegate
            (open-book-state-session-delegate factory '(fixture-owner)))
           (ready (book-state-session-delegate-ready-message delegate)))
      (start-book-state-session-delegate! delegate
                                          (lambda arguments #t))
      (announce-book-state-session-delegate! delegate ready)
      (dispatch-book-state-session-message!
       delegate
       (make-state-read-message
        (state-ready-message-grant-handle ready)
        (state-ready-message-grant-generation ready)))
      (wait-entered!)
      (write-process-record record '())
      (emit "BLOCKED-DELEGATE-WORKER-ENTERED")
      (let ((deadline (+ (now-seconds) 0.10)))
        (let wait-for-cooperative-expiry ()
          (if (< (now-seconds) deadline)
              (begin (usleep 5000) (wait-for-cooperative-expiry))
              (catch 'book-state-guest-error
                (lambda ()
                  ((@@ (book-state-guest-authority) check-deadline!)
                   deadline "blocked storage fixture")
                  (die "expired cooperative deadline unexpectedly returned"))
                (lambda arguments
                  (emit "GUEST-COOPERATIVE-BUDGET-EXPIRED")
                  (close-book-state-session-delegate-local!
                   delegate 'fixture-deadline)
                  (unless (eq? (book-state-session-delegate-phase delegate)
                               'closing)
                    (die "delegate was not fail-closed before blocking cleanup"))
                  (emit "DELEGATE-LOCAL-CLOSE-COMPLETE")
                  (format #t "DELEGATE-CLOSE-WAIT-ENTERED mode=~a~%"
                          close-mode)
                  (force-output)
                  (finish-book-state-session-delegate-close! delegate)
                  (emit "FORBIDDEN-DELEGATE-CLOSE-RETURN")))))))))

(match (cdr (command-line))
  (("never-stop" path) (run-never-stop path))
  (("blocking-waitpid" path) (run-blocking-waitpid path))
  (("blocked-revoke" path) (run-blocked-delegate-close path 'revoke))
  (("blocked-join" path) (run-blocked-delegate-close path 'join))
  (_ (die "usage: test-liveness-fixture.scm MODE RECORD")))
