(define-module (pinenote packages koreader)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system gnu)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages base)
  #:use-module (gnu packages cross-base)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages xdisorg))

;; KOReader from the upstream release binaries (the "linux" target), not
;; from source.  Rationale (see doc/koreader-spike.md): the source build
;; vendors ~30 third-party projects behind a network-fetching build
;; system, which Guix cannot run; the upstream tarball is self-contained
;; (bundled luajit, SDL3, mupdf, crengine, fonts) except for glibc and
;; the Wayland client stack that its SDL3 dlopens at runtime.  This is
;; also how the PineNote community runs it (hrdl's pinenote-dist ships
;; koreader-bin).  A from-source package stays future work.
;;
;; On the device KOReader does NOT use SDL at all: the bundled SDL3 can
;; only present on Wayland through GL or Vulkan (SDL3 dropped SDL2's shm
;; software path), and the PineNote image has neither.  Instead the
;; package grafts a native "pinenote" device target into the bundle
;; (koreader-device/): framebuffer_linux output on /dev/fb0, a pure-Lua
;; evdev input backend, and a full-refresh hook on the EBC driver's
;; global-refresh ioctl - the same way KOReader runs on Kobo hardware.
;; First light 2026-07-05: quickstart guide rendered, pen taps working.
;; On a workstation the SDL frontend still works under a desktop Wayland
;; session (or headless with SDL_VIDEODRIVER=offscreen, which is how the
;; smoke test works).

(define %koreader-version "2026.03")

