(define-module (pinenote images pinenote-image-type)
  #:use-module (gnu image)
  #:use-module (gnu system image)
  #:use-module (pinenote images pinenote-partitions)
  #:export (pinenote-raw-image-type
            pinenote-rootfs-image-note))

(define pinenote-rootfs-image-note
  "Build-only root filesystem target labelled PNGuixRoot. It is intended for a later manual placement into a confirmed experimental OS slot, not as a whole-device image.")

;; TODO: Replace this alias with a PineNote-specific ext4 rootfs image-type once
;; the exact Guix image API and target Guix revision are pinned in channels.scm.
;; Keep this module non-destructive: no full-device partition table, bootloader
;; installation, or firmware blob embedding belongs here.
(define pinenote-raw-image-type raw-with-offset-image-type)
