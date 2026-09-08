(define-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (gnu packages guile)
  #:use-module ((gnu packages python) #:select (python))
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module (guix utils)
  #:use-module (pinenote packages gvisor)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote systems base)
  #:export (pinenote-book-execution-spike-operating-system))

;; NON-SHIPPING TEST KERNEL.  At pinned gVisor commit
;; fd2f6b2674208086e324c2f739155eb7e1b48ff2, both --directfs values need host
;; user namespaces: modifySpecForDirectfs adds one for directfs+network=none,
;; and the non-DirectFS sandbox branch creates one for its support process.
;; Keep this one-option delta local to the execution-spike system; never change
;; the shipping kernel or the permanent forward-port patch for this experiment.
(define linux-pinenote-book-execution-test
  (package
    (inherit linux-pinenote)
    (name "linux-pinenote-book-execution-test")
    (arguments
     (substitute-keyword-arguments (package-arguments linux-pinenote)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'configure 'enable-user-namespaces-for-gvisor
              (lambda _
                (invoke "scripts/config" "--enable" "USER_NS")
                (invoke "make" "olddefconfig")
                (invoke "grep" "-Fqx" "CONFIG_USER_NS=y" ".config")))))))))

;; QEMU-only, non-shipping execution-spike system.  Keep the language
;; environment distinct from /run/current-system/profile: the future OCI
;; bundle can expose this narrow closure without exposing the whole system
;; profile.  The /etc entry is an immutable reference from the system closure,
;; so Guix retains the profile for the lifetime of this system generation.
(define %book-execution-language-profile
  (profile
   (name "wilkbook-book-execution-languages")
   ;; The sibling Book Protocol codec imports (json) and is tested against
   ;; guile-json 4.7.3.  Retain that exact current package with Guile now so a
   ;; later system realization does not repeat the profile closure build.
   (content (packages->manifest (list guile-3.0 guile-json-4 python)))))

;; Trusted generator/launcher environment.  Keep this separate from both the
;; broad system profile (whose Guile version may differ) and the sandboxed
;; language closure (which intentionally contains Python).
(define %book-execution-supervisor-profile
  (profile
   (name "wilkbook-book-execution-supervisor")
   (content (packages->manifest (list guile-3.0 guile-json-4)))))

;; This tiny immutable input is only for the first in-guest interpreter and
;; mount-policy smoke.  It is trusted system configuration, not a book manifest
;; and not a substitute for the Book Protocol fixtures.
(define %book-execution-smoke-book
  (plain-file "wilkbook-book-execution-smoke.txt"
              "trusted book-execution smoke fixture\n"))

;; package-version carries our Guix "-pinenote" identity, while the kernel's
;; configured LOCALVERSION is empty and its installed module directory fixes
;; uname -r at exactly 7.1.8.  Keep the runtime assertion explicit.
(define %book-execution-kernel-release "7.1.8")

;; The boot service loads the narrow OCI implementation as source and supplies
;; the profile closure through a Guix-generated reference graph, so the guest
;; needs neither a Guix daemon nor a broad /gnu/store mount supplied by QEMU.
;; Its fixed payload is the only first-smoke extension; no book-selected flag or
;; general execution contract is introduced here.
(define %book-execution-oci-source
  (local-file "../tools/book-execution-spike/oci-bundle.scm"
              "wilkbook-book-execution-oci-bundle.scm"))

(define %book-execution-guest-smoke-source
  (local-file "../tools/book-execution-spike/guest-smoke.scm"
              "wilkbook-book-execution-guest-smoke.scm"))

(define %book-execution-language-closure
  (references-file %book-execution-language-profile
                   "wilkbook-book-execution-language-closure"))

