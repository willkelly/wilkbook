(define-module (pinenote services ebc-direct)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote services ebc)
  #:export (%pinenote-ebc-direct-modprobe-options
            pinenote-ebc-direct-modprobe-service
            pinenote-ebc-clut-service-type
            pinenote-ebc-clut-configuration
            pinenote-ebc-clut-configuration?
            pinenote-ebc-clut-compiler
            pinenote-ebc-clut-source
            pinenote-ebc-clut-destination
            pinenote-ebc-clut-driver-directory
            pinenote-ebc-clut-device))

;; Services for hrdl's DIRECT-MODE rockchip_ebc (doc/direct-mode-adoption.md).
;;
;; EXACTLY ONE FLAVOR INSTANTIATES THIS FILE: pinenote-reader-direct, the
;; study flavor (since 2026-08-25; test-ebc-clut-install.py pins the set).
;; The shipping reader must never gain it: direct mode is a study artifact
;; until the embrace-or-reject decision, and everything here dies with a
;; reject or graduates with an embrace (the adoption doc's no-roots rule).
;; It lives in its own module, rather than beside the shipping EBC services
;; in (pinenote services ebc), so that adding to it cannot move the
;; reader's derivation even by accident.  Same posture as pinenote-wbf-clut
;; in (pinenote packages firmware).
;;
;; ---------------------------------------------------------------------
;; THE ORDERING PROBLEM, AND THE REBIND THAT SOLVES IT -- read before use
;; ---------------------------------------------------------------------
;;
;; doc/direct-mode-adoption.md P0 asserted, until this was checked on
;; 2026-08-25 and the paragraph rewritten:
;;
;;     "pinenote-ebc-modprobe-service-type loads the module from a shepherd
;;      one-shot ordered after pinenote-waveform, so the firmware path is
;;      already populated before modprobe"
;;
;; THAT IS FALSE, and it was the load-bearing reason the plan believed we
;; needed no initramfs work.  Measured in the tree, 2026-08-25:
;;
;;   * pinenote-ebc-modprobe-service-type extends etc-service-type ONLY.  It
;;     writes /etc/modprobe.d/rockchip_ebc.conf and loads nothing.  Nothing
;;     in pinenote/services or pinenote/systems ever runs
;;     `modprobe rockchip_ebc'.
;;   * The module is RAW-LOADED IN THE INITRD.  rockchip_ebc is in
;;     %pinenote-display-initrd-modules and pinenote-initrd*'s #:pre-mount
;;     hook calls load-linux-modules-from-directory on it, straight after
;;     copying the waveform partition to the INITRD's own
;;     /lib/firmware/rockchip/ebc.wbf.  That same file has the comment
;;     "the initrd raw-loads rockchip_ebc ... which passes no parameters at
;;     all", hardware-confirmed 2026-07-05.
;;
;; So probe -- and therefore request_firmware("rockchip/custom_wf.bin"), and
;; therefore hrdl's -EINVAL -- happens inside the initramfs, before the root
;; filesystem this service writes to is even mounted.  A shepherd one-shot
;; cannot be "before the module loads"; that is exactly why hrdl's unit runs
;; `mkinitcpio -P' and then `modprobe -r rockchip_ebc; modprobe rockchip_ebc'.
;;
;; RESOLVED ON GLASS, 2026-08-25 (doc/status.md D2): the answer is none of
;; the three options D7 priced (initrd compile / deferred modprobe / module
;; reload) but a fourth with a smaller blast radius -- a SYSFS REBIND.  The
;; initrd's failed probe leaves the module registered and the device
;; unbound, so after the CLUT is installed and verified,
;;
;;     echo fdec0000.ebc > /sys/bus/platform/drivers/rockchip-ebc/bind
;;
;; re-runs the probe against the CLUT and it passes.  The session proved
;; that by hand; the one-shot below now DOES IT ITSELF, every boot, as the
;; final stage of ebc-clut-install.sh -- unbind if bound, bind, then check
;; the end state (device bound AND a DRM card* minor under it), failing
;; LOUDLY if the probe still refuses.  No initrd change, no modprobe, no
;; modprobe.d exposure (the rebind re-probes the already-loaded module, so
;; module parameters never re-enter the picture).
;;
;; What this means for reading the boot log: under this flavor the initrd's
;; rockchip_ebc -EINVAL probe failure is EXPECTED ON EVERY BOOT and is not
;; the bug; the display's fate is decided by this service's rebind lines
;; that follow.  The wired-together path (this service doing the rebind)
;; has passed the host suite but has NOT itself booted on glass -- the
;; session ran the same steps by hand.

(define-record-type* <pinenote-ebc-clut-configuration>
  pinenote-ebc-clut-configuration make-pinenote-ebc-clut-configuration
  pinenote-ebc-clut-configuration?
  ;; The package providing bin/wbf-clut.  Its STORE PATH is half of the
  ;; freshness record the installer keeps, so a rebuilt compiler forces a
  ;; recompile without anyone having to remember to.
  (compiler    pinenote-ebc-clut-compiler    (default pinenote-wbf-clut))
  ;; The device's own waveform, as pinenote-install-waveform leaves it.
  ;; Never bundled, never committed: this service's whole input is
  ;; per-device calibration data extracted from the device's own partition.
  (source      pinenote-ebc-clut-source
               (default "/lib/firmware/rockchip/ebc.wbf"))
  ;; Where hrdl's driver looks: request_firmware("rockchip/custom_wf.bin").
  (destination pinenote-ebc-clut-destination
               (default "/lib/firmware/rockchip/custom_wf.bin"))
  ;; The rebind target: the driver's sysfs directory and the platform
  ;; device whose initrd-time probe failed -EINVAL.  Handed to the
  ;; installer as its two trailing arguments; the install without the
  ;; rebind is a file nobody reads (see the ordering note above), so
  ;; these have no "off" value.
  (driver-directory pinenote-ebc-clut-driver-directory
                    (default "/sys/bus/platform/drivers/rockchip-ebc"))
  (device pinenote-ebc-clut-device
          (default "fdec0000.ebc")))

(define %pinenote-ebc-clut-install
  ;; A real file, not a string inside this module, for manuals-stage.sh's
  ;; two reasons: CI's "every tracked shell script parses" gate covers it,
  ;; and pinenote/scripts/preflight/test-ebc-clut-install.py EXECUTES it
  ;; through every branch against a fake firmware tree instead of grepping
  ;; it.  That is also why it takes its paths as arguments.
  (local-file "ebc-clut-install.sh" "pinenote-ebc-clut-install"))

(define (pinenote-ebc-clut-shepherd-service config)
  (list
   (shepherd-service
    (provision '(pinenote-ebc-clut))
    ;; pinenote-waveform is the service that puts ebc.wbf on the ROOT
    ;; filesystem; it already requires root-file-system and udev.  Without
    ;; this edge shepherd would start the two concurrently and the compile
    ;; would race its own input.
    (requirement '(pinenote-waveform))
    (documentation "Compile this device's waveform into the CLUT hrdl's direct-mode rockchip_ebc requires (recompiling whenever the waveform or the compiler changes), then rebind the driver so the probe the initrd already failed runs again against it.  A failed rebind fails this service -- see the ordering note in this file.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* "/bin/sh" #$%pinenote-ebc-clut-install
                         #$(file-append (pinenote-ebc-clut-compiler config)
                                        "/bin/wbf-clut")
                         #$(pinenote-ebc-clut-source config)
                         #$(pinenote-ebc-clut-destination config)
                         ;; STAMP: "" keeps the script's default (a dotfile
                         ;; beside DESTINATION); it is passed only so the
                         ;; rebind pair can follow positionally.
                         ""
                         #$(pinenote-ebc-clut-driver-directory config)
                         #$(pinenote-ebc-clut-device config)))))
    (stop #~(const #t)))))

(define pinenote-ebc-clut-service-type
  (service-type
   (name 'pinenote-ebc-clut)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-ebc-clut-shepherd-service)))
   (default-value (pinenote-ebc-clut-configuration))
   (description "Compile the device's own ebc.wbf into rockchip/custom_wf.bin for hrdl's direct-mode EBC driver, which fails probe with -EINVAL without it, then rebind the driver via sysfs so the probe runs again with the CLUT in place (the initrd's raw-load probes -- and fails -- before the root filesystem exists, every boot).  The result is derived per-device calibration data: it is produced on the device at boot and never bundled.  Rebuilt whenever the waveform, the compiler or the installed file changes, rather than compiled once if absent.")))


;;; ===== The direct-mode modprobe options (blocker 1) =====

;;; The rockchip_ebc module options for hrdl's DIRECT-MODE driver.
;;;
;;; STUDY ARTIFACT.  `doc/direct-mode-adoption.md' P2 builds his driver as
;;; `linux-pinenote-hrdl-direct'; nothing here reaches a shipping image.
;;; The reader-direct flavor consumes this set (since 2026-08-25), REPLACING
;;; the shipping options instance rather than adding a second one.  It exists
;;; because the parameters had to be derived before a flavor could be
;;; written, and because getting them wrong is silent (see "WHAT THE KERNEL
;;; DOES" below).
;;;
;;; It lives in its own module rather than beside the shipping options in
;;; (pinenote services ebc) for a load-bearing reason: `make settings-check'
;;; (issue #12 step 1) reads ebc.scm and requires EXACTLY ONE
;;; `options rockchip_ebc' line there, because that string has three
;;; build-time copies it holds in agreement.  A second, unrelated options
;;; string in that file would break a gate that is right to be strict.
;;;
;;; WHAT THE KERNEL DOES WITH A WRONG OPTIONS LINE
;;; ==============================================
;;; Nothing loud.  `unknown_module_param_cb' (7.1.8,
;;; kernel/module/main.c:3366) `pr_warn's "unknown parameter '%s' ignored"
;;; and RETURNS 0.  Handing hrdl's driver our shipping options would load it
;;; successfully with eight of nine intents silently discarded and the ninth
;;; (`dclk_select') accepted into dead code.  That is worse than a refusal,
;;; and it is why `make ebc-modprobe-options-check' exists.
;;;
;;; WHY THIS SETS NOTHING
;;; =====================
;;; Not one of our nine shipping parameters transfers.  Seven do not exist in
;;; his driver at all (`direct_mode' only when CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE
;;; is on, which does not compile; `auto_refresh', `refresh_threshold',
;;; `panel_reflection', `prepare_prev_before_a2', `refresh_waveform' and
;;; `defio_delay_ms' are gone outright).  `split_area_limit' looks shared and
;;; is not -- `modinfo -p' advertises it because a stale MODULE_PARM_DESC sits
;;; on top of `module_param(limit_fb_blits, ...)'; the module accepts only
;;; `limit_fb_blits', and `limit_fb_blits=0' means "allow zero framebuffer
;;; blits", i.e. a panel nothing ever reaches.  `dclk_select' is real and
;;; inert: `rockchip_ebc_set_dclk()' returns before the `switch (dclk_select)'
;;; whenever `direct_mode' is true, having pinned cpll_333m to 33.33 MHz and
;;; dclk to 34 MHz.  That is not a smaller version of #23's 250 MHz result --
;;; it is a different clock regime.  3WIN divides dclk by `pixels_per_sdck'
;;; (8 here) to reach the panel's source-driver clock, so 200 MHz becomes
;;; 25 MHz SDCK; direct mode programs SDCLK_DIV=0, so dclk IS the SDCK and
;;; 34 MHz is the ~1.36x that yields the ~85 Hz the swap was for.  #23's
;;; measurement does not transfer, and setting the parameter cannot make it.
;;;
;;; That leaves his sixteen registered parameters, and we set none of them.
;;; The reason for each, so a later session can argue with a record rather
;;; than a guess:
;;;
;;;   default_hint 0xa0     Y4 | THRESHOLD | REDRAW.  Y4 is 16 grey levels,
;;;                         which is what reading wants; thresholding beats
;;;                         dithering for text at that depth.  ayakael's
;;;                         pinenote-dist ships `default_hint=0xa0', which is
;;;                         this value written out.
;;;   redraw_delay 0        Redraws OFF.  ayakael ships 200 (~2.35 s at 85 Hz):
;;;                         a periodic top-up drive of every REDRAW-hinted
;;;                         pixel.  We keep the default because our display
;;;                         policy is that USERSPACE owns every drive -- the
;;;                         2026-07-12 optics finding 10 that threshold-fired
;;;                         auto-globals corrupt panel state is why we ship
;;;                         `auto_refresh=0' today, and a driver-scheduled
;;;                         periodic redraw is the same class of thing.  Its
;;;                         power and DDR-fetch cost on our panel is also
;;;                         unmeasured, on the one axis with a known silent
;;;                         failure mode (`doc/power-management.md', DDR DVFS).
;;;   early_cancellation_addition 2   ayakael ships this value; it is also the
;;;                         driver default, so it is not evidence of tuning.
;;;   shrink_virtual_window #f   Restricts the EBC window to the ongoing clip,
;;;                         cutting DDR fetch with damage area -- attractive
;;;                         against our one confirmed failure mode, and the
;;;                         FIRST thing to try if direct mode shows corruption.
;;;                         hrdl ships it off and calls it an experiment
;;;                         (`doc/hrdl-evaluation.md'); a bring-up default is
;;;                         not where an experiment belongs.
;;;   limit_fb_blits -1     Unlimited.  A debug limiter, and see above for
;;;                         what 0 does.
;;;   no_off_screen #f      Keep applying the off-screen image (GC16) on the
;;;                         SUSPEND work item -- the same park-before-suspend
;;;                         shape we already ship.  Note his driver asks for
;;;                         `rockchip/rockchip_ebc_default_screen_x4y4.bin',
;;;                         one byte per pixel; our pinenote-ebc-default-screen
;;;                         package installs `rockchip_ebc_default_screen.bin'
;;;                         at 4bpp, so his request misses and he memsets
;;;                         white.  Harmless, and not a module-parameter fix.
;;;   delay_a 200           Declared, never read.  A dead parameter; nothing to
;;;                         gain by naming it.
;;;   refresh_thread_wait_idle 2000   ms of quiet before the refresh thread
;;;                         parks.  Parking is good for power; leave it.
;;;   dithering_method 2    Blue-noise 32.  Only consulted under a DITHER hint,
;;;                         which the default hint does not set.
;;;   bw_threshold 7, y2_dt_thresholds, y2_th_thresholds
;;;                         Y1/Y2 quantisation only.  Reading is Y4.
;;;   dclk_select 0         Dead in direct mode -- see above.
;;;   temp_override 0       Use the measured temperature.  Overriding pins one
;;;                         of the CLUT's temperature bins, which is a
;;;                         one-variable session tool, not a shipped default.
;;;                         (Note the P1 finding that drm_epd_helper.c never
;;;                         adds 1 to temp_range_count, so the top bin is
;;;                         unreachable either way.)
;;;   hskew_override 0      The panel mode supplies hskew; overriding it is a
;;;                         timing experiment.
;;;   rect_hint_batch 20    ioctl read batch size. No reader-visible meaning.
;;;
;;; So the file carries the panfrost softdep and nothing else.  The softdep is
;;; orthogonal to which EBC driver is loaded: it keeps the GPU from claiming
;;; the DRM device slot ahead of the display, and both postmarketOS and PNDeb
;;; ship it independently.
;;;
;;; WHAT THIS DOES NOT SOLVE, AND MUST NOT BE READ AS SOLVING
;;; ========================================================
;;;  * On our boot path /etc/modprobe.d is nearly inert: the initrd raw-loads
;;;    rockchip_ebc, so parameters actually land through
;;;    `pinenote-apply-ebc-params' (a one-shot in (pinenote packages firmware))
;;;    writing sysfs.  That script hard-codes our nine names and SKIPS a name
;;;    whose sysfs file is absent, returning success.  Against hrdl's driver it
;;;    would therefore apply nothing and exit 0 -- a vacuous success.  A
;;;    direct-mode flavor needs its own params one-shot, or none at all; it
;;;    must not inherit that one unexamined.
;;;  * Probe still fails without `rockchip/custom_wf.bin' (D1), and our EBC
;;;    device-tree node exposes only "hclk" and "dclk" while his driver does a
;;;    hard `devm_clk_get(dev, "cpll_333m")' and `dev_err_probe's on failure.
;;;    Nothing here can load, let alone display, until both are fixed.

(define %pinenote-ebc-direct-modprobe-options
  "softdep panfrost pre: rockchip_ebc\n")

;; A direct-mode flavor should REPLACE the shipping instance rather than add
;; a second one -- both write /etc/modprobe.d/rockchip_ebc.conf, so two
;; instances collide by construction:
;;
;;   (modify-services %pinenote-bringup-services
;;     (pinenote-ebc-modprobe-service-type config =>
;;       (pinenote-ebc-modprobe-configuration
;;        (inherit config)
;;        (options %pinenote-ebc-direct-modprobe-options))))
;;
;; This constructor is the standalone form, for a flavor that assembles its
;; bringup list itself.
(define (pinenote-ebc-direct-modprobe-service)
  (service pinenote-ebc-modprobe-service-type
           (pinenote-ebc-modprobe-configuration
            (options %pinenote-ebc-direct-modprobe-options))))
