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

;; Built-in support for QEMU's generic ARM64 "virt" machine so the exact
;; hardware kernel image can be smoke-tested off-device (virtio root disk,
;; PL011 console).  Built-in rather than modular so the initrd needs no
;; QEMU-specific module list.  Harmless on PineNote hardware.
(define %pinenote-qemu-virt-config-lines
  (list "CONFIG_PCI_HOST_GENERIC=y"
        ;; pinenote_defconfig disables the VIRTIO_MENU umbrella, which gates
        ;; the PCI/MMIO transports; without it olddefconfig silently drops
        ;; the lines below and QEMU's disk never appears.
        "CONFIG_VIRTIO_MENU=y"
        "CONFIG_VIRTIO_PCI=y"
        "CONFIG_VIRTIO_MMIO=y"
        "CONFIG_VIRTIO_BLK=y"
        "CONFIG_VIRTIO_NET=y"
        "CONFIG_VIRTIO_CONSOLE=y"
        "CONFIG_HW_RANDOM_VIRTIO=y"
        "CONFIG_SERIAL_AMBA_PL011=y"
        "CONFIG_SERIAL_AMBA_PL011_CONSOLE=y"
        "CONFIG_RTC_DRV_PL031=y"
        ;; Software stand-ins for PineNote hardware, modules so they only
        ;; exist when explicitly loaded inside the VM: dummy_hcd fakes a UDC
        ;; so the configfs/ACM gadget stack can be exercised without dwc3,
        ;; and vkms provides a virtual DRM device for render-path testing.
        "CONFIG_USB_DUMMY_HCD=m"
        "CONFIG_DRM_VKMS=m"
        ;; The offline visual loop (rung 4v): virtio-gpu gives the virt
        ;; guest a real /dev/fb0 for KOReader to paint (QMP screendump on
        ;; the host), virtio-input provides scripted tablet/keyboard
        ;; events.  Modules, loaded by udev coldplug from the rootfs on
        ;; virt only — no initrd change, invisible on hardware.
        "CONFIG_DRM_VIRTIO_GPU=m"
        "CONFIG_VIRTIO_INPUT=m"))

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
                (let ((port (open-file ".config" "a")))
                  (for-each (lambda (line)
                              (display line port)
                              (newline port))
                            '#$%pinenote-qemu-virt-config-lines)
                  (close-port port))
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


;; Diagnostic kernel for the quirk F investigation
;; (doc/driver-findings-report.md, finding 2026-07-12): linux-pinenote plus
;; one printk-only instrumentation patch that detects the straggler DSP_END
;; credit at global-refresh launch.  A separate inheriting variant so the
;; primary linux-pinenote stays byte-identical; delete this package and the
;; debug patch together when the investigation closes.
(define-public linux-pinenote-debug
  (package
    (inherit linux-pinenote)
    (name "linux-pinenote-debug")
    (source
     (origin
       (inherit (package-source %linux-pinenote-base))
       (patches
        (append (origin-patches (package-source %linux-pinenote-base))
                %linux-pinenote-patches
                (list (local-file
                       "../patches/linux-pinenote-debug-dspend-straggler.patch"))))))
    (synopsis "PineNote kernel with DSP_END straggler instrumentation")
    (description
     "The linux-pinenote kernel with an additional printk-only debug patch
that instruments the rockchip_ebc global-refresh completion handshake: it
warns when an unconsumed DSP_END credit is present at global launch, logs
every global wait's return value and elapsed time against the expected LUT
playback duration with launch provenance (threshold vs ioctl vs
init/reset/resume/offscreen), counts per-burst frame timeouts, and
rate-limit-warns when a DSP_END interrupt arrives while a previous credit
is still unconsumed.  Driver logic is unchanged; this is a diagnostic
artifact for the quirk F threshold-global corruption investigation.")))

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
                (let ((port (open-file ".config" "a")))
                  (for-each (lambda (line)
                              (display line port)
                              (newline port))
                            '#$%pinenote-qemu-virt-config-lines)
                  (close-port port))
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