(define %book-execution-guest-smoke-entry
  (program-file
   "wilkbook-book-execution-guest-smoke"
   #~(begin
       (primitive-load #$%book-execution-guest-smoke-source)
       (let ((status
              ((module-ref (resolve-module '(guest-smoke)) 'guest-smoke-main)
               (command-line))))
         ;; guest-smoke-main force-flushes every serial assertion and reports
         ;; failures before returning.  Complete filesystem writeback, then
         ;; replace this Shepherd-owned process with the shutdown client.  The
         ;; marker parser, not halt's exit status, remains the success oracle.
         (sync)
         (format (current-error-port)
                 "book-execution guest smoke exited with status ~a; requesting shutdown~%"
                 status)
         (force-output (current-output-port))
         (force-output (current-error-port))
         (execl "/run/current-system/profile/sbin/halt" "halt")))))

(define %book-execution-build-manifest-bounded-diagnostics-v1
  (mixed-text-file
   "wilkbook-book-execution-build-manifest-bounded-diagnostics-v1"
   "schema=1\n"
   "purpose=non-shipping-pinenote-qemu-virt-compatibility-smoke\n"
   "architecture=arm64\n"
   "target=aarch64-linux-gnu\n"
   "kernel-base-package=linux-pinenote\n"
   "kernel-upstream-package=nongnu:linux-7.1\n"
   "kernel-package=linux-pinenote-book-execution-test\n"
   "kernel-version=" (package-version linux-pinenote-book-execution-test) "\n"
   "kernel-runtime-release=" %book-execution-kernel-release "\n"
   "kernel-output=" linux-pinenote-book-execution-test "\n"
   "kernel-config=" (file-append linux-pinenote-book-execution-test "/.config") "\n"
   "kernel-config-delta=CONFIG_USER_NS:y-after-olddefconfig\n"
   "language-profile=" %book-execution-language-profile "\n"
   "supervisor-profile=" %book-execution-supervisor-profile "\n"
   "language-closure=" %book-execution-language-closure "\n"
   "gvisor-package=" gvisor-bin "\n"
   "gvisor-release=release-20260831.0\n"
   "execution-profile=isolation-userns\n"
   "directfs=false\n"
   "network=none\n"
    "platform=systrap\n"
    "ignore-cgroups=false\n"
    "diagnostic-debug=true\n"
    "diagnostic-debug-log=private-bundle/runsc-debug/\n"
     "diagnostic-panic-log=private-bundle/runsc-panic/runsc.panic.%COMMAND%.log\n"
    "diagnostic-alsologtostderr=true\n"))

(define (book-execution-guest-smoke-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(book-execution-guest-smoke))
    (requirement '(user-processes))
    (documentation
     "Run the fixed Guile-supervised gVisor compatibility smoke, emit serial markers, and halt the disposable QEMU guest.")
    (respawn? #f)
    (start
     #~(let* ((supervisor #$%book-execution-supervisor-profile)
              (guile (string-append supervisor "/bin/guile")))
         ;; Pinned Shepherd's fork+exec constructor returns a monitored process
         ;; after exec succeeds.  Thus this start callback reaches 'running'
         ;; before the child eventually replaces itself with halt; shutdown no
         ;; longer waits on the service's own still-'starting' future.
         (make-forkexec-constructor
          (list
           "/run/current-system/profile/bin/env" "-i"
           "HOME=/nonexistent"
           "LANG=C"
           "LC_ALL=C"
           "PATH=/run/current-system/profile/bin"
           "GUILE_AUTO_COMPILE=0"
           (string-append "GUILE_LOAD_PATH=" supervisor
                          "/share/guile/site/3.0")
           (string-append "GUILE_LOAD_COMPILED_PATH=" supervisor
                          "/lib/guile/3.0/site-ccache")
           guile "--no-auto-compile" "-s"
           #$%book-execution-guest-smoke-entry
           #$%book-execution-oci-source
           #$%book-execution-language-profile
           #$%book-execution-language-closure
           #$%book-execution-smoke-book
           #$%book-execution-kernel-release)
          #:file-creation-mask #o077)))
    (stop #~(make-kill-destructor)))))

(define book-execution-guest-smoke-service-type
  (service-type
   (name 'book-execution-guest-smoke)
   (extensions
    (list (service-extension shepherd-root-service-type
                             book-execution-guest-smoke-shepherd-service)))
   (default-value #f)
    (description
     "Run the fixed non-shipping book-execution compatibility assertions in a disposable QEMU guest.")))

;; This headless one-shot fixture has no serial operator login.  Retain the
;; serial kernel console for fixed markers and diagnostics, but remove the
;; inherited agetty so no prompt or login session can share that stream.
;; Guix's virtual-terminal mingetty services remain because console-font
;; services require their term-ttyN provisions; they cannot select ttyAMA0.
(define %book-execution-headless-base-services
  (modify-services %pinenote-base-services
    (delete agetty-service-type)))

(define %book-execution-spike-services
  (append
   (list
    (simple-service
     'book-execution-language-profile
     etc-service-type
      `(("wilkbook-execution-spike/profile"
         ,%book-execution-language-profile)
       ("wilkbook-execution-spike/supervisor-profile"
        ,%book-execution-supervisor-profile)
       ("wilkbook-execution-spike/smoke-book"
        ,%book-execution-smoke-book)
       ("wilkbook-execution-spike/build-manifest"
         ,%book-execution-build-manifest-bounded-diagnostics-v1)))
    (service book-execution-guest-smoke-service-type))
   %book-execution-headless-base-services))

(define %pinenote-book-execution-spike-base
  (make-pinenote-operating-system
   #:host-name "pinenote-book-execution-spike"
   #:kernel linux-pinenote-book-execution-test
   ;; runsc and all version-matched sidecars are installed in the system
   ;; profile.  Trusted Guile + guile-json live in their retained separate
   ;; profile above; the language profile is the only closure exposed to a
   ;; sandbox and additionally contains Python as a book language.
   #:packages (append (list gvisor-bin)
                       %pinenote-local-packages
                       %base-packages)
   #:services %book-execution-spike-services))

(define pinenote-book-execution-spike-operating-system
  (operating-system
    (inherit %pinenote-book-execution-spike-base)
    ;; runsc --ignore-cgroups=false creates and joins the explicit OCI
    ;; cgroupsPath.  %base-file-systems does not mount a hierarchy, so declare
    ;; cgroup2 only for this non-shipping VM system.  The Guile launcher also
    ;; verifies this mount and a create/remove probe before execing runsc.
    (file-systems
     (append %control-groups
             (operating-system-file-systems
              %pinenote-book-execution-spike-base)))))

pinenote-book-execution-spike-operating-system
