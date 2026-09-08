(define-module (pinenote systems pinenote-book-execution-diagnostic)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote systems pinenote-book-execution-source-control)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (srfi srfi-1)
  #:export (pinenote-book-execution-diagnostic-operating-system))

;; Current public, QEMU-only diagnostic image.  Inherit the reusable source
;; control definition and replace exactly its complete six-file runtime package
;; plus the corresponding provenance manifest.  The separately named package
;; applies the reviewed diagnostic source patch explicitly; it was lowered but
;; has not been compiled or run.  Historical v12 diagnostic runtime evidence is
;; retained for those exact local bytes and does not transfer to this revision.

(define %control-system
  pinenote-book-execution-source-control-operating-system)
(define %control-package gvisor/source)
(define %diagnostic-package gvisor/source-diagnostic)

(define %base-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define (base-private name)
  (module-ref %base-module name))

(define %diagnostic-build-manifest-public-source-v1
  (mixed-text-file
   "wilkbook-book-execution-diagnostic-build-manifest-public-source-v1"
   "schema=3\n"
   "purpose=non-shipping-pinenote-qemu-virt-compatibility-smoke\n"
   "architecture=arm64\n"
   "target=aarch64-linux-gnu\n"
   "kernel-base-package=linux-pinenote\n"
   "kernel-upstream-package=nongnu:linux-7.1\n"
   "kernel-package=linux-pinenote-book-execution-test\n"
   "kernel-version="
   (package-version (base-private 'linux-pinenote-book-execution-test)) "\n"
   "kernel-runtime-release="
   (base-private '%book-execution-kernel-release) "\n"
   "kernel-output="
   (base-private 'linux-pinenote-book-execution-test) "\n"
   "kernel-config="
   (file-append (base-private 'linux-pinenote-book-execution-test) "/.config")
   "\n"
   "kernel-config-delta=CONFIG_USER_NS:y-after-olddefconfig\n"
   "language-profile=" (base-private '%book-execution-language-profile) "\n"
   "supervisor-profile=" (base-private '%book-execution-supervisor-profile)
   "\n"
   "language-closure=" (base-private '%book-execution-language-closure) "\n"
   "gvisor-package=" %diagnostic-package "\n"
   "gvisor-package-name=" (package-name %diagnostic-package) "\n"
   "gvisor-package-version=" (package-version %diagnostic-package) "\n"
   "gvisor-package-role=reusable-source-built-explicit-diagnostic-variant\n"
   "gvisor-runtime-file-count=6\n"
   "gvisor-source-commit=fd2f6b2674208086e324c2f739155eb7e1b48ff2\n"
   "gvisor-release=release-20260831.0\n"
   "gvisor-diagnostic-patch-sha256=9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e\n"
   "gvisor-diagnostic-source-delta=pkg/sentry/pgalloc/pgalloc.go,pkg/sentry/platform/systrap/subprocess.go,pkg/sentry/platform/systrap/syscall_thread.go\n"
   "gvisor-package-build-status=lowered-not-compiled\n"
   "current-system-runtime-status=unproven-pending-separate-qemu\n"
   "historical-runtime-scope=local-v12-diagnostic-artifact-only-not-transferred\n"
   "execution-profile=isolation-userns\n"
   "directfs=false\n"
   "network=none\n"
   "host-uds=none\n"
   "platform=systrap\n"
   "ignore-cgroups=false\n"
   "sidecar-usage-policy=strict\n"
   "sidecar-release-enforcement-policy=always\n"
   "diagnostic-debug=true\n"
   "diagnostic-debug-log=private-bundle/runsc-debug/\n"
    "diagnostic-panic-log=private-bundle/runsc-panic/runsc.panic.%COMMAND%.log\n"
   "diagnostic-alsologtostderr=true\n"))

(define (replace-package packages)
  (unless (= 1 (count (lambda (item) (eq? item %control-package)) packages))
    (error "control system no longer selects exactly one control artifact"))
  (map (lambda (item)
         (if (eq? item %control-package) %diagnostic-package item))
       packages))

(define (manifest-service? service)
  (eq? (service-type-name (service-kind service))
       'book-execution-language-profile))

(define (replace-manifest-entry entries)
  (unless (= 1 (count (lambda (entry)
                       (string=? (car entry)
                                 "wilkbook-execution-spike/build-manifest"))
                     entries))
    (error "control execution-system build-manifest entry changed"))
  (map (lambda (entry)
         (if (string=? (car entry)
                       "wilkbook-execution-spike/build-manifest")
               (list (car entry)
                     %diagnostic-build-manifest-public-source-v1)
             entry))
       entries))

(define (replace-manifest-service services)
  (unless (= 1 (count manifest-service? services))
    (error "control execution-system manifest service changed"))
  (map (lambda (item)
         (if (manifest-service? item)
             (service (service-kind item)
                      (replace-manifest-entry (service-value item)))
             item))
       services))

(define pinenote-book-execution-diagnostic-operating-system
  (operating-system
    (inherit %control-system)
    (packages (replace-package (operating-system-packages %control-system)))
    (services
     (replace-manifest-service
      (operating-system-user-services %control-system)))))

pinenote-book-execution-diagnostic-operating-system
