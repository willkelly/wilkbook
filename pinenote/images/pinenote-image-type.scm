(define-module (pinenote images pinenote-image-type)
  #:use-module (gnu image)
  #:use-module (gnu system image)
  #:use-module (pinenote images pinenote-partitions)
  #:export (pinenote-raw-image-type
            pinenote-rootfs-image-note))

(define pinenote-rootfs-image-note
  "Build-only root filesystem target labelled PNGuixRoot. Guix currently builds the PineNote rootfs through a raw-with-offset whole-disk intermediate; use pinenote/scripts/preflight/extract-rootfs-from-raw.sh and inspect-rootfs-image.sh to produce and validate the direct ext4 partition artifact before any manual placement into a confirmed experimental OS slot.")

;; Guix's public image record supports disk-image, compressed-qcow2, docker,
;; iso9660, tarball, and wsl2 formats in the current channel.  There is no
;; exported partition-image format to select with `guix system image -t`, so the
;; safe PineNote rootfs artifact is extracted from this single-partition raw
;; image by the Gate 6 preflight helper instead of inventing a private image
;; format here.  Keep this module non-destructive: no full-device partition
;; table, bootloader installation, or firmware blob embedding belongs here.
(define pinenote-raw-image-type raw-with-offset-image-type)
