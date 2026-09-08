(use-modules (srfi srfi-64) (two-boot sequential))

(test-begin "two-boot-fail-stop")
(let ((calls '()))
  (test-assert "boot-1 failure is propagated"
    (catch 'fixture-boot-one-failed
      (lambda ()
        (call-with-two-sequential-boots
         'initial
         (lambda (index prior)
           (set! calls (append calls (list (list index prior))))
           (throw 'fixture-boot-one-failed)))
        #f)
      (lambda _ #t)))
  (test-equal "boot 2 is unreachable after boot-1 failure"
    '((1 initial)) calls))
(let ((calls '()))
  (call-with-values
      (lambda ()
        (call-with-two-sequential-boots
         'initial
         (lambda (index prior)
           (set! calls (append calls (list (list index prior))))
           (if (= index 1) 'after-one 'after-two))))
    (lambda (first second)
      (test-equal "both successful results are retained"
        '(after-one after-two) (list first second))))
  (test-equal "successful boots are strictly sequential"
    '((1 initial) (2 after-one)) calls))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "two-boot-fail-stop")
(exit (if (zero? failures) 0 1))
