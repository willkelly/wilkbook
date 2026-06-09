(define-module (pinenote systems pinenote-usb-console-linux-6-6)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (pinenote images pinenote-initramfs)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote services usb-gadget)
  #:use-module (pinenote systems base)
  #:export (pinenote-usb-console-linux-6-6-operating-system))

(define pinenote-usb-console-linux-6-6-sudoers
  (plain-file "sudoers" "\
root ALL=(ALL) ALL
%wheel ALL=(ALL) ALL
reader ALL=(ALL) NOPASSWD: ALL
"))

(define pinenote-usb-console-linux-6-6-services
  (append %pinenote-bringup-services
          (list (service pinenote-usb-acm-gadget-service-type)
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

(define pinenote-usb-console-linux-6-6-operating-system
  (operating-system
    (inherit (make-pinenote-operating-system
              #:host-name "pinenote-usb-console-linux-6-6"
              #:kernel linux-pinenote-6.6.30
              #:initrd pinenote-initrd-6.6
              #:packages (append %pinenote-local-packages %base-packages)
              #:services pinenote-usb-console-linux-6-6-services))
    (sudoers-file pinenote-usb-console-linux-6-6-sudoers)))

pinenote-usb-console-linux-6-6-operating-system
