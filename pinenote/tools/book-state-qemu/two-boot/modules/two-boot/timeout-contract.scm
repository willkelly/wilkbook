;;; Executable form of the frozen two-boot timeout boundary.
(define-module (two-boot timeout-contract)
  #:use-module (ice-9 match)
  #:export (guest-cooperative-budget-seconds
            outer-hard-vm-deadline-seconds
            owned-process-term-grace-seconds
            owned-process-kill-reap-seconds
            one-boot-owner-hard-deadline-seconds
            post-owner-cleanup-observation-seconds
            two-boot-timeout-contract
            mandatory-outer-timeout-arguments
            bind-mandatory-outer-timeout-arguments
            assert-mandatory-outer-timeout-arguments))

(define guest-cooperative-budget-seconds 300)
(define outer-hard-vm-deadline-seconds 360)
(define owned-process-term-grace-seconds 5)
(define owned-process-kill-reap-seconds 5)
(define one-boot-owner-hard-deadline-seconds 420)
(define post-owner-cleanup-observation-seconds 12)

(define two-boot-timeout-contract
  `((schema . 1)
    (guest-cooperative-budget-seconds . ,guest-cooperative-budget-seconds)
    (outer-hard-vm-deadline-seconds . ,outer-hard-vm-deadline-seconds)
    (owned-process-term-grace-seconds . ,owned-process-term-grace-seconds)
    (owned-process-kill-reap-seconds . ,owned-process-kill-reap-seconds)
    (one-boot-owner-hard-deadline-seconds
     . ,one-boot-owner-hard-deadline-seconds)
    (post-owner-cleanup-observation-seconds
     . ,post-owner-cleanup-observation-seconds)
    (maximum-sequential-boots . 2)
    (timeout-disposition . fail-preserve-never-launch-next-boot)))

(define mandatory-outer-timeout-arguments
  (list "--timeout-seconds"
        (number->string outer-hard-vm-deadline-seconds)
        "--term-grace-seconds"
        (number->string owned-process-term-grace-seconds)))

(define (option-values argv name)
  (let loop ((rest argv) (result '()))
    (match rest
      (() (reverse result))
      ((head) (reverse result))
      ((head value tail ...)
       (loop (if (string=? head name) tail (cdr rest))
             (if (string=? head name) (cons value result) result))))))

(define (assert-mandatory-outer-timeout-arguments argv)
  (unless (and (list? argv)
               (equal? (option-values argv "--timeout-seconds") '("360"))
               (equal? (option-values argv "--term-grace-seconds") '("5")))
    (throw 'book-state-two-boot-timeout-error
           "each boot requires exactly --timeout-seconds 360 and --term-grace-seconds 5"))
  #t)

(define (bind-mandatory-outer-timeout-arguments base-argv)
  (unless (and (list? base-argv)
               (null? (option-values base-argv "--timeout-seconds"))
               (null? (option-values base-argv "--term-grace-seconds")))
    (throw 'book-state-two-boot-timeout-error
           "base argv must not supply or override the mandatory timeout pair"))
  (let ((result (append base-argv mandatory-outer-timeout-arguments)))
    (assert-mandatory-outer-timeout-arguments result)
    result))
