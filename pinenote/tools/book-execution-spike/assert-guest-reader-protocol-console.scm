#!/usr/bin/env -S guile --no-auto-compile -s
!#
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (ice-9 match)
             (reader-protocol-console-assertions))

(exit
 (catch #t
   (lambda ()
     (match (cdr (command-line))
       ((path)
        (assert-reader-protocol-console-file path)
        (display "GUEST-READER-PROTOCOL-ASSERTIONS=PASS\n")
        0)
       (_
        (format (current-error-port) "usage: ~a CONSOLE-LOG\n"
                (car (command-line)))
        2)))
   (lambda (key . arguments)
     (format (current-error-port)
             "GUEST-READER-PROTOCOL-ASSERTIONS=FAIL key=~s details=~s\n"
             key arguments)
     1)))
