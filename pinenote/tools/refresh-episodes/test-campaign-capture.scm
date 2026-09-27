;;; Offline transport + report integration tests; no QEMU or guest required.
;;; Run: guile --no-auto-compile -s test-campaign-capture.scm
(use-modules (ice-9 textual-ports) (ice-9 format) (srfi srfi-13)
             (rnrs bytevectors) ((rnrs io ports) #:select (put-bytevector call-with-port)))
(define here (dirname (canonicalize-path (car (command-line)))))
(load (string-append here "/campaign-report.scm"))
(define work (string-append here "/build/capture-test-" (number->string (getpid))))
(unless (file-exists? (string-append here "/build")) (mkdir (string-append here "/build")))
(mkdir work)
(define failures 0)
(define checks 0)
(define (check name ok)
  (set! checks (+ checks 1))
  (unless ok (set! failures (+ failures 1)))
  (format #t "~a ~a~%" (if ok "PASS" "FAIL") name))
(define (refuses thunk)
  (catch #t (lambda () (thunk) #f) (lambda _ #t)))
(define (text path) (call-with-input-file path get-string-all))
(define (put path s) (call-with-output-file path (lambda (p) (display s p))))
(define source (string-append here "/fixtures/context.log"))
(define capture (string-append work "/harvest.txt"))
(define ledger (string-append work "/action-ledger.txt"))
(put ledger "90.0 PLAN-BEGIN fixture\n99.9 MARK possible-input\n100.0 TAP-DOWN 10,20\n101.0 PLAN-END -\n")
(checked-command (list "base64" source) (string-append work "/encoded"))
(define encoded (text (string-append work "/encoded")))
(define prefix
  (format #f "shell echo: echo $s-LOG-BEGIN~%WBCAMP-HOSTBEFORE WBCAMP-GUESTCLOCK 199.0~%WBCAMP-GUESTCLOCK 200.0~%WBCAMP-HOSTAT WBCAMP-GUESTCLOCK 200.0~%WBCAMP-LOGSTAT ~a ~a~%WBCAMP-LOG-BEGIN~%"
          (stat:size (stat source)) (sha256 source)))
(define complete (string-append prefix encoded "WBCAMP-LOG-END\n# "))
(put capture complete)
(check "complete capture validates"
       (not (refuses (lambda () (validate-harvest capture work)))))
(check "whole UTF-8 context log preserved byte-for-byte"
       (string=? (sha256 source) (sha256 (string-append work "/reader-session.log"))))
(check "clock interval and scope retained"
       (let ((s (text (string-append work "/capture-validation.txt"))))
         (and (string-contains s "[0.000000, 1.000000]")
              (string-contains s "campaign drift is unmeasured"))))
(check "complete capture runs both real analyzers"
       (not (refuses (lambda () (report-campaign capture work ledger here)))))
(check "both reports exist with context"
       (and (string-contains (text (string-append work "/triggers.txt")) "notebook lines")
            (string-contains (text (string-append work "/episodes.txt")) "MISSING ANTECEDENT COVERAGE")))
(check "report CLI succeeds on complete capture"
       (not (refuses (lambda ()
                       (checked-command
                        (list "guile" "--no-auto-compile" "-e" "main" "-s"
                              (string-append here "/campaign-report.scm") capture work ledger)
                        (string-append work "/cli.out"))))))

;; Terminal newline conversion must not affect decoded bytes.
(put capture (string-join (string-split complete #\newline) "\r\n"))
(check "CRLF console capture validates"
       (not (refuses (lambda () (validate-harvest capture work)))))
(put capture (string-append prefix encoded))
(check "truncated harvest without END fails"
       (refuses (lambda () (validate-harvest capture work))))
(put capture (string-append prefix (substring encoded 4) "WBCAMP-LOG-END\n"))
(check "truncated payload with END fails byte-count check"
       (refuses (lambda () (validate-harvest capture work))))
(put capture (string-append prefix "AAAA" (substring encoded 4) "WBCAMP-LOG-END\n"))
(check "same-size corruption fails SHA-256 check"
       (refuses (lambda () (validate-harvest capture work))))
(put capture (string-append prefix "console noise\n" encoded "WBCAMP-LOG-END\n"))
(check "interleaved console noise fails"
       (refuses (lambda () (validate-harvest capture work))))
(put capture "shell echo: echo $s-LOG-BEGIN; echo $s-LOG-END\n")
(check "echo-only missing harvest fails"
       (refuses (lambda () (validate-harvest capture work))))
(check "missing harvest file fails"
       (refuses (lambda () (validate-harvest (string-append work "/absent") work))))
(check "report CLI returns failure for missing harvest"
       (refuses (lambda ()
                  (checked-command
                   (list "guile" "--no-auto-compile" "-e" "main" "-s"
                         (string-append here "/campaign-report.scm")
                         (string-append work "/absent") work ledger)
                   (string-append work "/cli-failure.out")))))
(put capture (string-append complete "\nWBCAMP-LOG-END\n"))
(check "duplicate sentinel fails"
       (refuses (lambda () (validate-harvest capture work))))
;; Independently remove the clock sample rather than silently accepting offset 0.
(put capture (string-join
              (filter (lambda (line) (not (string-prefix? "WBCAMP-GUESTCLOCK " line)))
                      (string-split complete #\newline)) "\n"))
(check "missing clock sample fails"
       (refuses (lambda () (validate-harvest capture work))))
(put capture complete)
(check "first analyzer nonzero exit fails report"
       (refuses (lambda ()
                  (report-campaign capture work ledger here
                                   #:python '("guile" "--no-auto-compile" "-c" "(exit 23)" "--")))))
(check "failed first analyzer does not leave stale trigger report"
       (not (file-exists? (string-append work "/triggers.txt"))))
(check "second analyzer nonzero exit fails report"
       (refuses (lambda ()
                  (report-campaign capture work ledger here
                                   #:python (list "guile" "--no-auto-compile" "-s"
                                                  (string-append here "/fixtures/failing-analyzer.scm"))))))
(check "failing analyzer output is retained"
       (string-contains (text (string-append work "/triggers.txt")) "fixture analyzer output"))
(check "missing interpreter fails report"
       (refuses (lambda () (report-campaign capture work ledger here #:python '("/nonexistent/python")))))

;; Arbitrary log bytes including CR, NUL, UTF-8 and a final partial line survive.
(let ((binary (string-append work "/binary-source")))
  (call-with-port (open-file binary "wb")
    (lambda (p) (put-bytevector p (u8-list->bytevector '(65 13 10 0 195 169 90)))))
  (checked-command (list "base64" binary) (string-append work "/binary-encoded"))
  (put capture
       (format #f "WBCAMP-HOSTBEFORE WBCAMP-GUESTCLOCK 1.0~%WBCAMP-GUESTCLOCK 2.0~%WBCAMP-HOSTAT WBCAMP-GUESTCLOCK 1.5~%WBCAMP-LOGSTAT 7 ~a~%WBCAMP-LOG-BEGIN~%~aWBCAMP-LOG-END~%"
               (sha256 binary) (text (string-append work "/binary-encoded"))))
  (validate-harvest capture work)
  (check "binary bytes and unterminated final line survive"
         (string=? (sha256 binary) (sha256 (string-append work "/reader-session.log")))))
(format #t "~a checks; ~a failures; artifacts: ~a~%" checks failures work)
(exit (if (zero? failures) 0 1))
