(use-modules (owner-control) (rnrs bytevectors) (srfi srfi-64))

(test-begin "workbench-device-owner-control")
(define runner (test-runner-current))

(define (feed! control text) (owner-control-feed! control (string->utf8 text)))
(define (rejects? thunk)
  (catch 'owner-control-error (lambda () (thunk) #f) (lambda _ #t)))
(define (stopping-owner)
  (let ((control (make-owner-control)))
    (feed! control "ready\n")
    (owner-control-stop! control)
    control))

(let ((control (make-owner-control)))
  (test-assert "no delivery before ready" (not (owner-control-can-deliver? control)))
  (feed! control "rea")
  (test-assert "partial ready is not ready" (not (owner-control-can-deliver? control)))
  (feed! control "dy\n")
  (test-assert "ready admits delivery" (owner-control-can-deliver? control))
  (owner-control-stop! control)
  (test-assert "stop immediately retires delivery" (not (owner-control-can-deliver? control)))
  (feed! control "clean\n")
  (test-assert "clean alone is insufficient" (not (owner-control-cleanup-complete? control)))
  (owner-control-exited! control 'exit 0)
  (test-assert "clean plus wait proves owner cleanup" (owner-control-cleanup-complete? control))
  (test-assert "clean plus zero exit cannot pass before terminal drain"
    (not (owner-control-preview-eligible? control)))
  (owner-control-eof! control)
  (test-assert "zero exit eligible after requested stop and EOF"
    (owner-control-preview-eligible? control)))

(let ((control (stopping-owner)))
  (owner-control-exited! control 'exit 0)
  (feed! control "clean\n")
  (test-assert "exit before final drain cannot authorize preview"
    (not (owner-control-preview-eligible? control)))
  (owner-control-eof! control)
  (test-assert "exit-before-drain ordering succeeds after valid EOF"
    (owner-control-preview-eligible? control)))

(let ((control (make-owner-control)))
  (owner-control-stop! control)
  (owner-control-exited! control 'exit 0)
  (feed! control "ready\nclean\n")
  (test-assert "coalesced receipts after exit still require terminal drain"
    (not (owner-control-preview-eligible? control)))
  ;; Model a separate read discovering trailing bytes after the caller already
  ;; observed clean and exit zero. Eligibility must never become true meanwhile.
  (test-assert "later read rejects trailing receipt bytes"
    (rejects? (lambda () (feed! control "x"))))
  (test-assert "trailing bytes permanently refuse preview"
    (not (owner-control-preview-eligible? control)))
  (test-assert "EOF cannot repair invalid terminal drain"
    (rejects? (lambda () (owner-control-eof! control))))
  (test-assert "invalid drain retires cleanup evidence"
    (not (owner-control-cleanup-complete? control))))

;; Exercise every fragmentation boundary of the real wire records, including
;; coalescing. A pre-read stop can race readiness during startup cancellation.
(let ((wire "ready\nclean\n"))
  (do ((split 0 (+ split 1))) ((> split (string-length wire)))
    (let ((control (make-owner-control)))
      (owner-control-stop! control)
      (feed! control (substring wire 0 split))
      (feed! control (substring wire split))
      (owner-control-eof! control)
      (test-assert "EOF alone cannot substitute for waited terminal status"
        (not (owner-control-preview-eligible? control)))
      (owner-control-exited! control 'exit 0)
      (test-assert (format #f "fragmentation boundary ~a" split)
        (owner-control-cleanup-complete? control))
      (test-assert "drained fragmented stream permits successful owner verdict"
        (owner-control-preview-eligible? control)))))

(for-each
 (lambda (outcome)
   (let ((control (stopping-owner)))
     ;; Exit observed before draining clean must still establish disposal.
     (apply owner-control-exited! control outcome)
     (feed! control "clean\n")
     (owner-control-eof! control)
     (test-assert "nonzero/signal cleanup is distinct from success"
       (and (owner-control-cleanup-complete? control)
            (not (owner-control-preview-eligible? control))))))
 '((exit 1) (exit 137) (signal 9)))

(let ((control (make-owner-control)))
  (feed! control "clean\n")
  (owner-control-exited! control 'exit 1)
  (owner-control-eof! control)
  (test-assert "preparation failure can prove cleanup"
    (owner-control-cleanup-complete? control))
  (test-assert "preparation failure cannot pass preview"
    (not (owner-control-preview-eligible? control))))

(for-each
 (lambda (first)
   (let ((control (make-owner-control)))
     (feed! control "ready\n")
     (if (eq? first 'clean)
         (feed! control "clean\n")
         (owner-control-exited! control 'exit 0))
     (owner-control-stop! control)
     (if (eq? first 'clean)
         (owner-control-exited! control 'exit 0)
         (feed! control "clean\n"))
     (owner-control-eof! control)
     (test-assert "unsolicited termination never becomes preview success"
       (and (owner-control-cleanup-complete? control)
            (not (owner-control-preview-eligible? control))))))
 '(clean exit))

(for-each
 (lambda (wire)
   (let ((control (make-owner-control)))
     (test-assert (format #f "reject malformed receipt ~s" wire)
       (rejects? (lambda () (feed! control wire))))
     (test-assert "malformed stream permanently retires delivery"
       (not (owner-control-can-deliver? control)))
     (test-assert "later clean cannot repair malformed stream"
       (rejects? (lambda () (feed! control "clean\n"))))))
 '("ready\nready\n" "clean\nready\n" "clean\nclean\n" "ready\r\n"
   "ready\nclean\nx" "READY\n" "ready\n\x00"))

(for-each
 (lambda (wire)
   (let ((control (make-owner-control)))
     (feed! control wire)
     (test-assert "EOF before complete clean fails"
       (rejects? (lambda () (owner-control-eof! control))))))
 '("" "rea" "ready\n" "ready\nclea"))

(let ((control (stopping-owner)))
  (owner-control-exited! control 'exit 0)
  (test-assert "exit alone is not cleanup" (not (owner-control-cleanup-complete? control)))
  (test-assert "duplicate terminal observation fails"
    (rejects? (lambda () (owner-control-exited! control 'exit 0)))))

(test-end "workbench-device-owner-control")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
