(define-module (pinenote images pinenote-bootloader)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader extlinux)
  #:export (pinenote-rootfs-bootloader))

(define pinenote-rootfs-bootloader
  (bootloader
   (inherit extlinux-bootloader)
   (name 'pinenote-rootfs-extlinux)
   (installer #f)
   (disk-image-installer #f)))
