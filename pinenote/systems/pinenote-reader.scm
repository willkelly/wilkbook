(define-module (pinenote systems pinenote-reader)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module ((gnu packages admin) #:select (wpa-supplicant))
  #:use-module (gnu system)
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
                (service pinenote-usb-acm-gadget-service-type)
                (service pinenote-usb-acm-console-service-type)
                (service agetty-service-type
                         (agetty-configuration
                          (tty "ttyS2")
                          (baud-rate "1500000")
                          (term "vt100")
                          (auto-login "reader")
                          (local-line 'always)
                          (no-clear? #t))))
          %base-services-without-guix))

(define pinenote-reader-operating-system
  (operating-system
    (inherit (make-pinenote-operating-system
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
    (sudoers-file pinenote-reader-sudoers)))

pinenote-reader-operating-system
