(define-module (pinenote systems pinenote-book-state-reader)
  #:use-module (gnu packages)
  #:use-module (gnu packages guile)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix profiles)
  #:use-module (pinenote packages gvisor)
  #:use-module (pinenote packages gvisor-source)
  #:use-module (pinenote systems pinenote-book-execution-spike)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (pinenote-book-state-reader-operating-system))

;; NON-SHIPPING POST-V9 STARTUP-FIX GUEST SOURCE CANDIDATE.  This system has only a
;; cooperative in-guest budget and is not supported for standalone execution;
;; every eventual QEMU boot requires the separately reviewed hard outer owner.
;; Start from the public
;; execution-spike system, retain its 45-path language profile and USER_NS
;; kernel object, and replace the official binary gVisor package with the
;; reusable source-built release.  Do not import any of the historical systems
;; whose closure includes gvisor-local-test-artifacts.scm.
(define %base-system
  pinenote-book-execution-spike-operating-system)
(define %spike-module
  (resolve-module '(pinenote systems pinenote-book-execution-spike)))
(define (spike-private name) (module-ref %spike-module name))

(define %state-root "/var/lib/wilkbook-book-state-demo")
(define %state-database
  "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite")
(define %state-sentinel
  "/var/lib/wilkbook-book-state-demo/.sandbox-boundary-sentinel-v1")
(define %state-sentinel-content
  "wilkbook-sandbox-boundary-sentinel-v1\n")
(define %state-file-system-service
  (string->symbol
   "file-system-/var/lib/wilkbook-book-state-demo"))

(define %guile-gcrypt
  (specification->package "guile-gcrypt@0.5.0"))
(define %sqlite-binding guile-sqlite3)

(define (require-package-version package expected)
  (unless (string=? (package-version package) expected)
    (error "trusted Book State package version changed"
           (package-name package) (package-version package) expected))
  package)

(define (required-input package label)
  (let ((entry (assoc label (package-inputs package))))
    (if (and entry (pair? (cdr entry)) (package? (cadr entry)))
        (cadr entry)
        (error "trusted package input is absent" (package-name package) label))))

(define %sqlite-package (required-input %sqlite-binding "sqlite"))

;; Evaluation-time pins complement the already accepted AArch64 dependency
;; packet.  The output identities are repeated in the build manifest and guest
;; runtime provenance checks below.
(for-each
 (lambda (entry)
   (require-package-version (car entry) (cdr entry)))
 `((,guile-3.0 . "3.0.9")
   (,guile-json-4 . "4.7.3")
   (,%guile-gcrypt . "0.5.0")
   (,%sqlite-binding . "0.1.3")
   (,%sqlite-package . "3.53.1")))
(unless (member "aarch64-linux" (package-supported-systems %sqlite-binding))
  (error "pinned guile-sqlite3 no longer supports aarch64-linux"))

(define %book-state-supervisor-profile
  (profile
   (name "wilkbook-book-state-supervisor")
   (content
    (packages->manifest
     (list guile-3.0 guile-json-4 %guile-gcrypt %sqlite-binding)))))

;; Machine gates bind canonical functional source bytes, not mutable live
;; reviews, public runners, or generated build/ snapshots.  This small local
;; attestation records the independently accepted historical roots without
;; making append-only prose or retained packets executable dependencies.
(define %accepted-prerequisite-attestation
  (local-file
   "../tools/book-state-guest/accepted-prerequisites-v1.txt"
   "wilkbook-book-state-accepted-prerequisites-v1.txt"))
(define %outer-qemu-handoff
  (local-file
   "../tools/book-state-guest/outer-qemu-handoff-v1.txt"
   "wilkbook-book-state-outer-qemu-handoff-v1.txt"))
(define %channels-source
  (local-file "../../channels.scm" "wilkbook-book-state-channels.scm"))
(define %base-system-source
  (local-file
   "pinenote-book-execution-spike.scm"
   "wilkbook-public-book-execution-spike-system.scm"))
(define %gvisor-source-package-definition
  (local-file
   "../packages/gvisor-source.scm"
   "wilkbook-public-gvisor-source-package.scm"))
(define %gvisor-binary-package-definition
  (local-file
   "../packages/gvisor.scm"
   "wilkbook-public-gvisor-binary-package.scm"))

(define %guest-smoke-source
  (local-file "../tools/book-execution-spike/guest-smoke.scm"
              "wilkbook-accepted-guest-smoke.scm"))
(define %base-oci-source
  (local-file "../tools/book-execution-spike/oci-bundle.scm"
              "wilkbook-accepted-oci-bundle.scm"))
(define %accepted-protocol-oci-source
  (local-file "../tools/book-execution-spike/oci-book-bundle.scm"
              "wilkbook-accepted-protocol-oci-bundle.scm"))
(define %state-protocol-oci-source
  (local-file "../tools/book-state-guest/oci-state-book-bundle.scm"
              "wilkbook-state-protocol-oci-bundle.scm"))
(define %guest-protocol-source
  (local-file "../tools/book-execution-spike/guest-book-protocol.scm"
              "wilkbook-accepted-guest-book-protocol.scm"))
(define %guest-ui-source
  (local-file "../tools/book-execution-spike/guest-virtio-book-ui.scm"
              "wilkbook-accepted-guest-virtio-book-ui.scm"))
(define %private-control-source
  (local-file "../tools/book-state-reader/private-control.scm"
              "wilkbook-accepted-state-private-control.scm"))

(define %book-protocol-source
  (local-file
   "../tools/book-protocol/book-protocol.scm"
   "wilkbook-accepted-book-protocol.scm"))
(define %blocking-protocol-source
  (local-file
   "../tools/book-protocol/book-protocol/blocking-io.scm"
   "wilkbook-accepted-book-protocol-blocking-io.scm"))
(define %python-protocol-source
  (local-file
   "../tools/book-protocol/book_protocol.py"
   "wilkbook-accepted-book_protocol.py"))
(define %backend-source
  (local-file
   "../tools/book-state/book-state.scm"
   "wilkbook-accepted-book-state.scm"))
(define %schema-source
  (local-file
   "../tools/book-state/schema-v1.sql"
   "wilkbook-accepted-book-state-schema-v1.sql"))
(define %state-operation-id-source
  (local-file
   "../tools/book-state-protocol/book-state-operation-id.scm"
   "wilkbook-accepted-book-state-operation-id.scm"))
(define %state-protocol-source
  (local-file
   "../tools/book-state-protocol/book-state-protocol.scm"
   "wilkbook-accepted-book-state-protocol.scm"))
(define %state-adapter-source
  (local-file
   "../tools/book-state-protocol/book-state-backend-adapter.scm"
   "wilkbook-accepted-book-state-backend-adapter.scm"))
(define %state-delegate-source
  (local-file
   "../tools/book-state-protocol/session-integration/book-state-session-delegate.scm"
   "wilkbook-accepted-book-state-session-delegate.scm"))

(define %state-session-source
  (local-file
   "../tools/book-state-reader-join/empty-action-successor/book-session.scm"
   "wilkbook-accepted-reader-join-v2-book-session.scm"))
(define %reader-bridge-source
  (local-file
   "../tools/book-state-reader-join/book-state-reader-bridge.scm"
   "wilkbook-accepted-reader-join-v2-bridge.scm"))
(define %guile-book-source
  (local-file
   "../tools/book-state-reader-join/joined-note-book.scm"
   "wilkbook-accepted-reader-join-v2-guile-book.scm"))
(define %python-book-source
  (local-file
   "../tools/book-state-reader-join/joined_note_book.py"
   "wilkbook-accepted-reader-join-v2-python-book.py"))
(define %guile-boundary-probe-source
  (local-file
   "../tools/book-state-guest/sandbox-storage-boundary-guile.scm"
   "wilkbook-sandbox-storage-boundary-guile.scm"))
(define %python-boundary-probe-source
  (local-file
   "../tools/book-state-guest/sandbox_storage_boundary.py"
   "wilkbook-sandbox-storage-boundary-python.py"))

(define %authority-source
  (local-file "../tools/book-state-guest/book-state-guest-authority.scm"
              "wilkbook-book-state-guest-authority.scm"))
(define %runsc-fd3-source
  (local-file "../tools/book-state-guest/runsc-fd3-exec.scm"
              "wilkbook-book-state-runsc-fd3-exec.scm"))
(define %candidate-source-manifest
  (local-file "../tools/book-state-guest/SOURCE-MANIFEST.sha256"
              "wilkbook-book-state-guest-SOURCE-MANIFEST.sha256"))

;; These accepted UI files remain outer-QEMU inputs; retaining exact individual
;; references here binds the guest codec to the independently accepted native
;; control peer without depending on that component's mutable public runner or
;; aggregate hash file, installing KOReader, or exposing any file to a book.
(define %ui-meta-source
  (local-file
   "../tools/book-state-reader/fixture/bookstatereader.koplugin/_meta.lua"
   "wilkbook-accepted-state-reader-meta.lua"))
(define %ui-main-source
  (local-file
   "../tools/book-state-reader/fixture/bookstatereader.koplugin/main.lua"
   "wilkbook-accepted-state-reader-main.lua"))
(define %ui-channel-source
  (local-file
   "../tools/book-state-reader/fixture/bookstatereader.koplugin/state_channel.lua"
   "wilkbook-accepted-state-reader-channel.lua"))
(define %ui-audit-source
  (local-file
   "../tools/book-state-reader/fixture/bookstatereader.koplugin/ui_audit.lua"
   "wilkbook-accepted-state-reader-audit.lua"))

(define %trusted-modules
  (file-union
   "wilkbook-book-state-guest-trusted-modules"
   `(("guest-smoke.scm" ,%guest-smoke-source)
     ("oci-bundle.scm" ,%base-oci-source)
     ("book-protocol.scm" ,%book-protocol-source)
     ("book-protocol/blocking-io.scm" ,%blocking-protocol-source)
     ("book-state.scm" ,%backend-source)
     ("schema-v1.sql" ,%schema-source)
     ("book-state-operation-id.scm" ,%state-operation-id-source)
     ("book-state-protocol.scm" ,%state-protocol-source)
     ("book-state-backend-adapter.scm" ,%state-adapter-source)
     ("book-state-session-delegate.scm" ,%state-delegate-source)
     ("book-session.scm" ,%state-session-source)
     ("book-state-reader-bridge.scm" ,%reader-bridge-source)
     ("private-control.scm" ,%private-control-source)
     ("guest-virtio-book-ui.scm" ,%guest-ui-source))))

(define %runtime-source-hashes
  `(("guest-smoke.scm" ,%guest-smoke-source
     "74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa")
    ("oci-bundle.scm" ,%base-oci-source
     "a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c")
    ("accepted-oci-book-bundle.scm" ,%accepted-protocol-oci-source
     "c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7")
    ("oci-state-book-bundle.scm" ,%state-protocol-oci-source
     "2585371b7f961b7222a92e34818bde8fff0817c42a36b6f87c8c9839432e33b3")
    ("guest-book-protocol.scm" ,%guest-protocol-source
     "10b2bf5155697ad4ef361e3a975bff5afa8c97a3988c44d6f7356248c6900e6e")
    ("guest-virtio-book-ui.scm" ,%guest-ui-source
     "3b6e8eb172d7e3575c36a95a42d66635c101f7404d2f8028ca0f541dfba66966")
    ("private-control.scm" ,%private-control-source
     "4cf7702704cae8db2eff4cc48b13cf139cfb616b0809f69f141e9c684325f5d3")
    ("book-protocol.scm" ,%book-protocol-source
     "91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44")
    ("blocking-io.scm" ,%blocking-protocol-source
     "543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd")
    ("book_protocol.py" ,%python-protocol-source
     "4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735")
    ("book-state.scm" ,%backend-source
     "7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9")
    ("schema-v1.sql" ,%schema-source
     "70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb")
    ("book-state-operation-id.scm" ,%state-operation-id-source
     "dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee")
    ("book-state-protocol.scm" ,%state-protocol-source
     "425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257")
    ("book-state-backend-adapter.scm" ,%state-adapter-source
     "349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769")
    ("book-state-session-delegate.scm" ,%state-delegate-source
     "eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6")
    ("reader-join-v2-book-session.scm" ,%state-session-source
     "a6d904a0bc30237de4dc1ccc0e61e955e4def8e10037478505a33a5d15a934e7")
    ("book-state-reader-bridge.scm" ,%reader-bridge-source
     "5e74d144ba8a687425c2e892a5fa7c1ad812fc0680285e0aecd0089946410ac1")
    ("joined-note-book.scm" ,%guile-book-source
     "b4d9fd9b459b5738fcf1da50e578c020e7c5c2d8ca3a5d1a5d09c5f3ddb90a67")
    ("joined_note_book.py" ,%python-book-source
     "e9b0cebd483bae576976f8da0f6bcb5fdf877f29154ce0ce842f4325827ecb6a")
    ("sandbox-storage-boundary-guile.scm" ,%guile-boundary-probe-source
     "0ff742d707955a6c1db5d1eb93f1cddd277fa7c113eeaacc16f3eb785744079e")
    ("sandbox_storage_boundary.py" ,%python-boundary-probe-source
     "2381b92d3192375160909c60124e3dcb6004c20a581df18ac04dac4665137a5c")
    ("book-state-guest-authority.scm" ,%authority-source
     "f8a30641076d5e10fe4e49d5ee0f2fecf0da82450f5ac90d7137fcbdbb7037fb")
    ("runsc-fd3-exec.scm" ,%runsc-fd3-source
     "15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb")
    ("accepted-prerequisites-v1.txt" ,%accepted-prerequisite-attestation
     "b7ccb1d47d823de8b88c345b506ba8c4c865ee146c8fa7cad7ce0fd5561d99a5")
    ("outer-qemu-handoff-v1.txt" ,%outer-qemu-handoff
     "27b747aac8c8909fa4ce224d1030e61b389a3d2fee6a2d1737ac055889fd607d")
    ("channels.scm" ,%channels-source
     "661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1")
    ("pinenote-book-execution-spike.scm" ,%base-system-source
     "b56fafc9c64cf3ba816de85d6766b562fe1e62aac9956bfc2506af49c8336c09")
    ("gvisor-source.scm" ,%gvisor-source-package-definition
     "0b35b6bfa406bc6b063e3e1d1ff6daabe26acfdff66a673b1fe315ceffc4b740")
    ("gvisor.scm" ,%gvisor-binary-package-definition
     "8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d")
    ("accepted-state-reader-meta.lua" ,%ui-meta-source
     "64b2d8ad62e34854a8d4673b7b7aba01918f7aaa736497265449d31fa269e451")
    ("accepted-state-reader-main.lua" ,%ui-main-source
     "837a0934f2de2df071ee55b3288971b1628a523f5822f788c770324db6c33126")
    ("accepted-state-reader-channel.lua" ,%ui-channel-source
     "aa3c2cf9bbc025208e5ebdfe6745ac83d2e2d2572ceba7845b7b14c20bd6fc5c")
    ("accepted-state-reader-audit.lua" ,%ui-audit-source
     "1765dcb1bf907002eae66457c2bc00bf66409c341a5bcf844f3fae3a37232130")))

(define %source-manifest
  (apply
   mixed-text-file
   "wilkbook-book-state-guest-source-manifest"
   (append
    (list
     "schema=1\n"
      "role=non-shipping-two-boot-persistent-note-guest\n"
      "guest-source-successor=v9-generic-state-mount-flags\n"
      "post-v9-startup-fix=volume-ready-compiled-module-bindings-unrealized\n"
      "post-v9-startup-fix-runtime=not-executed\n"
      "candidate-repository-baseline=399764fa53d4e54bdcfaf84c362d4d1debf35f4c\n"
     "accepted-prerequisite-repository-base=549dded816e5f73d2c11557ffcd3130a018b82a8\n"
     "candidate-source-manifest=" %candidate-source-manifest "\n"
     "accepted-prerequisite-attestation="
     %accepted-prerequisite-attestation "\n"
     "live-reviews=informational-not-inputs\n"
     "canonical-generated-build-inputs=forbidden\n")
    (append-map
     (lambda (entry)
       (list "sha256=" (list-ref entry 2) " " (car entry) "="
             (cadr entry) "\n"))
     %runtime-source-hashes))))

(define %build-manifest
  (mixed-text-file
   "wilkbook-book-state-reader-build-manifest"
   "schema=1\n"
   "purpose=non-shipping-two-boot-native-ui-book-state-persistence\n"
   "architecture=arm64\n"
   "target=aarch64-linux-gnu\n"
    "base-system=pinenote-book-execution-spike\n"
    "base-system-build-manifest=not-inherited-runtime-identity-superseded\n"
   "source-manifest=" %source-manifest "\n"
   "kernel-package=linux-pinenote-book-execution-test\n"
   "kernel-derivation=/gnu/store/61ls988abhyi7lzvm19plffyv580nxc1-linux-pinenote-book-execution-test-7.1.8-pinenote.drv\n"
   "kernel-output=/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote\n"
   "kernel-image-sha256=5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9\n"
   "kernel-config-sha256=0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309\n"
   "kernel-config-delta=CONFIG_USER_NS:n-to-y-only\n"
   "gvisor-package=" gvisor/source "\n"
   "gvisor-package-label=gvisor/source\n"
   "gvisor-source-commit=fd2f6b2674208086e324c2f739155eb7e1b48ff2\n"
   "gvisor-source-aarch64-output=/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0\n"
   "gvisor-runtime-validation=not-yet-executed-new-qemu-gate-required\n"
   "historical-control-runtime=not-evidence-for-this-source-built-package\n"
   "gvisor-release=release-20260831.0\n"
   "language-profile=" (spike-private '%book-execution-language-profile) "\n"
   "language-closure=" (spike-private '%book-execution-language-closure) "\n"
    "language-closure-sha256=48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc\n"
    "language-closure-expected-paths=45\n"
    "language-closure-sqlite-version=3.39.3-present-nonauthority\n"
     "language-closure-sqlite-aarch64-output=/gnu/store/cy2qjbj9akbc2c3n6cjribi4alkqqzkc-sqlite-3.39.3\n"
     "language-closure-sqlite-native-output=/gnu/store/b769xis704c3h67y764hlnq0j3lb6asg-sqlite-3.39.3\n"
     "language-closure-sqlite-cli=sqlite3-present\n"
     "language-closure-python-sqlite3=package-and-_sqlite3-extension-present\n"
    "trusted-supervisor-profile=" %book-state-supervisor-profile "\n"
    "trusted-guile-sqlite3-output=/gnu/store/0c81pri4sf9sm16578hjp7di823l5m7y-guile-sqlite3-0.1.3\n"
    "trusted-sqlite-output=/gnu/store/jcrkzfnla7pg7g07v7xsv58hwgzlin8x-sqlite-3.53.1\n"
    "persistent-state-authority=trusted-guile-backend\n"
   "state-volume-size=67108864\n"
   "state-volume-label=WBBookStateV1\n"
   "state-volume-mount=/var/lib/wilkbook-book-state-demo\n"
   "state-volume-options=noatime,nodev,nosuid,noexec\n"
   "state-root-mode=0700\n"
    "state-database=/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite\n"
    "state-database-fallback=forbidden\n"
    "book-authority-storage-mount=absent\n"
    "book-authority-storage-fd=absent\n"
     "book-private-ui-transport=absent\n"
     "book-storage-boundary-probe=required-before-accepted-book\n"
     "book-storage-boundary-observer=actual-finalized-owned-runsc-stdout\n"
     "book-storage-boundary-marker-cardinality=exactly-one-per-language\n"
     "book-storage-boundary-marker-publication=verbatim-after-child-drain\n"
     "book-storage-boundary-capture-binding=language,container,bytes,sha256\n"
     "book-storage-boundary-book-result-binding=operation,resulting-state-version\n"
     "book-storage-boundary-read-only-result=read-version,no-new-commit\n"
     "book-storage-boundary-validation-or-publication-failure=guest-fail-even-after-exit-zero\n"
    "book-protocol-fd=3\n"
   "runsc-pass-fd=3:3\n"
   "python-flags=-I,-S\n"
   "named-port=org.wilkbook.book-interaction\n"
    "guest-cooperative-polling-budget-seconds=300\n"
    "guest-hard-cleanup-deadline=none\n"
    "state-operation-timeout-seconds=3\n"
    "required-outer-timeout-option=--timeout-seconds\n"
    "required-outer-timeout-seconds=360\n"
    "required-outer-term-grace-option=--term-grace-seconds\n"
    "required-outer-term-grace-seconds=5\n"
    "required-outer-timeout-result=fail-guest-status-not-assessed\n"
    "accepted-outer-process-guardian-sha256=0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca\n"
    "actual-two-boot-runner-binding=pending-independent-proof\n"
    "standalone-image-hard-deadline=not-provided\n"
   "execution-profile=isolation-userns\n"
   "platform=systrap\n"
   "directfs=false\n"
   "network=none\n"
   "host-uds=none\n"
   "sidecar-usage-policy=strict\n"
   "sidecar-release-enforcement-policy=always\n"))

(define %guest-entry
  (program-file
   "wilkbook-book-state-guest"
   #~(begin
       ;; Load accepted lifetime ownership first, then the one-line -S OCI
       ;; successor and finite persistent-state authority.
       (primitive-load #$%guest-protocol-source)
       (primitive-load #$%state-protocol-oci-source)
       (primitive-load #$%authority-source)
       (let* ((config
               (list
                (cons 'sources
                      (list
                       #$@(map (lambda (entry)
                                 #~(list #$(car entry) #$(cadr entry)
                                         #$(list-ref entry 2)))
                               %runtime-source-hashes)))
                (cons 'language-profile
                      #$(spike-private '%book-execution-language-profile))
                 (cons 'language-closure
                       #$(spike-private '%book-execution-language-closure))
                 (cons 'guile-boundary-probe #$%guile-boundary-probe-source)
                 (cons 'python-boundary-probe #$%python-boundary-probe-source)
                 (cons 'guile-book #$%guile-book-source)
                (cons 'python-book #$%python-book-source)
                (cons 'guile-protocol #$%book-protocol-source)
                (cons 'blocking-protocol #$%blocking-protocol-source)
                (cons 'python-protocol #$%python-protocol-source)
                (cons 'supervisor-guile
                      #$(file-append %book-state-supervisor-profile
                                    "/bin/guile"))
                (cons 'runsc-fd3-adapter #$%runsc-fd3-source)
                (cons 'kernel-release
                      #$(spike-private '%book-execution-kernel-release))))
              (status
               ((module-ref (resolve-module '(book-state-guest-authority))
                            'book-state-guest-main)
                config (command-line))))
         ;; A return means the authority closed both delegates, both runsc
         ;; ownership trees, SQLite, and the UI channel.  A blocked callback can
         ;; prevent this point forever; only the required outer QEMU owner then
         ;; supplies hard containment, and no halt/unmount success is claimed.
         ;; On ordinary return, flush the persistent volume and let Shepherd
         ;; stop services in dependency order before file-system unmount.
         (sync)
         (format (current-error-port)
                 "book-state guest exited with status ~a; requesting shutdown~%"
                 status)
         (force-output (current-output-port))
         (force-output (current-error-port))
         (execl "/run/current-system/profile/sbin/halt" "halt")))))

(define (book-state-volume-ready-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(book-state-volume-ready))
    (requirement (list %state-file-system-service))
    (documentation
     "Verify the mandatory WBBookStateV1 ext4 mount and make its trusted root mode 0700 before Book State opens SQLite.")
    (one-shot? #t)
    ;; This code is compiled in the generated Shepherd service module, not in
    ;; this configuration module.  Declare every non-default binding here;
    ;; `use-modules' inside the start procedure does not establish lexical
    ;; bindings for compiled g-expression code (V9 runtime diagnosis,
    ;; 2026-09-07).
    (modules
     (append '((ice-9 textual-ports)
               (srfi srfi-1)
               (srfi srfi-13))
             %default-modules))
    (start
     #~(lambda _
         (define root #$%state-root)
          (define sentinel #$%state-sentinel)
          (define sentinel-content #$%state-sentinel-content)
          (define (find-value procedure values)
           (and (pair? values)
                (or (procedure (car values))
                    (find-value procedure (cdr values)))))
         (define (mount-record)
           (find-value
            (lambda (line)
              (let* ((parts (string-tokenize line))
                     (separator
                      (list-index (lambda (part) (string=? part "-")) parts)))
                (and separator
                     (>= separator 6)
                     (= (- (length parts) separator 1) 3)
                     (string=? (list-ref parts 4) root)
                     (list (list-ref parts (+ separator 1))
                           (append (string-split (list-ref parts 5) #\,)
                                   (string-split (last parts) #\,))))))
            (string-split
             (call-with-input-file "/proc/self/mountinfo" get-string-all)
             #\newline)))
         (let ((record (mount-record)))
           (unless (and record
                        (string=? (car record) "ext4")
                        (every (lambda (option) (member option (cadr record)))
                               '("noatime" "nodev" "nosuid" "noexec")))
             (error "mandatory WBBookStateV1 ext4 mount is not exact")))
          (chmod root #o700)
          (let ((info (lstat root)))
           (unless (and (string=? (canonicalize-path root) root)
                        (eq? (stat:type info) 'directory)
                        (zero? (stat:uid info))
                        (= (logand (stat:mode info) #o7777) #o700))
              (error "trusted Book State root did not become mode 0700")))
          ;; This non-secret, compile-fixed file must exist on the authority
          ;; volume before either sandbox runs.  The in-sandbox probes know its
          ;; path but must be unable to stat, read, or write it.
          (let ((existing
                 (catch 'system-error
                   (lambda () (lstat sentinel))
                   (lambda arguments
                     (if (= (system-error-errno arguments) ENOENT)
                         #f
                         (apply throw 'system-error arguments))))))
            (unless existing
              (let* ((descriptor
                      (open-fdes sentinel
                                 (logior O_WRONLY O_CREAT O_EXCL O_CLOEXEC)
                                 #o600))
                     (port (fdopen descriptor "w")))
                (display sentinel-content port)
                (force-output port)
                (close-port port)))
            (chmod sentinel #o600)
            (let ((info (lstat sentinel)))
              (unless (and (eq? (stat:type info) 'regular)
                           (zero? (stat:uid info))
                           (= (stat:nlink info) 1)
                           (= (logand (stat:mode info) #o7777) #o600)
                           (string=?
                            (call-with-input-file sentinel get-string-all)
                            sentinel-content))
                (error "trusted sandbox-boundary sentinel is not exact"))))
          #t))
    (stop #~(const #t)))))

(define book-state-volume-ready-service-type
  (service-type
   (name 'book-state-volume-ready)
   (extensions
    (list (service-extension shepherd-root-service-type
                             book-state-volume-ready-shepherd-service)))
   (default-value #f)
   (description
    "Prepare the mandatory private Book State ext4 root before authority startup.")))

(define (book-state-guest-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(book-state-guest-gate))
    (requirement '(user-processes udev book-state-volume-ready))
    (documentation
     "Run the finite two-language native-UI/Book-State authority and halt the disposable guest after ordered cleanup.")
    (respawn? #f)
    (start
     #~(let* ((supervisor #$%book-state-supervisor-profile)
              (trusted-modules #$%trusted-modules)
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
           guile "--no-auto-compile" "-s" #$%guest-entry)
          #:file-creation-mask #o077)))
    (stop #~(make-kill-destructor)))))

(define book-state-guest-service-type
  (service-type
   (name 'book-state-guest-gate)
   (extensions
    (list (service-extension shepherd-root-service-type
                             book-state-guest-shepherd-service)))
   (default-value #f)
   (description
    "Run the source-only non-shipping persistent Book State guest gate.")))

(define %state-file-system
  (file-system
    (mount-point %state-root)
    (device (file-system-label "WBBookStateV1"))
    (type "ext4")
    (flags '(no-atime no-dev no-suid no-exec))
    (mount-may-fail? #f)
    (check? #t)))

(define (service-name item)
  (service-type-name (service-kind item)))

(define (replace-manifest-entries entries)
  (for-each
   (lambda (name)
     (unless (= 1 (count (lambda (entry) (string=? (car entry) name)) entries))
       (error "inherited public spike manifest entry changed" name)))
   '("wilkbook-execution-spike/profile"
     "wilkbook-execution-spike/supervisor-profile"
     "wilkbook-execution-spike/smoke-book"
     "wilkbook-execution-spike/build-manifest"))
  (append
   (filter-map
    (lambda (entry)
      (cond
       ((string=? (car entry) "wilkbook-execution-spike/smoke-book") #f)
       ((string=? (car entry) "wilkbook-execution-spike/build-manifest")
        (list (car entry) %build-manifest))
       ((string=? (car entry) "wilkbook-execution-spike/supervisor-profile")
        (list (car entry) %book-state-supervisor-profile))
       (else entry)))
    entries)
   (list (list "wilkbook-execution-spike/protocol-sources"
               %source-manifest))))

(define (replace-services services)
  (unless (= 1 (count (lambda (item)
                        (eq? (service-name item)
                             'book-execution-guest-smoke))
                      services))
    (error "inherited public spike guest service changed"))
  (unless (= 1 (count (lambda (item)
                        (eq? (service-name item)
                             'book-execution-language-profile))
                      services))
    (error "inherited public spike manifest service changed"))
  (append
   (map
    (lambda (item)
      (case (service-name item)
        ((book-execution-guest-smoke)
         (service book-state-guest-service-type))
        ((book-execution-language-profile)
         (service (service-kind item)
                  (replace-manifest-entries (service-value item))))
        (else item)))
    services)
   (list (service book-state-volume-ready-service-type))))

(define (replace-gvisor-package packages)
  (unless (= 1 (count (lambda (package) (eq? package gvisor-bin)) packages))
    (error "public spike gvisor-bin package selection changed"))
  (map (lambda (package)
         (if (eq? package gvisor-bin) gvisor/source package))
       packages))

(define pinenote-book-state-reader-operating-system
  (operating-system
    (inherit %base-system)
    (host-name "pinenote-book-state-reader")
    (packages
     (replace-gvisor-package (operating-system-packages %base-system)))
    (file-systems
     (cons %state-file-system
           (operating-system-file-systems %base-system)))
    (services
     (replace-services (operating-system-user-services %base-system)))))

pinenote-book-state-reader-operating-system
