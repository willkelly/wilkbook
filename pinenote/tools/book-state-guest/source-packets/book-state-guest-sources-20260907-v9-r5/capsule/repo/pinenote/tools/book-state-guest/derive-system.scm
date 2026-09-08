;;; Derivation-only lowering for the non-shipping persistent-state guest.
;;; Invoke through the pinned `guix time-machine ... repl -L . --` command in
;;; CONTRACT.md.  This script neither builds nor realizes any output.
(use-modules (gnu system)
             (guix derivations)
             (guix gexp)
             (guix monads)
             (guix packages)
             (guix store)
             (guix utils)
             (srfi srfi-1))

(unless (= (length (command-line)) 1)
  (error "derive-system.scm accepts no arguments"))

(define target "aarch64-linux-gnu")
(define expected-kernel-output
  "/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote")
(define expected-gvisor-output
  "/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0")
(define module-view
  (or (getenv "BOOK_STATE_MODULE_VIEW")
      (error "BOOK_STATE_MODULE_VIEW is absent")))
(unless (and (string-prefix? "/" module-view)
             (string=? module-view (canonicalize-path module-view)))
  (error "module view is not canonical" module-view))
(define package-view
  (or (getenv "BOOK_STATE_PACKAGE_VIEW")
      (error "BOOK_STATE_PACKAGE_VIEW is absent")))
(unless (and (member module-view %load-path)
             (every (lambda (path)
                      (or (string=? path module-view)
                          (string=? path package-view)
                          (string-prefix? "/gnu/store/" path)))
                    %load-path))
  (error "Guile load path contains an ambient source directory" %load-path))

;; gvisor/source selects its finite architecture-specific source graph while
;; its module is evaluated, so establish the target before resolving the OS.
(parameterize ((%current-target-system target)
               (%graft? #f))
  (let* ((module
          (resolve-interface
           '(pinenote systems pinenote-book-state-reader)))
         (operating-system
          (module-ref module 'pinenote-book-state-reader-operating-system))
         (kernel (operating-system-kernel operating-system))
         (gvisor
          (find (lambda (package)
                  (string=? (package-name package) "gvisor-source-built"))
                 (operating-system-packages operating-system))))
    (let* ((loaded
            (resolve-module '(pinenote systems pinenote-book-state-reader)))
           (filename (module-filename loaded))
           (origin
            (and filename
                 (if (string-prefix? "/" filename)
                     filename
                     (search-path %load-path filename)))))
      (unless
          (and origin
               (string=?
                origin
                (string-append
                 module-view
                 "/pinenote/systems/pinenote-book-state-reader.scm")))
        (error "guest system module did not originate in private view")))
    (unless gvisor
      (error "source-built gVisor package is absent from the guest system"))
    (with-store store
      (set-build-options store
                         #:use-substitutes? #f
                         #:max-build-jobs 1
                         #:build-cores 2)
      (let* ((result
              (run-with-store
               store
               (mlet %store-monad
                   ((_ (set-guile-for-build (default-guile)))
                    (kernel-output (package-file kernel #:target target))
                    (gvisor-output (package-file gvisor #:target target))
                    (system-derivation
                     (operating-system-derivation operating-system)))
                 (return (list kernel-output gvisor-output
                               system-derivation)))
               #:target target))
             (kernel-output (car result))
             (gvisor-output (cadr result))
             (system-derivation (caddr result)))
        (unless (string=? kernel-output expected-kernel-output)
          (error "unexpected kernel source graph; stopping"
                 kernel-output expected-kernel-output))
        (unless (string=? gvisor-output expected-gvisor-output)
          (error "unexpected gVisor source graph; stopping"
                 gvisor-output expected-gvisor-output))
        (format #t "PIN kernel-output=~a~%" kernel-output)
        (format #t "PIN gvisor-source-output=~a~%" gvisor-output)
        (format #t "SYSTEM-DERIVATION ~a~%"
                (derivation-file-name system-derivation))))))
