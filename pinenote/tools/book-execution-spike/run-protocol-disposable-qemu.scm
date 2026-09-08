#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; Fixed entry point for the protocol-specific isolated module view.
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
