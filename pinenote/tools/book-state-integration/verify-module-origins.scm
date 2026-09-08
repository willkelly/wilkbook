;;; Assert that every project module resolved from the authenticated snapshot.
(use-modules (ice-9 match))

(define (fail message . details) (error message details))

(let ((arguments (cdr (command-line))))
  (unless (= (length arguments) 2)
    (fail "usage: verify-module-origins.scm SNAPSHOT-ROOT COMPILED-ROOT"))
  (let* ((root (canonicalize-path (car arguments)))
         (compiled-root (canonicalize-path (cadr arguments)))
         (expected
          '(((book-protocol)
             "accepted-inputs/book-protocol/book-protocol.scm"
             "book-protocol.go")
            ((book-protocol blocking-io)
             "accepted-inputs/book-protocol/book-protocol/blocking-io.scm"
             "book-protocol/blocking-io.go")
            ((book-state) "accepted-inputs/backend/book-state.scm"
             "book-state.go")
            ((book-state-operation-id)
             "accepted-inputs/state-protocol/book-state-operation-id.scm"
             "book-state-operation-id.go")
            ((book-state-protocol)
             "accepted-inputs/state-protocol/book-state-protocol.scm"
             "book-state-protocol.go")
            ((book-state-backend-adapter)
             "accepted-inputs/state-protocol/book-state-backend-adapter.scm"
             "book-state-backend-adapter.go")
            ((book-state-session-delegate)
             "accepted-inputs/session/book-state-session-delegate.scm"
             "book-state-session-delegate.go")
            ((book-session) "accepted-inputs/session/book-session.scm"
             "book-session.go")
            ((book-state-integration) "integration/book-state-integration.scm"
             "book-state-integration.go"))))
    (for-each
     (lambda (entry)
       (let* ((name (car entry))
              (source-relative (cadr entry))
              (compiled-relative (caddr entry))
              (wanted-source (string-append root "/" source-relative))
              (wanted-compiled
               (string-append compiled-root "/" compiled-relative))
              (loaded (resolve-interface name))
              (actual-compiled
               (search-path %load-compiled-path compiled-relative)))
         (unless (module? loaded)
           (fail "module interface did not resolve" name))
         (unless (and actual-compiled
                      (file-exists? wanted-source)
                      (string=? (canonicalize-path actual-compiled)
                                wanted-compiled))
           (fail "module compiled origin escaped authenticated root"
                 name wanted-source wanted-compiled actual-compiled))
         (format #t "MODULE-ORIGIN: ~s authenticated-source=~a compiled=~a~%"
                 name wanted-source actual-compiled)))
     expected)))
