(define-module (pinenote services frontlight)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (pinenote-frontlight-service-type
            pinenote-frontlight-configuration
            pinenote-frontlight-configuration?
            pinenote-frontlight-boot-percent))

;; Light the panel early in boot, before anything paints on it.
;;
;; Two reasons, one product and one diagnostic:
;;
;;   * The panel is REFLECTIVE.  Between the kernel taking over the
;;     display and KOReader's powerd setting a level (~14 s on the
;;     2026-08-06 boot), a reader in a dim room shows nothing at all --
;;     the boot appears to hang when it is merely unlit.
;;   * Every camera observation of the boot is blind without it.  The
;;     2026-08-06 bench capture watched a full boot through the optics
;;     rig and saw the panel go dark at the console phase -- exactly the
;;     window where the display corruption under investigation appears
;;     (doc/status.md, 2026-08-06 night).  The frontlight IS the
;;     illuminant for the optics instrument (pinenote/tools/optics), so
;;     no external lamp can substitute.
;;
;; KOReader owns the level once it starts; this only sets the floor for
;; the window before that.  Percent, not raw counts: max_brightness is a
;; per-device property (255 on this panel) and hard-coding counts would
;; silently mean something different on another unit.

(define %backlight-root "/sys/class/backlight")

(define-record-type* <pinenote-frontlight-configuration>
  pinenote-frontlight-configuration make-pinenote-frontlight-configuration
  pinenote-frontlight-configuration?
  ;; 60% matches the optics recording standard (tools/optics/RECORDING.md:
  ;; bright enough for a camera, below the level where white clips).
  (boot-percent pinenote-frontlight-boot-percent (default 60)))

(define (pinenote-frontlight-shepherd-service config)
  (let ((percent (pinenote-frontlight-boot-percent config)))
    (list
     (shepherd-service
      (provision '(pinenote-frontlight))
      ;; The backlight class appears with the display stack, which the
      ;; initrd raw-loads; udev is enough to have the nodes populated.
      (requirement '(udev))
      (documentation "Light the e-ink frontlight early, before anything paints.")
      (one-shot? #t)
      (start
       #~(lambda _
           ;; Explicit module reference, NOT use-modules: a shepherd
           ;; service file is compiled, and a `use-modules` in a lambda
           ;; body does not import into the environment the compiled
           ;; toplevel references resolve against.  This service failed
           ;; its first boot (2026-08-07) with "Unbound variable:
           ;; scandir" for exactly that reason.
           (define scandir* (@ (ice-9 ftw) scandir))

           (define (log message . arguments)
             (apply format #t
                    (string-append "pinenote-frontlight: " message "~%")
                    arguments)
             (force-output))

           (define (read-first-line path)
             (catch #t
               (lambda ()
                 (call-with-input-file path
                   (lambda (port) (read port))))
               (lambda _ #f)))

           (define (set-one name)
             ;; Scale to THIS device's max_brightness; a write above it
             ;; is rejected outright (EINVAL, observed 2026-08-06 writing
             ;; 512 to a 255-max panel), so a hard-coded count is a
             ;; silent no-op waiting to happen.
             (let* ((dir (string-append #$%backlight-root "/" name))
                    (ceiling (read-first-line
                              (string-append dir "/max_brightness"))))
               (if (and (number? ceiling) (> ceiling 0))
                   (let ((value (max 1 (quotient (* ceiling #$percent) 100))))
                     (catch #t
                       (lambda ()
                         (call-with-output-file (string-append dir "/brightness")
                           (lambda (port) (display value port)))
                         (log "~a = ~a/~a (~a%)" name value ceiling #$percent)
                         #t)
                       (lambda (key . _)
                         (log "warning: could not set ~a: ~a" name key)
                         #f)))
                   (begin
                     (log "warning: ~a has no usable max_brightness" name)
                     #f))))

           (if (file-exists? #$%backlight-root)
               (let ((names (scandir* #$%backlight-root
                                     (lambda (n)
                                       (not (member n '("." "..")))))))
                 (if (null? (or names '()))
                     (log "no backlight devices -- panel stays unlit")
                     (for-each set-one names)))
               (log "no ~a -- panel stays unlit" #$%backlight-root))
           ;; Never block the boot on the light: an unlit reader still
           ;; reads in daylight, and this is also the diagnostic path.
           #t))
      (stop #~(const #t))))))

(define pinenote-frontlight-service-type
  (service-type
   (name 'pinenote-frontlight)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-frontlight-shepherd-service)))
   (default-value (pinenote-frontlight-configuration))
   (description "Set the e-ink frontlight early in boot, before the reader starts.")))
