;;; A successful first analysis followed by a failing second analysis.
(use-modules (srfi srfi-13))
(display "fixture analyzer output before exit\n")
(exit (if (string-suffix? "refresh-triggers.py" (cadr (command-line))) 23 0))
