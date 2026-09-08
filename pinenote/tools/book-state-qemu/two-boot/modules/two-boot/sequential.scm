;;; Pure fail-stop sequencing seam for exactly two fresh boot lifetimes.
(define-module (two-boot sequential)
  #:export (call-with-two-sequential-boots))

(define (call-with-two-sequential-boots initial-state launch)
  (unless (procedure? launch)
    (throw 'book-state-two-boot-sequence-error
           "boot launcher is not a procedure"))
  (let* ((after-first (launch 1 initial-state))
         ;; Scheme's let* makes this expression unreachable if boot 1 raises.
         (after-second (launch 2 after-first)))
    (values after-first after-second)))
