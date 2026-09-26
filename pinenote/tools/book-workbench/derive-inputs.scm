;;; Native test/desktop dependencies; no system, image, kernel or device operations.
(use-modules (gnu packages gl)
             (guix derivations)
             (guix gexp)
             (guix monads)
             (guix packages)
             (guix store)
             (pinenote packages koreader)
             (pinenote services book-state-device))

(unless (= (length (command-line)) 1)
  (error "derive-inputs.scm accepts no arguments"))

(parameterize ((%graft? #f))
  (with-store store
    (set-build-options store #:use-substitutes? #f
                       #:max-build-jobs 1 #:build-cores 2)
    (let ((inputs
           (run-with-store
            store
            (mlet %store-monad
                ((supervisor (lower-object book-state-device-supervisor-profile))
                 (languages (lower-object book-state-device-language-profile))
                 (closure (lower-object book-state-device-language-closure))
                 (reader (lower-object koreader-bin))
                 ;; Desktop-only: the pinned Mesa exports EGL/GLES directly,
                 ;; without GLVND's vendor dispatcher. The launcher supplies
                 ;; their exact paths; the tablet's fbdev profile needs neither.
                 (graphics (lower-object mesa)))
              (return (list supervisor languages closure reader graphics))))))
      (for-each
       (lambda (label drv)
         (format #t "~a\t~a\t~a~%" label (derivation-file-name drv)
                 (derivation->output-path drv)))
       '(supervisor languages language-closure koreader graphics) inputs))))
