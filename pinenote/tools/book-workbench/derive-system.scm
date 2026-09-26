;;; Cheap gate only. No output is realized. Run through channels.scm's pinned
;;; time-machine, since ambient Guix currently selects a different kernel.
(use-modules (gnu image) (gnu system) (gnu system image)
             (guix derivations) (guix gexp) (guix grafts) (guix monads)
             (guix packages) (guix store) (guix utils) (srfi srfi-1))

(define arguments (cdr (command-line)))
(unless (and (every (lambda (arg) (member arg '("--image" "--editor"))) arguments)
             (= (length arguments) (length (delete-duplicates arguments))))
  (error "usage: derive-system.scm [--image] [--editor]"))
(define image-request? (member "--image" arguments))
(define target "aarch64-linux-gnu")
(define expected-kernel
  "/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote")
(define expected-gvisor
  "/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0")

;; gvisor/source resolves architecture-sensitive inputs at module evaluation.
(parameterize ((%current-target-system target) (%graft? #f))
  (let* ((interface (resolve-interface '(pinenote systems pinenote-book-workbench)))
          (os (module-ref interface
                          (if (member "--editor" arguments)
                              'pinenote-book-workbench-editor-operating-system
                              'pinenote-book-workbench-operating-system)))
         (kernel (operating-system-kernel os))
         (gvisor (find (lambda (package)
                         (string=? (package-name package) "gvisor-source-built"))
                       (operating-system-packages os))))
    (unless gvisor (error "source-built gVisor is absent"))
    (with-store store
      (set-build-options store #:use-substitutes? #f #:max-build-jobs 1 #:build-cores 2)
      (let* ((pins (run-with-store
                    store
                    (mlet %store-monad
                        ((_ (set-guile-for-build (default-guile)))
                         (k (package-file kernel #:target target))
                         (g (package-file gvisor #:target target)))
                      (return (list k g))) #:target target)))
        ;; Stop before lowering the rest of the graph if an expensive pin moved.
        (unless (equal? pins (list expected-kernel expected-gvisor))
          (error "unexpected kernel/gVisor graph; use channels.scm" pins))
        (format #t "PIN kernel-output=~a~%PIN gvisor-source-output=~a~%"
                (car pins) (cadr pins))
        (let ((drv
               (run-with-store
                store
                (mlet %store-monad ((_ (set-guile-for-build (default-guile))))
                  (operating-system-derivation os)) #:target target)))
          (format #t "SYSTEM-DERIVATION ~a~%SYSTEM-OUTPUT ~a~%"
                  (derivation-file-name drv) (derivation->output-path drv)))
        (when image-request?
          ;; Do not use `guix system image -L .': image-type discovery traverses
          ;; every Scheme script in this repository, including test programs.
          ;; Select the imported constructor directly, with no module discovery.
          (let* ((image ((image-type-constructor raw-with-offset-image-type) os))
                 (image-system
                  (run-with-store
                   store
                   (mlet %store-monad ((_ (set-guile-for-build (default-guile))))
                     (operating-system-derivation (operating-system-for-image image)))
                   #:target target))
                 (drv
                 (run-with-store
                  store
                  (mlet %store-monad ((_ (set-guile-for-build (default-guile))))
                    (lower-object
                     (system-image image)))
                  #:target target)))
            ;; Image creation changes the root filesystem UUID, so its embedded
            ;; system differs from the standalone system printed above.
            (format #t "IMAGE-SYSTEM-DERIVATION ~a~%IMAGE-SYSTEM-OUTPUT ~a~%"
                    (derivation-file-name image-system)
                    (derivation->output-path image-system))
            (format #t "IMAGE-DERIVATION ~a~%IMAGE-OUTPUT ~a~%"
                    (derivation-file-name drv) (derivation->output-path drv))))))))
