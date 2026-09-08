(define-module (pinenote packages gvisor)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system gnu)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:export (gvisor-bin))

;; Complete upstream ARM64 release distribution, repackaged without executing
;; its foreign binaries.  This is deliberately not a source build: upstream's
;; source build uses Bazel, while the first book-computer execution spike needs
;; one reviewable runtime pin before taking on that separate packaging project.
;;
;; Since the 2026-07 releases, runsc is only one part of the distribution.  It
;; resolves version-matched executables from the adjacent gvisor-bin directory;
;; release-20260831.0's DEFAULT policy still permits its old embedded fallback.
;; Keep the release together, and require launchers to select strict sidecar use
;; and release matching explicitly rather than allowing a missing helper to be
;; concealed by that fallback.
;;
;; Supply-chain boundary: the origin is content-addressed by the SHA-256 that
;; upstream publishes in the release's SHA256SUMS.  The same local download was
;; independently checked against upstream SHA512SUMS while packaging.  GitHub
;; reports the annotated release tag as unsigned, so this is checksum/content
;; verification, not signature verification.  See
;; doc/book-computer-execution-spike.md.

(define %gvisor-version "20260831.0")
(define %gvisor-release-tag
  (string-append "release-" %gvisor-version))

(define %gvisor-release-members
  '("containerd-shim-runsc-v1"
    "gvisor-bin/checkpointgofer"
    "gvisor-bin/gvisor-sentry-prewarmer"
    "gvisor-bin/gvisor_sentry"
    "gvisor-bin/runsc-metric-server"
    "runsc"))

(define-public gvisor-bin
  (package
    (name "gvisor-bin")
    (version %gvisor-version)
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/google/gvisor/releases/download/"
             %gvisor-release-tag "/gvisor-aarch64.tar.zstd"))
       (file-name (string-append name "-" version ".tar.zstd"))
       (sha256
        (base32
         "0fhdmkrwihadrzlcg9f3i6x5a7az6c8lsfyi3j3lpip18rh2n661"))))
    ;; Keep #:target on cross builds, as the repository's other foreign binary
    ;; package does.  copy-build-system's lower method drops it; that is harmless
    ;; to these static bytes today but would make the package's target identity
    ;; and any future target input silently wrong.
    (build-system gnu-build-system)
    (arguments
     (list
      #:substitutable? #f
      #:tests? #f
      #:validate-runpath? #f
       #:strip-binaries? #f
       #:phases
       #~(begin
           (use-modules (ice-9 ftw))
           (modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              ;; GNU build setup writes an environment-variables file in the
              ;; build directory before this phase.  Extract into a dedicated
              ;; directory so the exact archive-member gate sees only upstream
              ;; release content.
              (mkdir "source")
              (invoke "tar" "--use-compress-program=unzstd"
                      "-xf" source "--no-same-owner" "-C" "source")
              (chdir "source")))
          (delete 'configure)
          (delete 'build)
          (add-before 'install 'validate-release
            (lambda _
              (define expected '#$%gvisor-release-members)
              (define (directory-members directory)
                (sort (scandir directory
                               (lambda (name)
                                 (not (member name '("." "..")))))
                      string<?))
              (define (validate-elf file)
                ;; Native readelf inspects the foreign objects; nothing ARM64 is
                ;; executed during this package build.
                (invoke
                 "sh" "-c"
                 (string-append
                  "set -eu\n"
                  "readelf -h \"$1\" | "
                  "grep -Eq 'Machine:[[:space:]]+AArch64$'\n"
                  "if readelf -l \"$1\" | grep -q INTERP; then\n"
                  "  echo \"unexpected ELF interpreter: $1\" >&2; exit 1\n"
                  "fi\n"
                  "if readelf -d \"$1\" 2>/dev/null | grep -q NEEDED; then\n"
                  "  echo \"unexpected dynamic dependency: $1\" >&2; exit 1\n"
                  "fi")
                 "validate-gvisor-elf" file))
              ;; Check the two-level release tree directly.  Unlike a recursive
              ;; find-files roster this also makes every directory and symlink
              ;; decision explicit.  The fixed-output origin remains the first
              ;; identity gate; this is the human-readable layout gate.
              (unless (equal? (directory-members ".")
                              '("containerd-shim-runsc-v1"
                                "gvisor-bin"
                                "runsc"))
                (error "gVisor release top-level layout changed"
                       (directory-members ".")))
              (unless (eq? 'directory (stat:type (lstat "gvisor-bin")))
                (error "gvisor-bin is not a real directory"))
              (unless (equal? (directory-members "gvisor-bin")
                              '("checkpointgofer"
                                "gvisor-sentry-prewarmer"
                                "gvisor_sentry"
                                "runsc-metric-server"))
                (error "gVisor sidecar layout changed"
                       (directory-members "gvisor-bin")))
              (for-each
               (lambda (file)
                 (unless (eq? 'regular (stat:type (lstat file)))
                   (error "gVisor release member is not a regular file" file))
                 (when (zero? (logand (stat:perms (stat file)) #o111))
                   (error "gVisor release member is not executable" file))
                 (validate-elf file))
               expected)
              ;; Do not run the ARM64 binary.  The version marker plus the
              ;; fixed-output origin and exact member list is the host-side gate.
              (invoke "sh" "-c"
                      "strings runsc | grep -Fq 'release-20260831.0'")))
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((bin (string-append (assoc-ref outputs "out") "/bin")))
                (mkdir-p bin)
                (for-each (lambda (file) (install-file file bin))
                          '("runsc" "containerd-shim-runsc-v1"))
                (copy-recursively "gvisor-bin"
                                  (string-append bin "/gvisor-bin")))))
          (add-after 'install 'validate-installed-layout
            (lambda* (#:key outputs #:allow-other-keys)
              (let* ((bin (string-append (assoc-ref outputs "out") "/bin"))
                     (members
                      (lambda (directory)
                        (sort (scandir directory
                                       (lambda (name)
                                         (not (member name '("." "..")))))
                              string<?))))
                (unless (equal? (members bin)
                                '("containerd-shim-runsc-v1"
                                  "gvisor-bin"
                                  "runsc"))
                  (error "installed gVisor top-level layout changed"
                         (members bin)))
                (unless (eq? 'directory
                             (stat:type
                              (lstat (string-append bin "/gvisor-bin"))))
                  (error "installed gvisor-bin is not a real directory"))
                (unless (equal? (members (string-append bin "/gvisor-bin"))
                                '("checkpointgofer"
                                  "gvisor-sentry-prewarmer"
                                  "gvisor_sentry"
                                  "runsc-metric-server"))
                  (error "installed gVisor sidecar layout changed"
                         (members (string-append bin "/gvisor-bin")))))))))))
    (native-inputs
     (list binutils zstd))
    (supported-systems '("aarch64-linux"))
    (home-page "https://gvisor.dev")
    (synopsis "gVisor application kernel (upstream ARM64 release)")
    (description
     "This package installs the complete official ARM64 gVisor release:
@command{runsc}, @command{containerd-shim-runsc-v1}, and their adjacent,
version-matched @file{gvisor-bin} sidecars.  The statically linked upstream
binaries are repackaged without modification, and the build has no downloader
beyond its fixed-output origin.  This is a prebuilt-binary package for the
Wilkbook execution spike, not a source build.
The runtime launcher must explicitly require strict sidecar use and release
matching; package layout alone does not enforce helper selection.")
    (license license:asl2.0)))
