(define-module (pinenote services dmc)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:export (pinenote-dmc-service-type))

;; Static-low DDR: load wilkbook_dmc (the DRAM-SIP devfreq driver, built
;; =m precisely so THIS service controls when the one runtime switch
;; happens) with the display quiesced, then verify the drop took.
;;
;; Why the quiescing: a DDR rate switch stalls every AXI master, and a
;; stall landing inside an active EBC frame risks the 25 ms
;; EBC_FRAME_TIMEOUT and terminal display poison until reboot
;; (pinenote/tools/ddr-dvfs-test/protocol.md par.4).  The probe-time drop
;; to 324 MHz — the module's only runtime switch under the powersave
;; governor — therefore runs with fbcon unbound (no cursor-blink damage
;; stream; the 2026-07-30 finding measured 63 Hz of EBC work from a bound
;; fbcon) and fb0 blanked, and only after the EBC interrupt count holds
;; still, the same EBC-idle precondition the barrier campaign uses.
;;
;; Failure policy: on ANY failure, log loudly, still restore the console,
;; and EXIT SUCCESS — a reader at 1056 MHz beats no reader, and the boot
;; acceptance check (doc: dmc acceptance.md) catches the miss.  Cost of a
;; miss is ~25 mA (measured quiesced delta, 324 vs 1056 —
;; doc/artifacts/pinenote-awake-levers-20260806 addendum).
;;
;; Suspend needs nothing from us: bl31 preserves a non-boot rate across
;; suspend/resume (proven twice, addendum 2), so there are no suspend
;; hooks anywhere in this stack, deliberately.

(define %dmc-module "wilkbook_dmc")

;; Without this, udev's coldplug (80-drivers.rules, kmod builtin, which
;; applies blacklists) would modalias-load wilkbook_dmc as soon as the
;; dmc platform device appears — long before this service quiesces the
;; console — and the probe-time switch would race the boot text's EBC
;; scans.  `blacklist` only suppresses alias-based loading; the explicit
;; modprobe-by-name below still works.
(define %dmc-modprobe-options
  "blacklist wilkbook_dmc\n")

;; the lowest entry of the firmware's own table (324/528/780/1056 MHz),
;; which the powersave governor pins at probe
(define %dmc-target-rate "324000000")

