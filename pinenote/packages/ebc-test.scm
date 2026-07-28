(define-module (pinenote packages ebc-test)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages python)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (guix utils))

(define-public pinenote-ebc-barrier-test
  (package
    (name "pinenote-ebc-barrier-test")
    (version "0.1.0")
    (source
     (file-union "pinenote-ebc-barrier-test-source"
                  `(("Makefile" ,(local-file "../tools/ebc-barrier/Makefile"))
                    ("ack-wait.c" ,(local-file "../tools/ebc-barrier/ack-wait.c"))
                     ("ack-wait.h" ,(local-file "../tools/ebc-barrier/ack-wait.h"))
                    ("signal-guard.c" ,(local-file "../tools/ebc-barrier/signal-guard.c"))
                    ("signal-guard.h" ,(local-file "../tools/ebc-barrier/signal-guard.h"))
                    ("reader-scan.c" ,(local-file "../tools/ebc-barrier/reader-scan.c"))
                    ("reader-scan.h" ,(local-file "../tools/ebc-barrier/reader-scan.h"))
                    ("ebc-barrier.c" ,(local-file "../tools/ebc-barrier/ebc-barrier.c"))
                   ("ebc-barrier.h" ,(local-file "../tools/ebc-barrier/ebc-barrier.h"))
                   ("pinenote-ebc-sleep-frame-test.c"
                    ,(local-file "../tools/ebc-barrier/pinenote-ebc-sleep-frame-test.c"))
                   ("shim/drm.h" ,(local-file "../tools/ebc-barrier/shim/drm.h"))
                   ("extract-from-patch.py" ,(local-file "../tools/wbf/extract-from-patch.py"))
                   ("linux-pinenote-7.0-forward-port.patch"
                    ,(local-file "../patches/linux-pinenote-7.0-forward-port.patch")))))
    (build-system gnu-build-system)
    (native-inputs (list python))
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke "make"
                      (string-append "CC=" #$(cc-for-target))
                      "PATCH=linux-pinenote-7.0-forward-port.patch"
                      "EXTRACT=extract-from-patch.py"
                      "build/pinenote-ebc-sleep-frame-test")))
          (replace 'install
            (lambda _
              (invoke "make" "PREFIX=" (string-append "DESTDIR=" #$output)
                      "PATCH=linux-pinenote-7.0-forward-port.patch"
                      "EXTRACT=extract-from-patch.py"
                      "install"))))))
    (home-page "https://codeberg.org/wilkbook")
    (synopsis "Supervised reversible PineNote EBC sleep-frame test")
    (description
     "Install pinenote-ebc-sleep-frame-test, a root-only, separately invoked
PineNote framebuffer sleep-frame and EBC generation-barrier test.  It is not a
service and does not request suspend: an operator must stop reader-session and
acknowledge restoration on an interactive tty.  The package extracts the exact
barrier UAPI header from the carried kernel patch while building.")
    (license gpl3+)))

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
                 (script (string-append bin "/pinenote-ebc-test"))
                 (refresh (string-append bin "/pinenote-ebc-refresh")))
            (mkdir-p bin)
            ;; Trigger the rockchip_ebc GLOBAL_REFRESH ioctl (a full-panel
            ;; deghosting refresh) from stock Guile via the FFI — no
            ;; compiled tools needed on the device.  Technique validated on
            ;; hardware 2026-07-04.  The ioctl number is
            ;; DRM_IOWR(DRM_COMMAND_BASE + 0x00, struct { bool; }) =
            ;; _IOC(3, 'd', 0x40, 1) = #xC0016440 (see
            ;; include/uapi/drm/rockchip_ebc_drm.h in the forward-port
            ;; patch).  DRM_AUTH-gated: run as root with no other DRM
            ;; master (the first opener of card0 becomes master).
            (call-with-output-file refresh
              (lambda (port)
                (display (string-append
                          "#!" #$(file-append guile-3.0 "/bin/guile")
                          " --no-auto-compile\n") port)
                (display "!#\n" port)
                (display "(use-modules (system foreign) (rnrs bytevectors))\n" port)
                (display "(define card \"/dev/dri/card0\")\n" port)
                (display "(define ioctl\n" port)
                (display "  (pointer->procedure int (dynamic-func \"ioctl\" (dynamic-link))\n" port)
                (display "                      (list int unsigned-long '*)))\n" port)
                (display "(define fd (open-fdes card O_RDWR))\n" port)
                (display "(define buf (make-bytevector 1 1))\n" port)
                (display "(define ret (ioctl fd #xC0016440 (bytevector->pointer buf)))\n" port)
                (display "(close-fdes fd)\n" port)
                (display "(if (zero? ret)\n" port)
                (display "    (format #t \"pinenote-ebc-refresh: global refresh triggered~%\")\n" port)
                (display "    (begin\n" port)
                (display "      (format (current-error-port)\n" port)
                (display "              \"pinenote-ebc-refresh: ioctl failed (ret=~a); run as root with no other DRM master~%\" ret)\n" port)
                (display "      (exit 1)))\n" port)))
            (chmod refresh #o555)
            (call-with-output-file script
              (lambda (port)
                (display "#!/bin/sh\n" port)
                (display "set -eu\n" port)
                (display "fb=/dev/fb0\n" port)
                (display "geometry=/sys/class/graphics/fb0/virtual_size\n" port)
                (display "bpp_file=/sys/class/graphics/fb0/bits_per_pixel\n" port)
                (display "stride_file=/sys/class/graphics/fb0/stride\n" port)
                (display "draw_smoke() {\n" port)
                (display "  [ -c \"$fb\" ] || { echo 'missing framebuffer /dev/fb0' >&2; exit 1; }\n" port)
                (display "  [ -r \"$geometry\" ] && [ -r \"$bpp_file\" ] && [ -r \"$stride_file\" ] || { echo 'missing framebuffer geometry sysfs' >&2; exit 1; }\n" port)
                (display "  IFS=, read width height < \"$geometry\"\n" port)
                (display "  bpp=$(cat \"$bpp_file\")\n" port)
                (display "  stride=$(cat \"$stride_file\")\n" port)
                (display "  bytes_per_pixel=$((bpp / 8))\n" port)
                (display "  size=96\n" port)
                (display "  x=32\n" port)
                (display "  y=32\n" port)
                (display "  [ \"$bytes_per_pixel\" -gt 0 ] && [ $((x + size)) -le \"$width\" ] && [ $((y + size)) -le \"$height\" ] || { echo 'framebuffer geometry is too small for smoke test' >&2; exit 1; }\n" port)
                (display "  row_bytes=$((size * bytes_per_pixel))\n" port)
                (display "  temporary=$(mktemp -d /tmp/pinenote-ebc-test.XXXXXX)\n" port)
                (display "  trap 'rm -rf -- \"$temporary\"' EXIT HUP INT TERM\n" port)
                (display "  dd if=/dev/zero bs=1 count=\"$row_bytes\" status=none | tr '\\000' '\\377' > \"$temporary/white-row\"\n" port)
                (display "  row=0\n" port)
                (display "  while [ \"$row\" -lt \"$size\" ]; do\n" port)
                (display "    offset=$(((y + row) * stride + x * bytes_per_pixel))\n" port)
                (display "    dd if=\"$fb\" of=\"$temporary/row-$row\" bs=1 skip=\"$offset\" count=\"$row_bytes\" status=none\n" port)
                (display "    dd if=\"$temporary/white-row\" of=\"$fb\" bs=1 seek=\"$offset\" conv=notrunc status=none\n" port)
                (display "    row=$((row + 1))\n" port)
                (display "  done\n" port)
                (display "  sync\n" port)
                (display "  echo \"pinenote-ebc-test: drew ${size}x${size} white square at ${x},${y}; restoring in 10 seconds\"\n" port)
                (display "  sleep 10\n" port)
                (display "  row=0\n" port)
                (display "  while [ \"$row\" -lt \"$size\" ]; do\n" port)
                (display "    offset=$(((y + row) * stride + x * bytes_per_pixel))\n" port)
                (display "    dd if=\"$temporary/row-$row\" of=\"$fb\" bs=1 seek=\"$offset\" conv=notrunc status=none\n" port)
                (display "    row=$((row + 1))\n" port)
                (display "  done\n" port)
                (display "  sync\n" port)
                (display "  echo 'pinenote-ebc-test: framebuffer smoke test restored saved region'\n" port)
                (display "}\n" port)
                (display "case \"${1:-}\" in\n" port)
                (display "  --draw-smoke) draw_smoke; exit 0 ;;\n" port)
                (display "  --help) echo 'usage: pinenote-ebc-test [--draw-smoke]'; exit 0 ;;\n" port)
                (display "  '') ;;\n" port)
                (display "  *) echo 'usage: pinenote-ebc-test [--draw-smoke]' >&2; exit 2 ;;\n" port)
                (display "esac\n" port)
                (display "echo 'pinenote-ebc-test: read-only report; use --draw-smoke for a reversible framebuffer test'\n" port)
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
                (display "echo 'No framebuffer, DRM, EBC, partition, or bootloader writes are performed unless --draw-smoke is passed.'\n" port)))
            (chmod script #o555)))))
    (home-page "https://github.com/m-weigand/linux/tree/branch_pinenote_6-12-11")
    (synopsis "Conservative PineNote EBC bring-up tools")
    (description
      "Install a small pinenote-ebc-test command that reports the EBC and DRM
state without writing by default, and can run an explicit reversible framebuffer
smoke test with --draw-smoke; plus pinenote-ebc-refresh, which triggers the
rockchip_ebc GLOBAL_REFRESH ioctl (full-panel deghosting) through Guile's FFI.
It is a real package so the minimal operating-system declaration can refer to
an in-repository test artifact while native rendering is still being
implemented.")
    (license gpl3+)))
