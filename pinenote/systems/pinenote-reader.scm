(define-module (pinenote systems pinenote-reader)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (pinenote packages kiosk)
  #:use-module (pinenote packages koreader)
  #:use-module (pinenote services reader-session)
  #:use-module (pinenote services usb-gadget)
  #:use-module (pinenote systems base)
  #:export (pinenote-reader-operating-system))

;; The reading-first flavor: the usb-console flavor (gadget console as
;; the escape hatch, UART auto-login) plus the cage+KOReader kiosk.
;; See doc/koreader-spike.md for the stack and its validation status.

(define pinenote-reader-sudoers
  (plain-file "sudoers" "\
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
reader ALL=(ALL) NOPASSWD: ALL
"))

(define pinenote-reader-services
  (append %pinenote-bringup-services
          (list (service pinenote-reader-session-service-type)
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
              #:packages (append (list cage-pixman koreader-bin)
                                 %pinenote-local-packages
                                 %base-packages)
              #:services pinenote-reader-services))
    (sudoers-file pinenote-reader-sudoers)))

pinenote-reader-operating-system
