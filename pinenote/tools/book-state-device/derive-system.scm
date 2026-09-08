;;; Cheap derivation gate: lower the hardware flavor without realizing it and
;;; refuse any kernel/gVisor output other than the two-boot-proven objects.
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
(define expected-kernel
  "/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote")
(define expected-gvisor
  "/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0")

(parameterize ((%current-target-system target) (%graft? #f))
  (let* ((interface
          (resolve-interface
           '(pinenote systems pinenote-book-state-device-reader)))
         (os (module-ref interface
                         'pinenote-book-state-device-reader-operating-system))
         (kernel (operating-system-kernel os))
         (gvisor
          (find (lambda (package)
                  (string=? (package-name package) "gvisor-source-built"))
                (operating-system-packages os))))
    (unless gvisor (error "source-built gVisor is absent from device flavor"))
    (with-store store
      (set-build-options store #:use-substitutes? #f
                         #:max-build-jobs 1 #:build-cores 2)
      (let* ((result
              (run-with-store
               store
               (mlet %store-monad
                   ((_ (set-guile-for-build (default-guile)))
                    (kernel-output (package-file kernel #:target target))
                    (gvisor-output (package-file gvisor #:target target))
                    (system (operating-system-derivation os)))
                 (return (list kernel-output gvisor-output system)))
               #:target target))
             (kernel-output (car result))
             (gvisor-output (cadr result))
             (system (caddr result)))
        (unless (string=? kernel-output expected-kernel)
          (error "unexpected USER_NS kernel output" kernel-output expected-kernel))
        (unless (string=? gvisor-output expected-gvisor)
          (error "unexpected gVisor output" gvisor-output expected-gvisor))
        (format #t "PIN kernel-output=~a~%" kernel-output)
        (format #t "PIN gvisor-source-output=~a~%" gvisor-output)
        (format #t "SYSTEM-DERIVATION ~a~%" (derivation-file-name system))))))
