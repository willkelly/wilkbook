(define-module (pinenote packages ebc-test)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages))

(define-public pinenote-ebc-test
  (package
    (name "pinenote-ebc-test")
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
                 (bin (string-append out "/bin"))
                 (script (string-append bin "/pinenote-ebc-test")))
            (mkdir-p bin)
            (call-with-output-file script
              (lambda (port)
                (display "#!/bin/sh\n" port)
                (display "set -eu\n" port)
                (display "echo 'pinenote-ebc-test: conservative placeholder'\n" port)
                (display "echo 'rockchip_ebc parameters:'\n" port)
                (display "if [ -d /sys/module/rockchip_ebc/parameters ]; then\n" port)
                (display "  for parameter in /sys/module/rockchip_ebc/parameters/*; do\n" port)
                (display "    [ -r \"$parameter\" ] || continue\n" port)
                (display "    printf '%s=' \"$(basename \"$parameter\")\"\n" port)
                (display "    cat \"$parameter\"\n" port)
                (display "  done\n" port)
                (display "else\n" port)
                (display "  echo 'rockchip_ebc module parameters not present'\n" port)
                (display "fi\n" port)
                (display "echo 'DRM devices:'\n" port)
                (display "ls -1 /dev/dri 2>/dev/null || true\n" port)
                (display "echo 'No framebuffer, DRM, EBC, partition, or bootloader writes are performed.'\n" port)))
            (chmod script #o555)))))
    (home-page "https://github.com/m-weigand/linux/tree/branch_pinenote_6-6-30")
    (synopsis "Conservative PineNote EBC bring-up placeholder")
    (description
     "Install a small pinenote-ebc-test command that reports the EBC and DRM
state without writing to the framebuffer, storage, bootloader, or EBC control
paths.  It is a real package so the minimal operating-system declaration can
refer to an in-repository test artifact while native rendering is still being
implemented.")
    (license gpl3+)))
