(define-module (pinenote systems pinenote-networked)
  #:use-module (gnu services)
  #:use-module (gnu services networking)
  #:use-module (pinenote systems base)
  #:export (pinenote-networked-operating-system))

(define pinenote-networked-services
  (append %pinenote-bringup-services
          (list (service dhcpcd-service-type)
                (service wpa-supplicant-service-type
                         (wpa-supplicant-configuration
                          (dbus? #f)
                          (interface "wlan0"))))
          %base-services-without-guix))

(define pinenote-networked-operating-system
  (make-pinenote-operating-system
   #:host-name "pinenote-networked"
   #:packages %pinenote-local-packages
   #:services pinenote-networked-services))

pinenote-networked-operating-system
