(define-module (pinenote services autosuspend)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (pinenote packages koreader)
  #:export (pinenote-autosuspend-service-type
            pinenote-autosuspend-configuration
            pinenote-autosuspend-configuration?
            pinenote-autosuspend-idle-seconds
            pinenote-autosuspend-backstop-seconds
            pinenote-autosuspend-overlay?
            pinenote-autosuspend-suspend-while-charging?
            pinenote-autosuspend-config-file
            pinenote-autosuspend-luajit
            pinenote-autosuspend-script))

;; Auto-suspend to platform `deep` after a period with no user input.
;;
;; Why this is the highest-value power work available: measured 2026-08-02,
;; awake idle costs ~172 mA and deep costs ~19.3 mA, so scheduling deep
;; well is worth ~7x.  Nothing else measured on this platform is worth more
;; than single-digit percent -- see doc/power-management.md, "Power
;; program".
;;
;; Two hardware facts this service depends on, both proven before it was
;; written:
;;   * a power-button press wakes the device from deep (2026-08-02: woke at
;;     35s against a 90s RTC backstop, alarm still pending);
;;   * deep suspend works with reader-session RUNNING, which is the only
;;     case that matters here.
;;
;; Tunables are two-layer by design:
;;   build time -- the fields below, baked into the service;
;;   run time   -- /var/lib/pinenote/autosuspend.conf, re-read before every
;;                 idle wait, no restart needed:
;;                   idle=120      seconds of no input before suspending
;;                   backstop=3600 RTC safety wake, seconds
;;                   enabled=0     pause auto-suspend entirely
;; The runtime file wins when present.  A malformed value is ignored rather
;; than fatal: a typo must not leave the device unable to sleep or, worse,
;; unable to wake.

(define-record-type* <pinenote-autosuspend-configuration>
  pinenote-autosuspend-configuration make-pinenote-autosuspend-configuration
  pinenote-autosuspend-configuration?
  ;; Seconds of no input on any /dev/input/event* before suspending.
  ;; 300 is a deliberate starting point, not a tuned value: long enough not
  ;; to fight a reader who pauses to think, short enough that a device left
  ;; on a table is asleep within minutes.
  (idle-seconds     pinenote-autosuspend-idle-seconds     (default 300))
  ;; RTC wake armed on every cycle.  Insurance: if button wake ever
  ;; regresses, the device still comes back instead of becoming a brick in
  ;; a bag.  Do not remove this to save power -- an RTC alarm costs
  ;; nothing and the failure it guards against is unrecoverable in the field.
  ;; The PERIOD is not free, though, and 900 -> 3600 on 2026-08-07 because
  ;; a backstop wake now re-suspends after a ~20 s settle instead of
  ;; burning a fresh idle period: nobody is present when the alarm fires,
  ;; so each wake is ~1.2 mAh of resume work and a wash nobody sees.  The
  ;; cost of the change is the worst-case wait for a device with regressed
  ;; button wake, 15 min -> 1 h.  Rationale and arithmetic:
  ;; doc/power-management.md, "The idle duty cycle".
  (backstop-seconds pinenote-autosuspend-backstop-seconds (default 3600))
  ;; Draw the sleep screen (current framebuffer + banner) before suspending.
  (overlay?         pinenote-autosuspend-overlay?         (default #t))
  ;; Suspend even while plugged in.  Off by default: on a charger there is
  ;; no power to save, and a device that darkens on your desk mid-use is
  ;; just friction.  Runtime override: suspend_while_charging=1.
  (suspend-while-charging? pinenote-autosuspend-suspend-while-charging?
                           (default #f))
  (config-file      pinenote-autosuspend-config-file
                    (default "/var/lib/pinenote/autosuspend.conf"))
  ;; The bundle's own luajit -- same interpreter reader-session runs, and
  ;; the only one on the image with the ffi the daemon needs.
  (luajit           pinenote-autosuspend-luajit
                    (default (file-append koreader-bin "/lib/koreader/luajit")))
  (script           pinenote-autosuspend-script
                    (default (local-file "../tools/power/autosuspend.lua"))))

(define (pinenote-autosuspend-shepherd-service config)
  (let ((charging (pinenote-autosuspend-suspend-while-charging? config))
        (idle     (pinenote-autosuspend-idle-seconds config))
        (backstop (pinenote-autosuspend-backstop-seconds config))
        (overlay  (pinenote-autosuspend-overlay? config))
        (conf     (pinenote-autosuspend-config-file config))
        (luajit   (pinenote-autosuspend-luajit config))
        (script   (pinenote-autosuspend-script config)))
    (list
     (shepherd-service
      (provision '(pinenote-autosuspend))
      ;; Needs input nodes and the reader it suspends around.  Ordering
      ;; after reader-session also means a boot that fails to reach the
      ;; reader does not start suspending itself.
      (requirement '(udev reader-session))
      (documentation "Suspend to deep after an idle period; wake on button.")
      (start
       #~(make-forkexec-constructor
          (list #$luajit #$script
                "--idle" #$(number->string idle)
                "--backstop" #$(number->string backstop)
                "--config" #$conf
                #$@(if overlay '() '("--no-overlay"))
                #$@(if charging '("--suspend-while-charging") '()))
          #:log-file "/var/log/pinenote-autosuspend.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;; The daemon degrades gracefully when the runtime config is absent, but
;; the directory must exist for anyone to WRITE one -- on a fresh image
;; /var/lib/pinenote does not exist, so the documented runtime tunables
;; were unusable without a manual mkdir (found 2026-08-03).
(define (pinenote-autosuspend-activation config)
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p "/var/lib/pinenote")))

(define pinenote-autosuspend-service-type
  (service-type
   (name 'pinenote-autosuspend)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-autosuspend-shepherd-service)
          (service-extension activation-service-type
                             pinenote-autosuspend-activation)))
   (default-value (pinenote-autosuspend-configuration))
   (description "Auto-suspend the PineNote to deep after user inactivity.")))
