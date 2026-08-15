(define-module (pinenote systems base)
  #:use-module (gnu bootloader)
  #:use-module ((gnu packages linux) #:select (wireless-regdb))
  #:use-module (pinenote images pinenote-bootloader)
  #:use-module ((gnu services) #:select (service service-kind modify-services))
  #:use-module ((guix packages) #:select (package? package-name))
  #:use-module ((srfi srfi-1) #:select (remove))
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
         pinenote-ebc-barrier-test
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

;; %base-services registers udev RULE PROVIDERS -- lvm2, fuse, alsa-utils,
;; crda -- and a provider is a whole package, pulled into the closure just to
;; harvest its lib/udev/rules.d.  alsa-utils drags the entire ALSA userland
;; (and, cross-compiling, its autotools bootstrap) into a device that has no
;; audio stack, no mixer, and no way for a user to play anything: the reader
;; runs KOReader on fbdev and nothing else.
;;
;; It is also, as of 2026-08-15, the thing that makes the image unbuildable
;; here at all: cross-building alsa-lib bootstraps with libtoolize, and its
;; automake dependency fails its own test suite locally while no substitute
;; lands cleanly.  Dropping the rules is the correct change on its own terms
;; and happens to remove that entire subtree.
;;
;; Only alsa-utils is dropped.  crda stays -- Wi-Fi regulatory domain is real
;; on this device -- and lvm2/fuse are left alone as a deliberately minimal
;; edit rather than a sweep.
(define (%without-alsa-udev-rules services)
  (modify-services services
    (udev-service-type
     config => (udev-configuration
                (inherit config)
                (rules (remove (lambda (r)
                                 (and (package? r)
                                      (string=? (package-name r) "alsa-utils")))
                               (udev-configuration-rules config)))))))

(define %base-services-without-guix
  ;; Release-slot flavors should not carry on-device package management unless
  ;; they explicitly opt in, as pinenote-dev does below.
  (%without-alsa-udev-rules
   (filter (lambda (base-service)
             (not (eq? (service-kind base-service) guix-service-type)))
           %base-services)))

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
