#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; CLI entry point; oci-bundle.scm contains the trusted implementation.
(add-to-load-path (dirname (canonicalize-path (car (command-line)))))
(use-modules (oci-bundle))
(exit (oci-bundle-main (command-line)))
