(define-module (pinenote systems pinenote-reader)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (gnu services ssh)
  #:use-module ((gnu packages admin) #:select (wpa-supplicant))
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:use-module (guix gexp)
  #:use-module (pinenote packages fonts)
  #:use-module (pinenote packages koreader)
  #:use-module (pinenote services reader-session)
  #:use-module (pinenote services usb-gadget)
  #:use-module (pinenote services wifi)
  #:use-module (pinenote systems base)
  #:export (pinenote-reader-operating-system))

;; The reading-first flavor: the usb-console flavor (gadget console as
;; the escape hatch, UART auto-login) plus KOReader running natively on
;; the framebuffer (no compositor - see doc/koreader-spike.md for why
;; the cage/SDL kiosk was abandoned and how the native port works).

(define pinenote-reader-sudoers
  (plain-file "sudoers" "\
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
reader ALL=(ALL) NOPASSWD: ALL
"))

(define pinenote-reader-services
  (append %pinenote-bringup-services
          (list (service pinenote-reader-session-service-type)
                ;; Wi-Fi (doc/networking.md): associate from an out-of-band
                ;; credential file on the persistent data partition (no-op
                ;; when absent), and lease with dhcpcd.  Credentials are
                ;; provisioned once over the serial console; nothing secret
                ;; enters the image or the store.
                (service pinenote-wifi-service-type)
                (service dhcpcd-service-type)
                ;; SSH (key-only, no passwords) so the boxed device is
                ;; reachable over Wi-Fi once the USB cable is removed — this is
                ;; also the recorder's SSHTransport. Host keys land in /etc/ssh
                ;; (regenerated on reflash; persistent /data host keys are a
                ;; follow-up if the changing fingerprint becomes annoying).
                ;;
                ;; /var/empty (sshd's privilege-separation dir) ships from the
                ;; image build owned by a build-container uid (998:981 observed
                ;; on the A.2.5 first boot, 2026-07-11), and sshd then fatals on
                ;; every connection: "/var/empty must be owned by root and not
                ;; group or world-writable".  Re-assert ownership at activation.
                (simple-service 'pinenote-fix-var-empty
                                activation-service-type
                                #~(when (file-exists? "/var/empty")
                                    (chown "/var/empty" 0 0)
                                    (chmod "/var/empty" #o555)))
                ;; The user's library lives at /data/books on the persistent
                ;; data partition (mounted below), so books survive os2
                ;; reflashes.  /root does NOT survive a reflash, so seed the
                ;; dogfooding KOReader profile's home_dir on first boot --
                ;; only when the settings file is absent, never overriding a
                ;; profile the user has since customized.
                (simple-service 'pinenote-koreader-home-dir
                                activation-service-type
                                #~(let ((f "/root/.config/koreader/settings.reader.lua"))
                                    (unless (file-exists? f)
                                      (mkdir-p "/root/.config/koreader")
                                      (call-with-output-file f
                                        (lambda (port)
                                          (display "-- seeded by the reader flavor (pinenote-koreader-home-dir)\nreturn {\n    [\"home_dir\"] = \"/data/books\",\n}\n" port))))))
                (service openssh-service-type
                         (openssh-configuration
                          (password-authentication? #f)
                          (permit-root-login 'prohibit-password)
                          (authorized-keys
                           `(("root" ,(plain-file "wkelly.pub"
                                                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICMbOSX755vG0PSWm1z9WrGP+x8YRsPqJ0YtUnGjufGP wkelly@pop-os\n"))))))
                (service pinenote-usb-acm-gadget-service-type)
                (service pinenote-usb-acm-console-service-type)
                ;; wait-cr?: without it, --autologin on an UNATTACHED UART
                ;; spawns a shell against a floating RX line that EOFs ~10 s
                ;; in -> agetty exits 1 -> shepherd respawns, forever.  3,201
                ;; such cycles over ~9 h degraded PID 1 until it stopped
                ;; servicing the (inetd-style) sshd listener -- the 2026-07-12
                ;; os2 wedge (doc/status.md).  With wait-cr the getty sits
                ;; quietly until a human on the cable presses Enter.
                (service agetty-service-type
                         (agetty-configuration
                          (tty "ttyS2")
                          (baud-rate "1500000")
                          (term "vt100")
                          (auto-login "reader")
                          (local-line 'always)
                          (wait-cr? #t)
                          (no-clear? #t))))
          %base-services-without-guix))

(define pinenote-reader-base-os
  (make-pinenote-operating-system
   #:host-name "pinenote-reader"
   #:packages (append (list koreader-bin
                            ;; wpa_supplicant + wpa_cli in the
                            ;; profile: pinenote-wifi execs them,
                            ;; and Phase 2's KOReader Wi-Fi UI will
                            ;; drive wpa_cli against the same conf.
                            wpa-supplicant)
                      ;; licensed fonts staged locally; #f on
                      ;; a fresh clone (pinenote/fonts/README.md)
                      (if pinenote-local-fonts
                          (list pinenote-local-fonts)
                          '())
                      %pinenote-local-packages
                      %base-packages)
   #:services pinenote-reader-services))

(define pinenote-reader-operating-system
  (operating-system
    (inherit pinenote-reader-base-os)
    ;; The persistent data partition at /data: the library lives in
    ;; /data/books and survives os2 reflashes.  Addressed by GPT partlabel
    ;; (the PineNote community convention; same key pinenote-wifi uses) --
    ;; no per-device identifiers in the image.  mount-may-fail? so a
    ;; system without the partition (QEMU virt) still boots.  The wifi
    ;; one-shot's own ro mount of the same fs coexists fine -- this rw
    ;; mount happens first (file-systems mount before shepherd one-shots).
    (file-systems
     (cons (file-system
             (mount-point "/data")
             (device "/dev/disk/by-partlabel/data")
             (type "ext4")
             (create-mount-point? #t)
             (mount-may-fail? #t))
           (operating-system-file-systems pinenote-reader-base-os)))
    (sudoers-file pinenote-reader-sudoers)))

pinenote-reader-operating-system
