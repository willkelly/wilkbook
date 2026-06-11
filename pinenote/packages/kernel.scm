(define-module (pinenote packages kernel)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages linux)
  #:use-module ((nongnu packages linux) #:prefix nongnu:))

;; Vanilla kernel.org source via the nonguix channel.  linux-libre cannot be
;; the base: its deblob pass disables non-free firmware loading outright
;; (request paths become /*(DEBLOBBED)*/), which blocks the PineNote's
;; Broadcom Wi-Fi even when the firmware files are present.  See
;; doc/kernel-forward-port.md.
(define %linux-pinenote-base nongnu:linux)

(define %linux-pinenote-6.6-version "6.6.30-pinenote")

(define %linux-pinenote-6.6-commit
  "6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931")

(define %linux-pinenote-6.6-source
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/m-weigand/linux")
          (commit %linux-pinenote-6.6-commit)))
    (file-name (git-file-name "linux-pinenote" %linux-pinenote-6.6-version))
    (sha256
     (base32 "0n1drcm98ljif528sfx9jxyvmc80zg28s47x91pn6dns4d7xlvjd"))))

(define %linux-pinenote-version
  (string-append (package-version %linux-pinenote-base) "-pinenote"))

(define %linux-pinenote-patches
  (list (local-file "../patches/linux-pinenote-7.0-forward-port.patch")))

(define %linux-pinenote-source
  (origin
    (inherit (package-source %linux-pinenote-base))
    (patches
     (append (origin-patches (package-source %linux-pinenote-base))
             %linux-pinenote-patches))))

(define-public linux-pinenote
  (package
    (inherit %linux-pinenote-base)
    (name "linux-pinenote")
    (version %linux-pinenote-version)
    (source %linux-pinenote-source)
    (arguments
     (substitute-keyword-arguments (package-arguments %linux-pinenote-base)
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'configure
              (lambda _
                (invoke "make" "pinenote_defconfig")
                (invoke "make" "olddefconfig")))))))
    (home-page
     "https://github.com/m-weigand/linux/tree/branch_pinenote_6-12-11")
    (synopsis "PineNote-oriented Linux kernel")
    (description
     "PineNote kernel package using vanilla kernel.org sources (via the
nonguix channel) with a local forward-port of the downstream PineNote EBC
display stack, WS8100 pen driver, and pinenote_defconfig derived from
m-weigand/linux.  The vanilla base keeps non-free firmware loading intact for
the Broadcom Wi-Fi/Bluetooth chip.  The package inherits the standard Linux
build and install phases, replacing only configuration so a full build runs
the PineNote defconfig and installs the kernel image, modules, and device-tree
blobs through the normal Guix kernel package layout.  The expected
hardware-facing artifacts are the uncompressed arch/arm64/boot/Image and
rockchip/rk3566-pinenote-v1.2.dtb; this package does not flash, repartition,
or mutate bootloader state.")
    (license license:gpl2)))


(define-public linux-pinenote-6.6.30
  (package
    (inherit linux-libre)
    (name "linux-pinenote")
    (version %linux-pinenote-6.6-version)
    (source %linux-pinenote-6.6-source)
    (arguments
     (substitute-keyword-arguments (package-arguments linux-libre)
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'configure
              (lambda _
                (substitute* "arch/arm64/configs/pinenote_defconfig"
                  (("# CONFIG_KEXEC=y") "CONFIG_KEXEC=y")
                  (("# CONFIG_KEXEC_CORE=y") "CONFIG_KEXEC_CORE=y")
                  (("# CONFIG_CRASH_CORE=y") "CONFIG_CRASH_CORE=y"))
                (invoke "make" "pinenote_defconfig")
                (invoke "make" "olddefconfig")))))))
    (home-page
     (string-append "https://github.com/m-weigand/linux/tree/"
                    %linux-pinenote-6.6-commit))
    (synopsis "Known-booting PineNote 6.6 kernel")
    (description
     "PineNote kernel package using the previously hardware-validated
m-weigand/linux 6.6.30 PineNote source.  This package is kept as a temporary
bring-up fallback for isolating regressions in newer forward-ported kernels.")
    (license license:gpl2)))
