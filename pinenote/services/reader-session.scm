(define-module (pinenote services reader-session)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages fonts)
  #:use-module (pinenote packages koreader)
  #:export (pinenote-reader-session-service-type))

;; KOReader running natively on the framebuffer - no compositor, no SDL.
;; The koreader-bin package grafts a "pinenote" device target into the
;; bundle (fbdev output on /dev/fb0, pure-Lua evdev input, full-refresh
;; via the EBC driver's global-refresh ioctl), the same architecture
;; KOReader uses on Kobo hardware.  See doc/koreader-spike.md for why
;; the cage/SDL kiosk was abandoned: SDL3's Wayland backend cannot
;; present without GL/Vulkan, neither of which exists on the device.
;;
;; fbcon is unbound before launch: with console=tty0 on the cmdline,
;; every kernel message would otherwise redraw the text console over
;; KOReader's framebuffer content (first-light finding, 2026-07-05).
;; It is re-bound on stop so the console comes back as a rescue path.
;;
;; v1 runs as root; unprivileged hardening is follow-up work.

(define %fbcon-bind "/sys/class/vtconsole/vtcon1/bind")

(define (pinenote-reader-session-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(reader-session))
    ;; the EBC module is loaded from the initrd, but the waveform
    ;; install and param application order ahead of anything that
    ;; would light the panel
    (requirement '(udev user-processes
                   pinenote-waveform pinenote-ebc-params))
    (documentation "KOReader running natively on the e-ink framebuffer.")
    (respawn? #t)
    (start
     #~(lambda args
         ;; don't race the fb node on a slow module load; respawn
         ;; still covers the pathological case
         (let loop ((tries 0))
           (unless (or (file-exists? "/dev/fb0")
                       (>= tries 50))
             (usleep 200000)
             (loop (+ tries 1))))
         ;; keep fbcon off the panel while the reader owns it
         (when (file-exists? #$%fbcon-bind)
           (call-with-output-file #$%fbcon-bind
             (lambda (port) (display "0" port))))
         ;; when local fonts are staged in the image, seed the font
         ;; defaults once (never overwrite on-device choices).  Mirrors
         ;; wilkhome's fontconfig aliases: serif=Equity, sans=Concourse,
         ;; mono=Triplicate Code; crengine's built-in fallback chain
         ;; (Noto Serif/Sans, CJK, FreeSans/Serif) stays in effect below
         ;; these.
         #$@(if pinenote-local-fonts
                #~((let ((settings "/root/.config/koreader/settings.reader.lua"))
                     (unless (file-exists? settings)
                       (for-each (lambda (dir)
                                   (unless (file-exists? dir)
                                     (mkdir dir #o700)))
                                 '("/root/.config" "/root/.config/koreader"))
                       (call-with-output-file settings
                         (lambda (port)
                           (display "\
-- seeded by wilkbook reader-session; KOReader rewrites this file
return {
    [\"cre_font\"] = \"Equity A\",
    [\"monospace_font\"] = \"Triplicate A Code\",
    [\"cre_font_family_fonts\"] = {
        [\"serif\"] = \"Equity A\",
        [\"sans-serif\"] = \"Concourse 4\",
        [\"monospace\"] = \"Triplicate A Code\",
    },
}
" port))))))
                #~())
         (apply
          (make-forkexec-constructor
           ;; reader.lua's own shebang is #!./luajit, so run the
           ;; bundled luajit directly from the bundle directory.
           (list #$(file-append koreader-bin "/lib/koreader/luajit")
                 "reader.lua")
           #:directory #$(file-append koreader-bin "/lib/koreader")
           #:environment-variables
           ;; KO_HOME is load-bearing: without it KOReader treats its
           ;; own directory (the read-only store) as the data dir and
           ;; dies in cache init before painting anything - the panel
           ;; shows only framebuffer_linux's white init fill, on a
           ;; respawn loop (found on the 2026-07-05 boot of the first
           ;; native-reader image; reproduced offline in 30 s).
           (list "HOME=/root"
                 "KO_HOME=/root/.config/koreader"
                 "PATH=/run/current-system/profile/bin"
                 "LC_ALL=en_US.UTF-8"
                 ;; KOReader's supported external-font hook; only set
                 ;; when fonts are actually staged in this image
                 #$@(if pinenote-local-fonts
                        #~("EXT_FONT_DIR=/run/current-system/profile/share/fonts/local")
                        #~()))
           #:log-file "/var/log/reader-session.log")
          args)))
    (stop
     #~(lambda (pid . args)
         (let ((stopped ((make-kill-destructor) pid)))
           ;; restore the text console as a rescue path
           (when (file-exists? #$%fbcon-bind)
             (call-with-output-file #$%fbcon-bind
               (lambda (port) (display "1" port))))
           stopped))))))

(define pinenote-reader-session-service-type
  (service-type
   (name 'pinenote-reader-session)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-reader-session-shepherd-service)))
   (default-value #f)
   (description "Run KOReader natively on the PineNote framebuffer.")))
