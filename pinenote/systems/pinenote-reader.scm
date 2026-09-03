(define-module (pinenote systems pinenote-reader)
  #:use-module (gnu services)
  #:use-module (gnu packages linux)
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
  #:use-module (pinenote packages platform-controls)
  #:use-module (pinenote packages update-path)
  #:use-module (pinenote services orientation)
  #:use-module (pinenote services koreader-profile)
  #:use-module (pinenote services reader-session)
  #:use-module (pinenote services platform-controls)
  #:use-module (pinenote services update-path)
  #:use-module (pinenote services dmc)
  #:use-module (pinenote services library)
  #:use-module (pinenote services manuals)
  #:use-module (pinenote services frontlight)
  #:use-module (pinenote services ddr-boost)
  #:use-module (pinenote services ssh-keys)
  #:use-module (pinenote services timesync)
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

;; Named, because two things now need the SAME list: the profile the device
;; installs, and the manuals shelf, which converts the documentation of
;; exactly the packages that are on the device and nothing else.
(define %pinenote-reader-packages
  (append (list koreader-bin pinenote-orientation-bridge
                pinenote-platform-controls
                ;; The update path (doc/update-path.md): kexec for the
                ;; trial boot, and the generation helper.
                kexec-tools
                pinenote-update-path
                ;; wpa_supplicant + wpa_cli in the profile: pinenote-wifi
                ;; execs them, and Phase 2's KOReader Wi-Fi UI will drive
                ;; wpa_cli against the same conf.
                wpa-supplicant)
          ;; licensed fonts staged locally; #f on a fresh clone
          ;; (pinenote/fonts/README.md)
          (if pinenote-local-fonts
              (list pinenote-local-fonts)
              '())
          %pinenote-local-packages
          %base-packages))

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
                 ;; The man pages and Texinfo manuals of the packages above,
                 ;; converted to EPUB at BUILD time and staged into
                 ;; /data/books/Manuals (issue #17).  They already ship --
                 ;; man-db and info-reader come from %base-packages -- and
                 ;; without this there is no way to read a word of them on a
                 ;; device with no terminal.  Ordered after pinenote-library
                 ;; (which creates /data/books) and deliberately NOT ahead of
                 ;; reader-session: the shepherd ordering around the reader
                 ;; cost the first two hardware sessions, and a shelf that
                 ;; appears a second into the session is not worth touching it.
                 (service pinenote-manuals-service-type
                          (pinenote-manuals-configuration
                           (packages (pinenote-fix-package-list
                                      %pinenote-reader-packages))))
                 ;; The acknowledged suspend broker must create its named
                 ;; uinput device before reader-session starts.  It owns all
                 ;; physical/cover triggers and every /sys/power/state write;
                 ;; KOReader owns idle policy and screen preparation.
                 (service pinenote-platform-controls-service-type)
                 (service pinenote-reader-session-service-type)
                 ;; The update path (doc/update-path.md): the daemon comes
                 ;; back as a STORE IMPORTER for `guix copy`, never a
                 ;; builder -- --max-jobs=0 makes local builds impossible,
                 ;; substitutes are off, no substitute key is generated,
                 ;; no channels are installed.  Rollback is then Guix's own
                 ;; system generations.  Measured 2026-09-02: ~5 MB idle,
                 ;; no timers.
                 (service guix-service-type
                          (guix-configuration
                           (use-substitutes? #f)
                           (substitute-urls '())
                           (authorize-key? #f)
                           (generate-substitute-key? #f)
                           (discover? #f)
                           (extra-options '("--max-jobs=0"))))
                 (service pinenote-grow-root-service-type)
                 (service pinenote-guix-acl-service-type)
                ;; Wi-Fi (doc/networking.md): associate from an out-of-band
                ;; credential file on the persistent data partition (no-op
                ;; when absent), and lease with dhcpcd.  Credentials are
                ;; provisioned once over the serial console; nothing secret
                ;; enters the image or the store.
                (service pinenote-wifi-service-type)
                (service dhcpcd-service-type)
                ;; Set the clock from SNTP when a network happens to be
                ;; there (issue #27).  SHIPPED INERT: the default
                ;; `servers' list is empty, so the daemon logs one line
                ;; and exits without opening a socket -- reaching a time
                ;; server is an outbound connection on an image that
                ;; otherwise makes none, so it is the operator's choice,
                ;; not ours.  Give it one and the reader stops
                ;; reconstructing its own sessions from whatever the RTC
                ;; happened to hold:
                ;;
                ;;   (service pinenote-timesync-service-type
                ;;            (pinenote-timesync-configuration
                ;;             (servers '("192.168.1.1"))))
                ;;
                ;; The reader flavor only, not base.scm: this is the
                ;; flavor that has Wi-Fi, and a service that can never
                ;; find a network is not worth carrying elsewhere.
                (service pinenote-timesync-service-type)
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
                ;; The KOReader profile seeded onto a fresh image, and the
                ;; ONLY writer of KOReader's settings file in the tree.  Every
                ;; default -- the library home_dir, the six e-ink refresh
                ;; keys, the font aliases -- is declared exactly once, on
                ;; the record in (pinenote services koreader-profile),
                ;; which also carries the measurement behind each.  It
                ;; writes only when the file is ABSENT, so a profile the
                ;; user has customized is never overwritten; /root comes
                ;; from the image, so "absent" means a fresh reflash.
                ;;
                ;; Override a field rather than editing a string:
                ;;   (service pinenote-koreader-profile-service-type
                ;;            (pinenote-koreader-profile-configuration
                ;;             (font-size 32)))
                ;;
                ;; Until 2026-08-24 reader-session.scm carried a SECOND
                ;; seed of this same file.  It could never run -- activation
                ;; runs before shepherd services and both were gated on the
                ;; file being absent -- which is how the 2026-08-05 image
                ;; shipped with none of the refresh keys: they were added to
                ;; the dead copy only.  One writer now, pinned by
                ;; `make koreader-profile-check'.
                (service pinenote-koreader-profile-service-type)
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
   #:packages %pinenote-reader-packages
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
