#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Separate reader entry; the accepted non-reader entry remains unchanged.
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (disposable-qemu)
             (disposable-reader-qemu))

(umask #o077)
(sigaction SIGCHLD SIG_DFL)
(for-each
 (lambda (signal-number)
   (sigaction signal-number
              (lambda (received)
                (note-disposable-qemu-signal received))))
 (list SIGINT SIGTERM SIGHUP))
(exit (disposable-reader-qemu-main (command-line)))
