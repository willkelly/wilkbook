;;; Lower the two native inputs used to syntax/load-check the exact production
;;; source-only authority. Realization remains the caller's explicit step.
(use-modules (guix derivations)
             (guix gexp)
             (guix monads)
             (guix store)
             (pinenote packages book-state-device)
             (pinenote services book-state-device))

(unless (= (length (command-line)) 1)
  (error "derive-runtime-inputs.scm accepts no arguments"))

(with-store store
  (set-build-options store #:use-substitutes? #f
                     #:max-build-jobs 1 #:build-cores 2)
  (let ((values
         (run-with-store
          store
          (mlet %store-monad
              ((modules (lower-object book-state-device-modules))
               (supervisor (lower-object book-state-device-supervisor-profile))
               (language-profile
                (lower-object book-state-device-language-profile))
               (language-closure
                (lower-object book-state-device-language-closure))
               (guile-boundary
                (lower-object book-state-device-boundary-probe))
               (python-boundary
                (lower-object book-state-device-python-boundary-probe))
               (guile-book (lower-object book-state-device-guile-book))
               (python-book (lower-object book-state-device-python-book))
               (guile-protocol
                (lower-object book-state-device-guile-protocol))
               (blocking-protocol
                (lower-object book-state-device-blocking-protocol))
               (python-protocol
                (lower-object book-state-device-python-protocol))
               (runsc-adapter
                (lower-object book-state-device-runsc-fd3-adapter)))
            (return
             (list modules supervisor language-profile language-closure
                   guile-boundary python-boundary guile-book python-book
                   guile-protocol blocking-protocol python-protocol
                   runsc-adapter))))))
    (for-each
     (lambda (label drv)
       (if (derivation? drv)
           (format #t "~a\t~a\t~a~%" label (derivation-file-name drv)
                   (derivation->output-path drv))
           (format #t "~a\t-\t~a~%" label drv)))
     '(modules supervisor language-profile language-closure
               guile-boundary python-boundary guile-book python-book
               guile-protocol blocking-protocol python-protocol runsc-adapter)
     values)))
