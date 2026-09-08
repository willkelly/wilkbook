(define-module (pinenote packages gvisor-source)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages cross-base)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages llvm)
  #:use-module (gnu packages python)
  #:use-module (pinenote packages gvisor-dependencies)
  #:export (gvisor-source-origin
               gvisor-source-inventory
                gvisor-release-vendor-inputs
                gvisor-bazel-bootstrap
                gvisor-build-phase-helper-check
                gvisor/source
                gvisor/source-diagnostic))

;; Keep the reusable source build here, separate from the frozen official
;; release repack in (pinenote packages gvisor).  gvisor/source is an honestly
;; labelled source build whose Bazel and Go bootstrap executables remain
;; explicit fixed binary inputs.

(define %gvisor-source-version "20260831.0")
(define %gvisor-source-commit
  "fd2f6b2674208086e324c2f739155eb7e1b48ff2")

(define-public gvisor-source-origin
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/google/gvisor.git")
          (commit %gvisor-source-commit)))
    (file-name (git-file-name "gvisor" %gvisor-source-version))
    (sha256
     (base32
      "12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy"))))

(define-public gvisor-source-inventory
  (package
    (name "gvisor-source-inventory")
    (version %gvisor-source-version)
    (source gvisor-source-origin)
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #t
      #:phases
      #~(modify-phases %standard-phases
          (delete 'bootstrap)
          (delete 'patch-usr-bin-file)
          (delete 'patch-source-shebangs)
          (delete 'patch-generated-file-shebangs)
          (delete 'configure)
          (replace 'build
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (let ((python
                     (search-input-file (or native-inputs inputs)
                                        "/bin/python3"))
                    (inventory
                     #$(local-file
                        "../tools/gvisor-package/inventory.py"
                        "gvisor-source-inventory.py"))
                    (golden
                     #$(local-file
                        "../tools/gvisor-package/pinned-source-inventory.json"
                        "gvisor-pinned-source-inventory.json")))
                ;; git-fetch deliberately supplies no .git directory.  The
                ;; commit assertion comes from the enclosing fixed-output
                ;; origin; the tool additionally pins the source metadata.
                (invoke python inventory "."
                        "--source-commit" #$%gvisor-source-commit
                        "--output" "source-inventory.json")
                (invoke "cmp" golden "source-inventory.json"))))
          (replace 'check
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (let ((python
                     (search-input-file (or native-inputs inputs)
                                        "/bin/python3"))
                    (inventory
                     #$(local-file
                        "../tools/gvisor-package/inventory.py"
                        "gvisor-source-inventory-for-tests.py"))
                    (tests
                     #$(local-file
                        "../tools/gvisor-package/test_inventory.py"
                        "test-gvisor-source-inventory.py")))
                (invoke python tests inventory))))
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (bin (string-append out "/bin"))
                     (share (string-append out "/share/gvisor-source-inventory"))
                     (program (string-append bin "/gvisor-source-inventory"))
                     (inventory
                      #$(local-file
                         "../tools/gvisor-package/inventory.py"
                         "gvisor-source-inventory-installed.py")))
                (mkdir-p bin)
                (mkdir-p share)
                (copy-file inventory program)
                (chmod program #o555)
                (install-file "source-inventory.json" share)
                (copy-file "LICENSE"
                           (string-append share "/gvisor-LICENSE"))
                (copy-file
                 #$(local-file "../../LICENSE" "wilkbook-LICENSE")
                 (string-append share "/inventory-LICENSE"))))))))
    (native-inputs (list python))
    ;; Only this metadata/preparation derivation has been checked, natively, on
    ;; x86_64.  The future runtime package must state native and cross support
    ;; from its own build evidence rather than inheriting this declaration.
    (supported-systems '("x86_64-linux"))
    (home-page "https://gvisor.dev")
    (synopsis "Pinned source and dependency inventory gate for gVisor")
    (description
     "This preparation package validates the exact gVisor
@code{release-20260831.0} source pin and installs an executable inventory of
its Bazel and Go dependency declarations.  Its build performs no dependency
download and runs unit tests.  It is not a gVisor runtime package; the separate
@code{gvisor-release-vendor-inputs} preparation package owns the resolved
target closure.")
    (license (list license:agpl3+ license:asl2.0))))

(define %gvisor-package-tools
  (local-file "../tools/gvisor-package" "gvisor-package-tools"
              #:recursive? #t
              ;; Keep the accepted fixed-input package's recursive source
              ;; byte-identical while runtime-only setup tests live beside it.
              #:select?
              (lambda (file stat)
                (not (member (basename file)
                             '("__pycache__"
                               "bazel_bootstrap.py"
                               "runtime-check.sh"
                               "runtime_setup.py"
                               "test_bazel_bootstrap.py"
                               "test_runtime_setup.py"))))))

(define %gvisor-release-fixed-input-ids
  (map car %gvisor-release-fixed-inputs))

