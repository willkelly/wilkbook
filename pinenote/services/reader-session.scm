(define-module (pinenote services reader-session)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (pinenote packages kiosk)
  #:use-module (pinenote packages koreader)
  #:export (pinenote-reader-session-service-type))

;; A cage (wlroots) Wayland kiosk running KOReader as its sole client,
;; on the EBC DRM driver with software rendering (WLR_RENDERER=pixman).
;; KOReader's bundled SDL3 only has a wayland video backend, so the
;; compositor is not optional - see doc/koreader-spike.md.
;;
;; v1 deliberately runs as root with libseat's builtin backend: no seatd
;; service, no seat-group plumbing, fewest moving parts for first light.
;; Hardening (seatd + the reader user + logind-style idle) is follow-up
;; work once the kiosk is hardware-proven.

(define (pinenote-reader-session-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(reader-session))
    ;; the EBC module is loaded from the initrd, but the waveform
    ;; install and param application order ahead of anything that
    ;; would light the panel
    (requirement '(udev user-processes
                   pinenote-waveform pinenote-ebc-params))
    (documentation "cage Wayland kiosk running KOReader on the e-ink panel.")
    (respawn? #t)
    (start
     #~(lambda args
         ;; runtime dir for the compositor and its client
         (for-each (lambda (dir)
                     (unless (file-exists? dir)
                       (mkdir dir #o700)))
                   '("/run/user" "/run/user/0"))
         ;; don't race the DRM node on a slow module load; respawn
         ;; still covers the pathological case
         (let loop ((tries 0))
           (unless (or (file-exists? "/dev/dri/card0")
                       (>= tries 50))
             (usleep 200000)
             (loop (+ tries 1))))
         (apply
          (make-forkexec-constructor
           (list #$(file-append cage-pixman "/bin/cage") "--"
                 #$(file-append koreader-bin "/bin/koreader"))
           #:environment-variables
           ;; PATH: koreader.sh is a shell script (realpath, dirname);
           ;; LIBSEAT_BACKEND=builtin: root session without seatd;
           ;; pixman: software rendering on the EBC's dumb buffers
           (list "HOME=/root"
                 "PATH=/run/current-system/profile/bin"
                 "XDG_RUNTIME_DIR=/run/user/0"
                 "LIBSEAT_BACKEND=builtin"
                 "WLR_RENDERER=pixman"
                 "WLR_NO_HARDWARE_CURSORS=1"
                 "LC_ALL=en_US.UTF-8")
           #:log-file "/var/log/reader-session.log")
          args)))
    (stop #~(make-kill-destructor)))))

(define pinenote-reader-session-service-type
  (service-type
   (name 'pinenote-reader-session)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-reader-session-shepherd-service)))
   (default-value #f)
   (description "Run KOReader in a cage Wayland kiosk on the PineNote panel.")))
