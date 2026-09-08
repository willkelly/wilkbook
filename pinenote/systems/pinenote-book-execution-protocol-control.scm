(define-module (pinenote systems pinenote-book-execution-protocol-control)
  #:use-module (gnu packages)
  #:use-module (gnu packages guile)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote systems pinenote-book-execution-source-control)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (srfi srfi-1)
  #:export (pinenote-book-execution-protocol-control-operating-system))

;; Current public revision of the non-shipping corrected-CONTROL successor.  It
;; changes no kernel, source-built runtime package, sandbox language profile,
;; cgroup mount, or shipping service.  The old compatibility smoke service is
;; replaced with the fixed Book Protocol FD-donation gate.  Its accepted
;; historical QEMU result used exact local v12 artifact bytes; changing the
;; package identity to gvisor/source requires a separate future QEMU proof.
(define %base-system
  pinenote-book-execution-source-control-operating-system)
(define %spike-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define (spike-private name)
  (module-ref %spike-module name))

(define %guile-gcrypt
  (specification->package "guile-gcrypt@0.5.0"))

;; guile-gcrypt belongs only to the trusted Guile authority.  The inherited
;; 45-path sandbox language profile remains byte-for-byte the accepted object.
(define %book-protocol-supervisor-profile
  (profile
   (name "wilkbook-book-protocol-supervisor")
   (content
    (packages->manifest (list guile-3.0 guile-json-4 %guile-gcrypt)))))

(define %accepted-guest-smoke-source
  (local-file "../tools/book-execution-spike/guest-smoke.scm"
              "wilkbook-accepted-guest-smoke.scm"))
(define %accepted-base-oci-source
  (local-file "../tools/book-execution-spike/oci-bundle.scm"
              "wilkbook-accepted-oci-bundle.scm"))
(define %accepted-book-protocol-source
  (local-file "../tools/book-protocol/book-protocol.scm"
              "wilkbook-accepted-book-protocol.scm"))
(define %accepted-blocking-protocol-source
  (local-file "../tools/book-protocol/book-protocol/blocking-io.scm"
              "wilkbook-accepted-book-protocol-blocking-io.scm"))
(define %accepted-python-protocol-source
  (local-file "../tools/book-protocol/book_protocol.py"
              "wilkbook-accepted-book_protocol.py"))
(define %accepted-book-session-source
  (local-file "../tools/book-session/book-session.scm"
              "wilkbook-accepted-book-session.scm"))
(define %protocol-oci-source
  (local-file "../tools/book-execution-spike/oci-book-bundle.scm"
              "wilkbook-protocol-oci-bundle.scm"))
(define %guest-protocol-adapter-source
  (local-file "../tools/book-execution-spike/guest-book-protocol.scm"
              "wilkbook-guest-book-protocol.scm"))
(define %guile-book-source
  (local-file "../tools/book-execution-spike/guest-protocol-book.scm"
              "wilkbook-fixed-guile-protocol-book.scm"))
(define %python-book-source
  (local-file "../tools/book-execution-spike/guest_protocol_book.py"
              "wilkbook-fixed-python-protocol-book.py"))

;; Source hashes are an explicit review boundary in addition to the immutable
;; Guix store identities.  The static gate compares every value to the checkout
;; before any system realization is authorized.
(define %book-protocol-source-hashes
  '(("guest-smoke.scm"
     . "74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa")
    ("oci-bundle.scm"
     . "a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c")
    ("book-protocol.scm"
     . "91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44")
    ("blocking-io.scm"
     . "543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd")
    ("book_protocol.py"
     . "4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735")
    ("book-session.scm"
     . "f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668")
    ("oci-book-bundle.scm"
     . "c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7")
    ("guest-book-protocol.scm"
      . "10b2bf5155697ad4ef361e3a975bff5afa8c97a3988c44d6f7356248c6900e6e")
    ("guest-protocol-book.scm"
     . "9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a")
    ("guest_protocol_book.py"
     . "b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0")))