(define-public gvisor-release-vendor-inputs
  (package
    (name "gvisor-release-vendor-inputs")
    (version %gvisor-source-version)
    (source #f)
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #t
      #:phases
      #~(modify-phases %standard-phases
          (delete 'unpack)
          (delete 'bootstrap)
          (delete 'patch-usr-bin-file)
          (delete 'patch-source-shebangs)
          (delete 'patch-generated-file-shebangs)
          (delete 'configure)
          (replace 'build
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (let ((python
                     (search-input-file (or native-inputs inputs)
                                        "/bin/python3"))
                    (tools #$%gvisor-package-tools))
                (invoke python
                        (string-append tools "/vendor_inputs.py")
                        "check"
                        (string-append tools "/release-vendor-manifest.json")
                        "--artifacts" tools))))
          (replace 'check
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (let ((python
                     (search-input-file (or native-inputs inputs)
                                        "/bin/python3"))
                    (tools #$%gvisor-package-tools))
                (invoke python
                        (string-append tools "/test_vendor.py")
                        (string-append tools "/vendor_manifest.py")
                        (string-append tools "/vendor_inputs.py")
                        (string-append tools "/release-vendor-manifest.json")
                        (string-append tools "/emit_guix_inputs.py")
                        #$(local-file "gvisor-dependencies.scm"
                                      "gvisor-dependencies.scm")))))
          (replace 'install
            (lambda* (#:key inputs native-inputs outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out"))
                    (tools #$%gvisor-package-tools))
                (call-with-output-file "input-map.tsv"
                  (lambda (port)
                    (for-each
                     (lambda (name)
                       (let ((path (assoc-ref inputs name)))
                         (unless path
                           (error "fixed input is missing" name))
                         (display name port)
                         (display #\tab port)
                         (display path port)
                         (newline port)))
                     '#$%gvisor-release-fixed-input-ids)))
                (invoke (search-input-file (or native-inputs inputs)
                                           "/bin/python3")
                        (string-append tools "/vendor_inputs.py")
                        "assemble"
                        (string-append tools "/release-vendor-manifest.json")
                        "--artifacts" tools
                        "--input-map" "input-map.tsv"
                        "--output" out)
                (let ((share
                       (string-append out
                                      "/share/gvisor-release-vendor-inputs")))
                  (chmod share #o755)
                  (copy-file #$(local-file "../../LICENSE"
                                            "wilkbook-LICENSE")
                             (string-append share "/wilkbook-LICENSE"))
                  (chmod (string-append share "/wilkbook-LICENSE") #o444)
                  (chmod share #o555))))))))
    (inputs %gvisor-release-fixed-inputs)
    (native-inputs (list python))
    (supported-systems '("x86_64-linux"))
    (home-page "https://gvisor.dev")
    (synopsis "Fixed inputs for offline gVisor release analysis")
    (description
     "This preparation package assembles the content-addressed Bazel
repository cache, local Go module proxy, exact prebuilt Bazel bootstrap, lock,
and native and AArch64 @code{//:release} closure records for gVisor
@code{release-20260831.0}.  Its build has no downloader and performs no gVisor
compilation.  Bazel 8.3.1 and Go 1.26.3 are explicitly labelled prebuilt
bootstrap inputs; protoc is selected from the fixed protobuf source instead of
upstream's prebuilt compiler.  The installed manifest records each source URL,
archive hash, canonical repository, and license evidence or omission.  It is
deliberately not a gVisor runtime package.")
    ;; The output is a heterogeneous source collection.  Per-input licenses
    ;; and upstream omissions are recorded in the installed manifest;
    ;; the assembly tools themselves are AGPLv3-or-later.
    (license #f)))

(define %gvisor-bazel-bootstrap-repacker
  (local-file "../tools/gvisor-package/bazel_bootstrap.py"
              "gvisor-bazel-bootstrap.py"))

(define-public gvisor-bazel-bootstrap
  (package
    (name "gvisor-bazel-bootstrap")
    (version "8.3.1")
    (source #f)
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #t
      #:strip-binaries? #f
      ;; The self-extracting launcher's interpreter is intentionally
      ;; /proc/self/fd/9 and its wrapper supplies a fixed LD_LIBRARY_PATH;
      ;; Guix's static RUNPATH validator cannot model that pair.
      #:validate-runpath? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'unpack)
          (delete 'bootstrap)
          (delete 'patch-usr-bin-file)
          (delete 'patch-source-shebangs)
          (delete 'patch-generated-file-shebangs)
          (delete 'configure)
          (replace 'build
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (let* ((all-inputs (append (or native-inputs '()) inputs))
                     (fixed (assoc-ref all-inputs "fixed-inputs"))
                     (raw (string-append
                           fixed
                           "/bootstrap/bazel-8.3.1-linux-x86_64"))
                      (python (search-input-file all-inputs "/bin/python3"))
                      (patchelf (search-input-file all-inputs "/bin/patchelf"))
                      (bash (search-input-file all-inputs "/bin/bash"))
                      (loader (search-input-file all-inputs
                                                "/lib/ld-linux-x86-64.so.2"))
                     (glibc (assoc-ref inputs "glibc"))
                     (gcc (assoc-ref inputs "gcc-toolchain"))
                     (zlib (assoc-ref inputs "zlib"))
                     (library-path
                      (string-join
                       (list (string-append glibc "/lib")
                             (string-append gcc "/lib")
                             (string-append zlib "/lib"))
                       ":")))
                ;; The raw launcher cannot be patchelf'd as a whole: doing so
                ;; moves ELF notes used by Bazel's embedded-file reader.  The
                ;; focused repacker changes its PT_INTERP bytes in place and
                ;; patches each ELF ZIP member before rebuilding the SFX ZIP.
                (invoke python #$%gvisor-bazel-bootstrap-repacker
                        "--source" raw
                        "--output" "bazel.real"
                        "--patchelf" patchelf
                        "--interpreter" loader
                        "--wrapper-shell" bash
                        "--library-path" library-path
                        "--expected-sha256"
                        "17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c"
                        "--expected-elf-count" "29"
                        "--manifest" "bootstrap-manifest.json"))))
          (replace 'check
            (lambda* (#:key inputs native-inputs #:allow-other-keys)
              (use-modules (ice-9 textual-ports))
              (let* ((all-inputs (append (or native-inputs '()) inputs))
                     (bash (search-input-file all-inputs "/bin/bash"))
                     (loader (search-input-file all-inputs
                                                "/lib/ld-linux-x86-64.so.2"))
                     (glibc (assoc-ref inputs "glibc"))
                     (gcc (assoc-ref inputs "gcc-toolchain"))
                     (zlib (assoc-ref inputs "zlib"))
                     (library-path
                      (string-join
                       (list (string-append glibc "/lib")
                             (string-append gcc "/lib")
                             (string-append zlib "/lib"))
                       ":"))
                     (root (getcwd))
                     (wrapper (string-append root "/bazel-check"))
                     (home (string-append root "/check-home"))
                     (user-root (string-append root "/check-user"))
                     (probe (string-append root "/process-wrapper-probe")))
                (call-with-output-file wrapper
                  (lambda (port)
                    (format port
                            "#!~a~%set -eu~%exec 9<~a~%export LD_LIBRARY_PATH=~a~%exec ~a/bazel.real \"$@\"~%"
                            bash loader library-path root)))
                (chmod wrapper #o555)
                (for-each mkdir-p (list home user-root))
                (setenv "HOME" home)
                (setenv "TMPDIR" home)
                ;; `version' extracts and starts the embedded JDK but cannot
                ;; touch a registry or compile a target.
                (invoke wrapper "--batch" "--nosystem_rc" "--nohome_rc"
                        (string-append "--output_user_root=" user-root)
                        "version")
                (let ((process-wrapper
                       (find-files user-root "^process-wrapper$")))
                  (unless (= 1 (length process-wrapper))
                    (error "Bazel extracted an unexpected process-wrapper set"
                           process-wrapper))
                   ;; Exercise the repacked action helper directly with no
                   ;; caller library path.  Its embedded wrapper must supply the
                   ;; explicit Guix libraries before entering the real ELF.
                   (unsetenv "LD_LIBRARY_PATH")
                   (invoke (car process-wrapper) "--" bash "-c"
                          (string-append "printf ok >" probe)))
                (unless (string=?
                         "ok"
                         (call-with-input-file probe get-string-all))
                  (error "Bazel process-wrapper probe produced wrong output")))))
          (replace 'install
            (lambda* (#:key inputs native-inputs outputs #:allow-other-keys)
              (let* ((all-inputs (append (or native-inputs '()) inputs))
                     (out (assoc-ref outputs "out"))
                     (bin (string-append out "/bin"))
                     (share (string-append out
                                           "/share/gvisor-bazel-bootstrap"))
                     (libexec (string-append out
                                             "/libexec/gvisor-bazel-bootstrap"))
                     (real (string-append libexec "/bazel.real"))
                     (wrapper (string-append bin "/bazel"))
                     (bash (search-input-file all-inputs "/bin/bash"))
                     (loader (search-input-file all-inputs
                                                "/lib/ld-linux-x86-64.so.2"))
                     (glibc (assoc-ref inputs "glibc"))
                     (gcc (assoc-ref inputs "gcc-toolchain"))
                     (zlib (assoc-ref inputs "zlib"))
                     (library-path
                      (string-join
                       (list (string-append glibc "/lib")
                             (string-append gcc "/lib")
                             (string-append zlib "/lib"))
                       ":")))
                (mkdir-p bin)
                (mkdir-p share)
                (mkdir-p libexec)
                (copy-file "bazel.real" real)
                (copy-file "bootstrap-manifest.json"
                           (string-append share "/bootstrap-manifest.json"))
                (call-with-output-file (string-append share "/library-path")
                  (lambda (port)
                    (display library-path port)
                    (newline port)))
                (call-with-output-file wrapper
                  (lambda (port)
                    ;; FD 9 lets the kernel resolve a long Guix loader path
                    ;; through the launcher's in-place /proc/self/fd/9
                    ;; PT_INTERP without moving Bazel's ELF note payload.
                    (format port
                            "#!~a~%set -eu~%exec 9<~a~%export LD_LIBRARY_PATH=~a~%exec ~a \"$@\"~%"
                            bash loader library-path real)))
                (chmod real #o555)
                (chmod wrapper #o555)))))))
    (inputs
     `(("bash" ,bash-minimal)
       ("gcc-toolchain" ,gcc-toolchain)
       ("glibc" ,glibc)
       ("zlib" ,zlib)))
    (native-inputs
     `(("fixed-inputs" ,gvisor-release-vendor-inputs)
         ("patchelf" ,patchelf)
         ("python" ,python)))
    (supported-systems '("x86_64-linux"))
    (home-page "https://bazel.build")
    (synopsis "Fixed Bazel bootstrap for the gVisor source package")
    (description
     "This package adapts the hash-pinned upstream Bazel 8.3.1 Linux x86_64
bootstrap and its embedded JDK 24 for a Guix build chroot.  Its installed
transform manifest records the raw and repacked identities, gives each
embedded executable an explicit Guix loader,
and directly exercises the extracted process-wrapper.  It is a binary bootstrap package,
not a source-built Bazel package.")
    ;; Bazel is Apache-2.0, while the retained embedded JDK is GPL-2.0 with
    ;; the Classpath Exception and carries its own third-party legal shelf.
    (license #f)))

(define %gvisor-runtime-setup
  (local-file "../tools/gvisor-package/runtime_setup.py"
              "gvisor-runtime-setup.py"))

(define %gvisor-runtime-build-patches
  (list (local-file "../patches/gvisor-bpf-guix-toolchain.patch")
        (local-file "../patches/gvisor-nogo-bazel8-file-path.patch")
        (local-file "../patches/gvisor-nogo-go126-stdlib-filter.patch")
        (local-file "../patches/gvisor-release-version-offline.patch")
        (local-file "../patches/gvisor-prewarmer-guix-headers.patch")
        (local-file "../patches/gvisor-sysmsg-guix-headers.patch")
        (local-file "../patches/gvisor-starlark-actions-guix-tools.patch")
        (local-file "../patches/gvisor-vdso-guix-headers.patch")))

(define %gvisor-diagnostic-error-report-patch
  (local-file
   "../patches/gvisor-diagnostic-systrap-error-context.patch"))

(define %gvisor-coral-crosstool-guix-patch
  (local-file "../patches/gvisor-coral-crosstool-guix.patch"))

(define %gvisor-protobuf-authenticity-guix-tools-patch
  (local-file
   "../patches/gvisor-protobuf-authenticity-guix-tools.patch"))

(define %gvisor-runtime-action-inputs
  `(("action-bash" ,bash-minimal)
    ("action-coreutils" ,coreutils)
    ("action-diffutils" ,diffutils)
    ("action-findutils" ,findutils)
    ("action-gawk" ,gawk)
    ("action-grep" ,grep)
    ("action-gzip" ,gzip)
    ("action-patch" ,patch)
    ("action-python" ,python)
    ("action-sed" ,sed)
    ("action-tar" ,tar)
    ("action-unzip" ,unzip)
    ("action-which" ,which)
    ("action-zip" ,zip)))

(define %gvisor-runtime-action-input-names
  (map car %gvisor-runtime-action-inputs))

;; Keep a real Guix-build-side regression for the non-core helpers used by the
;; runtime package's build phase.  Host-side Guile evaluation does not prove
;; that these interfaces are in scope when the daemon executes the phase.
(define-public gvisor-build-phase-helper-check
  (package
    (name "gvisor-build-phase-helper-check")
    (version %gvisor-source-version)
    (source #f)
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(list
         (cons 'exercise-build-phase-helpers
               (lambda* (#:key inputs native-inputs outputs
                         #:allow-other-keys)
                 (use-modules (ice-9 textual-ports)
                              (srfi srfi-1)
                              (srfi srfi-13))
                 (let* ((all-inputs (append (or native-inputs '()) inputs))
                        (out (assoc-ref outputs "out"))
                        (bazel (search-input-file all-inputs "/bin/bazel"))
                        (root (getcwd))
                        (workspace (string-append root "/workspace"))
                        (private (string-append root "/private"))
                        (home (string-append private "/home"))
                        (user-root (string-append private "/output-user"))
                        (contents-cache
                         (string-append private "/repo-contents"))
                        (flattened
                         (append-map (lambda (item) (list item item))
                                     '("a" "b")))
                        (joined (string-join flattened ":"))
                        (trimmed
                         (string-trim-right
                          (get-string-all
                           (open-input-string "build-side\n")))))
                   (unless (and (string=? joined "a:a:b:b")
                                (string=? trimmed "build-side"))
                     (error "build-side helper probe returned wrong values"
                            joined trimmed))
                   ;; GCC derives the location of cc1 from argv[0].  Exercise
                   ;; the same explicit launcher used by Bazel under a renamed
                   ;; toolchain path in this real daemon chroot.
                   (let* ((python (string-append
                                   (assoc-ref all-inputs "action-python")
                                   "/bin/python3"))
                          (shell (string-append
                                  (assoc-ref all-inputs "action-bash")
                                  "/bin/bash"))
                          (gcc (string-append
                                (assoc-ref all-inputs "native-gcc")
                                "/bin/gcc"))
                          (binutils (string-append
                                     (assoc-ref all-inputs "native-binutils")
                                     "/bin"))
                          (wrapper (string-append private "/renamed-gcc"))
                          (source (string-append private "/probe.c"))
                          (object (string-append private "/probe.o")))
                     (mkdir-p private)
                     (invoke python #$%gvisor-runtime-setup
                             "compiler-wrapper" "--shell" shell
                             "--compiler" gcc "--output" wrapper)
                     (call-with-output-file source
                       (lambda (port)
                         (display "int probe(void) { return 0; }\n" port)))
                     (setenv "PATH"
                             (string-append binutils ":" (getenv "PATH")))
                     (invoke wrapper "-c" source "-o" object)
                     (unless (file-exists? object)
                       (error "compiler wrapper did not produce an object")))
                   ;; Bazel 8 rejects a repository-contents cache nested below
                   ;; its workspace.  Exercise the exact option in a real
                   ;; daemon chroot without resolving dependencies or actions.
                   (for-each mkdir-p
                             (list workspace private home user-root
                                   contents-cache))
                   (call-with-output-file
                       (string-append workspace "/MODULE.bazel")
                     (lambda (port)
                       (display "module(name = \"cache_probe\")\n" port)))
                   (call-with-output-file
                       (string-append workspace "/WORKSPACE")
                     (lambda (port)
                       (display "workspace(name = \"cache_probe\")\n" port)))
                   (call-with-output-file (string-append workspace "/BUILD")
                     (lambda (port)
                       (display "filegroup(name = \"probe\", srcs = [])\n"
                                port)))
                   (setenv "HOME" home)
                   (setenv "TMPDIR" private)
                   (with-directory-excursion workspace
                     (invoke bazel "--batch" "--nosystem_rc" "--nohome_rc"
                             (string-append "--output_user_root=" user-root)
                             "info"
                             (string-append "--repo_contents_cache="
                                            contents-cache)
                             "--repository_disable_download"
                             "--color=no" "--curses=no" "workspace"))
                   (mkdir out)
                   (call-with-output-file
                       (string-append out "/passed")
                     (lambda (port)
                        (display "append-map string helpers textual-port compiler-wrapper\n"
                                 port)))))))))
    (supported-systems '("x86_64-linux"))
    (native-inputs
     `(("action-bash" ,bash-minimal)
       ("action-python" ,python)
       ("bazel-bootstrap" ,gvisor-bazel-bootstrap)
       ("native-binutils" ,binutils-gold)
       ("native-gcc" ,gcc-toolchain)))
    (home-page "https://gvisor.dev")
    (synopsis "Build-side Guile helper probe for gVisor packaging")
    (description
     "This tiny regression executes the non-core Guile helpers and renamed GCC
launcher used by the gVisor runtime build phase in an actual Guix daemon build
environment.  It starts Bazel without repository resolution and compiles only
a trivial C probe, never gVisor.")
    (license license:agpl3+)))

(define (gvisor-build-architecture)
  (let ((system (%current-system))
        (target (%current-target-system)))
    (unless (string=? system "x86_64-linux")
      (error "gVisor's fixed Bazel bootstrap requires an x86_64-linux build host"
             system))
    (cond ((not target) "native-x86_64")
          ((string=? target "aarch64-linux-gnu") "aarch64")
          (else (error "unsupported gVisor source-build target" target)))))

(define (gvisor-aarch64-toolchain-inputs)
  (let* ((target "aarch64-linux-gnu")
         (xbinutils (cross-binutils target #:binutils binutils-gold))
         (libc (cross-libc target))
         (gcc (cross-gcc target #:xbinutils xbinutils #:libc libc))
         (kernel-headers
          (car (assoc-ref (package-propagated-inputs libc)
                          "kernel-headers"))))
    `(("target-binutils" ,xbinutils)
       ("target-gcc" ,gcc)
       ("target-gcc-lib" ,gcc "lib")
       ("target-linux-headers" ,kernel-headers)
       ("target-libc" ,libc))))

(define-public gvisor/source
  (package
    (name "gvisor-source-built")
    (version %gvisor-source-version)
    (source gvisor-source-origin)
    (build-system gnu-build-system)
    (arguments
     (let ((architecture (gvisor-build-architecture)))
       (list
        #:tests? #t
        #:strip-binaries? #f
        #:phases
        #~(modify-phases %standard-phases
            (delete 'bootstrap)
            (delete 'patch-usr-bin-file)
            (delete 'configure)
            (add-after 'unpack 'prepare-reviewed-source-inputs
              (lambda* (#:key inputs native-inputs #:allow-other-keys)
                (let* ((all-inputs (append (or native-inputs '()) inputs))
                        (fixed (assoc-ref all-inputs "fixed-inputs"))
                        (tools (assoc-ref all-inputs "package-tools"))
                        (python (search-input-file all-inputs "/bin/python3"))
                       (artifacts (string-append
                                   fixed
                                   "/share/gvisor-release-vendor-inputs")))
                  ;; Reuse the accepted source-protoc transform byte-for-byte.
                  (invoke python (string-append tools "/vendor_inputs.py")
                          "prepare-source" "."
                          (string-append artifacts
                                         "/rules_go_offline_sdk_index.patch"))
                  (copy-file (string-append artifacts
                                            "/release-MODULE.bazel.lock")
                             "MODULE.bazel.lock")
                  (for-each
                   (lambda (patch)
                     (invoke "patch" "--batch" "--forward" "--fuzz=0"
                             "-p1" "-i" patch))
                   '#$%gvisor-runtime-build-patches))))
            (replace 'build
              (lambda* (#:key inputs native-inputs #:allow-other-keys)
                (use-modules (ice-9 textual-ports)
                             (srfi srfi-1)
                             (srfi srfi-13))
                (let* ((all-inputs (append (or native-inputs '()) inputs))
                       (architecture #$architecture)
                       (config (if (string=? architecture "aarch64")
                                   "aarch64"
                                   "x86_64"))
                       (fixed (assoc-ref all-inputs "fixed-inputs"))
                       (tools (assoc-ref all-inputs "package-tools"))
                       (python (search-input-file all-inputs "/bin/python3"))
                       (bash (search-input-file all-inputs "/bin/bash"))
                       (patch-command
                        (search-input-file all-inputs "/bin/patch"))
                        (tar-command (search-input-file all-inputs "/bin/tar"))
                        (cp-command (search-input-file all-inputs "/bin/cp"))
                         (cat-command
                          (search-input-file all-inputs "/bin/cat"))
                         (grep-command
                          (search-input-file all-inputs "/bin/grep"))
                        (mkdir-command
                         (search-input-file all-inputs "/bin/mkdir"))
                        (dirname-command
                         (search-input-file all-inputs "/bin/dirname"))
                       (timeout (search-input-file all-inputs "/bin/timeout"))
                       (bazel (search-input-file all-inputs "/bin/bazel"))
                       (native-gcc (assoc-ref all-inputs "native-gcc"))
                       (native-binutils (assoc-ref all-inputs
                                                  "native-binutils"))
                       (native-libc (assoc-ref all-inputs "native-libc"))
                       (clang (assoc-ref all-inputs "clang"))
                       (linux-headers (assoc-ref all-inputs "linux-headers"))
                        (libbpf (assoc-ref all-inputs "libbpf"))
                        (work (string-append (getcwd) "/.gvisor-build"))
                        ;; Bazel 8 requires its repository-contents cache to
                        ;; live outside the workspace.  Keep three independent
                        ;; empty caches so vendoring cannot feed analysis or
                        ;; compilation through this secondary cache channel.
                        (private (string-append
                                  (dirname (getcwd))
                                  "/.gvisor-bazel-private"))
                        (setup (string-append work "/setup"))
                       (repository-cache (string-append work
                                                        "/repository-cache"))
                        (vendor (string-append work "/vendor"))
                        (coral (string-append work "/coral-crosstool"))
                        (crosstool (string-append private "/crosstool"))
                       (empty-cache (string-append work "/empty-cache"))
                        (action-cache (string-append work "/action-cache"))
                        (vendor-contents-cache
                         (string-append private "/vendor-repo-contents"))
                        (analysis-contents-cache
                         (string-append private "/analysis-repo-contents"))
                        (build-contents-cache
                         (string-append private "/build-repo-contents"))
                       (home (string-append work "/home"))
                       (tmp (string-append work "/tmp"))
                       (native-prefix
                        (string-append setup
                                       "/toolchains/x86_64-linux-gnu/bin/"
                                       "x86_64-linux-gnu-"))
                        (target-prefix
                         (string-append setup
                                        "/toolchains/aarch64-linux-gnu/bin/"
                                        "aarch64-linux-gnu-"))
                       (native-roots
                        (string-join
                         (list native-gcc native-binutils native-libc) ":"))
                         (target-roots
                         (string-join
                          (map (lambda (name) (assoc-ref all-inputs name))
                               '("target-gcc" "target-gcc-lib"
                                 "target-binutils" "target-libc"))
                          ":"))
                         (prewarmer-flags #f)
                         (sysmsg-native-flags #f)
                         (sysmsg-aarch64-flags #f)
                         (vdso-native-flags #f)
                         (vdso-aarch64-flags #f)
                         (native-linux-include #f)
                        (target-linux-include #f)
                       (action-roots
                        (map (lambda (name) (assoc-ref all-inputs name))
                             '#$%gvisor-runtime-action-input-names))
                       (action-path
                        (string-join
                          (append
                           (list (dirname native-prefix))
                           (list (dirname target-prefix))
                          (map (lambda (root)
                                 (string-append root "/bin"))
                               action-roots))
                         ":"))
                       (bpf-clang (string-append clang "/bin/clang"))
                       (native-cc (string-append native-prefix "gcc"))
                       (native-cxx (string-append native-prefix "g++"))
                       (native-ar (string-append native-prefix "ar"))
                       (native-ld (string-append native-prefix "ld.gold"))
                       (bpf-flags
                        (string-append "-isystem " linux-headers "/include "
                                       "-isystem " libbpf "/include"))
                       (bazel-library-path
                        (string-trim-right
                         (call-with-input-file
                             (string-append
                              (assoc-ref all-inputs "bazel-bootstrap")
                              "/share/gvisor-bazel-bootstrap/library-path")
                           get-string-all)))
                       (go-proxy (string-append "file://" fixed "/go-proxy")))
                  (define (startup output-user output-base)
                    (list bazel "--batch" "--nosystem_rc" "--nohome_rc"
                          (string-append "--output_user_root=" output-user)
                          (string-append "--output_base=" output-base)
                          "--host_jvm_args=-Xmx8192m"
                          "--host_jvm_args=-XX:ActiveProcessorCount=2"))
                   (define (command-options cache contents-cache)
                     (list
                     (string-append "--config=" config) "-c" "opt"
                     "--jobs=2" "--local_cpu_resources=2"
                     "--local_ram_resources=4096"
                      "--@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false"
                      "--workspace_status_command="
                      "--embed_label=release-20260831.0"
                      (string-append "--repository_cache=" cache)
                      (string-append "--repo_contents_cache=" contents-cache)
                     (string-append "--vendor_dir=" vendor)
                      (string-append
                       "--override_repository="
                       "+crosstool_extension+crosstool=" crosstool)
                     "--repository_disable_download" "--lockfile_mode=error"
                     "--incompatible_strict_action_env"
                     "--spawn_strategy=local"
                     (string-append "--shell_executable=" bash)
                     (string-append "--action_env=PATH=" action-path)
                     (string-append "--host_action_env=PATH=" action-path)
                     (string-append "--repo_env=PATH=" action-path)
                     (string-append "--action_env=CC=" native-cc)
                     (string-append "--host_action_env=CC=" native-cc)
                     (string-append "--repo_env=CC=" native-cc)
                     (string-append "--action_env=CXX=" native-cxx)
                     (string-append "--host_action_env=CXX=" native-cxx)
                     (string-append "--repo_env=CXX=" native-cxx)
                     (string-append "--action_env=AR=" native-ar)
                     (string-append "--host_action_env=AR=" native-ar)
                     (string-append "--repo_env=AR=" native-ar)
                     (string-append "--action_env=LD=" native-ld)
                     (string-append "--host_action_env=LD=" native-ld)
                     (string-append "--repo_env=LD=" native-ld)
                     (string-append "--action_env=LD_LIBRARY_PATH="
                                    bazel-library-path)
                     (string-append "--host_action_env=LD_LIBRARY_PATH="
                                    bazel-library-path)
                       (string-append "--action_env=GVISOR_BPF_CLANG=" bpf-clang)
                       (string-append "--host_action_env=GVISOR_BPF_CLANG="
                                      bpf-clang)
                       (string-append "--action_env=GVISOR_GUIX_CP=" cp-command)
                       (string-append "--host_action_env=GVISOR_GUIX_CP="
                                      cp-command)
                       (string-append "--action_env=GVISOR_GUIX_CAT="
                                      cat-command)
                       (string-append "--host_action_env=GVISOR_GUIX_CAT="
                                      cat-command)
                       (string-append "--action_env=GVISOR_GUIX_GREP="
                                      grep-command)
                       (string-append "--host_action_env=GVISOR_GUIX_GREP="
                                      grep-command)
                       (string-append "--action_env=GVISOR_GUIX_MKDIR="
                                      mkdir-command)
                       (string-append "--host_action_env=GVISOR_GUIX_MKDIR="
                                      mkdir-command)
                       (string-append "--action_env=GVISOR_GUIX_DIRNAME="
                                      dirname-command)
                       (string-append "--host_action_env=GVISOR_GUIX_DIRNAME="
                                      dirname-command)
                       (string-append "--action_env=GVISOR_BPF_INCLUDE_FLAGS="
                                      bpf-flags)
                       (string-append
                        "--host_action_env=GVISOR_BPF_INCLUDE_FLAGS="
                        bpf-flags)
                        (string-append
                         "--action_env=GVISOR_PREWARMER_INCLUDE_FLAGS="
                         prewarmer-flags)
                        (string-append
                         "--host_action_env=GVISOR_PREWARMER_INCLUDE_FLAGS="
                         prewarmer-flags)
                        (string-append
                         "--action_env=GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS="
                         sysmsg-native-flags)
                        (string-append
                         "--host_action_env=GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS="
                         sysmsg-native-flags)
                        (string-append
                         "--action_env=GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS="
                         sysmsg-aarch64-flags)
                        (string-append
                         "--host_action_env=GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS="
                          sysmsg-aarch64-flags)
                         (string-append
                          "--action_env=GVISOR_VDSO_NATIVE_INCLUDE_FLAGS="
                          vdso-native-flags)
                         (string-append
                          "--host_action_env=GVISOR_VDSO_NATIVE_INCLUDE_FLAGS="
                          vdso-native-flags)
                         (string-append
                          "--action_env=GVISOR_VDSO_AARCH64_INCLUDE_FLAGS="
                          vdso-aarch64-flags)
                         (string-append
                          "--host_action_env=GVISOR_VDSO_AARCH64_INCLUDE_FLAGS="
                          vdso-aarch64-flags)
                      (string-append "--repo_env=GVISOR_GUIX_NATIVE_TOOL_PREFIX="
                                    native-prefix)
                     (string-append "--repo_env=GVISOR_GUIX_NATIVE_INCLUDE_ROOTS="
                                    native-roots)
                     (string-append "--repo_env=GVISOR_GUIX_AARCH64_TOOL_PREFIX="
                                    target-prefix)
                     (string-append "--repo_env=GVISOR_GUIX_AARCH64_INCLUDE_ROOTS="
                                    target-roots)
                     (string-append "--repo_env=GOPROXY=" go-proxy)
                     "--repo_env=GOSUMDB=off" "--repo_env=GONOSUMDB=*"
                     "--repo_env=GOPRIVATE=" "--announce_rc"
                     "--color=no" "--curses=no"))
                  (define (bounded duration output-user output-base command options)
                    (apply invoke
                           (append
                            (list timeout "--signal=TERM" "--kill-after=2m"
                                  duration)
                            (startup output-user output-base)
                            (list command)
                            options)))
                   (when (or (file-exists? work) (file-exists? private))
                     (error "private Bazel root already exists" work private))
                   (for-each mkdir-p
                             (list work private repository-cache vendor coral
                                   empty-cache action-cache home tmp
                                   vendor-contents-cache analysis-contents-cache
                                   build-contents-cache))
                  (invoke "cp" "-a"
                          (string-append fixed
                                         "/repository-cache/content_addressable")
                          repository-cache)
                  (invoke "chmod" "-R" "u+w" repository-cache)

                   ;; Keep the reviewed lock and fixed-input output immutable.
                   ;; Reconstruct Coral from the accepted archive and apply
                   ;; gVisor's two declared patches plus our focused FHS patch.
                   ;; A rendered repository below, rather than this transitive
                   ;; .bzl source, is exposed to Bazel.
                  (invoke tar-command "--extract"
                          "--file"
                          (string-append
                           fixed
                           "/repository-cache/content_addressable/sha256/"
                           "f86d488ca353c5ee99187579fe408adb73e9f2bb1d69c6e3a42ffb904ce3ba01/"
                           "file")
                          "--directory" coral "--strip-components=1")
                  (for-each
                   (lambda (patch-file)
                     (invoke patch-command "--batch" "--forward" "--fuzz=0"
                             "-p1" "-d" coral "-i" patch-file))
                   (list (string-append (getcwd)
                                        "/tools/crosstool-arm-dirs.patch")
                         (string-append (getcwd)
                                        "/tools/remove_windows_deps.patch")
                         #$%gvisor-coral-crosstool-guix-patch))

                  (let ((setup-command
                         (append
                          (list python #$%gvisor-runtime-setup "prepare"
                                "--architecture" architecture
                                "--output" setup
                                "--native-gcc" native-gcc
                                "--native-binutils" native-binutils
                                "--native-libc" native-libc
                                "--clang" clang
                                "--linux-headers" linux-headers
                                 "--libbpf" libbpf
                                 "--action-shell" bash
                                 "--action-cp" cp-command
                                 "--action-mkdir" mkdir-command
                                 "--action-dirname" dirname-command
                                 "--require-store")
                          (append-map
                           (lambda (root) (list "--action-root" root))
                           action-roots)
                           (list
                            "--target-gcc"
                            (assoc-ref all-inputs "target-gcc")
                            "--target-gcc-lib"
                            (assoc-ref all-inputs "target-gcc-lib")
                            "--target-linux-headers"
                            (assoc-ref all-inputs "target-linux-headers")
                            "--target-binutils"
                            (assoc-ref all-inputs "target-binutils")
                            "--target-libc"
                            (assoc-ref all-inputs "target-libc")))))
                     (apply invoke setup-command))
                   (define (read-setup-environment name)
                     (string-trim-right
                      (call-with-input-file
                          (string-append setup "/environment/" name)
                        get-string-all)))
                   ;; runtime_setup.py obtains the actual compiler include
                   ;; directories from each host-executable driver.  Consume
                   ;; those generated values rather than recomputing them in
                   ;; Scheme or retaining broad package roots.
                   (set! native-roots
                         (read-setup-environment
                          "GVISOR_GUIX_NATIVE_INCLUDE_ROOTS"))
                   (set! target-roots
                         (read-setup-environment
                          "GVISOR_GUIX_AARCH64_INCLUDE_ROOTS"))
                   (set! prewarmer-flags
                         (read-setup-environment
                          "GVISOR_PREWARMER_INCLUDE_FLAGS"))
                   (set! sysmsg-native-flags
                         (read-setup-environment
                          "GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS"))
                    (set! sysmsg-aarch64-flags
                          (read-setup-environment
                           "GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS"))
                    (set! vdso-native-flags
                          (read-setup-environment
                           "GVISOR_VDSO_NATIVE_INCLUDE_FLAGS"))
                    (set! vdso-aarch64-flags
                          (read-setup-environment
                           "GVISOR_VDSO_AARCH64_INCLUDE_FLAGS"))
                   (set! native-linux-include
                         (read-setup-environment
                          "GVISOR_NATIVE_LINUX_INCLUDE"))
                   (set! target-linux-include
                         (read-setup-environment
                          "GVISOR_TARGET_LINUX_INCLUDE"))

                   ;; Render the generated crosstool repository directly from
                   ;; the patched, accepted Coral templates.  Overriding this
                   ;; generated output leaves the locked Coral extension bytes
                   ;; unchanged, unlike overriding its transitive .bzl source.
                   (invoke python #$%gvisor-runtime-setup "render-crosstool"
                           "--coral" coral "--output" crosstool
                           "--native-tool-prefix" native-prefix
                            "--native-include-roots" native-roots
                            "--aarch64-tool-prefix" target-prefix
                            "--aarch64-include-roots" target-roots
                            "--native-linux-include" native-linux-include
                            "--target-linux-include" target-linux-include)

                  (for-each unsetenv
                            '("HTTP_PROXY" "HTTPS_PROXY" "FTP_PROXY"
                              "ALL_PROXY" "NO_PROXY" "http_proxy"
                              "https_proxy" "ftp_proxy" "all_proxy"
                              "no_proxy" "GONOPROXY" "GOINSECURE"
                              "CPATH" "C_INCLUDE_PATH" "CPLUS_INCLUDE_PATH"
                              "OBJC_INCLUDE_PATH" "OBJCPLUS_INCLUDE_PATH"
                              "LIBRARY_PATH" "LD_LIBRARY_PATH"))
                  (setenv "HOME" home)
                  (setenv "XDG_CACHE_HOME" (string-append home "/.cache"))
                  (setenv "TMPDIR" tmp)
                  (setenv "TMP" tmp)
                  (setenv "TEMP" tmp)
                  (setenv "LANG" "C")
                  (setenv "LC_ALL" "C")
                  (setenv "TZ" "UTC")
                  (setenv "SOURCE_DATE_EPOCH" "1788467832")
                  (setenv "PATH" action-path)
                  (setenv "SHELL" bash)
                  (setenv "CC" native-cc)
                  (setenv "CXX" native-cxx)
                  (setenv "AR" native-ar)
                  (setenv "LD" native-ld)
                  (setenv "GOPROXY" go-proxy)
                  (setenv "GOSUMDB" "off")
                  (setenv "GONOSUMDB" "*")
                  (setenv "GOPRIVATE" "")
                   (setenv "GVISOR_BPF_CLANG" bpf-clang)
                   (setenv "GVISOR_GUIX_CP" cp-command)
                    (setenv "GVISOR_GUIX_CAT" cat-command)
                    (setenv "GVISOR_GUIX_GREP" grep-command)
                   (setenv "GVISOR_GUIX_MKDIR" mkdir-command)
                   (setenv "GVISOR_GUIX_DIRNAME" dirname-command)
                   (setenv "GVISOR_BPF_INCLUDE_FLAGS" bpf-flags)
                   (setenv "GVISOR_PREWARMER_INCLUDE_FLAGS"
                           prewarmer-flags)
                   (setenv "GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS"
                           sysmsg-native-flags)
                    (setenv "GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS"
                            sysmsg-aarch64-flags)
                    (setenv "GVISOR_VDSO_NATIVE_INCLUDE_FLAGS"
                            vdso-native-flags)
                    (setenv "GVISOR_VDSO_AARCH64_INCLUDE_FLAGS"
                            vdso-aarch64-flags)
                   (setenv "GVISOR_NATIVE_LINUX_INCLUDE"
                           native-linux-include)
                   (setenv "GVISOR_TARGET_LINUX_INCLUDE"
                           target-linux-include)
                  (setenv "GVISOR_GUIX_NATIVE_TOOL_PREFIX" native-prefix)
                  (setenv "GVISOR_GUIX_NATIVE_INCLUDE_ROOTS" native-roots)
                  (setenv "GVISOR_GUIX_AARCH64_TOOL_PREFIX" target-prefix)
                  (setenv "GVISOR_GUIX_AARCH64_INCLUDE_ROOTS" target-roots)

                  ;; First materialize the vendor tree from the accepted cache.
                  (bounded
                   "75m" (string-append work "/vendor-user")
                   (string-append work "/vendor-output") "vendor"
                   (append (command-options repository-cache
                                            vendor-contents-cache)
                            (list "//:release")))
                  (mkdir-p (string-append vendor "/_registries"))
                   (invoke "cp" "-a"
                           (string-append fixed
                                          "/vendor-registry/bcr.bazel.build")
                           (string-append vendor "/_registries/"))

                   ;; Keep the accepted protobuf cache bytes immutable.  Patch
                   ;; only this derivation's private vendor copy so the
                   ;; authenticity action can use declared tools; mismatch
                   ;; failures and the release closure remain enforced.
                   (invoke patch-command "--batch" "--forward" "--fuzz=0"
                           "-p1" "-d" (string-append vendor "/protobuf+")
                           "-i"
                           #$%gvisor-protobuf-authenticity-guix-tools-patch)

                    (invoke python #$%gvisor-runtime-setup "audit"
                            "--source" (getcwd)
                            "--vendor-coral" coral
                            "--rendered-crosstool" crosstool
                            "--vendor-protobuf"
                            (string-append vendor "/protobuf+"))

                  ;; Re-analyze from the vendor tree alone and compare the
                  ;; configured labels before authorizing expensive actions.
                  (let ((closure (string-append work "/release-closure.txt")))
                    (with-output-to-file closure
                      (lambda ()
                        (bounded
                         "75m" (string-append work "/analysis-user")
                         (string-append work "/analysis-output") "cquery"
                         (append (command-options empty-cache
                                                  analysis-contents-cache)
                                  (list "--output=label" "deps(//:release)")))))
                    (invoke
                     python #$%gvisor-runtime-setup "compare-closure"
                     "--actual" closure "--expected"
                     (string-append
                      fixed "/share/gvisor-release-vendor-inputs/"
                      (if (string=? architecture "aarch64")
                          "release-closure-aarch64.txt"
                          "release-closure-native-x86_64.txt"))))

                  ;; This is the only phase that compiles gVisor.  The disk
                  ;; cache is new and private to this derivation.
                  (bounded
                   "8h" (string-append work "/build-user")
                   (string-append work "/build-output") "build"
                   (append (command-options empty-cache build-contents-cache)
                            (list (string-append "--disk_cache=" action-cache)
                                  "//:release"))))))
            (replace 'check
              (lambda* (#:key inputs native-inputs #:allow-other-keys)
                (use-modules (ice-9 ftw)
                             (ice-9 popen)
                             (ice-9 textual-ports))
                (let* ((all-inputs (append (or native-inputs '()) inputs))
                       (architecture #$architecture)
                       (readelf (search-input-file all-inputs "/bin/readelf"))
                       (release "bazel-bin/release")
                       (members
                        '("containerd-shim-runsc-v1"
                          "gvisor-bin/checkpointgofer"
                          "gvisor-bin/gvisor-sentry-prewarmer"
                          "gvisor-bin/gvisor_sentry"
                          "gvisor-bin/runsc-metric-server"
                          "runsc"))
                       (versioned
                        '("gvisor-bin/checkpointgofer"
                          "gvisor-bin/gvisor_sentry"
                          "gvisor-bin/runsc-metric-server"
                          "runsc"))
                       (unversioned
                        '("containerd-shim-runsc-v1"
                          "gvisor-bin/gvisor-sentry-prewarmer"))
                       (go-built
                        '("containerd-shim-runsc-v1"
                          "gvisor-bin/checkpointgofer"
                          "gvisor-bin/gvisor_sentry"
                          "gvisor-bin/runsc-metric-server"
                          "runsc"))
                        (machine
                         (if (string=? architecture "aarch64")
                             "AArch64"
                             "Advanced Micro Devices X86-64")))
                  (define (directory-members directory)
                    (sort (scandir directory
                                   (lambda (name)
                                     (not (member name '("." "..")))))
                          string<?))
                  (unless (equal? (directory-members release)
                                  '("containerd-shim-runsc-v1"
                                    "gvisor-bin"
                                    "runsc"))
                    (error "gVisor release top-level layout changed"
                           (directory-members release)))
                  (unless (eq? 'directory
                               (stat:type
                                (lstat (string-append release "/gvisor-bin"))))
                    (error "release gvisor-bin is not a real directory"))
                  (unless (equal?
                           (directory-members
                            (string-append release "/gvisor-bin"))
                           '("checkpointgofer"
                             "gvisor-sentry-prewarmer"
                             "gvisor_sentry"
                             "runsc-metric-server"))
                    (error "gVisor release sidecar layout changed"
                           (directory-members
                            (string-append release "/gvisor-bin"))))
                  (for-each
                   (lambda (relative)
                     (let* ((file (string-append release "/" relative))
                            (header
                             (let ((port (open-pipe* OPEN_READ readelf "-h" file)))
                               (let ((text (get-string-all port)))
                                 (unless (zero? (close-pipe port))
                                   (error "readelf rejected release member" relative))
                                 text)))
                            (program-headers
                             (let ((port (open-pipe* OPEN_READ readelf "-l" file)))
                               (let ((text (get-string-all port)))
                                 (unless (zero? (close-pipe port))
                                   (error "readelf program-header failure" relative))
                                 text)))
                            (dynamic
                             (let ((port (open-pipe* OPEN_READ readelf "-d" file)))
                               (let ((text (get-string-all port)))
                                 (unless (zero? (close-pipe port))
                                   (error "readelf dynamic-section failure" relative))
                                 text))))
                        (unless (and (eq? 'regular
                                          (stat:type (lstat file)))
                                     (access? file X_OK)
                                     (string-contains header machine))
                         (error "wrong or non-executable release member" relative))
                       (when (or (string-contains program-headers
                                                  "Requesting program interpreter")
                                 (string-contains dynamic "(NEEDED)"))
                         (error "release member is not statically linked"
                                relative))))
                   members)
                  (for-each
                   (lambda (relative)
                     (invoke "grep" "-aFq" "release-20260831.0"
                             (string-append release "/" relative)))
                   versioned)
                  (for-each
                   (lambda (relative)
                     (invoke "grep" "-aFq" "go1.26.3"
                             (string-append release "/" relative)))
                   go-built)
                  (for-each
                   (lambda (relative)
                     (when (zero? (system* "grep" "-aFq"
                                          "release-20260831.0"
                                          (string-append release "/" relative)))
                       (error "unversioned release member gained a version marker"
                              relative)))
                   unversioned))))
            (replace 'install
              (lambda* (#:key outputs #:allow-other-keys)
                (use-modules (ice-9 ftw))
                (let* ((out (assoc-ref outputs "out"))
                       (bin (string-append out "/bin"))
                       (release "bazel-bin/release")
                       (members
                        '("containerd-shim-runsc-v1"
                          "gvisor-bin/checkpointgofer"
                          "gvisor-bin/gvisor-sentry-prewarmer"
                          "gvisor-bin/gvisor_sentry"
                          "gvisor-bin/runsc-metric-server"
                          "runsc")))
                  (define (directory-members directory)
                    (sort (scandir directory
                                   (lambda (name)
                                     (not (member name '("." "..")))))
                          string<?))
                  (for-each
                   (lambda (relative)
                     (let ((destination (string-append bin "/" relative)))
                       (mkdir-p (dirname destination))
                       (copy-file (string-append release "/" relative)
                                  destination)
                       (chmod destination #o555)))
                    members)
                  (unless (equal? (directory-members out) '("bin"))
                    (error "installed package contains non-release files"
                           (directory-members out)))
                  (unless (equal? (directory-members bin)
                                  '("containerd-shim-runsc-v1"
                                    "gvisor-bin"
                                    "runsc"))
                    (error "installed top-level release layout changed"
                           (directory-members bin)))
                  (unless (eq? 'directory
                               (stat:type
                                (lstat (string-append bin "/gvisor-bin"))))
                    (error "installed gvisor-bin is not a real directory"))
                  (unless (equal?
                           (directory-members
                            (string-append bin "/gvisor-bin"))
                           '("checkpointgofer"
                             "gvisor-sentry-prewarmer"
                             "gvisor_sentry"
                             "runsc-metric-server"))
                    (error "installed sidecar layout changed"
                           (directory-members
                            (string-append bin "/gvisor-bin")))))))))))
    (native-inputs
     `(;; Both are host tools/data even under --target=aarch64-linux-gnu.
       ("bazel-bootstrap" ,gvisor-bazel-bootstrap)
       ("fixed-inputs" ,gvisor-release-vendor-inputs)
       ("package-tools" ,%gvisor-package-tools)
       ("native-gcc" ,gcc-toolchain)
       ("native-binutils" ,binutils-gold)
       ("native-libc" ,glibc)
       ("clang" ,clang-toolchain)
       ("linux-headers" ,linux-libre-headers)
       ("libbpf" ,libbpf)
       ("python" ,python)
       ,@%gvisor-runtime-action-inputs
       ,@(gvisor-aarch64-toolchain-inputs)))
    ;; The build execution host is intentionally x86_64 because the accepted
    ;; Bazel and Go seeds are x86_64 binaries.  The target-aware fields above
    ;; contain the separately validated x86_64 -> AArch64 path.  This field
    ;; names execution hosts, not target systems, so it remains x86_64-only.
    (supported-systems '("x86_64-linux"))
    (home-page "https://gvisor.dev")
    (synopsis "gVisor release runtime compiled from pinned source")
    (description
     "This reusable package compiles the six-file gVisor
@code{release-20260831.0} runtime distribution from the exact pinned source.
Its Bazel repository and Go module inputs are content-addressed and replayed
without downloader fallback in fresh per-derivation caches.  Bazel 8.3.1, its
embedded JDK 24, and Go 1.26.3 are explicitly identified binary bootstrap
seeds; this package does not claim an all-source toolchain bootstrap.  It
contains no PineNote runtime or security policy.")
    (license license:asl2.0)))

(define-public gvisor/source-diagnostic
  (package
    (inherit gvisor/source)
    (name "gvisor-source-built-diagnostic")
    ;; Keep the default package's origin pristine.  This separately named
    ;; variant applies only the reviewed, message-only Systrap diagnostic.
    (source
     (origin
       (inherit gvisor-source-origin)
       (patches (list %gvisor-diagnostic-error-report-patch))))
    (synopsis "Diagnostic gVisor runtime compiled from pinned source")
    (description
     "This diagnostic variant inherits the complete networkless source build
and six-file release validation from @code{gvisor/source}, but applies the
reviewed Systrap failure-context patch to its own source origin.  The patch
changes failure reporting only.  This package is distinct from the default
runtime and contains no PineNote runtime or security policy.")))
