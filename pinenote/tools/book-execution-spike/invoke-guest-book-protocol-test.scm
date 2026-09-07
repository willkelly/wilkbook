;;; Host-only invocation adapter.  It cannot select guest-runsc evidence mode.
(use-modules (ice-9 match)
             (oci-book-bundle))

;; Match the installed program-file path: the adapter is a primitive-loaded
;; entry source, while its accepted protocol/session dependencies are modules.
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define %adapter (resolve-module '(guest-book-protocol)))
(define run-protocol-self-tests!
  (module-ref %adapter 'run-protocol-self-tests!))
(define run-protocol-pair!
  (module-ref %adapter 'run-protocol-pair!))
(define assert-source-provenance!
  (module-ref %adapter 'assert-source-provenance!))

(match (cdr (command-line))
  (("self-tests")
   (run-protocol-self-tests!)
   (display "BOOKEXEC-PROTOCOL-AUTHORITY-HOST-TEST=PASS\n"))
  (("provenance" profile closure guest-smoke base-oci protocol-oci
    guest-adapter expected-guest-adapter-sha256 guile-book python-book
    guile-protocol blocking-protocol python-protocol book-session)
   (assert-source-provenance!
    profile closure guest-smoke base-oci protocol-oci guest-adapter
    expected-guest-adapter-sha256 guile-book python-book guile-protocol
    blocking-protocol python-protocol book-session)
   (display "BOOKEXEC-PROTOCOL-PROVENANCE-HOST-TEST=PASS\n"))
  (("unproven-guest-mode")
   (let ((rejected?
          (catch 'book-execution-protocol-integration-error
            (lambda ()
              (run-protocol-pair! "/must-not-open/guile"
                                  "/must-not-open/python")
              #f)
            (lambda (key message)
              (string=?
               message
               "guest-runsc evidence requires checked source/profile provenance")))))
     (unless rejected?
       (error "unproven guest evidence mode was not rejected"))
     (display "BOOKEXEC-PROTOCOL-UNPROVEN-GUEST-HOST-TEST=PASS\n")))
  (("pair" guile-bundle python-bundle fake-runsc timeout)
   (run-protocol-pair!
    guile-bundle python-bundle
    #:evidence-mode 'host-fake
    #:runtime-override fake-runsc
    #:timeout-seconds (string->number timeout))
   ;; This host-only label is intentionally outside the actual guest marker
   ;; namespace.  A fake runtime can never emit or obtain guest-runsc PASS.
   (display "BOOKEXEC-PROTOCOL-FD-HOST-TEST=PASS\n"))
  (_ (error "invalid host-only protocol adapter invocation")))
