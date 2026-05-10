(define-module (pinenote systems qemu-aarch64-smoke)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader extlinux)
  #:use-module (gnu services base)
  #:use-module (gnu system)
  #:use-module (gnu system accounts)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system shadow)
  #:use-module (pinenote packages boot)
  #:use-module (pinenote packages ebc-test)
  #:use-module (pinenote packages firmware)
  #:use-module (pinenote packages system-tools)
  #:export (pinenote-qemu-smoke-operating-system))

(define pinenote-qemu-smoke-operating-system
  (operating-system
    (host-name "pinenote-qemu-smoke")
    (timezone "Etc/UTC")
    (locale "en_US.utf8")
    (bootloader
     (bootloader-configuration
      (bootloader extlinux-bootloader)
      (targets '("/dev/vda"))))
    (kernel-arguments '("console=ttyAMA0" "console=tty0"))
    (file-systems
     (cons* (file-system
              (mount-point "/")
              (device (file-system-label "GuixQemuRoot"))
              (type "ext4"))
            %base-file-systems))
    (users
     (cons (user-account
            (name "reader")
            (comment "PineNote QEMU smoke account")
            (group "users")
            (supplementary-groups '("wheel" "tty")))
           %base-user-accounts))
    (packages
     (append (list pinenote-firmware-support
                   pinenote-diagnostics
                   pinenote-ebc-test
                   pinenote-extlinux-reference)
             %base-packages))
    (services %base-services)))

pinenote-qemu-smoke-operating-system
