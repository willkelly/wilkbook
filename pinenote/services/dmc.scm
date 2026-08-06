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
           ;; the campaign's EBC-idle precondition, bounded: two samples
           ;; 500 ms apart with an unchanged interrupt count.  An
           ;; in-flight GC16 pass is ~46 frames ~ 1 s, so the 5 s bound
           ;; outlasts any single refresh; on timeout we proceed anyway
           ;; (fail-open) but say so.
           (let ((before (ebc-irq-count)))
             (usleep 500000)
             (let ((after (ebc-irq-count)))
               (cond
                ((not before) #t)          ; no EBC (virt): nothing to wait for
                ((equal? before after) #t)
                ((zero? attempts)
                 (log "EBC did not go idle in time (irq ~a -> ~a); proceeding"
                      before after)
                 #t)
                (else (wait-ebc-idle (- attempts 1)))))))

         (define (ddr-at-target?)
           ;; clk_summary row: name enable prepare protect rate ...
           ;; the SCMI ddr clock is bl31's own view of the rate
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
                                     (string=? (list-ref tokens 4)
                                               #$%dmc-target-rate))))
                             (else (loop)))))))))
             (lambda _ #f)))

         (define (poll-ddr attempts)
           ;; the probe-time switch completes inside modprobe (~107 ms +
           ;; the driver's 100 ms MCU wait); ~3 s is belt and braces
           (cond
            ((ddr-at-target?) #t)
            ((zero? attempts) #f)
            (else
             (usleep 100000)
             (poll-ddr (- attempts 1)))))

         ;; ---- quiesce: no EBC work may overlap the switch ----
         (write-sysfs %fbcon-bind "0")
         (write-sysfs %fb-blank "1")
         (wait-ebc-idle 10)

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
                     ;; clk_summary lives in debugfs; the usb-gadget
                     ;; service usually mounts it first, but do not
                     ;; depend on ordering
                     (unless (file-exists? %clk-summary)
                       (when (file-exists? "/sys/kernel/debug")
                         (system* #$(file-append util-linux "/bin/mount")
                                  "-t" "debugfs" "none"
                                  "/sys/kernel/debug")))
                     (if (poll-ddr 30)
                         (log "DDR at ~a Hz (static low)" #$%dmc-target-rate)
                         (log "FAILED: DDR did not reach ~a Hz within ~~3 s; \
reader continues at the boot rate (costs ~~25 mA); see dmesg for wilkbook_dmc"
                              #$%dmc-target-rate)))
                   (log "FAILED: modprobe ~a exited with ~a; \
reader continues at the boot rate (costs ~~25 mA)"
                        #$%dmc-module status))))
           (lambda (key . args)
             (log "FAILED: ~a ~s; reader continues at the boot rate"
                  key args)))

         ;; ---- ALWAYS restore the console, reverse order ----
         (write-sysfs %fb-blank "0")
         (write-sysfs %fbcon-bind "1")

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
