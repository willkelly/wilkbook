#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; CLI entry point; disposable-qemu.scm contains the trusted implementation.
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (disposable-qemu))

(umask #o077)
(sigaction SIGCHLD SIG_DFL)
(for-each
 (lambda (signal-number)
   (sigaction signal-number
              (lambda (received)
                (note-disposable-qemu-signal received))))
 (list SIGINT SIGTERM SIGHUP))
(exit (disposable-qemu-main (command-line)))
