#!/usr/bin/env -S guile --no-auto-compile -s
!#
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (guest-console-assertions))
(exit (guest-console-assertions-main (command-line)))
