(define-module (pinenote systems base)
  #:use-module (gnu bootloader)
  #:use-module ((gnu packages linux) #:select (wireless-regdb))
  #:use-module (pinenote images pinenote-bootloader)
  #:use-module ((gnu services) #:select (service service-kind modify-services))
  #:use-module ((guix packages) #:select (package? package-name))
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system shadow)
  #:use-module (pinenote images pinenote-initramfs)
  #:use-module (pinenote images pinenote-partitions)
  #:use-module (pinenote packages boot)
  #:use-module (pinenote packages cross-fixes)
  #:use-module (pinenote packages ebc-test)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote packages kernel)
  #:use-module (pinenote packages system-tools)
  #:use-module (pinenote services diagnostics)
  #:use-module (pinenote services ebc)
  #:use-module (pinenote services state)
  #:use-module (pinenote timezone)
  #:export (%pinenote-local-packages
            %pinenote-firmware
            %pinenote-bringup-services
            %base-services-without-guix
            %pinenote-base-services
            %pinenote-dev-services
            pinenote-fix-package-list
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

;; The udev rule PROVIDERS are packages too (lvm2, fuse, alsa-utils, crda), and
;; they arrive through services, not through the `packages' field -- so the
;; rewrite applied there never sees them.  alsa-utils is exactly the one that
;; needs it: cross-building alsa-lib bootstraps with libtoolize, which pulls
;; automake, whose own test suite does not survive a cross build.
(define (%fix-cross-udev-rules services)
  (modify-services services
    (udev-service-type
     config => (udev-configuration
                (inherit config)
                (rules (map (lambda (r)
                              (if (and (package? r)
                                       (string=? (package-name r) "alsa-utils"))
                                  (fix-cross-builds r)
                                  r))
                            (udev-configuration-rules config)))))))

(define %base-services-without-guix
  ;; Release-slot flavors should not carry on-device package management unless
  ;; they explicitly opt in, as pinenote-dev does below.
  (%fix-cross-udev-rules
   (filter (lambda (base-service)
             (not (eq? (service-kind base-service) guix-service-type)))
           %base-services)))

(define %pinenote-base-services
  (append %pinenote-bringup-services %base-services-without-guix))

(define %pinenote-dev-services
  (append %pinenote-bringup-services %base-services))

;; SURGICAL, and it has to be.  Mapping fix-cross-builds over the whole list
;; makes a rewritten variant of everything that build-depends on automake, and
;; the profile then refuses to hold two e2fsprogs ("You cannot have two
;; different versions or variants of `e2fsprogs'").  man-db is the one leaf
;; that pulls the broken groff-minimal, and nothing propagates it, so
;; rewriting just that collides with nothing.
;;
;; EXPORTED because a second consumer now needs the SAME list: the manuals
;; shelf (pinenote/services/manuals.scm) converts the documentation of the
;; packages the flavor installs, and handing it the un-rewritten man-db would
;; pull the broken cross build back into the image's dependency graph through
;; a side door -- a build failure whose cause is nowhere near its symptom.
(define (pinenote-fix-package-list packages)
  "Apply the surgical cross-build repairs to a flavor's package list."
  (map (lambda (p)
         (if (and (package? p)
                  (string=? (package-name p) "man-db"))
             (fix-cross-builds p)
             p))
       packages))

(define* (make-pinenote-operating-system
          #:key
          (host-name "pinenote-guix")
          (kernel linux-pinenote)
          (initrd pinenote-initrd)
          (packages (append %pinenote-local-packages %base-packages))
          (services %pinenote-base-services))
  (operating-system
    (host-name host-name)
    ;; Build-time, and here rather than on the reader flavor so that every
    ;; flavor's log timestamps agree -- see pinenote/timezone.scm for why
    ;; the default stays Etc/UTC and how to override it (WILKBOOK_TIMEZONE
    ;; or local.mk, the same mechanism as the insecure flag).
    (timezone %pinenote-timezone)
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
    ;; Applied HERE, not to the #:packages default: pinenote-reader.scm passes
    ;; its own #:packages, so a default-arg rewrite is silently skipped for the
    ;; flavor that matters.  See pinenote-fix-package-list above.
    (packages (pinenote-fix-package-list packages))
    (services services)))
