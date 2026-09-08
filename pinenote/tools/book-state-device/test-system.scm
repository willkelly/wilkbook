;;; Structural comparison of the shipping reader and opt-in device flavor.
(use-modules (gnu services)
             (gnu system)
             (guix packages)
             (guix utils)
             (srfi srfi-1))

(define (fail message . values) (apply error message values))
(define (only values label)
  (unless (= (length values) 1) (fail "expected exactly one value" label values))
  (car values))

(parameterize ((%current-target-system "aarch64-linux-gnu"))
  (let* ((reader-module (resolve-module '(pinenote systems pinenote-reader)))
         (device-module
          (resolve-module '(pinenote systems pinenote-book-state-device-reader)))
         (kernel-module (resolve-module '(pinenote packages kernel)))
         (koreader-module (resolve-module '(pinenote packages koreader)))
         (plugin-module (resolve-module '(pinenote packages book-state-device)))
         (session-module (resolve-module '(pinenote services reader-session)))
         (state-service-module
          (resolve-module '(pinenote services book-state-device)))
         (base (module-ref reader-module 'pinenote-reader-operating-system))
         (device
          (module-ref
           device-module 'pinenote-book-state-device-reader-operating-system))
         (shipping-kernel (module-ref kernel-module 'linux-pinenote))
         (userns-kernel
          (module-ref kernel-module 'linux-pinenote-book-execution-test))
         (shipping-koreader (module-ref koreader-module 'koreader-bin))
         (device-koreader
          (module-ref plugin-module 'koreader-book-state-device))
         (reader-session-type
          (module-ref session-module 'pinenote-reader-session-service-type))
         (ready-type
          (module-ref state-service-module
                      'pinenote-book-state-device-ready-service-type))
         (authority-type
          (module-ref state-service-module
                      'pinenote-book-state-device-service-type))
         (base-packages (operating-system-packages base))
         (device-packages (operating-system-packages device))
         (base-services (operating-system-user-services base))
         (device-services (operating-system-user-services device)))
    (unless (and (eq? (operating-system-kernel base) shipping-kernel)
                 (eq? (operating-system-kernel device) userns-kernel)
                 (member shipping-koreader base-packages eq?)
                 (not (member device-koreader base-packages eq?))
                 (member device-koreader device-packages eq?)
                 (not (member shipping-koreader device-packages eq?)))
      (fail "shipping/experimental kernel or KOReader selection changed"))
    (unless (= (length device-packages) (+ 1 (length base-packages)))
      (fail "experimental package delta is not KOReader replacement plus gVisor"))
    (for-each
     (lambda (package)
       (unless (or (eq? package shipping-koreader)
                   (member package device-packages eq?))
         (fail "reader package was dropped" (package-name package))))
     base-packages)
    (unless (= 1 (count (lambda (package)
                          (string=? (package-name package) "gvisor-source-built"))
                        device-packages))
      (fail "experimental flavor lacks exactly one source-built gVisor"))
    (let ((base-reader
           (only (filter (lambda (item)
                           (eq? (service-kind item) reader-session-type))
                         base-services)
                 'base-reader-session))
          (device-reader
           (only (filter (lambda (item)
                           (eq? (service-kind item) reader-session-type))
                         device-services)
                 'device-reader-session)))
      (unless (and (not (service-value base-reader))
                   (eq? (service-value device-reader) device-koreader))
        (fail "reader-session package override escaped the experimental flavor")))
    (for-each
     (lambda (item)
       (unless (or (eq? (service-kind item) reader-session-type)
                   (member item device-services eq?))
         (fail "inherited reader service was replaced or dropped"
               (service-type-name (service-kind item)))))
     base-services)
    (unless (and (= (length device-services) (+ 3 (length base-services)))
                 (= 1 (count (lambda (item) (eq? (service-kind item) ready-type))
                             device-services))
                 (= 1 (count (lambda (item) (eq? (service-kind item) authority-type))
                             device-services)))
      (fail "experimental service delta is not Book State readiness, authority, and build note"))
    (for-each
     (lambda (accessor label)
       (unless (equal? (accessor base) (accessor device))
         (fail "reader hardware field changed" label)))
     (list operating-system-user-kernel-arguments
           operating-system-initrd
           operating-system-bootloader
           operating-system-firmware)
     '(kernel-arguments initrd bootloader firmware))
    (let ((base-file-systems (operating-system-file-systems base))
          (device-file-systems (operating-system-file-systems device)))
      (unless (every (lambda (item) (member item device-file-systems eq?))
                     base-file-systems)
        (fail "reader filesystem was dropped or replaced")))
    (display "PASS: shipping reader unchanged; experimental flavor is an inherited opt-in delta\n")))
