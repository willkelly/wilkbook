(define-module (pinenote systems pinenote-book-execution-source-control)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (pinenote packages gvisor)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (pinenote-book-execution-source-control-operating-system))

;; Current public, QEMU-only control image.  Inherit the historical spike
;; system and replace exactly one profile package plus the manifest that refers
;; to it.  The permanent official gvisor-bin definition remains untouched,
;; while its output is absent from this system's runtime closure.  The reusable
;; source package has independently accepted build outputs, but this system
;; revision has not run: the retained v12 local-artifact runtime evidence is
;; historical evidence for those exact local bytes, not for gvisor/source.

(define %base-system pinenote-book-execution-spike-operating-system)
(define %control-package gvisor/source)

(define %base-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define (base-private name)
  (module-ref %base-module name))

(define %control-build-manifest-public-source-v1
  (mixed-text-file
   "wilkbook-book-execution-source-control-build-manifest-public-source-v1"
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
   "gvisor-package=" %control-package "\n"
   "gvisor-package-name=" (package-name %control-package) "\n"
   "gvisor-package-version=" (package-version %control-package) "\n"
   "gvisor-package-role=reusable-source-built-unpatched-control\n"
   "gvisor-runtime-file-count=6\n"
   "gvisor-source-commit=fd2f6b2674208086e324c2f739155eb7e1b48ff2\n"
   "gvisor-release=release-20260831.0\n"
   "gvisor-diagnostic-patch=absent\n"
   "gvisor-package-build-evidence=accepted-source-package-output\n"
   "current-system-runtime-status=unproven-pending-separate-qemu\n"
   "historical-runtime-scope=local-v12-artifact-only-not-transferred\n"
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
  (unless (= 1 (count (lambda (item) (eq? item gvisor-bin)) packages))
     (error "base execution system no longer selects exactly one official gvisor-bin"))
  (map (lambda (item)
         (if (eq? item gvisor-bin) %control-package item))
       packages))

(define (manifest-service? service)
  (eq? (service-type-name (service-kind service))
       'book-execution-language-profile))

(define (replace-manifest-entry entries)
  (unless (= 1 (count (lambda (entry)
                       (string=? (car entry)
                                 "wilkbook-execution-spike/build-manifest"))
                     entries))
    (error "base execution system build-manifest entry changed"))
  (map (lambda (entry)
         (if (string=? (car entry)
                       "wilkbook-execution-spike/build-manifest")
               (list (car entry)
                     %control-build-manifest-public-source-v1)
             entry))
       entries))

(define (replace-manifest-service services)
  (unless (= 1 (count manifest-service? services))
    (error "base execution system manifest service changed"))
  (map (lambda (item)
         (if (manifest-service? item)
             (service (service-kind item)
                      (replace-manifest-entry (service-value item)))
             item))
       services))

(define pinenote-book-execution-source-control-operating-system
  (operating-system
    (inherit %base-system)
    (packages (replace-package (operating-system-packages %base-system)))
    (services
     (replace-manifest-service
      (operating-system-user-services %base-system)))))

pinenote-book-execution-source-control-operating-system
