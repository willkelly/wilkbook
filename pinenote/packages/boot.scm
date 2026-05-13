(define-module (pinenote packages boot)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages))

(define-public pinenote-extlinux-reference
  (package
    (name "pinenote-extlinux-reference")
    (version "0.1.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out #$output)
                 (doc (string-append out "/share/doc/pinenote"))
                 (file (string-append doc "/extlinux-reference.conf")))
            (mkdir-p doc)
            (call-with-output-file file
              (lambda (port)
                (display "# Reference only. Do not install automatically.\n" port)
                (display "LABEL Guix PineNote minimal\n" port)
                (display "  LINUX /extlinux/Image\n" port)
                (display "  FDT /extlinux/rk3566-pinenote-v1.2.dtb\n" port)
                (display "  INITRD /extlinux/uInitrd.img\n" port)
                (display "  APPEND ignore_loglevel rw root=PNGuixRoot rootwait earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off\n" port)))))))
    (home-page "https://github.com/PNDeb/pinenote-debian-image")
    (synopsis "Reference PineNote extlinux stanza")
    (description
     "Install documentation containing the PNDeb-derived extlinux kernel, DTB,
initrd, and kernel argument shape.  The package does not install bootloader
files or mutate U-Boot environment.")
    (license gpl3+)))
