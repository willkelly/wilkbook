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
  #:use-module (pinenote packages orientation)
  #:use-module (pinenote services orientation)
  #:use-module (pinenote services reader-session)
  #:use-module (pinenote services autosuspend)
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
           (list (service pinenote-orientation-bridge-service-type)
                 (service pinenote-reader-session-service-type)
                 ;; Sleep to deep after inactivity: ~7x on measured power
                 ;; (172 mA awake vs 19.3 mA deep, 2026-08-02).  Wake is by
                 ;; power button, hardware-proven, with an RTC backstop
                 ;; armed every cycle so a wake regression cannot strand
                 ;; the device.  Runtime-tunable via
                 ;; /var/lib/pinenote/autosuspend.conf.
                 (service pinenote-autosuspend-service-type)
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
                ;; Comfort defaults beyond home_dir (2026-07-13, first
                ;; dogfooding session on a bare profile): KOReader's stock
                ;; refresh_on_pages_with_images=true promotes every
                ;; image-bearing page to a full flash — the quickstart
                ;; guide flashed on nearly every turn.  full_refresh_count
                ;; 0 (= never): the washer owns cadence outright per
                ;; finding 11's validated configuration — Will's call
                ;; 2026-07-13 after finding 6/11 evidence (48+ washless
                ;; turns clean; promotion adds flashes the washer makes
                ;; redundant). Seeding a DEFAULT — the user's menu
                ;; changes persist, the seed never overwrites an
                ;; existing profile.
                 ;; The SC7A20 bridge owns physical orientation.  Upstream
                 ;; lock_rotation remains authoritative for document/FM
                 ;; overrides; input_ignore_gsensor is the sole autorotation
                 ;; on/off setting and is intentionally not seeded here.
                 ;;
                 ;; THIS is the seed that wins.  reader-session.scm carries
                 ;; the same e-ink refresh keys, but both are gated on the
                 ;; file being absent and activation runs before services,
                 ;; so on a fresh image this one writes first and the
                 ;; service's is a no-op.  Found the hard way on 2026-08-05:
                 ;; the keys were added only to reader-session and shipped
                 ;; an image with none of them.  Keep the two in sync, or
                 ;; better, add refresh defaults HERE.
                 ;;
                 ;; The six refresh keys and why, in one line each (full
                 ;; reasoning in reader-session.scm and doc/refresh-policy.md):
                 ;;   cre_show_progress    -- progress bar fsyncs the whole
                 ;;                           page every 500 ms mid-render
                 ;;   cre_partial_rerendering -- 75x75 status icon costs a
                 ;;                           full-screen pass (partial cost
                 ;;                           is per-frame, not per-area)
                 ;;   flash_ui             -- two forceRePaint() per tap
                 ;;   flash_keyboard       -- same, per keystroke
                 ;;   cre_header_auto_refresh -- clock digit redraws the page
                 ;;                           every 60 s (~48 s/hour)
                 ;;   coverbrowser_initial_default_setup_done -- stops
                 ;;                           CoverBrowser seeding itself on;
                 ;;                           leaves the classic filename list
                (simple-service 'pinenote-koreader-home-dir
                                activation-service-type
                                #~(let ((f "/root/.config/koreader/settings.reader.lua"))
                                    (unless (file-exists? f)
                                      (mkdir-p "/root/.config/koreader")
                                      (call-with-output-file f
                                        (lambda (port)
                                          (display "-- seeded by the reader flavor (pinenote-koreader-home-dir)\nreturn {\n    [\"closed_rotation_mode\"] = 1,\n    [\"copt_b_page_margin\"] = 25,\n    [\"copt_font_size\"] = 30,\n    [\"copt_h_page_margins\"] = { [1] = 30, [2] = 30 },\n    [\"copt_t_page_margin\"] = 15,\n    [\"coverbrowser_initial_default_setup_done\"] = true,\n    [\"cre_font\"] = \"Equity A\",\n    [\"cre_header_auto_refresh\"] = 0,\n    [\"cre_partial_rerendering\"] = false,\n    [\"cre_show_progress\"] = false,\n    [\"flash_keyboard\"] = false,\n    [\"flash_ui\"] = false,\n    [\"full_refresh_count\"] = 0,\n    [\"home_dir\"] = \"/data/books\",\n    [\"lock_rotation\"] = true,\n    [\"refresh_on_pages_with_images\"] = false,\n    [\"screensaver_type\"] = \"cover\",\n}\n" port))))))
                (service openssh-service-type
                         (openssh-configuration
                          (password-authentication? #f)
                          (permit-root-login 'prohibit-password)
                          (authorized-keys
                           `(("root" ,(plain-file "wkelly.pub"
                                                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICMbOSX755vG0PSWm1z9WrGP+x8YRsPqJ0YtUnGjufGP wkelly@pop-os\n"))))))
                (service pinenote-usb-acm-gadget-service-type)
                (service pinenote-usb-acm-console-service-type)
                ;; NO custom UART getty: %base-services already runs agetty
                ;; on the kernel console (tty #f resolves console=ttyS2 from
                ;; the cmdline), and a second agetty on the same tty can
                ;; never win it -- it exits ~10 s in and shepherd respawns
                ;; it forever.  3,201 such cycles over ~9 h degraded PID 1
                ;; until it stopped servicing the (inetd-style) sshd
                ;; listener: the 2026-07-12 os2 wedge (doc/status.md).
                ;; (wait-cr? was tried first and did not help -- the exit is
                ;; the tty conflict, not the floating RX line.)  UART login
                ;; is the base getty's prompt; the ACM gadget console keeps
                ;; its own auto-login.
                )
          %base-services-without-guix))

(define pinenote-reader-base-os
  (make-pinenote-operating-system
   #:host-name "pinenote-reader"
    #:packages (append (list koreader-bin pinenote-orientation-bridge
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