;; Runtime source layout for trusted modules only.  The fixed books receive
;; separately mounted source files in their own OCI roots and cannot see this
;; session-authority tree.
(define %book-protocol-trusted-modules
  (file-union
   "wilkbook-book-protocol-trusted-modules"
   `(("guest-smoke.scm" ,%accepted-guest-smoke-source)
     ("book-protocol.scm" ,%accepted-book-protocol-source)
     ("book-protocol/blocking-io.scm"
      ,%accepted-blocking-protocol-source)
     ("book-session.scm" ,%accepted-book-session-source))))

(define %book-protocol-source-manifest
  (mixed-text-file
   "wilkbook-book-protocol-source-manifest"
   "schema=1\n"
   "role=fixed-qemu-only-book-protocol-fd-donation-gate\n"
   (string-concatenate
    (map (lambda (entry)
           (string-append "sha256=" (cdr entry) " " (car entry) "\n"))
         %book-protocol-source-hashes))
   "trusted-modules=" %book-protocol-trusted-modules "\n"
   "accepted-base-oci-source=" %accepted-base-oci-source "\n"
   "protocol-oci-source=" %protocol-oci-source "\n"
   "guest-protocol-adapter=" %guest-protocol-adapter-source "\n"
   "guile-book-source=" %guile-book-source "\n"
   "python-book-source=" %python-book-source "\n"
   "python-protocol-source=" %accepted-python-protocol-source "\n"))

(define %protocol-build-manifest
  (mixed-text-file
   "wilkbook-book-execution-protocol-control-build-manifest-public-source-v1"
   "schema=4\n"
   "purpose=non-shipping-pinenote-qemu-book-protocol-fd-donation\n"
   "architecture=arm64\n"
   "target=aarch64-linux-gnu\n"
   "kernel-package=linux-pinenote-book-execution-test\n"
   "kernel-runtime-release=" (spike-private '%book-execution-kernel-release)
   "\n"
   "kernel-output=" (operating-system-kernel %base-system) "\n"
   "kernel-config-delta=CONFIG_USER_NS:y-after-olddefconfig\n"
   "gvisor-package=" gvisor/source "\n"
   "gvisor-package-name=" (package-name gvisor/source) "\n"
   "gvisor-package-version=" (package-version gvisor/source) "\n"
   "gvisor-package-role=reusable-source-built-unpatched-control\n"
   "gvisor-runtime-file-count=6\n"
   "gvisor-source-commit=fd2f6b2674208086e324c2f739155eb7e1b48ff2\n"
   "gvisor-release=release-20260831.0\n"
   "gvisor-diagnostic-patch=absent\n"
   "gvisor-package-build-evidence=accepted-source-package-output\n"
   "current-system-runtime-status=unproven-pending-separate-qemu\n"
   "historical-runtime-scope=local-v12-control-artifact-only-not-transferred\n"
   "language-profile=" (spike-private '%book-execution-language-profile) "\n"
   "language-closure=" (spike-private '%book-execution-language-closure) "\n"
   "language-closure-sha256=48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc\n"
   "language-closure-expected-paths=45\n"
   "supervisor-profile=" %book-protocol-supervisor-profile "\n"
   "supervisor-only-delta=guile-gcrypt@0.5.0\n"
   "source-manifest=" %book-protocol-source-manifest "\n"
   "runtime-source-profile-provenance-check=required-before-runsc\n"
   "book-protocol-fd=3\n"
   "runsc-pass-fd=3:3\n"
   "execution-profile=isolation-userns\n"
   "platform=systrap\n"
   "directfs=false\n"
   "network=none\n"
   "host-uds=none\n"
   "ignore-cgroups=false\n"
   "sidecar-usage-policy=strict\n"
   "sidecar-release-enforcement-policy=always\n"
   "payload-rlimit-fsize=1048576\n"
   "supervisor-rlimit-fsize=unlimited-by-this-fixture\n"
    "capture-limit-per-stream=4194304\n"
    "gofer-network-namespace=null-default-unchanged\n"
     "runtime-state-expected-entry=null-netns\n"
     "runtime-state-expected-mount=single-nsfs-net-namespace-not-authority-netns\n"
     "runtime-state-root-mount-policy=forbidden-before-pin-cleanup-and-before-placeholder-unlink\n"
     "runtime-state-cleanup=identity-checked-nonlazy-unmount-owned-placeholder-only\n"
     "runtime-state-residual-policy=fail-preserve-no-recursive-delete\n"
     "runtime-state-diagnostic-entry-limit=4\n"
     "runtime-state-diagnostic-mount-limit-per-entry=2\n"
     "runtime-state-diagnostic-root-mount-limit=2\n"
    "runtime-state-diagnostic-content=metadata-and-escaped-name-only\n"
    "debug-store-bytes=4194304\n"
   "debug-store-files=10\n"
   "debug-store-nr-inodes=11\n"
   "panic-store-bytes=1048576\n"
   "panic-store-files=2\n"
   "panic-store-nr-inodes=3\n"
   "diagnostic-debug-log=private-bundle/runsc-debug/\n"
   "diagnostic-panic-log=private-bundle/runsc-panic/runsc.panic.%COMMAND%.log\n"))

(define %guest-protocol-entry
  (program-file
   "wilkbook-guest-book-protocol"
   #~(begin
       (primitive-load #$%guest-protocol-adapter-source)
       (let ((status
              ((module-ref (resolve-module '(guest-book-protocol))
                           'guest-book-protocol-main)
               (command-line))))
         ;; PASS/FAIL has already been force-flushed to the console by the
         ;; adapter.  Complete writeback, then leave this one-shot service by
         ;; replacing it with the fixed shutdown client.
         (sync)
         (format (current-error-port)
                 "book protocol guest gate exited with status ~a; requesting shutdown~%"
                 status)
         (force-output (current-output-port))
         (force-output (current-error-port))
         (execl "/run/current-system/profile/sbin/halt" "halt")))))

(define (book-protocol-guest-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(book-execution-protocol-gate))
    (requirement '(user-processes))
    (documentation
     "Run the fixed Guile-authority Book Protocol FD-donation gate through accepted CONTROL runsc, then halt disposable QEMU.")
    (respawn? #f)
    (start
     #~(let* ((supervisor #$%book-protocol-supervisor-profile)
              (trusted-modules #$%book-protocol-trusted-modules)
              (guile (string-append supervisor "/bin/guile")))
         (make-forkexec-constructor
          (list
           "/run/current-system/profile/bin/env" "-i"
           "HOME=/nonexistent"
           "LANG=C"
           "LC_ALL=C"
           "PATH=/run/current-system/profile/bin"
           "GUILE_AUTO_COMPILE=0"
           (string-append "GUILE_LOAD_PATH=" trusted-modules ":"
                          supervisor "/share/guile/site/3.0")
           (string-append "GUILE_LOAD_COMPILED_PATH=" supervisor
                          "/lib/guile/3.0/site-ccache")
           guile "--no-auto-compile" "-s" #$%guest-protocol-entry
           #$%accepted-base-oci-source
           #$%protocol-oci-source
           #$(spike-private '%book-execution-language-profile)
           #$(spike-private '%book-execution-language-closure)
           #$%guile-book-source
           #$%python-book-source
           #$%accepted-book-protocol-source
           #$%accepted-blocking-protocol-source
           #$%accepted-python-protocol-source
           #$%accepted-guest-smoke-source
           #$%accepted-book-session-source
           #$%guest-protocol-adapter-source
             "10b2bf5155697ad4ef361e3a975bff5afa8c97a3988c44d6f7356248c6900e6e"
           #$(spike-private '%book-execution-kernel-release))
          #:file-creation-mask #o077)))
    (stop #~(make-kill-destructor)))))

(define book-protocol-guest-service-type
  (service-type
   (name 'book-execution-protocol-gate)
   (extensions
    (list (service-extension shepherd-root-service-type
                             book-protocol-guest-shepherd-service)))
   (default-value #f)
   (description
    "Run the fixed non-shipping Book Protocol FD-donation QEMU gate.")))

(define (service-name item)
  (service-type-name (service-kind item)))

(define (replace-etc-service services)
  (unless (= 1 (count (lambda (item)
                        (eq? (service-name item)
                             'book-execution-language-profile))
                      services))
    (error "accepted execution system manifest service changed"))
  (map
   (lambda (item)
     (if (eq? (service-name item) 'book-execution-language-profile)
         (service
          (service-kind item)
          `(("wilkbook-execution-spike/profile"
             ,(spike-private '%book-execution-language-profile))
            ("wilkbook-execution-spike/supervisor-profile"
             ,%book-protocol-supervisor-profile)
            ("wilkbook-execution-spike/protocol-sources"
             ,%book-protocol-source-manifest)
            ("wilkbook-execution-spike/build-manifest"
             ,%protocol-build-manifest)))
         item))
   services))

(define (replace-guest-service services)
  (unless (= 1 (count (lambda (item)
                        (eq? (service-name item)
                             'book-execution-guest-smoke))
                      services))
    (error "accepted corrected-CONTROL guest smoke service changed"))
  (map
   (lambda (item)
     (if (eq? (service-name item) 'book-execution-guest-smoke)
         (service book-protocol-guest-service-type)
         item))
   services))

(define pinenote-book-execution-protocol-control-operating-system
  (operating-system
    (inherit %base-system)
    (services
     (replace-guest-service
      (replace-etc-service
       (operating-system-user-services %base-system))))))

pinenote-book-execution-protocol-control-operating-system
