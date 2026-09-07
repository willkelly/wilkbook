(define-module (pinenote systems pinenote-book-execution-reader-interaction)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote systems pinenote-book-execution-protocol-control)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (srfi srfi-1)
  #:export (pinenote-book-execution-reader-interaction-operating-system))

;; Current public revision of the non-shipping reader-interaction successor.  It
;; retains the protocol image's kernel, reusable unpatched source-built runtime,
;; 45-path sandbox language profile, fixed OCI generators/books, and trusted
;; Guile profile.  Only the one-shot authority gains the fixed named UI port.
;; The package identity differs from the historical local-v12 QEMU run, so this
;; current system revision remains runtime-unproven pending a separate QEMU gate.
(define %base-system
  pinenote-book-execution-protocol-control-operating-system)
(define %protocol-module
  (resolve-module
   '(pinenote systems pinenote-book-execution-protocol-control)))
(define (protocol-private name) (module-ref %protocol-module name))
(define %spike-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define (spike-private name) (module-ref %spike-module name))

(define %private-control-source
  (local-file "../tools/book-interaction/private-control.scm"
              "wilkbook-accepted-private-control.scm"))
(define %guest-virtio-ui-source
  (local-file "../tools/book-execution-spike/guest-virtio-book-ui.scm"
              "wilkbook-guest-virtio-book-ui.scm"))
(define %guest-reader-authority-source
  (local-file "../tools/book-execution-spike/guest-book-interaction.scm"
              "wilkbook-guest-book-interaction.scm"))

(define %private-control-sha256
  "1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d")
(define %guest-virtio-ui-sha256
  "3b6e8eb172d7e3575c36a95a42d66635c101f7404d2f8028ca0f541dfba66966")
(define %guest-reader-authority-sha256
  "6dc0dfc9b577b3b5b854690879ce02909fc1f85f4b7a776365d8d9dde46e1129")

(define %reader-interaction-trusted-modules
  (file-union
   "wilkbook-book-reader-interaction-trusted-modules"
   `(("guest-smoke.scm"
      ,(protocol-private '%accepted-guest-smoke-source))
     ("book-protocol.scm"
      ,(protocol-private '%accepted-book-protocol-source))
     ("book-protocol/blocking-io.scm"
      ,(protocol-private '%accepted-blocking-protocol-source))
     ("book-session.scm"
      ,(protocol-private '%accepted-book-session-source))
     ("private-control.scm" ,%private-control-source)
     ("guest-virtio-book-ui.scm" ,%guest-virtio-ui-source))))

(define %reader-interaction-source-manifest
  (mixed-text-file
   "wilkbook-book-reader-interaction-source-manifest"
   "schema=1\n"
   "role=fixed-qemu-native-reader-to-guest-book-session-gate\n"
   "accepted-protocol-source-manifest="
   (protocol-private '%book-protocol-source-manifest) "\n"
   "sha256=" %private-control-sha256 " private-control.scm\n"
   "sha256=" %guest-virtio-ui-sha256 " guest-virtio-book-ui.scm\n"
   "sha256=" %guest-reader-authority-sha256
   " guest-book-interaction.scm\n"
   "trusted-modules=" %reader-interaction-trusted-modules "\n"
   "accepted-guest-protocol-adapter="
   (protocol-private '%guest-protocol-adapter-source) "\n"
   "reader-authority=" %guest-reader-authority-source "\n"
   "named-port=org.wilkbook.book-interaction\n"
   "named-port-path=/dev/virtio-ports/org.wilkbook.book-interaction\n"))

(define %reader-interaction-build-manifest
  (mixed-text-file
   "wilkbook-book-execution-reader-interaction-build-manifest-public-source-v1"
   "schema=2\n"
   "purpose=non-shipping-native-reader-guest-book-session-seam\n"
   "architecture=arm64\n"
   "target=aarch64-linux-gnu\n"
   "inherited-protocol-build-manifest="
   (protocol-private '%protocol-build-manifest) "\n"
   "kernel-output=" (operating-system-kernel %base-system) "\n"
   "kernel-runtime-release=" (spike-private '%book-execution-kernel-release)
   "\n"
   "gvisor-package=" gvisor/source "\n"
   "gvisor-package-name=" (package-name gvisor/source) "\n"
   "gvisor-package-version=" (package-version gvisor/source) "\n"
   "gvisor-package-role=reusable-source-built-unpatched-control\n"
   "gvisor-runtime-file-count=6\n"
   "gvisor-release=release-20260831.0\n"
   "gvisor-diagnostic-patch=absent\n"
   "gvisor-package-build-evidence=accepted-source-package-output\n"
   "current-system-runtime-status=unproven-pending-separate-qemu\n"
   "historical-runtime-scope=local-v12-control-artifact-only-not-transferred\n"
   "language-profile=" (spike-private '%book-execution-language-profile) "\n"
   "language-closure=" (spike-private '%book-execution-language-closure) "\n"
   "language-closure-sha256=48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc\n"
   "language-closure-expected-paths=45\n"
   "supervisor-profile="
   (protocol-private '%book-protocol-supervisor-profile) "\n"
   "supervisor-package-delta=none\n"
   "source-manifest=" %reader-interaction-source-manifest "\n"
   "guest-whole-run-timeout-seconds=360\n"
   "ui-control-generation=1\n"
   "ui-control-value-limit-bytes=4096\n"
   "ui-control-queue-limit-frames=8\n"
   "ui-control-queue-limit-bytes=65800\n"
   "ui-control-fd-policy=cloexec-never-donated\n"
   "book-protocol-fd=3\n"
   "runsc-pass-fd=3:3\n"
   "service-requires=user-processes,udev\n"
   "named-port=org.wilkbook.book-interaction\n"
   "execution-profile=isolation-userns\n"
   "platform=systrap\n"
   "network=none\n"
   "host-uds=none\n"
   "directfs=false\n"
   "ignore-cgroups=false\n"
   "sidecar-usage-policy=strict\n"
   "sidecar-release-enforcement-policy=always\n"))

(define %guest-reader-interaction-entry
  (program-file
   "wilkbook-guest-book-reader-interaction"
   #~(begin
       ;; The accepted adapter is a program-file-style module and is loaded
       ;; first so the sibling authority can lexically reuse its reviewed
       ;; SRFI-9 ownership operations without mutating that source.
       (primitive-load #$(protocol-private '%guest-protocol-adapter-source))
       (primitive-load #$%guest-reader-authority-source)
       (let ((status
              ((module-ref (resolve-module '(guest-book-interaction))
                           'guest-book-interaction-main)
               (command-line))))
         (sync)
         (format (current-error-port)
                 "book reader interaction guest gate exited with status ~a; requesting shutdown~%"
                 status)
         (force-output (current-output-port))
         (force-output (current-error-port))
         (execl "/run/current-system/profile/sbin/halt" "halt")))))

(define (book-reader-interaction-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(book-execution-reader-interaction-gate))
    ;; Udev owns /dev/virtio-ports.  The adapter then requires the exact named
    ;; symlink and an identity-stable character-device target before opening.
    (requirement '(user-processes udev))
    (documentation
     "Run the fixed reader-driven Guile Book Session authority over the named private virtio-serial port, then halt disposable QEMU.")
    (respawn? #f)
    (start
     #~(let* ((supervisor
               #$(protocol-private '%book-protocol-supervisor-profile))
              (trusted-modules #$%reader-interaction-trusted-modules)
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
           guile "--no-auto-compile" "-s" #$%guest-reader-interaction-entry
           #$(protocol-private '%accepted-base-oci-source)
           #$(protocol-private '%protocol-oci-source)
           #$(spike-private '%book-execution-language-profile)
           #$(spike-private '%book-execution-language-closure)
           #$(protocol-private '%guile-book-source)
           #$(protocol-private '%python-book-source)
           #$(protocol-private '%accepted-book-protocol-source)
           #$(protocol-private '%accepted-blocking-protocol-source)
           #$(protocol-private '%accepted-python-protocol-source)
           #$(protocol-private '%accepted-guest-smoke-source)
           #$(protocol-private '%accepted-book-session-source)
           #$(protocol-private '%guest-protocol-adapter-source)
           #$%private-control-source
           #$%guest-virtio-ui-source
           #$%guest-reader-authority-source
           #$%guest-virtio-ui-sha256
           #$%guest-reader-authority-sha256
           #$(spike-private '%book-execution-kernel-release))
          #:file-creation-mask #o077)))
    (stop #~(make-kill-destructor)))))

(define book-reader-interaction-service-type
  (service-type
   (name 'book-execution-reader-interaction-gate)
   (extensions
    (list (service-extension shepherd-root-service-type
                             book-reader-interaction-shepherd-service)))
   (default-value #f)
   (description
    "Run the fixed non-shipping native-reader/guest Book Session QEMU gate.")))

(define (service-name item)
  (service-type-name (service-kind item)))

(define (replace-manifest-entries entries)
  (for-each
   (lambda (name)
     (unless (= 1 (count (lambda (entry) (string=? (car entry) name))
                         entries))
       (error "inherited protocol manifest entry changed" name)))
   '("wilkbook-execution-spike/protocol-sources"
     "wilkbook-execution-spike/build-manifest"))
  (map
   (lambda (entry)
     (cond
      ((string=? (car entry) "wilkbook-execution-spike/protocol-sources")
       (list (car entry) %reader-interaction-source-manifest))
      ((string=? (car entry) "wilkbook-execution-spike/build-manifest")
       (list (car entry) %reader-interaction-build-manifest))
      (else entry)))
   entries))

(define (replace-services services)
  (unless (= 1 (count (lambda (item)
                        (eq? (service-name item)
                             'book-execution-protocol-gate))
                      services))
    (error "inherited protocol guest service changed"))
  (unless (= 1 (count (lambda (item)
                        (eq? (service-name item)
                             'book-execution-language-profile))
                      services))
    (error "inherited protocol manifest service changed"))
  (map
   (lambda (item)
     (case (service-name item)
       ((book-execution-protocol-gate)
        (service book-reader-interaction-service-type))
       ((book-execution-language-profile)
        (service (service-kind item)
                 (replace-manifest-entries (service-value item))))
       (else item)))
   services))

(define pinenote-book-execution-reader-interaction-operating-system
  (operating-system
    (inherit %base-system)
    (services
     (replace-services (operating-system-user-services %base-system)))))

pinenote-book-execution-reader-interaction-operating-system
