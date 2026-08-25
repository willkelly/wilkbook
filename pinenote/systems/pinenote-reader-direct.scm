(define-module (pinenote systems pinenote-reader-direct)
  #:use-module (gnu system)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote systems pinenote-reader)
  #:export (pinenote-reader-direct-operating-system))

;; STUDY FLAVOR, not a product.  The reader image on hrdl's direct-mode EBC
;; driver (linux-pinenote-hrdl-direct) -- doc/direct-mode-adoption.md P2's
;; "new flavor alongside the shipping reader, exactly as reader-debug exists
;; today, so the production image is never the experiment".  The shape is
;; pinenote-reader-debug's, deliberately: inherit the reader, swap the
;; kernel, rename the host so the flashed slot is identifiable at the login
;; prompt, add one tool.  Nothing here touches pinenote-reader, and no
;; shipping flavor references linux-pinenote-hrdl-direct.
;;
;; NOTHING IN THIS FLAVOR HAS EVER RUN.  The kernel and its three modules
;; build and link (2026-08-25, doc/direct-mode-adoption.md P2); no module has
;; been loaded, no device bound, no panel driven.  The realistic first goal
;; is "rockchip_ebc probes, binds, and lights the panel at all", not a
;; working page turn.
;;
;; THREE REASONS TO EXPECT A FIRST BOOT WITHOUT A DISPLAY, all known offline
;; and none of them fixed here:
;;
;;   1. custom_wf.bin IS MANDATORY AND NOTHING PRODUCES IT AT BOOT.  hrdl's
;;      rockchip_ebc request_firmware()s rockchip/custom_wf.bin in
;;      rockchip_ebc_waveform_init() and returns -EINVAL when it is absent,
;;      so the probe fails outright -- D4's "worse first-boot failure": no
;;      display, indistinguishable from a brick.  pinenote-wbf-clut compiles
;;      that file from the device's own ebc.wbf and is added to this flavor's
;;      profile below (as wbf-clut), so an operator on the console can make
;;      one by hand; NO SERVICE RUNS IT.
;;
;;      TODO(direct-mode): the custom_wf.bin installation -- a one-shot in
;;      the shape of pinenote-install-waveform, with the checksum
;;      doc/direct-mode-adoption.md P0 demands instead of upstream's
;;      compile-once-if-absent -- is separate work.  When it lands, wire it
;;      in here.  Do not grow a second copy of it in this file.
;;
;;      AND THE ORDERING IS THE HARDER HALF.  Our initrd RAW-LOADS
;;      rockchip_ebc from its pre-mount hook (%pinenote-display-initrd-modules
;;      in pinenote/images/pinenote-initramfs.scm), i.e. before the root
;;      filesystem is mounted and long before any shepherd one-shot can
;;      compile anything.  That hook stages ebc.wbf into the initrd's
;;      /lib/firmware/rockchip and stages no custom_wf.bin -- so under this
;;      kernel the probe runs, and fails, inside the initrd.  A root-filesystem
;;      service that writes custom_wf.bin afterwards cannot fix that on its
;;      own: something must also reload the module (hrdl's own
;;      pinenote-hrdl-convert-waveform.service ends in `modprobe -r
;;      rockchip_ebc; modprobe rockchip_ebc' for exactly this reason), or the
;;      compile must happen in the initrd, or rockchip_ebc must come out of
;;      the initrd module list for this flavor and be loaded later.  Which of
;;      those is right is undecided; measuring it needs the module to have
;;      probed once, which has not happened.
;;
;;   2. THE MODPROBE OPTIONS NAME PARAMETERS THIS DRIVER DOES NOT HAVE.
;;      pinenote-ebc-modprobe-service-type installs
;;      /etc/modprobe.d/rockchip_ebc.conf with nine `options rockchip_ebc'
;;      settings (pinenote/services/ebc.scm).  Against hrdl's module -- 17
;;      module_param() calls in his source, 16 of them registered in what we
;;      build, direct_mode's being compiled out with 3WIN off -- exactly ONE
;;      of our nine exists:
;;      dclk_select.  auto_refresh, refresh_threshold, panel_reflection,
;;      prepare_prev_before_a2, refresh_waveform and defio_delay_ms are simply
;;      absent; direct_mode is registered only under
;;      CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE, which does not compile in his tree
;;      and which we correctly build without, so `direct_mode=0' is both
;;      invalid and backwards -- direct mode is what this flavor is for.
;;
;;      split_area_limit looks shared and is not: his tree has
;;      MODULE_PARM_DESC(split_area_limit, ...) attached to
;;      module_param(limit_fb_blits, ...), a copy/paste that puts the name in
;;      modinfo's parm lines while registering nothing.  There is no
;;      parameters/split_area_limit and modprobe would reject it.  Read
;;      modinfo carefully here; a "parm:" line is not proof of a parameter.
;;
;;      This is INERT TODAY only because the initrd raw-load ignores
;;      modprobe.d (the same reason kernel-cmdline module params never
;;      applied -- hardware-confirmed 2026-07-05).  It stops being inert the
;;      moment anyone reloads the module, which is precisely what (1) will
;;      ask them to do: modprobe then fails on the unknown parameters.
;;      pinenote-apply-ebc-params is the softer half -- it skips parameters
;;      whose sysfs node is absent, so it degrades to setting dclk_select and
;;      nothing else.
;;
;;      TODO(direct-mode): making the modprobe options per-flavor means giving
;;      pinenote-ebc-modprobe-service-type a configuration; that is separate
;;      work in pinenote/services/ebc.scm, not this file's.  Until it lands
;;      this flavor ships the shipping reader's option line, wrong parameters
;;      and all.
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
;;      whose node is absent.  So this is reading quality, not a boot failure.
;;
;;      What should survive: GLOBAL_REFRESH is ABI-identical (DRM_COMMAND_BASE
;;      + 0x00, the same single-bool struct), so KOReader's page-turn ioctl in
;;      device.lua is unchanged.  REFRESH_BARRIER does not exist in his driver
;;      at all, but nothing in pinenote/services, pinenote/systems or the
;;      plugins uses it -- it costs two host-test subjects, not shipped
;;      behaviour.
;;
;; Delete this file together with linux-pinenote-hrdl-direct and its patch if
;; the adoption hits one of doc/direct-mode-adoption.md's bail-out criteria.

(define pinenote-reader-direct-operating-system
  (operating-system
    (inherit pinenote-reader-operating-system)
    (host-name "pinenote-reader-direct")
    (kernel linux-pinenote-hrdl-direct)
    ;; wbf-clut on the device, for the by-hand path in (1) above:
    ;;
    ;;   wbf-clut /lib/firmware/rockchip/ebc.wbf \
    ;;            /lib/firmware/rockchip/custom_wf.bin
    ;;
    ;; reading the waveform pinenote-install-waveform has already staged on
    ;; the root filesystem, and writing the CLUT0002 table this driver
    ;; demands.  Reloading the module to pick it up then trips (2) above,
    ;; because modprobe -- unlike the initrd's raw load -- reads
    ;; /etc/modprobe.d.
    ;; Per-device calibration data, compiled on the device from the device's
    ;; own waveform -- as with the waveform itself, nothing of the sort is
    ;; ever bundled in the image.
    (packages (cons pinenote-wbf-clut
                    (operating-system-packages
                     pinenote-reader-operating-system)))))

pinenote-reader-direct-operating-system
