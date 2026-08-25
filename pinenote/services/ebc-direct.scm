(define-module (pinenote services ebc-direct)
  #:use-module (gnu services)
  #:use-module (pinenote services ebc)
  #:export (%pinenote-ebc-direct-modprobe-options
            pinenote-ebc-direct-modprobe-service))

;;; The rockchip_ebc module options for hrdl's DIRECT-MODE driver.
;;;
;;; STUDY ARTIFACT.  `doc/direct-mode-adoption.md' P2 builds his driver as
;;; `linux-pinenote-hrdl-direct'; nothing here reaches a shipping image, and
;;; no flavor consumes this module yet.  It exists because the parameters had
;;; to be derived before a flavor could be written, and because getting them
;;; wrong is silent (see "WHAT THE KERNEL DOES" below).
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
