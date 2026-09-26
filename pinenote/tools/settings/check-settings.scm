#!/usr/bin/env guile
!#
(load (string-append (dirname (current-filename)) "/audit.scm"))
(let ((args (cdr (command-line))))
  (when (> (length args) 1) (error "usage: check-settings.scm [REPO_ROOT]"))
  (exit (audit (if (null? args)
                  (canonicalize-path (string-append (dirname (current-filename)) "/../../.."))
                  (car args)))))
