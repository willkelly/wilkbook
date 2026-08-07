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
  #:use-module (pinenote services dmc)
  #:use-module (pinenote services library)
  #:use-module (pinenote services frontlight)
  #:use-module (pinenote services ddr-boost)
  #:use-module (pinenote services autosuspend)
  #:use-module (pinenote services ssh-keys)
  #:use-module (pinenote services usb-gadget)
  #:use-module (pinenote services wifi)
  #:use-module (pinenote images pinenote-initramfs)
  #:use-module (pinenote insecure)
  #:use-module (pinenote systems base)
  #:export (pinenote-reader-operating-system))

;; The reading-first flavor: the usb-console flavor (gadget console as
;; the escape hatch, UART auto-login) plus KOReader running natively on
;; the framebuffer (no compositor - see doc/koreader-spike.md for why
;; the cage/SDL kiosk was abandoned and how the native port works).

(define pinenote-reader-sudoers
  ;; The reader account's passwordless sudo is what makes the gadget
  ;; console root-equivalent, so it is gated with it rather than left
  ;; standing on its own -- a secure build with an unauthenticated shell
  ;; that can still sudo would be the worst of both.
  (plain-file "sudoers"
              (string-append "\
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
"
                             (if %very-insecure-for-convenience?
                                 "reader ALL=(ALL) NOPASSWD: ALL\n"
                                 ""))))

;; The KOReader profile seeded onto a fresh image.
;;
;; Built HOST-SIDE, as a string, so the font block can be CONDITIONAL.  A
;; fresh clone has no pinenote/fonts/local (gitignored, licensed), so
;; pinenote-local-fonts is #f and EXT_FONT_DIR is never set on that path --
;; naming "Equity A" there points the reader at a font that is not in the
;; image.  reader-session.scm has always got this right; this seed did not.
;;
;; And this is the seed that WINS: activation runs before services and both
;; are gated on the settings file being absent, so on a fresh image this one
;; writes and reader-session's is a no-op.  Which means the font block here
;; must be the FULL one from reader-session.scm, not just cre_font -- with
;; only cre_font, monospace_font and cre_font_family_fonts were silently
;; dropped from every fonts-present image.  Keep the two in sync.
(define %pinenote-koreader-seed
  (string-append
   "-- seeded by the reader flavor (pinenote-koreader-home-dir)\n"
   "return {\n"
   "    [\"closed_rotation_mode\"] = 1,\n"
   "    [\"copt_b_page_margin\"] = 25,\n"
   "    [\"copt_font_size\"] = 30,\n"
   "    [\"copt_h_page_margins\"] = { [1] = 30, [2] = 30 },\n"
   "    [\"copt_t_page_margin\"] = 15,\n"
   "    [\"coverbrowser_initial_default_setup_done\"] = true,\n"
   (if pinenote-local-fonts
       (string-append
        "    [\"cre_font\"] = \"Equity A\",\n"
        "    [\"monospace_font\"] = \"Triplicate A Code\",\n"
        "    [\"cre_font_family_fonts\"] = {\n"
        "        [\"serif\"] = \"Equity A\",\n"
        "        [\"sans-serif\"] = \"Concourse 4\",\n"
        "        [\"monospace\"] = \"Triplicate A Code\",\n"
        "    },\n")
       "")
   "    [\"cre_header_auto_refresh\"] = 0,\n"
   "    [\"cre_partial_rerendering\"] = false,\n"
   "    [\"cre_show_progress\"] = false,\n"
   "    [\"flash_keyboard\"] = false,\n"
   "    [\"flash_ui\"] = false,\n"
   "    [\"full_refresh_count\"] = 0,\n"
   "    [\"home_dir\"] = \"/data/books\",\n"
   "    [\"lock_rotation\"] = true,\n"
   "    [\"quickstart_shown_version\"] = 2021070000,\n"
   "    [\"refresh_on_pages_with_images\"] = false,\n"
   "    [\"screensaver_type\"] = \"cover\",\n"
   "}\n"))


