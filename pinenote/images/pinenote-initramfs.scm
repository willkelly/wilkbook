(define-module (pinenote images pinenote-initramfs)
  #:export (pinenote-initramfs-note
            pinenote-kernel-arguments))

(define pinenote-initramfs-note
  "Initial scaffold uses Guix default initrd generation. PineNote-specific initrd hooks should be added only after the release-slot rootfs flavors are stable.")

(define pinenote-kernel-arguments
  '("ignore_loglevel"
    "rw"
    "rootwait"
    "earlycon"
    "console=tty0"
    "console=ttyS2,1500000n8"
    "fw_devlink=off"))
