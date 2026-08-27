(define-module (pinenote systems pinenote-reader-direct)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote services ebc)
  #:use-module (pinenote services ebc-direct)
  #:use-module (pinenote systems pinenote-reader)
  #:export (pinenote-reader-direct-operating-system))

;; STUDY FLAVOR, not a product.  The reader image on hrdl's direct-mode EBC
;; driver (linux-pinenote-hrdl-direct) -- doc/direct-mode-adoption.md P2's
;; "new flavor alongside the shipping reader, exactly as reader-debug exists
;; today, so the production image is never the experiment".  The shape is
;; pinenote-reader-debug's plus the direct-mode wiring: inherit the reader,
;; swap the kernel, rename the host so the flashed slot is identifiable at
;; the login prompt, add one tool, add the CLUT one-shot, and REPLACE the
;; shipping rockchip_ebc modprobe options with the direct-mode set.  Nothing
;; here touches pinenote-reader, and no shipping flavor references
;; linux-pinenote-hrdl-direct or (pinenote services ebc-direct).
;;
;; Per the adoption doc's no-roots rule, everything in this file dies with a
;; reject or graduates into pinenote-reader with an embrace; delete it
;; together with linux-pinenote-hrdl-direct and its patch either way.
;;
;; WHERE THIS STANDS (2026-08-25, doc/status.md).  The first direct-mode
;; glass session ran an image built from this file AS IT WAS -- which never
;; instantiated the CLUT service or the direct options (the release
;; review's top tag-blocker, confirmed live: `herd` showed no clut
;; service).  D1-D4 passed anyway because the operator did the wiring's job
;; by hand: compiled the CLUT on the device with wbf-clut, then rebound the
;; driver via sysfs.  This file now lands exactly that wiring.  THE WIRED
;; IMAGE ITSELF HAS NOT BOOTED: the services below reproduce the proven
;; hand-sequence, host-suite-tested (make ebc-clut-check), but no glass
;; session has run them.
;;
;; THE THREE THINGS THIS FLAVOR WIRES DIFFERENTLY, and why:
;;
;;   1. THE CLUT ONE-SHOT (pinenote-ebc-clut-service-type), WITH THE
;;      PER-BOOT REBIND.  hrdl's rockchip_ebc request_firmware()s
;;      rockchip/custom_wf.bin in rockchip_ebc_waveform_init() and returns
;;      -EINVAL when it is absent.  Our initrd RAW-LOADS the module from its
;;      pre-mount hook (%pinenote-display-initrd-modules in
;;      pinenote/images/pinenote-initramfs.scm), before the root filesystem
;;      -- and therefore before any CLUT -- exists, so under this kernel the
;;      first probe fails -EINVAL EVERY BOOT, by construction.  That initrd
;;      failure is EXPECTED and is not the bug.  The one-shot, ordered after
;;      pinenote-waveform, compiles the CLUT from the device's own ebc.wbf
;;      (never bundled -- per-device calibration, CLAUDE.md safety model),
;;      checksums it against a freshness record, and then REBINDS the
;;      driver:
;;
;;          echo fdec0000.ebc > /sys/bus/platform/drivers/rockchip-ebc/bind
;;
;;      which re-runs the probe against the CLUT -- the exact sequence the
;;      2026-08-25 session proved by hand (doc/status.md D1/D2).  A rebind
;;      that fails fails the service loudly; see the ordering note in
;;      (pinenote services ebc-direct).
;;
;;      KNOWN GAP, deliberate: reader-session does NOT require
;;      pinenote-ebc-clut, so shepherd may start KOReader before /dev/fb0
;;      exists.  Its requirement list is hard-coded in the shared service
;;      type, and adding the edge there would move the SHIPPING reader's
;;      derivation -- the one thing this flavor must never do.  KOReader
;;      has respawn? #t, so the expected first-boot behaviour is a few
;;      failed starts until the rebind lands; whether shepherd's
;;      crash-loop backoff copes is a bring-up observation for the next
;;      glass session, not something to engineer around unobserved.
;;      (Precision about 2026-08-25, doc/status.md: after crash-loops
;;      shepherd marked reader-session failing and later starts failed
;;      SILENTLY -- undiagnosed.  The herd-stop WEDGE that session was a
;;      different bug: orientation-bridge ignoring SIGTERM, since fixed
;;      in the bridge itself.)
;;
;;      wbf-clut stays in the profile below as the CONSOLE FALLBACK: if the
;;      service path breaks, an operator can still run
;;
;;        wbf-clut /lib/firmware/rockchip/ebc.wbf \
;;                 /lib/firmware/rockchip/custom_wf.bin
;;
;;      and rebind by hand, exactly as the first session did.
;;
;;   2. THE MODPROBE OPTIONS ARE THE DIRECT-MODE SET, replacing the shipping
;;      instance (both write /etc/modprobe.d/rockchip_ebc.conf, so this must
;;      be a replacement, not a second service).  Of our nine shipping
;;      parameters, exactly one (dclk_select) is registered by hrdl's module
;;      at all -- and the kernel WARNS AND IGNORES an unknown parameter
;;      (unknown_module_param_cb returns 0, kernel/module/main.c), so
;;      feeding it the shipping line would not refuse the load: it would
;;      load fine with eight of nine intents silently dropped, which is
;;      worse.  The direct set carries the panfrost softdep and sets
;;      nothing; the parameter-by-parameter derivation lives in
;;      (pinenote services ebc-direct), and `make ebc-modprobe-options-check'
;;      gates both sets against their own driver's registrations.  Note the
;;      rebind in (1) re-probes the already-loaded module, so modprobe.d
;;      stays out of the boot path either way; this matters the day
;;      something really does modprobe the module.
;;
;;   3. EVERYTHING ABOVE THE DRIVER STILL SPEAKS THE OLD VOCABULARY.  The
;;      shipped refresh policy is written in A2/DU/GL16/GC16 terms and hrdl's
;;      CLUT drops A2 entirely (D2: DU, DU4, GL16, GC16, INIT, WAITING, with
;;      bit depth chosen per rect by hints).  Three separate paths write
;;      /sys/module/rockchip_ebc/parameters/refresh_waveform -- the idle wash
;;      in pinenote/tools/power/autosuspend.lua, the idlewasher KOReader
;;      plugin, and pinenote-apply-ebc-params -- and that node does not exist
;;      here.  None of the three crashes on it: the two washers log and fall
;;      back to a plain full wash, and the params one-shot skips any parameter
;;      whose node is absent.  So this is reading quality, not a boot failure
;;      -- and the 2026-08-25 session CONFIRMED the predicted cost on glass:
;;      quality good, but more flashing/redrawing per page turn than a
;;      smooth read wants (the two-pass + waveform-class expectation, now
;;      driving P4's policy rewrite in doc/direct-mode-adoption.md).
;;
;;      The ioctl NUMBER survives: GLOBAL_REFRESH is ABI-identical
;;      (DRM_COMMAND_BASE + 0x00, same single-bool struct), so KOReader's
;;      0xC0016440 still reaches the driver -- though on this image it must
;;      reach the EBC's card node, not /dev/dri/card0, which panfrost claims
;;      (doc/status.md D4: every wash was a malformed GPU job until the
;;      session bind-mounted a card1 copy; the KOReader-side fix is its own
;;      work, not this file's).

(define pinenote-reader-direct-operating-system
  (operating-system
    (inherit pinenote-reader-operating-system)
    (host-name "pinenote-reader-direct")
    (kernel linux-pinenote-hrdl-direct)
    ;; fbcon=map:1 keeps the framebuffer console off fb0 for good: the
    ;; panel never shows a tty (operator directive 2026-08-27, after a
    ;; night of console text burning into the ghost ledger during every
    ;; reader stop and rebind).  The pinenote-ebc-splash one-shot paints
    ;; the white page that replaces it.  Serial console and sysrq are
    ;; untouched.
    (kernel-arguments
     (append (operating-system-user-kernel-arguments
              pinenote-reader-operating-system)
             '("fbcon=map:1")))
    ;; Per-device calibration data is compiled on the device from the
    ;; device's own waveform -- as with the waveform itself, nothing of the
    ;; sort is ever bundled in the image.
    (packages (cons pinenote-wbf-clut
                    (operating-system-packages
                     pinenote-reader-operating-system)))
    (services
     (cons* (service pinenote-ebc-direct-params-service-type)
            (service pinenote-ebc-clut-service-type)
            (service pinenote-ebc-splash-service-type)
            (modify-services (operating-system-user-services
                             pinenote-reader-operating-system)
             (pinenote-ebc-modprobe-service-type
              config => (pinenote-ebc-modprobe-configuration
                         (inherit config)
                         (options %pinenote-ebc-direct-modprobe-options))))))))

pinenote-reader-direct-operating-system
