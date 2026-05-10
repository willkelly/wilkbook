(define-module (pinenote packages kernel)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (gnu packages linux))

(define %linux-pinenote-version "6.6.30-pinenote")

(define %linux-pinenote-commit
  "6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931")

(define %linux-pinenote-source
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/m-weigand/linux")
          (commit %linux-pinenote-commit)))
    (file-name (git-file-name "linux-pinenote" %linux-pinenote-version))
    (sha256
     (base32 "0n1drcm98ljif528sfx9jxyvmc80zg28s47x91pn6dns4d7xlvjd"))))

(define-public linux-pinenote
  (package
    (inherit linux-libre)
    (name "linux-pinenote")
    (version %linux-pinenote-version)
    (source %linux-pinenote-source)
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
                    %linux-pinenote-commit))
    (synopsis "PineNote-oriented Linux kernel")
    (description
     "PineNote kernel package using m-weigand/linux commit
6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931 and its in-tree pinenote_defconfig.
The package inherits Guix's standard Linux build and install phases, replacing
only configuration so a full build runs the PineNote defconfig and installs the
kernel image, modules, and device-tree blobs through the normal Guix kernel
package layout.  The expected hardware-facing artifacts are the uncompressed
arch/arm64/boot/Image and
rockchip/rk3566-pinenote-v1.2.dtb; this package does not flash, repartition, or
mutate bootloader state.  The build normalizes three malformed legacy defconfig
assignment comments before Linux Kconfig reads the file.")
    (license license:gpl2)))
