(define-module (pinenote packages system-tools)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages))

(define-public pinenote-diagnostics
  (package
    (name "pinenote-diagnostics")
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
                 (script (string-append bin "/pinenote-diagnostics")))
            (mkdir-p bin)
            (call-with-output-file script
              (lambda (port)
                (display "#!/bin/sh\n" port)
                (display "set -eu\n" port)
                (display "echo 'PineNote diagnostics'\n" port)
                (display "printf 'kernel: '; uname -a\n" port)
                (display "printf 'cmdline: '; cat /proc/cmdline\n" port)
                (display "echo 'block labels:'\n" port)
                (display "ls -l /dev/disk/by-partlabel 2>/dev/null || true\n" port)
                (display "echo 'firmware path:'\n" port)
                (display "ls -l /lib/firmware/rockchip /usr/lib/firmware/rockchip 2>/dev/null || true\n" port)
                (display "echo 'EBC module parameters:'\n" port)
                (display "if [ -d /sys/module/rockchip_ebc/parameters ]; then\n" port)
                (display "  for parameter in /sys/module/rockchip_ebc/parameters/*; do\n" port)
                (display "    [ -r \"$parameter\" ] || continue\n" port)
                (display "    printf '%s=' \"$(basename \"$parameter\")\"\n" port)
                (display "    cat \"$parameter\"\n" port)
                (display "  done\n" port)
                (display "else\n" port)
                (display "  echo 'rockchip_ebc not loaded or no parameters exported'\n" port)
                (display "fi\n" port)
                (display "echo 'diagnostics complete'\n" port)))
            (chmod script #o555)))))
    (home-page "https://wiki.pine64.org/wiki/PineNote")
    (synopsis "Read-only PineNote bring-up diagnostics")
    (description
     "Install pinenote-diagnostics, a read-only diagnostics command for the
minimal PineNote Guix bring-up image.")
    (license gpl3+)))
