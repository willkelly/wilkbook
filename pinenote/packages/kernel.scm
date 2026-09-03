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
;;
;; PINNED TO A SERIES, deliberately.  This was `nongnu:linux' -- a FLOATING
;; alias for whatever kernel.org release nonguix currently packages -- so the
;; kernel this repo built was decided by when the developer last ran `guix
;; pull', not by anything in the repo.  It moved to 7.1 and `make kernel'
;; stopped working entirely: mainline picked up commit 1d608a269e24, which is
;; the battery/charger DTS backport the forward-port patch also carries, and
;; dtc rejects the duplicate nodes (issue #13, doc/kernel-forward-port.md).
;;
;; A SERIES pin, not an exact-version pin, and that is a judgement call:
;;   * it eliminates the whole 7.0 -> 7.1 class of breakage, which is the one
;;     that actually bit and the one that silently changes what ships;
;;   * it still accepts 7.0.x POINT releases, so security fixes arrive without
;;     a commit here.  Those do not touch arch DTS in practice -- verified for
;;     the 7.0.11 -> 7.0.14 step (see doc/kernel-forward-port.md, "Upgrading
;;     the kernel"), not assumed.
;;
;; The exact hardware-proven version is 7.0.11 (doc/status.md).  Anything else
;; in 7.0.x is *accepted* but not *proven*; `make kernel-version-check' asserts
;; the series, and the upgrade procedure in doc/kernel-forward-port.md says what
;; re-proving costs.  Moving OFF 7.0.x is a deliberate forward-port project,
;; not a `guix pull' side effect -- which is the entire point of this line.
(define %linux-pinenote-base nongnu:linux-7.1)

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

(define %pinenote-kexec-config-lines
  ;; The update path (doc/update-path.md) trial-boots a new system
  ;; generation with kexec, because the stock U-Boot defaults to os1 on
  ;; its countdown and saveenv is forbidden: no unattended reboot lands in
  ;; os2 otherwise.  Both syscalls: kexec-tools prefers kexec_file_load on
  ;; arm64 and falls back to kexec_load.  Appended here, never by editing
  ;; the forward-port patch's defconfig.
  (list "CONFIG_KEXEC=y"
        "CONFIG_KEXEC_FILE=y"))

(define %linux-pinenote-patches
  (list (local-file "../patches/linux-pinenote-7.0-forward-port.patch")
        (local-file "../patches/linux-pinenote-7.0-bsp-sip-probe.patch")
        ;; ST accelerometer system-sleep support.  The mainline driver has
        ;; no .pm at all, so a suspend that removes power leaves the DRDY
        ;; line asserted and the kernel disables the IRQ permanently
        ;; ("irq 71: nobody cared") -- autorotation dies until reboot.
        ;; Reproduces on stock 6.12 too, so it is the driver, not us.
        ;; doc/upstream-register.md item 8.
        (local-file "../patches/linux-pinenote-7.0-st-accel-pm.patch")
        ;; EXPERIMENTAL (2026-08-05): CPU idle-states, so a cpuidle driver
        ;; exists at all.  Rockchip ships these for rk3308/3328/1808/3528/
        ;; 3562/3576/3588 but not rk356x, and mainline has none, so the
        ;; cores never leave WFI and awake idle sits at a ~206 mA floor.
        ;; The firmware is willing: its own PSCI debugfs reports CPU_SUSPEND
        ;; implemented, non-OSI, Original StateID format -- which is what
        ;; Rockchip's 0x0010000 (StateID 0, PowerDown, core) encodes.
        ;; Unproven on this SoC by anyone; a firmware that accepts the
        ;; parameter but cannot wake the core wedges the device.  Drop this
        ;; line to revert.  doc/power-management.md.
        (local-file "../patches/linux-pinenote-7.0-cpuidle-psci.patch")
        ;; vdd_cpu (TCS4525) boots in forced-PWM and nothing in the
        ;; ecosystem ever clears it.  Measured on glass 2026-08-06 by a
        ;; runtime i2c ABA with a dead-man revert: the chip's automatic
        ;; PFM/PWM mode saves ~30 mA at idle -- ~18% of the 163 mA awake
        ;; static floor.  Carries the fan53555_set_mode NORMAL-branch fix
        ;; (upstream-register item 10) that the DT route requires, plus
        ;; of_map_mode so regulator-initial-mode = <2> is honoured.
        ;; Acceptance on next boot: vdd_cpu opmode reads "normal" with no
        ;; runtime poke.  Drop this line to revert.
        (local-file "../patches/linux-pinenote-7.0-vdd-cpu-auto-pfm.patch")
        ;; Static-low DDR (2026-08-06): wilkbook_dmc, a minimal devfreq
        ;; driver over the DRAM SIP, holds DDR at the firmware table's
        ;; lowest rate (324 MHz).  Measured on glass: ~25 mA saved
        ;; quiesced vs the 1056 MHz boot rate; a switch costs ~107 ms
        ;; wall, sub-ms DRAM stall (awake-levers-20260806 addenda).
        ;; Built =m so the pinenote-dmc one-shot controls switch timing
        ;; around an idle EBC.  bl31 preserves the rate across
        ;; suspend/resume (addendum 2), so there are deliberately NO
        ;; suspend hooks anywhere.  Drop this line to revert.
        (local-file "../patches/linux-pinenote-7.0-dmc-static-low.patch")
        ;; Ultra suspend: hrdl's matched rails+override payload, validated
        ;; on this device 2026-08-08 (R12: three resumes, 4.64 mA).  MUST
        ;; apply after the bsp-sip patch -- it adds the standing override
        ;; to the /rockchip-suspend node that patch creates.  See the
        ;; patch header for why the pair must never be split.
        (local-file "../patches/linux-pinenote-7.0-ultra-rails.patch")
        ;; ---- The direct-mode EBC driver, embraced 2026-09-02 (both
        ;; operators; doc/direct-mode-adoption.md, doc/embrace-sweep-plan.md
        ;; S1).  hrdl's rework swaps out the forward-port patch's
        ;; rockchip_ebc.c: per-pixel software TCON, NEON blitters in their
        ;; own module, an offline-compiled CLUT instead of the hardware LUT
        ;; walk.  Two run-time conditions: the driver request_firmware()s
        ;; rockchip/custom_wf.bin (what wbf-clut produces on the device from
        ;; its own waveform; -EINVAL without it, so the FIRST probe of every
        ;; boot fails and the clut one-shot rebinds), and the third clock
        ;; (cpll_333m) is supplied by the swap patch's own DT hunk.  On
        ;; glass since 2026-08-25; the shipping reader's driver since S1.
        (local-file "../patches/linux-pinenote-7.1-hrdl-direct-mode.patch")
        ;; Ours, on top of hrdl's: the banded parallel NORMAL advance
        ;; (full-panel frames 18.4 -> 11.9 ms, glass-proven 2026-08-26 via
        ;; live module swap) plus the frame_period_us / advance_bands
        ;; instruments; queue_work's return checked.  See the patch header.
        (local-file "../patches/linux-pinenote-7.1-ebc-parallel-advance.patch")
        ;; Ours, on top of hrdl's: the RECT_HINTS ioctl bounded (an inverted
        ;; rectangle wrote a whole pitch past the hint plane; a short copy
        ;; over-read the batch; -ENOMEM).  doc/upstream-register.md item 24;
        ;; pinned by make direct-rect-hints-check.
        (local-file "../patches/linux-pinenote-7.1-rect-hints-bounds.patch")
        ;; Ours, on top of hrdl's: the probe unwinds again when drm_init
        ;; fails (stop the parked refresh kthread, disable runtime PM) --
        ;; the by-construction first probe no longer leaks and the rebind
        ;; stops logging "Unbalanced pm_runtime_enable!".  Item 23; pinned
        ;; by make direct-probe-quirk-check.
        (local-file "../patches/linux-pinenote-7.1-probe-unwind.patch")))

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
                            (append '#$%pinenote-qemu-virt-config-lines
                                    '#$%pinenote-kexec-config-lines))
                  (close-port port))
                (invoke "make" "olddefconfig")))))))
    (home-page
     "https://github.com/m-weigand/linux/tree/branch_pinenote_6-12-11")
    (synopsis "PineNote kernel: vanilla 7.1 + the EBC forward-port, hrdl's direct-mode EBC driver, and the suspend/power patches")
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



;; The EXTRACT_FBS diagnostic kernel (linux-pinenote-debug) and the direct-mode
;; study kernel (linux-pinenote-hrdl-direct) were retired by the embrace sweep's
;; S1 (2026-09-03): the shipping kernel IS the direct driver now, and it registers
;; EXTRACT_FBS natively.  linux-pinenote-debug-extract-fbs.patch stays in the tree
;; only as the ebc-logic harness's dbg fixture over the retained forward-port
;; driver source (doc/embrace-sweep-plan.md, decision 4).

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
                            (append '#$%pinenote-qemu-virt-config-lines
                                    '#$%pinenote-kexec-config-lines))
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