(define pinenote-reader-services
  (append %pinenote-bringup-services
           (list (service pinenote-orientation-bridge-service-type)
                 ;; Light the panel before anything paints on it: a
                 ;; reflective display with no frontlight is
                 ;; indistinguishable from a hung boot, and every camera
                 ;; observation of the boot window is blind without it.
                 (service pinenote-frontlight-service-type)
                 ;; Static-low DDR: modprobe wilkbook_dmc with fbcon
                 ;; quiesced (the probe-time drop to 324 MHz is the
                 ;; module's only runtime switch, and it must not overlap
                 ;; an EBC scan), then verify via clk_scmi_ddr.  ~25 mA
                 ;; measured quiesced (awake-levers-20260806 addendum).
                 ;; Fails OPEN: any miss logs loudly and exits success --
                 ;; a reader at 1056 beats no reader (acceptance catches
                 ;; the miss).
                 (service pinenote-dmc-service-type)
                 (service pinenote-ddr-boost-service-type)
                 ;; Creates /data/books before the reader opens its file
                 ;; browser on it.  Ordering is declared in
                 ;; reader-session's requirement, not implied by this
                 ;; list -- shepherd starts services concurrently.
                 (service pinenote-library-service-type)
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
                ;; and are synchronized with /data/ssh/host/ at boot
                ;; (ssh-keys.scm, since 2026-08-06), so the device identity
                ;; persists across reflashes.
                ;;
                ;; /var/empty (sshd's privilege-separation dir) ships from the
                ;; image build owned by a build-container uid (998:981 observed
                ;; on the A.2.5 first boot, 2026-07-11), and sshd then fatals on
                ;; every connection: "/var/empty must be owned by root and not
                ;; group or world-writable".  Re-assert ownership at activation.
                (simple-service 'wilkbook-build-marker etc-service-type
                                (list `("wilkbook-build"
                                        ,(plain-file "wilkbook-build"
                                                     (insecure-build-marker)))))
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
                ;; Shadowed fallback for the case where p7 never mounts.
                ;; pinenote-library (a shepherd one-shot) correctly refuses to
                ;; create the library when /data is not a mount point -- but
                ;; then home_dir does not resolve, and KOReader does NOT
                ;; recover from that: realpath returns nil, root_path falls
                ;; through to lfs.currentdir(), and the user's first sight of
                ;; "their library" is the read-only Guix store directory
                ;; listing luajit and reader.lua.
                ;;
                ;; Activation runs BEFORE /data is mounted, so this always
                ;; writes to the os2 root filesystem -- which is exactly the
                ;; point.  When p7 is present the real mount shadows it and
                ;; nobody ever sees it.  When p7 is absent or its mount
                ;; failed, it is what the file browser opens on, and it says
                ;; so in a sentence instead of showing a store path.
                (simple-service 'pinenote-library-fallback
                                activation-service-type
                                #~(let ((f "/data/books/DATA-PARTITION-DID-NOT-MOUNT.txt"))
                                    (unless (file-exists? f)
                                      (mkdir-p "/data/books")
                                      (call-with-output-file f
                                        (lambda (port)
                                          (display "\
If you can read this file in the reader, the shared data partition did not
mount, and this is NOT your library -- it is a placeholder on the OS
partition.

Your books live on the data partition (the one labelled \"data\", which the
stock Debian system mounts as /home).  Nothing here is lost: this directory
is normally hidden underneath that mount.

Check that the partition exists and is healthy from the other OS slot, or
over the serial console.  See doc/install.md in the wilkbook repository.
" port))))))
                (simple-service 'pinenote-koreader-home-dir
                                activation-service-type
                                #~(let ((f "/root/.config/koreader/settings.reader.lua"))
                                    (unless (file-exists? f)
                                      (mkdir-p "/root/.config/koreader")
                                      (call-with-output-file f
                                        (lambda (port)
                                          (display #$%pinenote-koreader-seed port))))))
                ;; Key-only SSH with NO baked authorized key: root's key
                ;; is installed at boot from /data/ssh/authorized_keys
                ;; (ssh-keys.scm), the same out-of-band channel as the
                ;; Wi-Fi credentials, so the image stays generic and the
                ;; key survives reflashes.  A device with no staged key
                ;; boots normally and is reachable over the ACM/UART
                ;; consoles only.
                (service openssh-service-type
                         (openssh-configuration
                          (password-authentication? #f)
                          (permit-root-login 'prohibit-password)))
                (service pinenote-ssh-authorized-keys-service-type)
                ;; The gadget itself is harmless and useful (it is how a
                ;; host sees the device at all); the CONSOLE on it execs a
                ;; shell with no login prompt, so only that half is gated.
                (service pinenote-usb-acm-gadget-service-type)
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
          %base-services-without-guix
          ;; Development conveniences: opt-in, off by default, and the
          ;; image says which build it is either way (pinenote/insecure.scm).
          (if %very-insecure-for-convenience?
              (list (service pinenote-usb-acm-console-service-type))
              '())))

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
    ;; No console=tty0: the panel is the product surface, not a printk
    ;; sink.  See pinenote-reader-kernel-arguments for why this is also a
    ;; display-integrity change and not just cosmetics.
    (kernel-arguments pinenote-reader-kernel-arguments)
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
