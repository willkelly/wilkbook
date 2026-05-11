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
                (service agetty-service-type
                         (agetty-configuration
                          (tty "ttyGS0")
                          (baud-rate "115200")
                          (term "vt100")
                          (auto-login "reader")
                          (local-line 'always)
                          (no-clear? #t)
                          (shepherd-requirement
                           '(pinenote-usb-acm-gadget)))))
          %base-services-without-guix))

(define pinenote-usb-console-operating-system
  (operating-system
    (inherit (make-pinenote-operating-system
              #:host-name "pinenote-usb-console"
              #:packages %pinenote-local-packages
              #:services pinenote-usb-console-services))
    (sudoers-file pinenote-usb-console-sudoers)))

pinenote-usb-console-operating-system
