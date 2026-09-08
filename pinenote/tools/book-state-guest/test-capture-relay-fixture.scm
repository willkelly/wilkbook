;;; Native child-output fixture for the finalized-capture relay model.
;;; This is host-only: it does not invoke runsc, gVisor, QEMU, or ARM code.
(use-modules (ice-9 binary-ports)
             (rnrs bytevectors))

(define (usage)
  (format (current-error-port) "usage: fixture SCENARIO LANGUAGE~%")
  (exit 2))

(unless (= (length (command-line)) 3) (usage))
(define scenario (cadr (command-line)))
(define language (caddr (command-line)))
(unless (member language '("guile" "python")) (usage))

(define (boundary-marker selected-language result tail)
  (format #f
          "BOOK_STATE_SANDBOX_BOUNDARY: language=~a result=~a ~a"
          selected-language result tail))

(define exact-tail
  "storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3")
(define exact-marker (boundary-marker language "pass" exact-tail))
(define other-language (if (string=? language "guile") "python" "guile"))

(define (line text)
  (display text)
  (newline))

(line "MODEL-RUNSC-STDOUT diagnostic-before-boundary")
(cond
 ((string=? scenario "valid")
  (line exact-marker))
 ((string=? scenario "missing") #t)
 ((string=? scenario "wrong-language")
  (line (boundary-marker other-language "pass" exact-tail)))
 ((string=? scenario "duplicate")
  (line exact-marker)
  (line exact-marker))
 ((string=? scenario "extra")
  (line exact-marker)
  (line (string-append "quoted-record=\"" exact-marker "\"")))
 ((string=? scenario "failure-record")
  (line (boundary-marker language "fail" exact-tail)))
 ((string=? scenario "malformed")
  (line (boundary-marker
         language "pass"
         "storage-mount=absent ui-transport=absent book-session-fd=3")))
 ((string=? scenario "truncated")
  (display "BOOK_STATE_SANDBOX_BOUNDARY"))
 ((string=? scenario "invalid-utf8")
  (line exact-marker)
  (put-u8 (current-output-port) #xff))
 ((string=? scenario "overflow")
  (line exact-marker)
  (put-bytevector (current-output-port)
                  (make-bytevector (+ (* 4 1024 1024) 1) 120)))
 ((string=? scenario "stderr-overflow")
  (line exact-marker)
  (put-bytevector (current-error-port)
                  (make-bytevector (+ (* 4 1024 1024) 1) 121)))
 ((string=? scenario "nonzero")
  (line exact-marker))
 (else (usage)))
(unless (string=? scenario "truncated")
  (line "BOOK_STATE_READER_JOIN_BOOK: model-book-finished"))
(force-output)
(exit (if (string=? scenario "nonzero") 7 0))