(define (pinenote-dmc-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-dmc))
    (requirement '(udev))
    (documentation "Drop DDR to the lowest firmware rate (fbcon quiesced).")
    (one-shot? #t)
    (start
     #~(lambda _
         (use-modules (ice-9 rdelim))

         (define %fbcon-bind "/sys/class/vtconsole/vtcon1/bind")
         (define %fb-blank "/sys/class/graphics/fb0/blank")
         (define %clk-summary "/sys/kernel/debug/clk/clk_summary")
         (define %devfreq "/sys/class/devfreq/memory-controller")
         ;; Experiment selector on the PERSISTENT data partition, which
         ;; is os1's /home -- so a slot that cannot be reached from the
         ;; U-Boot menu can still have its next boot configured from the
         ;; rescue slot, and a reflash does not erase the choice.
         ;;   mode=normal    quiesce, switch, verify (the product path)
         ;;   mode=noswitch  quiesce and restore, but never load the
         ;;                  module -- isolates the blank/unblank cycle
         ;;                  from the DDR switch
         ;;   mode=off       do nothing at all -- the baseline that says
         ;;                  whether this service is implicated in the
         ;;                  boot-time display corruption at all
         (define %mode-file "/data/wilkbook/dmc.conf")

         (define (log message . arguments)
           (apply format #t
                  (string-append "pinenote-dmc: " message "~%")
                  arguments)
           (force-output))

         (define (write-sysfs path value)
           ;; #t only if the write really happened — quiesce/restore and
           ;; the poll all want the distinction
           (if (file-exists? path)
               (catch #t
                 (lambda ()
                   (call-with-output-file path
                     (lambda (port) (display value port)))
                   #t)
                 (lambda (key . _)
                   (log "warning: could not write ~s to ~a: ~a"
                        value path key)
                   #f))
               (begin
                 (log "warning: ~a does not exist" path)
                 #f)))

         (define (ebc-irq-count)
           ;; total interrupt count of the EBC's line, from
           ;; /proc/interrupts; #f when no such line (QEMU virt).  The
           ;; driver requests its IRQ as dev_name(dev), so the line reads
           ;; "fdec0000.ebc" (ebc@fdec0000 in rk356x-base.dtsi).
           (catch #t
             (lambda ()
               (call-with-input-file "/proc/interrupts"
                 (lambda (port)
                   (let loop ()
                     (let ((line (read-line port)))
                       (cond
                        ((eof-object? line) #f)
                        ((string-contains line "fdec0000.ebc")
                         (apply +
                                (map string->number
                                     (filter (lambda (tok)
                                               (string->number tok))
                                             (string-tokenize line)))))
                        (else (loop))))))))
             (lambda _ #f)))

         (define (wait-ebc-idle attempts)
           ;; the campaign's EBC-idle precondition, bounded -- but the
           ;; IRQ pattern is asymmetric (the standing lesson: a zero IRQ
           ;; delta means nothing on its own).  A partial ticks once per
           ;; frame; a GLOBAL emits its single IRQ only at COMPLETION,
           ;; so one unchanged pair reads exactly like idle while the
           ;; glass is mid-drive (the 2026-08-06 v3-boot review finding,
           ;; ported here from autosuspend.lua).  Idle requires the
           ;; count unchanged across 5 consecutive 500 ms samples --
           ;; 2.5 s, longer than any measured global -- so a mid-flight
           ;; global is outwaited, not mistaken for quiet.  On timeout
           ;; we proceed anyway (fail-open) but say so.
           (let loop ((quiet 0)
                      (before (ebc-irq-count))
                      (attempts attempts))
             (cond
              ((not before) #t)           ; no EBC (virt): nothing to wait for
              ((>= quiet 5) #t)
              ((zero? attempts)
               (log "EBC did not go idle in time; proceeding")
               #t)
              (else
               (usleep 500000)
               (let ((after (ebc-irq-count)))
                 (if (equal? before after)
                     (loop (+ quiet 1) before (- attempts 1))
                     (loop 0 after (- attempts 1))))))))

         (define (devfreq-rate)
           ;; The driver's own view, and the ONLY one that needs no
           ;; debugfs.  The 2026-08-06 v3 boot reported "DDR did not
           ;; reach 324000000" while the module was in fact loaded and
           ;; its devfreq device registered -- pinenote-usb-acm-gadget,
           ;; which mounts debugfs, does not start until AFTER this
           ;; service runs, so clk_summary was very likely absent and the
           ;; failure report was about the INSTRUMENT, not the switch.
           (catch #t
             (lambda ()
               (let ((path (string-append %devfreq "/cur_freq")))
                 (and (file-exists? path)
                      (call-with-input-file path
                        (lambda (port)
                          (let ((v (read port)))
                            (and (number? v) v)))))))
             (lambda _ #f)))

         (define (clk-summary-rate)
           ;; bl31's view, kept as the cross-check when debugfs happens
           ;; to be mounted.  Row: name enable prepare protect rate ...
           (catch #t
             (lambda ()
               (and (file-exists? %clk-summary)
                    (call-with-input-file %clk-summary
                      (lambda (port)
                        (let loop ()
                          (let ((line (read-line port)))
                            (cond
                             ((eof-object? line) #f)
                             ((string-contains line "clk_scmi_ddr")
                              (let ((tokens (string-tokenize line)))
                                (and (> (length tokens) 4)
                                     (string->number (list-ref tokens 4)))))
                             (else (loop)))))))))
             (lambda _ #f)))

         (define (ddr-at-target?)
           (let ((rate (devfreq-rate)))
             (if rate
                 (= rate (string->number #$%dmc-target-rate))
                 (equal? (clk-summary-rate)
                         (string->number #$%dmc-target-rate)))))

         ;; One line per checkpoint, carrying the three numbers that
         ;; discriminate every hypothesis about this window: wall time,
         ;; cumulative EBC interrupts (is the panel driving?), and the
         ;; rate from both sources (did the switch land, and when?).
         (define (checkpoint label)
           (log "~a: irq=~a devfreq=~a clk=~a"
                label
                (or (ebc-irq-count) 'none)
                (or (devfreq-rate) 'absent)
                (or (clk-summary-rate) 'absent)))

         (define (poll-ddr attempts)
           ;; When the probe runs inside modprobe the switch lands in
           ;; ~107 ms + the driver's 100 ms MCU wait.  But probe can
           ;; DEFER (SCMI/OPP dependency not ready) and complete on a
           ;; later re-probe -- on the 2026-08-06 v3 boot the rate
           ;; arrived after a 3 s poll had already given up, the console
           ;; was back, and the unguarded switch scribbled the glass
           ;; mid-console-paint.  So the poll is long (~15 s) and the
           ;; quiesce is held for all of it.
           (cond
            ((ddr-at-target?) #t)
            ((zero? attempts) #f)
            (else
             (usleep 100000)
             (poll-ddr (- attempts 1)))))

         (define mode
           ;; first word of the first mode= line; anything unrecognised
           ;; means the product path, because a typo in a diagnostic file
           ;; must never silently disable the power saving
           (catch #t
             (lambda ()
               (if (file-exists? %mode-file)
                   (call-with-input-file %mode-file
                     (lambda (port)
                       (let loop ()
                         (let ((line (read-line port)))
                           (cond
                            ((eof-object? line) "normal")
                            ((string-prefix? "mode=" line)
                             (let ((v (string-trim-both
                                       (substring line 5))))
                               (if (member v '("normal" "noswitch" "off"))
                                   v
                                   "normal")))
                            (else (loop)))))))
                   "normal"))
             (lambda _ "normal")))

         (log "mode=~a (selector ~a)" mode %mode-file)
         (checkpoint "entry")

         (define (load-and-verify)
           (catch #t
             (lambda ()
               (let ((status (system* #$(file-append kmod "/bin/modprobe")
                                      ;; -d: only the profile under
                                      ;; /run/booted-system/kernel carries
                                      ;; modules.dep (usb-gadget.scm,
                                      ;; lesson of 2026-06-11)
                                      "-d" "/run/booted-system/kernel"
                                      #$%dmc-module)))
                 (if (zero? status)
                     (begin
                       ;; only the clk_summary cross-check needs this;
                       ;; devfreq works without it, which is why the
                       ;; verdict no longer hinges on the mount
                       (unless (file-exists? %clk-summary)
                         (when (file-exists? "/sys/kernel/debug")
                           (system* #$(file-append util-linux "/bin/mount")
                                    "-t" "debugfs" "none"
                                    "/sys/kernel/debug")))
                       (if (poll-ddr 150)
                           (begin
                             (checkpoint "switched")
                             (log "DDR at ~a Hz (static low)"
                                  #$%dmc-target-rate))
                           (begin
                             ;; The switch happens inside the guarded
                             ;; window or NOT AT ALL: a still-deferred
                             ;; probe would otherwise complete after the
                             ;; console is back and fire an unguarded
                             ;; switch into live EBC scans.  remove()
                             ;; restores the boot rate, and any switch it
                             ;; makes runs inside the still-held quiesce.
                             ;; This now fires only when BOTH rate
                             ;; sources disagree with the target for 15 s
                             ;; -- the old debugfs-only check cried
                             ;; failure on a switch that had landed.
                             (system* #$(file-append kmod "/bin/modprobe")
                                      "-r" "-d" "/run/booted-system/kernel"
                                      #$%dmc-module)
                             (checkpoint "removed")
                             (log "FAILED: DDR did not reach ~a Hz within ~~15 s; \
module removed so no unguarded switch can follow; reader continues at the \
boot rate (costs ~~25 mA); see dmesg for wilkbook_dmc"
                                  #$%dmc-target-rate))))
                     (log "FAILED: modprobe ~a exited with ~a; \
reader continues at the boot rate (costs ~~25 mA)"
                          #$%dmc-module status))))
             (lambda (key . args)
               (log "FAILED: ~a ~s; reader continues at the boot rate"
                    key args))))

         (define (run-quiesced)
           ;; no EBC work may overlap the switch
           (write-sysfs %fbcon-bind "0")
           (write-sysfs %fb-blank "1")
           (checkpoint "blanked")
           (wait-ebc-idle 40)
           (checkpoint "ebc-idle")
           (if (string=? mode "noswitch")
               (log "mode=noswitch: quiesced and restoring WITHOUT loading ~a"
                    #$%dmc-module)
               (load-and-verify))
           ;; ALWAYS restore the console, reverse order
           (write-sysfs %fb-blank "0")
           (write-sysfs %fbcon-bind "1")
           (checkpoint "console-restored"))

         (if (string=? mode "off")
             (log "mode=off: leaving the display and the DDR rate alone")
             (run-quiesced))

         ;; one-shot success regardless: never block the reader on a
         ;; power optimization
         #t))
    (stop #~(const #t)))))

(define (pinenote-dmc-etc-files _config)
  (list `("modprobe.d/wilkbook_dmc.conf"
          ,(plain-file "wilkbook_dmc.conf" %dmc-modprobe-options))))

(define pinenote-dmc-service-type
  (service-type
   (name 'pinenote-dmc)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-dmc-shepherd-service)
          ;; keep udev coldplug's hands off the module (see
          ;; %dmc-modprobe-options)
          (service-extension etc-service-type
                             pinenote-dmc-etc-files)))
   (default-value #f)
   (description "Load the wilkbook DMC driver with fbcon quiesced, pinning DDR at the lowest firmware rate.")))
