;;; Print one derivation's complete requisites through the pinned store API.
(use-modules (guix store)
             (srfi srfi-1))

(unless (= (length (command-line)) 2)
  (error "usage: query-requisites.scm /gnu/store/ROOT.drv"))
(define root (cadr (command-line)))
(unless (and (string-prefix? "/gnu/store/" root)
             (string-suffix? ".drv" root)
             (file-exists? root))
  (error "root is not an existing store derivation" root))

(with-store store
  (let ((paths (sort (delete-duplicates (requisites store (list root))) string<?)))
    (for-each (lambda (path) (display path) (newline)) paths)
    (format (current-error-port) "REQUISITES count=~a root=~a~%"
            (length paths) root)))
