(define-module (pinenote packages firmware)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (guix utils))

(define-public pinenote-broadcom-wifi-firmware
  (package
    (name "pinenote-broadcom-wifi-firmware")
    (version "20260410")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://cdn.kernel.org/pub/linux/kernel/firmware/"
                           "linux-firmware-" version ".tar.xz"))
       (sha256
        (base32 "0y71y41bykla8xhclihfriwjms578bl0panxrvn0jswzspb2x0dp"))))
    (build-system copy-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          (replace 'install
            (lambda _
              (let ((brcm (string-append #$output "/lib/firmware/brcm"))
                    (source "."))
                (mkdir-p brcm)
                (copy-file (string-append source "/cypress/cyfmac43455-sdio.bin")
                           (string-append brcm "/brcmfmac43455-sdio.bin"))
                (copy-file (string-append source "/cypress/cyfmac43455-sdio.bin")
                           (string-append brcm "/brcmfmac43455-sdio.pine64,pinenote-v1.2.bin"))
                (copy-file (string-append source "/cypress/cyfmac43455-sdio.clm_blob")
                           (string-append brcm "/brcmfmac43455-sdio.clm_blob"))
                (copy-file (string-append source "/brcm/brcmfmac43455-sdio.AW-CM256SM.txt")
                           (string-append brcm "/brcmfmac43455-sdio.pine64,pinenote-v1.2.txt"))))))))
    (home-page "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git")
    (synopsis "Broadcom Wi-Fi firmware for PineNote")
    (description
     "Install the BCM43455 SDIO firmware, CLM blob, and PineNote v1.2 NVRAM
file names requested by brcmfmac on PineNote.")
    (license #f)))

(define-public pinenote-broadcom-bt-firmware
  (let ((commit "cdf61dc691a49ff01a124752bd04194907f0f9cd"))
    (package
      (name "pinenote-broadcom-bt-firmware")
      (version "0-cdf61dc")
      (source
       (origin
         (method url-fetch)
         (uri (string-append "https://github.com/RPi-Distro/bluez-firmware/archive/"
                             commit ".tar.gz"))
         (sha256
          (base32 "03z72vm24jp0d75i08vx0jb1b9gh8lwg3dj47sfi52qscw1p00jy"))))
      (build-system copy-build-system)
      (arguments
       (list
        #:install-plan
        #~'(("debian/firmware/broadcom/BCM4345C0.hcd" "lib/firmware/brcm/"))
        #:phases
        #~(modify-phases %standard-phases
            (add-after 'install 'add-pinenote-alias
              (lambda _
                (with-directory-excursion (string-append #$output "/lib/firmware/brcm")
                  (copy-file "BCM4345C0.hcd"
                             "BCM4345C0.pine64,pinenote-v1.2.hcd")))))))
      (home-page "https://github.com/RPi-Distro/bluez-firmware")
      (synopsis "Broadcom Bluetooth firmware for PineNote")
      (description
       "Install the BCM4345C0 Bluetooth patch file under the generic name and
the PineNote v1.2 device-specific alias requested by the kernel Bluetooth
       driver.")
      (license #f))))

(define-public pinenote-ebc-default-screen
  (package
    (name "pinenote-ebc-default-screen")
    (version "0.1.0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder
      #~(begin
          (use-modules (rnrs io ports))
          (let ((destination (string-append #$output
                                            "/lib/firmware/rockchip/"
                                            "rockchip_ebc_default_screen.bin")))
          (mkdir #$output)
          (mkdir (string-append #$output "/lib"))
          (mkdir (string-append #$output "/lib/firmware"))
          (mkdir (string-append #$output "/lib/firmware/rockchip"))
          (call-with-port (open-file-output-port destination)
            (lambda (port)
              (let loop ((remaining (/ (* 1872 1404) 2)))
                (unless (zero? remaining)
                  (put-u8 port #xff)
                  (loop (- remaining 1))))))))))
    (home-page "https://github.com/m-weigand/linux/tree/branch_pinenote_6-12-11")
    (synopsis "Generated PineNote EBC off-screen seed")
    (description
     "Install a generated all-white 1872x1404 4bpp off-screen buffer under the
name requested by the downstream PineNote Rockchip EBC driver.  This matches the
driver's built-in fallback when the file is absent and avoids bundling the stock
Debian screen image from device backups.")
    (license public-domain)))

;; On-device EXTRACT_FBS grabber for the debug kernel (the belief half of
;; the camera<->driver-belief instrument; doc/pageturn-program.md §5.2,
;; optics PLAN task 23).  The sources are the ebc-logic host tool's own
;; files, so the container format can never drift between the device
;; grabber and the host decoder; the offline dbg suite
;; (make ebc-logic-check) executes the ioctl + decode path end to end.
;; Precedent for shipping a driver-buffer dump tool in a debug image:
;; hrdl's rockchip_ebc_dump_buffers.py, packaged by ayakael
;; (doc/hrdl-evaluation.md).
(define-public pinenote-ebc-dump
  (package
    (name "pinenote-ebc-dump")
    (version "0.1.0")
    (source
     (file-union "pinenote-ebc-dump-source"
                 `(("ebc-dump-grab.c"
                    ,(local-file "../tools/ebc-logic/ebc-dump-grab.c"))
                   ("ebc-dump-format.h"
                    ,(local-file "../tools/ebc-logic/ebc-dump-format.h")))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke #$(cc-for-target) "-O2" "-Wall" "-Wextra"
                      "-o" "ebc-dump-grab" "ebc-dump-grab.c")))
          (replace 'install
            (lambda _
              (install-file "ebc-dump-grab"
                            (string-append #$output "/bin")))))))
    (home-page "https://codeberg.org/wilkbook")
    (synopsis "PineNote EXTRACT_FBS grabber (debug kernel)")
    (description
     "Dump the rockchip_ebc driver's belief buffers (prev/next/final and
both phase planes) through the EXTRACT_FBS ioctl into an EBCDUMP1
container for host-side decoding (pinenote/tools/ebc-logic/ebc-dump) and
camera-vs-belief analysis.  Only functional on the linux-pinenote-debug
kernel; on the primary kernel the ioctl is stubbed and the tool exits
with a clear message.  Supports quiescence verification by double-dump
comparison (--verify) and partial dumps (--planes).")
    (license gpl2)))

(define-public pinenote-firmware-support
  (package
    (name "pinenote-firmware-support")
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
                  (modprobe (string-append out "/etc/modprobe.d"))
                  (waveform-script
                   (string-append bin "/pinenote-install-waveform"))
                  (params-script (string-append bin "/pinenote-apply-ebc-params"))
                  (config (string-append modprobe "/rockchip_ebc.conf")))
             (mkdir-p bin)
             (mkdir-p modprobe)
             (call-with-output-file waveform-script
               (lambda (port)
                 (display "#!/bin/sh\n" port)
                 (display "set -eu\n" port)
                 ;; shepherd one-shots run with an empty environment; the
                 ;; external tools below (dd, cp, mktemp, ...) need a PATH
                 ;; (first-light finding 2026-07-04: cat -> exit 127).
                 (display "export PATH=\"/run/current-system/profile/bin${PATH:+:$PATH}\"\n" port)
                 (display "primary_source=/dev/disk/by-partlabel/waveform\n" port)
                 (display "fallback_source=/state/firmware/ebc.wbf\n" port)
                 (display "destination=/lib/firmware/rockchip/ebc.wbf\n" port)
                 (display "destination_directory=/lib/firmware/rockchip\n" port)
                  (display "if [ -e \"$destination\" ] || [ -L \"$destination\" ]; then\n" port)
                  (display "  echo \"waveform already installed at $destination\"\n" port)
                  (display "  exit 0\n" port)
                  (display "fi\n" port)
                  ;; Mirror the initrd's udev-independent discovery: if the
                  ;; by-partlabel symlink is absent, scan sysfs for the
                  ;; partition named "waveform".
                  (display "find_waveform_partition() {\n" port)
                  (display "  for uevent in /sys/class/block/*/uevent; do\n" port)
                  (display "    [ -e \"$uevent\" ] || continue\n" port)
                  (display "    if grep -q '^PARTNAME=waveform$' \"$uevent\"; then\n" port)
                  (display "      device=/dev/$(basename \"$(dirname \"$uevent\")\")\n" port)
                  (display "      if [ -b \"$device\" ]; then\n" port)
                  (display "        printf '%s\\n' \"$device\"\n" port)
                  (display "        return 0\n" port)
                  (display "      fi\n" port)
                  (display "    fi\n" port)
                  (display "  done\n" port)
                  (display "  return 1\n" port)
                  (display "}\n" port)
                  (display "if [ -e \"$primary_source\" ]; then\n" port)
                  (display "  source=$primary_source\n" port)
                  (display "elif sysfs_source=$(find_waveform_partition); then\n" port)
                  (display "  source=$sysfs_source\n" port)
                  (display "elif [ -e \"$fallback_source\" ]; then\n" port)
                  (display "  if [ ! -f \"$fallback_source\" ] || [ -L \"$fallback_source\" ]; then\n" port)
                  (display "    echo 'fallback waveform source is not a regular file' >&2\n" port)
                  (display "    exit 1\n" port)
                  (display "  fi\n" port)
                  (display "  source=$fallback_source\n" port)
                  (display "else\n" port)
                  (display "  echo 'no waveform source found; not loading EBC panel firmware' >&2\n" port)
                  (display "  exit 1\n" port)
                  (display "fi\n" port)
                  (display "if [ -L \"$destination_directory\" ]; then\n" port)
                  (display "  echo 'waveform destination directory is a symlink' >&2\n" port)
                  (display "  exit 1\n" port)
                  (display "fi\n" port)
                  (display "mkdir -p -- \"$destination_directory\"\n" port)
                  (display "if [ ! -d \"$destination_directory\" ] || [ -L \"$destination_directory\" ]; then\n" port)
                  (display "  echo 'waveform destination directory is not a real directory' >&2\n" port)
                  (display "  exit 1\n" port)
                  (display "fi\n" port)
                  (display "temporary=$(mktemp \"$destination_directory/.ebc.wbf.XXXXXX\")\n" port)
                  (display "trap 'rm -f -- \"$temporary\"' EXIT HUP INT TERM\n" port)
                  (display "echo \"copying waveform from $source to $destination\"\n" port)
                  (display "if [ -b \"$source\" ]; then\n" port)
                  (display "  dd if=\"$source\" of=\"$temporary\" bs=1k count=2048 status=none\n" port)
                 (display "else\n" port)
                 (display "  cp --no-preserve=mode,ownership -- \"$source\" \"$temporary\"\n" port)
                  (display "fi\n" port)
                  (display "chmod -- 0644 \"$temporary\"\n" port)
                  (display "mv -- \"$temporary\" \"$destination\"\n" port)
                  (display "trap - EXIT HUP INT TERM\n" port)
                  (display "echo \"installed waveform at $destination\"\n" port)))
             (chmod waveform-script #o555)
             (call-with-output-file params-script
               (lambda (port)
                (display "#!/bin/sh\n" port)
                (display "set -eu\n" port)
                ;; see waveform-script: shepherd runs this with no PATH
                (display "export PATH=\"/run/current-system/profile/bin${PATH:+:$PATH}\"\n" port)
                (display "directory=/sys/module/rockchip_ebc/parameters\n" port)
                (display "if [ ! -d \"$directory\" ]; then\n" port)
                (display "  echo 'rockchip_ebc parameters are not available yet' >&2\n" port)
                (display "  exit 1\n" port)
                (display "fi\n" port)
                (display "parameter_matches() {\n" port)
                (display "  current=$1\n" port)
                (display "  desired=$2\n" port)
                (display "  case \"$desired:$current\" in\n" port)
                (display "    0:0|0:N|1:1|1:Y) return 0 ;;\n" port)
                (display "  esac\n" port)
                (display "  [ \"$current\" = \"$desired\" ]\n" port)
                (display "}\n" port)
                (display "set_parameter() {\n" port)
                (display "  name=$1\n" port)
                (display "  value=$2\n" port)
                (display "  path=$directory/$name\n" port)
                (display "  if [ ! -e \"$path\" ]; then\n" port)
                (display "    return 0\n" port)
                (display "  fi\n" port)
                (display "  current=$(cat \"$path\")\n" port)
                (display "  if parameter_matches \"$current\" \"$value\"; then\n" port)
                (display "    return 0\n" port)
                (display "  fi\n" port)
                (display "  printf '%s' \"$value\" > \"$path\"\n" port)
                (display "  current=$(cat \"$path\")\n" port)
                (display "  if parameter_matches \"$current\" \"$value\"; then\n" port)
                (display "    return 0\n" port)
                (display "  fi\n" port)
                (display "  echo \"EBC parameter $name stayed at $current, wanted $value\" >&2\n" port)
                (display "  exit 1\n" port)
                (display "}\n" port)
                (display "set_parameter direct_mode 0\n" port)
                (display "# auto_refresh=0 (2026-07-12, optics finding 10): the driver's\n" port)
                (display "# threshold-triggered auto-globals CORRUPT panel state (2x2 +\n" port)
                (display "# on-camera evidence, doc/refresh-policy.md); ioctl-fired globals\n" port)
                (display "# are clean, so userspace owns all full refreshes.\n" port)
                (display "set_parameter auto_refresh 0\n" port)
                (display "set_parameter refresh_threshold 60\n" port)
                (display "set_parameter split_area_limit 0\n" port)
                (display "set_parameter panel_reflection 1\n" port)
                (display "set_parameter prepare_prev_before_a2 0\n" port)
                (display "set_parameter dclk_select 0\n" port)
                ;; Global refreshes use GL16 (enum 6) instead of GC16:
                ;; decoded from the device's own waveform
                ;; (doc/refresh-policy.md), GL16 is GC16 minus the
                ;; white->white drive — the page background stays white
                ;; through a full wash instead of flashing to a negative
                ;; for ~220 ms, at identical duration and ghost-clearing
                ;; everywhere else.  Residue in believed-white pixels is
                ;; the one thing GL16 never scrubs; the reader-session
                ;; boot blank runs one deliberate GC16 deep clean to
                ;; cover the boot console, and a user-facing deep-clean
                ;; action can follow if hardware shows it accumulating.
                ;; This must live here, not on the kernel cmdline: the
                ;; initrd raw-loads the module, so module.param= tokens
                ;; never apply (hardware-confirmed 2026-07-05).
                (display "set_parameter refresh_waveform 6\n" port)))
            (chmod params-script #o555)
            (call-with-output-file config
              (lambda (port)
                (display "options rockchip_ebc direct_mode=0 auto_refresh=0 refresh_threshold=60 split_area_limit=0 panel_reflection=1 prepare_prev_before_a2=0 dclk_select=0 refresh_waveform=6\n" port)))))))
    (home-page "https://github.com/PNDeb/pinenote-debian-image")
    (synopsis "PineNote firmware helper scripts and EBC module options")
    (description
     "Install PineNote firmware support files without bundling private firmware
or waveform blobs.  The waveform helper copies the first 2 MiB of the local
waveform partition, or a state-file fallback, into the firmware path expected by
rockchip_ebc.  The
modprobe configuration records the PNDeb-derived conservative EBC module
options.  (The former /state/firmware/brcm Broadcom staging helper was retired
2026-07-04: the packaged firmware in the operating-system firmware field is
hardware-proven, making the runtime fallback dead code.)")
    (license gpl3+)))
