(define-module (pinenote systems pinenote-usb-console)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (pinenote services usb-gadget)
  #:use-module (pinenote systems base)
  #:export (pinenote-usb-console-operating-system))

(define pinenote-usb-console-sudoers
  (plain-file "sudoers" "\
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
reader ALL=(ALL) NOPASSWD: ALL
"))

(define pinenote-usb-console-services
  (append %pinenote-bringup-services
          (list (service pinenote-usb-acm-gadget-service-type)
                (service pinenote-usb-acm-console-service-type)
                (service agetty-service-type
                         (agetty-configuration
                          (tty "ttyS2")
                          (baud-rate "115200")
                          (term "vt100")
                          (auto-login "reader")
                          (local-line 'always)
                          (no-clear? #t))))
          %base-services-without-guix))

(define pinenote-usb-console-operating-system
  (operating-system
    (inherit (make-pinenote-operating-system
              #:host-name "pinenote-usb-console"
              #:packages (append %pinenote-local-packages %base-packages)
              #:services pinenote-usb-console-services))
    (sudoers-file pinenote-usb-console-sudoers)))

pinenote-usb-console-operating-system
