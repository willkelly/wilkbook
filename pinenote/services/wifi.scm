(define-module (pinenote services wifi)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (pinenote-wifi-service-type))

;; Phase 1 Wi-Fi bring-up for the reader flavor (doc/networking.md §4).
;;
;; Credentials live OUT OF BAND on the persistent `data' partition
;; (/dev/mmcblk0p7, label "data") — which survives an os2 reflash, unlike
;; the rootfs — exactly mirroring the waveform pattern: no SSID/PSK ever
;; enters the repo, the image, or the Guix store.  The file is placed once
;; over the USB serial console (the cdc-acm root path: no Wi-Fi needed to
;; configure Wi-Fi), then this one-shot associates on every boot.
;;
;; Every path is a graceful no-op: no data partition, no credential file,
;; or no wlan0 -> the reader still boots exactly as before.  That is what
;; keeps QEMU-virt (rung 4, no p7) and a credential-less device booting
;; cleanly, so this can be gated offline before any hardware session.
;;
;; The conf format is standard wpa_supplicant(5); Phase 2 (KOReader's own
;; Wi-Fi UI: device.lua hasWifiManager) will reuse the SAME file with a
;; ctrl_interface + update_config=1 so networks picked on-device persist.

;; Tools (wpa_supplicant, mount, rfkill) come from the system profile — the
;; reader flavor puts them there via its packages; shepherd one-shots run
;; with an empty environment, so PATH is set explicitly (the same lesson the
;; EBC boot scripts learned, firmware.scm).
(define %pinenote-wifi-up
  (computed-file
   "pinenote-wifi-up"
   #~(begin
       (call-with-output-file #$output
         (lambda (port)
           (display "\
#!/bin/sh
set -u
export PATH=\"/run/current-system/profile/bin${PATH:+:$PATH}\"

mnt=/run/pinenote-wifi
conf=\"$mnt/wifi/wlan0.conf\"

# Locate the persistent data partition (udev symlink first; sysfs scan as
# the udev-independent fallback, mirroring the waveform installer).
find_data_partition() {
  for d in /dev/disk/by-partlabel/data /dev/disk/by-label/data; do
    [ -e \"$d\" ] && { printf '%s\\n' \"$d\"; return 0; }
  done
  for uevent in /sys/class/block/*/uevent; do
    [ -e \"$uevent\" ] || continue
    if grep -q '^PARTNAME=data$' \"$uevent\"; then
      dev=/dev/$(basename \"$(dirname \"$uevent\")\")
      [ -b \"$dev\" ] && { printf '%s\\n' \"$dev\"; return 0; }
    fi
  done
  return 1
}

dev=$(find_data_partition) || { echo 'pinenote-wifi: no data partition; skipping'; exit 0; }
mkdir -p \"$mnt\"
mountpoint -q \"$mnt\" || mount -o ro \"$dev\" \"$mnt\" 2>/dev/null || {
  echo \"pinenote-wifi: could not mount $dev; skipping\"; exit 0; }

if [ ! -f \"$conf\" ]; then
  echo \"pinenote-wifi: no $conf; skipping (reader boots without Wi-Fi)\"
  umount \"$mnt\" 2>/dev/null || true
  exit 0
fi

# The radio can boot soft-blocked (CONFIG_RFKILL=m); best-effort unblock.
if command -v rfkill >/dev/null 2>&1; then rfkill unblock wifi 2>/dev/null || true; fi

# brcmfmac is SDIO-attached and coldplugs a beat after udev; wait for wlan0.
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ \"$i\" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
if [ ! -e /sys/class/net/wlan0 ]; then
  echo 'pinenote-wifi: wlan0 never appeared; skipping' >&2
  exit 0
fi

# wpa_supplicant brings wlan0 up itself and daemonizes (-B); dhcpcd leases.
if wpa_supplicant -B -i wlan0 -c \"$conf\"; then
  echo 'pinenote-wifi: wpa_supplicant started on wlan0 (dhcpcd will lease)'
else
  echo 'pinenote-wifi: wpa_supplicant failed to start' >&2
fi
exit 0
" port)))
       (chmod #$output #o555))))

(define (pinenote-wifi-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-wifi))
    ;; udev populates /dev/disk/by-partlabel/data and /sys/class/net/wlan0;
    ;; run after the root fs is mounted and userland is up.
    (requirement '(root-file-system udev user-processes))
    (documentation "Associate Wi-Fi from an out-of-band credential file on the persistent data partition; no-op when absent.")
    (one-shot? #t)
    (start
     #~(lambda _
         (zero? (system* #$%pinenote-wifi-up))))
    (stop #~(const #t)))))

(define pinenote-wifi-service-type
  (service-type
   (name 'pinenote-wifi)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-wifi-shepherd-service)))
   (default-value #f)
   (description "Bring up Wi-Fi on the reader from a credential file on the persistent data partition (mmcblk0p7), or no-op when none is present.  Credentials never enter the image or the store.")))