(define (koreader-release-tarball)
  ;; Upstream names: koreader-linux-{x86_64,arm64}-v<version>.tar.xz.
  ;; Called from the package's *thunked* `inputs' field so that
  ;; (%current-target-system) is honored: a package-level `source' field
  ;; is evaluated at module load and would pin the host architecture
  ;; (that bug shipped briefly - both native and cross builds produced
  ;; the x86_64 variant).
  (let* ((system (or (%current-target-system) (%current-system)))
         (arch (cond ((string-prefix? "aarch64" system) "arm64")
                     ((string-prefix? "x86_64" system) "x86_64")
                     (else (error "koreader-bin: unsupported system"
                                  system)))))
    (origin
      (method url-fetch)
      (uri (string-append
            "https://github.com/koreader/koreader/releases/download/v"
            %koreader-version "/koreader-linux-" arch "-v"
            %koreader-version ".tar.xz"))
      (sha256
       (base32
        (if (string=? arch "arm64")
            "1mia2lrrbkds0zvqc9c3cmznfgd4x1rni0yvpl5qd5d29kjh80zm"
            "1bs1qy0szg2yqdqs9axcf9ic4v4xah5kgy9j74x0xqvkg6xybr1g"))))))

(define-public koreader-bin
  (package
    (name "koreader-bin")
    (version %koreader-version)
    ;; The real source is the "koreader-tarball" input (see above).
    (source #f)
    ;; gnu-build-system, not copy-build-system: copy's `lower' drops
    ;; #:target, so under --target it silently builds a native bag and
    ;; the rpath/interpreter point at build-machine libraries.  gnu's
    ;; cross path hands the phases target inputs.
    (build-system gnu-build-system)
    (arguments
     (list
      ;; Foreign binaries: no tests, never strip, and skip the
      ;; store-only RUNPATH validation ($ORIGIN is load-bearing).
      #:substitutable? #f
      #:tests? #f
      #:validate-runpath? #f
      #:strip-binaries? #f
      #:phases
      #~(modify-phases %standard-phases
          ;; unpack from the arch-selected input; the tarball has
          ;; multiple top-level entries (bin/, lib/, README.md)
          (replace 'unpack
            (lambda* (#:key inputs #:allow-other-keys)
              (mkdir "koreader")
              (invoke "tar" "-xJf"
                      (assoc-ref inputs "koreader-tarball")
                      "-C" "koreader" "--no-same-owner")
              (chdir "koreader")))
          (delete 'configure)
          (delete 'build)
          ;; Foreign bundle: leave every shebang alone.  Under --target
          ;; the default phases rewrite koreader.sh's #!/bin/sh to a
          ;; *build-machine* (x86_64) bash store path, producing "Exec
          ;; format error" on the device.
          (delete 'patch-source-shebangs)
          (delete 'patch-generated-file-shebangs)
          (delete 'patch-shebangs)
          (replace 'install
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((out (assoc-ref outputs "out")))
                (copy-recursively "bin" (string-append out "/bin"))
                (copy-recursively "lib" (string-append out "/lib"))
                (install-file "README.md"
                              (string-append
                               out "/share/doc/koreader-bin")))))
          ;; Graft the native PineNote device target into the bundle:
          ;; fbdev screen + pure-Lua evdev input (the release tarball
          ;; ships no compiled input module), plus the device probe hook.
          (add-after 'install 'add-pinenote-device
            (lambda* (#:key inputs native-inputs outputs
                      #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (kor (string-append out "/lib/koreader"))
                     (aux (or (assoc-ref (or native-inputs '())
                                         "pinenote-device")
                              (assoc-ref inputs "pinenote-device"))))
                (copy-recursively aux kor)
                ;; Probe order: PineNote before the SDL desktop fallback.
                (substitute* (string-append kor "/frontend/device.lua")
                  (("^    if util\\.loadSDL3\\(\\) then" line)
                   (string-append
                    "    -- PineNote (wilkbook): fbdev + evdev, no compositor\n"
                    "    local pinenote_model = io.open(\"/proc/device-tree/model\", \"r\")\n"
                    "    if pinenote_model then\n"
                    "        local model = pinenote_model:read(\"*a\") or \"\"\n"
                    "        pinenote_model:close()\n"
                    "        if model:find(\"PineNote\") then\n"
                    "            return require(\"device/pinenote/device\")\n"
                    "        end\n"
                    "    end\n\n"
                    line))))))
          ;; The bundle's C++ pieces (crengine, k2pdfopt) and luajit
          ;; need libstdc++.so.6/libgcc_s.so.1, which upstream does not
          ;; ship.  Copy them from the toolchain into the bundle's own
          ;; libs/ (GCC runtime-library exception), so no gcc package
          ;; ends up in the rpath or the closure.  They come from a
          ;; *native* input: the cross toolchain's lib output carries
          ;; the target runtime under <triplet>/lib, and putting
          ;; cross-gcc in `inputs' would try to cross-compile the
          ;; compiler itself (Canadian cross - fails).
          (add-after 'install 'bundle-gcc-runtime
            (lambda* (#:key inputs native-inputs outputs
                      #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (libs (string-append out "/lib/koreader/libs"))
                     (gcc-rt (or (assoc-ref (or native-inputs '())
                                            "gcc-runtime")
                                 (assoc-ref inputs "gcc-runtime"))))
                (for-each
                 (lambda (soname)
                   (let ((src (car (find-files
                                    gcc-rt
                                    (lambda (file stat)
                                      (string=? (basename file) soname)))))
                         (dst (string-append libs "/" soname)))
                     (copy-file src dst)
                     (chmod dst #o555)))
                 '("libgcc_s.so.1" "libstdc++.so.6")))))
          (add-after 'bundle-gcc-runtime 'patchelf
            (lambda* (#:key inputs native-inputs outputs
                      #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (kor (string-append out "/lib/koreader"))
                     (glibc (or (assoc-ref (or native-inputs '())
                                           "target-glibc")
                                (assoc-ref inputs "glibc")))
                     (ld (car (find-files (string-append glibc "/lib")
                                          "^ld-linux.*\\.so")))
                     ;; keep the bundle's own $ORIGIN search first, then
                     ;; the system deps.  --force-rpath uses classic
                     ;; DT_RPATH, which dlopened bundle modules inherit
                     ;; (the tarball itself relies on that behavior).
                     (rpath (string-join
                             (list "$ORIGIN" "$ORIGIN/libs"
                                   (string-append glibc "/lib")
                                   (string-append
                                    (assoc-ref inputs "wayland") "/lib")
                                   (string-append
                                    (assoc-ref inputs "libxkbcommon")
                                    "/lib"))
                             ":")))
                ;; the two ELF executables in the bundle
                (for-each
                 (lambda (file)
                   (invoke "patchelf" "--set-interpreter" ld file)
                   (invoke "patchelf" "--force-rpath" "--set-rpath" rpath
                           file))
                 (list (string-append kor "/luajit")
                       (string-append kor "/sdcv")))
                ;; SDL3 dlopens libwayland-client/-cursor and libxkbcommon
                ;; by soname; give it the store dirs.
                (invoke "patchelf" "--force-rpath" "--set-rpath" rpath
                        (string-append kor "/libs/libSDL3.so.0"))))))))
    ;; gcc-runtime / target-glibc: the toolchain pieces whose *payload*
    ;; must match the target but whose *package* must not be
    ;; cross-compiled (putting cross-gcc or glibc in `inputs' under
    ;; --target attempts a Canadian cross and fails).  As native inputs
    ;; they resolve to the same cross-toolchain artifacts every
    ;; cross-built package in the image links against.
    (native-inputs
     `(("patchelf" ,patchelf)
       ;; Architecture-independent Lua sources grafted into the bundle.
       ("pinenote-device" ,(local-file "koreader-device"
                                       "koreader-pinenote-device"
                                       #:recursive? #t))
       ("gcc-runtime" ,(let ((target (%current-target-system)))
                         (if target
                             (cross-gcc target
                                        #:xbinutils (cross-binutils target)
                                        #:libc (cross-libc target))
                             gcc))
        "lib")
       ,@(let ((target (%current-target-system)))
           (if target
               `(("target-glibc" ,(cross-libc target)))
               '()))))
    ;; Old-style labeled alist: the phases above assoc-ref these labels,
    ;; and the tarball origin needs an explicit label anyway.
    (inputs
     `(("koreader-tarball" ,(koreader-release-tarball))
       ,@(if (%current-target-system)
             '()
             `(("glibc" ,glibc)))
       ("wayland" ,wayland)
       ;; no libdecor: it fails to cross-build (pyproject dep), and SDL3
       ;; only dlopens it for client-side window decorations - pointless
       ;; in the cage kiosk and gracefully absent elsewhere
       ("libxkbcommon" ,libxkbcommon)))
    (supported-systems '("x86_64-linux" "aarch64-linux"))
    (home-page "https://koreader.rocks")
    (synopsis "KOReader document reader (upstream binary release)")
    (description
     "KOReader e-book/document reader, repackaged from the upstream
@code{linux} release tarball with patched ELF interpreter and library
paths.  Bundles its own luajit, SDL3, rendering engines and fonts;
requires a Wayland session (or @env{SDL_VIDEODRIVER=offscreen} for
headless use).")
    (license license:agpl3)))
