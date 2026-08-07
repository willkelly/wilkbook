(define-module (pinenote services dmc)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages linux)
  #:use-module (gnu services base)
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
;; fbcon), and only after the EBC interrupt count holds still for longer
;; than a global refresh can drive — the EBC-idle precondition the
;; barrier campaign uses, at the strength protocol.md actually asks for.
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

;; Belt half of a belt-and-braces pair.  This alone does NOT stop the
;; coldplug -- measured 2026-08-07, the module loaded and switched the
;; DDR at 10.60 s with this file installed -- because eudev's kmod
;; builtin loads by modalias without applying modprobe.d blacklists.
;; The braces are %dmc-udev-rule below.  Kept because it costs nothing
;; and does bind any modprobe path that DOES honour blacklists; the
;; explicit modprobe-by-name this service runs is unaffected either way.
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
         ;; Resolve these EXPLICITLY, never via use-modules.  A
         ;; shepherd service file is COMPILED, and a `use-modules` in a
         ;; lambda body does not import into the environment the compiled
         ;; toplevel references resolve against -- every call throws
         ;; Unbound variable, and every one of them here sits inside a
         ;; `catch #t` that turns the throw into a plausible-looking #f.
         ;; Consequence, live on the 2026-08-07 boot: wait-ebc-idle never
         ;; waited (a #f count reads as "no EBC, nothing to wait for"),
         ;; the mode selector always fell back to "normal", and every
         ;; checkpoint field but devfreq -- the one function using `read`
         ;; rather than `read-line` -- logged "none"/"absent".
         (define read-line* (@ (ice-9 rdelim) read-line))
         (define scandir* (@ (ice-9 ftw) scandir))

         (define %fbcon-bind "/sys/class/vtconsole/vtcon1/bind")
         (define %clk-summary "/sys/kernel/debug/clk/clk_summary")
         (define %devfreq "/sys/class/devfreq/memory-controller")
         ;; Experiment selector on the PERSISTENT data partition, which
         ;; is os1's /home -- so a slot that cannot be reached from the
         ;; U-Boot menu can still have its next boot configured from the
         ;; rescue slot, and a reflash does not erase the choice.
         ;;   mode=normal    quiesce, switch, verify (the product path)
         ;;   mode=noswitch  unbind fbcon, wait, rebind -- everything
         ;;                  except loading the module.  Isolates this
         ;;                  service's console handling from the DDR
         ;;                  switch: same window, same repaint, rate left
         ;;                  at the boot value
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
           ;; "fdec0000.ebc" (ebc@fdec0000 in rk356x-base.dtsi).  The sum
           ;; also picks up the GIC hwirq printed mid-line; that is a
           ;; CONSTANT per boot, so every delta and equality test here is
           ;; unaffected -- but the absolute number is not an interrupt
           ;; count and should not be quoted as one.
           (catch #t
             (lambda ()
               (call-with-input-file "/proc/interrupts"
                 (lambda (port)
                   (let loop ()
                     (let ((line (read-line* port)))
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
           ;;
           ;; 2.5 s is not a guess.  The supervised campaign's own
           ;; precondition is an EBC IRQ delta of 0 "over several
           ;; seconds" (ddr-dvfs-test/protocol.md, "The EBC question"),
           ;; and this service shipped it as a single 500 ms pair --
           ;; weaker than the protocol it was derived from, and exactly
           ;; the gap a mid-flight global fits through.  The same
           ;; document predicts the symptom when a stall does land
           ;; inside a frame: "wrong voltages on some pixel region",
           ;; a ghosting artifact, with no timeout of any kind.
           (let loop ((quiet 0)
                      (before (ebc-irq-count))
                      (attempts attempts))
             (cond
              ((not before)
               ;; No readable count.  Genuinely absent on QEMU virt --
               ;; but it is ALSO what a broken reader looks like, and
               ;; that silence hid a dead gate for a week (2026-08-07).
               ;; Say so rather than reporting quiet.
               (log "WARNING: EBC interrupt count unreadable -- \
proceeding WITHOUT an idle gate")
               #t)
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
           ;; its devfreq device registered.  debugfs is mounted by
           ;; Guix's own %debug-file-system (a member of
           ;; %base-file-systems, which systems/base.scm takes verbatim),
           ;; and shepherd was serialised through this one-shot -- the
           ;; file-system-* services appear in the log only after it
           ;; returns -- so clk_summary was absent and the failure report
           ;; was about the INSTRUMENT, not the switch.
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
                          (let ((line (read-line* port)))
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
         ;; Count of rate transitions over the devfreq device's life.
         ;; This is the number that settles "did anything switch the DDR
         ;; when we were not looking": it must read 1 immediately after
         ;; modprobe and STILL 1 at every later checkpoint.  A 2 anywhere
         ;; downstream is a switch this service did not order.
         (define (devfreq-transitions)
           (catch #t
             (lambda ()
               (let ((path (string-append %devfreq "/trans_stat")))
                 (and (file-exists? path)
                      (call-with-input-file path
                        (lambda (port)
                          (let loop ()
                            (let ((line (read-line* port)))
                              (cond
                               ((eof-object? line) #f)
                               ((string-contains line "Total transition")
                                (let ((tokens (filter string->number
                                                      (string-tokenize line))))
                                  (and (pair? tokens)
                                       (string->number (car (reverse tokens))))))
                               (else (loop))))))))))
             (lambda _ #f)))

         ;; State of the EBC refresh kthread: the DIRECT answer to "is
         ;; the panel driving right now", where an IRQ delta is only an
         ;; inference (and a famously misleading one -- a global holds
         ;; the count still for its whole drive).  D = uninterruptible,
         ;; i.e. inside a refresh; I/S = parked or waiting.  The thread
         ;; is created as "ebc-refresh/%s" with dev_name appended, so
         ;; comm truncates to "ebc-refresh/fde" at 15 chars and matching
         ;; the full name finds nothing -- match the prefix.  The state
         ;; is the token after the LAST ')' in /proc/N/stat, because comm
         ;; is parenthesised and may itself contain punctuation.
         (define (ebc-thread-state)
           (catch #t
             (lambda ()
               (let loop ((entries (scandir* "/proc")))
                 (cond
                  ((or (not entries) (null? entries)) #f)
                  ((not (string->number (car entries)))
                   (loop (cdr entries)))
                  (else
                   (let* ((pid (car entries))
                          (comm-path (string-append "/proc/" pid "/comm"))
                          (comm (and (file-exists? comm-path)
                                     (catch #t
                                       (lambda ()
                                         (call-with-input-file comm-path
                                           read-line*))
                                       (lambda _ #f)))))
                     (if (and (string? comm)
                              (string-prefix? "ebc-refresh" comm))
                         (catch #t
                           (lambda ()
                             (let* ((stat (call-with-input-file
                                              (string-append "/proc/" pid "/stat")
                                            read-line*))
                                    (tail (substring stat
                                                     (1+ (string-rindex stat #\))))))
                               (car (string-tokenize tail))))
                           (lambda _ #f))
                         (loop (cdr entries))))))))
             (lambda _ #f)))

         (define (checkpoint label)
           (log "cp=~a irq=~a thr=~a devfreq=~a trans=~a clk=~a"
                label
                (or (ebc-irq-count) 'none)
                (or (ebc-thread-state) 'none)
                (or (devfreq-rate) 'absent)
                (or (devfreq-transitions) 'absent)
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
                         (let ((line (read-line* port)))
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
                           ;; Report and leave the module alone.  An
                           ;; earlier version rmmod'd here, on the theory
                           ;; that a deferred probe could still fire an
                           ;; unguarded switch later.  The driver refutes
                           ;; every step: the probe takes no clock,
                           ;; regulator or OPP phandle so it has no
                           ;; -EPROBE_DEFER path, it runs synchronously
                           ;; inside modprobe, and its one switch happens
                           ;; inside devfreq_add_device() -- which
                           ;; unregisters the device if the switch fails.
                           ;; A live devfreq node therefore IS a
                           ;; completed, firmware-verified switch, and
                           ;; unloading on a failed READ would discard a
                           ;; working module because the instrument
                           ;; broke.  That is what happened 2026-08-06.
                           (log "FAILED: DDR did not read back as ~a Hz within ~~15 s; \
module left loaded (a live devfreq node means the switch itself succeeded); \
see the checkpoint lines and dmesg for wilkbook_dmc"
                                #$%dmc-target-rate)))
                     (log "FAILED: modprobe ~a exited with ~a; \
reader continues at the boot rate (costs ~~25 mA)"
                          #$%dmc-module status))))
             (lambda (key . args)
               (log "FAILED: ~a ~s; reader continues at the boot rate"
                    key args))))

         (define (run-quiesced)
           ;; Unbinding fbcon is the WHOLE quiesce: it removes the damage
           ;; producer (63 Hz of EBC work from a bound fbcon, measured
           ;; 2026-07-30).  There is deliberately no fb0 blank here.  It
           ;; used to be, and it bought nothing: an fbdev DPMS blank sets
           ;; only active_changed, while every EBC hook
           ;; (crtc_atomic_check / _disable / _enable) is gated on
           ;; mode_changed -- so the worker is never parked and no
           ;; off-screen wash runs.  What the blank DOES do is commit a
           ;; damage-clip-less full-plane update at the exact moment this
           ;; service believes it is quiescing.
           (write-sysfs %fbcon-bind "0")
           (checkpoint "unbound")
           (wait-ebc-idle 40)
           (checkpoint "ebc-idle")
           (if (string=? mode "noswitch")
               (log "mode=noswitch: quiesced and restoring WITHOUT loading ~a"
                    #$%dmc-module)
               (load-and-verify))
           ;; ALWAYS restore the console as a rescue path -- but do not
           ;; walk away while it is still painting.  `bind 1` runs
           ;; redraw_screen over the whole visible console, and those
           ;; draws reach the panel IMMEDIATELY: defio_delay_ms governs
           ;; only the mmap path, not fbcon's damage, which goes straight
           ;; to schedule_work.  Leaving that burst in flight is how the
           ;; service hands a still-driving panel to reader-session,
           ;; whose GC16 boot wash then interleaves with it.
           (write-sysfs %fbcon-bind "1")
           (checkpoint "console-restored")
           (wait-ebc-idle 40)
           (checkpoint "restore-drained"))

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

;; The modprobe.d blacklist above is NOT sufficient, proven on glass
;; 2026-08-07: the module still coldplugged and switched the DDR at
;; kernel time 10.60 s, 865 ms BEFORE this service unbound fbcon at
;; 11.47 s -- i.e. the 100 ms all-master stall landed in live console
;; scans, which is the whole hazard the guarded window exists to
;; prevent.  eudev's kmod builtin loads by modalias without applying
;; modprobe.d blacklists, so the only thing that reliably stops the
;; coldplug is removing the modalias from the device before
;; 80-drivers.rules runs.  An explicit `modprobe wilkbook_dmc` by name
;; is unaffected, which is exactly what this service does inside the
;; window.
(define %dmc-udev-rule
  "SUBSYSTEM==\"platform\", KERNEL==\"memory-controller\", ENV{MODALIAS}=\"\"\n")

(define pinenote-dmc-service-type
  (service-type
   (name 'pinenote-dmc)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-dmc-shepherd-service)
          ;; keep udev coldplug's hands off the module -- BOTH of these
          ;; are needed; the modprobe.d blacklist alone demonstrably is
          ;; not (see %dmc-udev-rule)
          (service-extension etc-service-type
                             pinenote-dmc-etc-files)
          (service-extension udev-service-type
                             (const (list (udev-rule
                                           "60-wilkbook-dmc-noautoload.rules"
                                           %dmc-udev-rule))))))
   (default-value #f)
   (description "Load the wilkbook DMC driver with fbcon quiesced, pinning DDR at the lowest firmware rate.")))
