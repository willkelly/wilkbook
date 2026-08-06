(define-module (pinenote services ddr-boost)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (pinenote packages koreader)
  #:export (pinenote-ddr-boost-service-type
            pinenote-ddr-boost-configuration))

;; Input-driven DDR boost: policy layer over the wilkbook_dmc devfreq
;; driver.  The kernel provides the capability (SIP rate switching, a
;; powersave 324 MHz floor, min_freq as the universal hint interface);
;; this daemon provides the policy: full bandwidth while the user
;; interacts, floor after a short quiet period.  Any application
;; can override by holding min_freq itself -- the daemon only ever
;; raises it on input and lowers it on idle, so an app's own hold wins
;; by writing after (last-writer semantics on min_freq are acceptable
;; here; revisit with PM QoS from the app side if that ever bites).
;;
;; Measured basis (doc/artifacts/pinenote-awake-levers-20260806/):
;; 324 vs 1056 MHz is ~24.8 mA; a rate switch is ~107 ms wall with a
;; sub-ms DRAM stall, safe against the EBC's 25 ms frame budget.
;;
;; Opt-in (2026-08-06): the daemon defaults to disabled -- without
;; enabled=1 in its runtime conf it only watches for a conf flip and
;; never touches min_freq.  /var/lib is wiped by a reflash, so a
;; conf-based pause cannot survive a redeploy: the no-conf state must
;; be the validated configuration (the static-324 floor) until the
;; wake-boundary behavior is proven on glass.

(define-record-type* <pinenote-ddr-boost-configuration>
  pinenote-ddr-boost-configuration make-pinenote-ddr-boost-configuration
  pinenote-ddr-boost-configuration?
  ;; Seconds at the floor after the last input event.  10 s covers the
  ;; long tail of a rotation re-render without holding boost through a
  ;; reading pause.
  (hold-seconds pinenote-ddr-boost-hold-seconds (default 10))
  (config-file  pinenote-ddr-boost-config-file
                (default "/var/lib/pinenote/ddr-boost.conf"))
  (luajit       pinenote-ddr-boost-luajit
                (default (file-append koreader-bin "/lib/koreader/luajit")))
  (script       pinenote-ddr-boost-script
                (default (local-file "../tools/power/ddr-boost.lua"))))

(define (pinenote-ddr-boost-shepherd-service config)
  (list
   (shepherd-service
    (provision '(pinenote-ddr-boost))
    ;; Needs input nodes and the dmc driver's devfreq node.  The daemon
    ;; itself retries and exits 0 if the node never appears (fail-open:
    ;; the powersave floor stands and a slower reader beats no reader),
    ;; so a missing pinenote-dmc must not wedge boot.
    (requirement '(udev pinenote-dmc))
    (documentation "Raise the DDR floor while the user is interacting.")
    (start
     #~(make-forkexec-constructor
        (list #$(pinenote-ddr-boost-luajit config)
              #$(pinenote-ddr-boost-script config)
              "--hold" #$(number->string
                          (pinenote-ddr-boost-hold-seconds config))
              "--config" #$(pinenote-ddr-boost-config-file config))
        #:log-file "/var/log/pinenote-ddr-boost.log"))
    (stop #~(make-kill-destructor))
    (respawn? #t))))

(define pinenote-ddr-boost-service-type
  (service-type
   (name 'pinenote-ddr-boost)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-ddr-boost-shepherd-service)))
   (default-value (pinenote-ddr-boost-configuration))
   (description "Input-driven DDR frequency boost over wilkbook_dmc.")))
