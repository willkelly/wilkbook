(define-module (pinenote systems base)
  #:use-module (gnu bootloader)
  #:use-module ((gnu packages linux) #:select (wireless-regdb))
  #:use-module (pinenote images pinenote-bootloader)
  #:use-module ((gnu services) #:select (service service-kind))
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system shadow)
  #:use-module (pinenote images pinenote-initramfs)
  #:use-module (pinenote images pinenote-partitions)
  #:use-module (pinenote packages boot)
  #:use-module (pinenote packages ebc-test)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote packages system-tools)
  #:use-module (pinenote services diagnostics)
  #:use-module (pinenote services ebc)
  #:use-module (pinenote services state)
  #:export (%pinenote-local-packages
            %pinenote-firmware
            %pinenote-bringup-services
            %base-services-without-guix
            %pinenote-base-services
            %pinenote-dev-services
            make-pinenote-operating-system))

(define %pinenote-local-packages
  (list pinenote-firmware-support
        pinenote-diagnostics
        pinenote-ebc-test
        pinenote-extlinux-reference))

(define %pinenote-firmware
  (list pinenote-broadcom-wifi-firmware
        pinenote-broadcom-bt-firmware
        pinenote-ebc-default-screen
        wireless-regdb))

(define %pinenote-bringup-services
  (list (service pinenote-waveform-service-type)
        (service pinenote-ebc-modprobe-service-type)
        (service pinenote-ebc-params-service-type)
        (service pinenote-diagnostics-service-type)
        (service pinenote-ebc-test-service-type)
        (service pinenote-state-service-type)))

(define %base-services-without-guix
  ;; Release-slot flavors should not carry on-device package management unless
  ;; they explicitly opt in, as pinenote-dev does below.
  (filter (lambda (base-service)
            (not (eq? (service-kind base-service) guix-service-type)))
          %base-services))

(define %pinenote-base-services
  (append %pinenote-bringup-services %base-services-without-guix))

(define %pinenote-dev-services
  (append %pinenote-bringup-services %base-services))

(define* (make-pinenote-operating-system
          #:key
          (host-name "pinenote-guix")
          (kernel linux-pinenote)
          (initrd pinenote-initrd)
          (packages (append %pinenote-local-packages %base-packages))
          (services %pinenote-base-services))
  (operating-system
    (host-name host-name)
    (timezone "Etc/UTC")
    (locale "en_US.utf8")
    (kernel kernel)
    (firmware %pinenote-firmware)
    (initrd initrd)
    (kernel-arguments pinenote-kernel-arguments)
    (initrd-modules '())
    (bootloader
     (bootloader-configuration
      (bootloader pinenote-rootfs-bootloader)
      (targets '("/dev/disk/by-label/PNGuixRoot"))))
    (file-systems
     (cons* (file-system
              (mount-point "/")
              (device (file-system-label pinenote-root-label))
              (type "ext4"))
            %base-file-systems))
    (users
     (cons (user-account
            (name "reader")
            (comment "PineNote bring-up account")
            (group "users")
            (supplementary-groups '("wheel" "input" "video" "tty")))
           %base-user-accounts))
    (packages packages)
    (services services)))
