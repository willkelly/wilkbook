# Wi-Fi and networking

The reading-first reader flavor has no way to join a network, and there is
no story for supplying Wi-Fi credentials without committing a secret. This
is the last open item on ROADMAP §4 and the gate in front of two concrete
goals: the on-device optics recorder (`pinenote/tools/optics/`), which must
drive the device "over the network," and general usefulness (syncing books,
reaching the reader without the UART/ACM cable).

This doc lays out the state of play, the option space with tradeoffs, a
credentials plan that respects the repo's "never commit/bundle per-device
secrets" culture, a concrete recommended approach with an implementation
sketch, and the short list of assumptions that only a hardware or os1-oracle
session can confirm. Everything below the "recommended approach" heading is
**design, not proven** — no networking userland has been booted on the
device yet.

Related docs: `doc/status.md` (hardware truth), `doc/kernel-forward-port.md`
(the Wi-Fi deblob history and the config), `doc/refresh-policy.md` +
`pinenote/tools/optics/README.md` (why the control channel matters),
`doc/hardware-deploy.md` (the os2 write protocol a credential file has to
live alongside).

## 1. State of play

### What is proven

The radio and firmware layer works. Verified in the repo and on hardware:

- **Chip / driver.** Broadcom BCM43455 over SDIO, driven by `brcmfmac`.
  The forward-port defconfig ships the full stack as modules:
  `CONFIG_BRCMFMAC=m`, `CONFIG_MAC80211=m`, `CONFIG_CFG80211=m`,
  `CONFIG_RFKILL=m` (all other WLAN vendors disabled). Bluetooth is a
  separate BCM4345C0 path (`CONFIG_BT=m`, `CONFIG_BT_HCIUART_BCM=y`).
  (`pinenote/patches/linux-pinenote-7.0-forward-port.patch`, defconfig
  hunk.)
- **Firmware loads on the 7.0 vanilla kernel** — hardware-confirmed
  2026-06-11: `brcmfmac` loaded `BCM4345/6 wl0 ... version 7.45.234`
  (`doc/status.md`). This is the payoff of moving the base off
  `linux-libre` to nonguix vanilla sources; the deblob pass had been
  gating firmware *loading*, not just omitting files
  (`doc/kernel-forward-port.md`, "Why the base is vanilla"). The firmware
  is packaged and shipped in the OS `firmware` field, not staged at
  runtime (`pinenote-broadcom-wifi-firmware` in
  `pinenote/packages/firmware.scm`; `%pinenote-firmware` in
  `pinenote/systems/base.scm`).
- **Firmware file names cover what brcmfmac asks for.** The package
  installs `brcmfmac43455-sdio.bin`, the device-specific alias
  `brcmfmac43455-sdio.pine64,pinenote-v1.2.bin`, the `.clm_blob`, and the
  `...pine64,pinenote-v1.2.txt` NVRAM — matching the request path the os1
  oracle showed (Debian requests the `pine64,pinenote-v1.2` name first,
  then falls back to the generic `brcmfmac43455-sdio.bin`;
  `doc/kernel-forward-port.md`).
- **Regulatory database is handled by the kernel, not CRDA/udev.** The
  config sets `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y`,
  `CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y`, and `#
  CONFIG_CFG80211_CRDA_SUPPORT is not set`, so the kernel loads the signed
  `regulatory.db` directly. `wireless-regdb` is already in
  `%pinenote-firmware` (`pinenote/systems/base.scm`), which puts
  `regulatory.db`/`regulatory.db.p7s` on the firmware path. So the
  regdomain *mechanism* is present; the regdomain still has to be
  *selected* (§6).

### What is absent

- **No connection userland on the reader.** The `reader` and `usb-console`
  flavors carry no supplicant, no DHCP client, and nothing that brings
  `wlan0` up. They reach the device only over UART (`ttyS2`) and the USB
  ACM gadget (`ttyGS0`) — and on the reader image the ACM console lands in
  the unprivileged `reader` shell, so even that is not a root control path
  (`doc/status.md`, 2026-07-05 unattended-boot note).
- **No credentials story.** Nothing supplies an SSID/PSK, and the repo
  culture forbids committing one (CLAUDE.md safety model; same rule as the
  waveform/VCOM).
- **No remote-access service.** `grep` across `pinenote/` finds no
  `openssh`, `dropbear`, `nginx`, `avahi`, or any listener. The device is
  currently unreachable over IP even if it associated.
- **The `networked` flavor is a size baseline, not a working join.** It
  already wires `dhcpcd-service-type` plus a D-Bus-free
  `wpa-supplicant-service-type` on `wlan0`
  (`pinenote/systems/pinenote-networked.scm`), but with **no config file
  and no credentials**, so wpa_supplicant starts and idles. It is also
  built on `slim` (no KOReader, no `%base-packages`), so it is not a
  deployable reader. Its purpose to date was closure measurement
  (`doc/pinenote-flavors.md`: "an initial Wi-Fi/DHCP size baseline ... no
  network credentials are embedded").

### os1 reference (the working stock system)

Stock Debian on os1 (6.12-pinenote) is the "everything works" oracle. What
is discernible from the repo about how it does networking: it drives the
same BCM43455 via `brcmfmac` with the same firmware request path
(`doc/kernel-forward-port.md`), and the PineNote community image lineage
(PNDeb, referenced throughout `firmware.scm`) is a wpa_supplicant world.
The runbook reaches os1 over SSH at a static-looking address
(`user@192.168.86.141`, `doc/hardware-deploy.md`) — evidence that a
wpa_supplicant + DHCP + OpenSSH stack is exactly what a PineNote runs
happily. What os1 actually uses for its supplicant/manager and its
interface name has not been harvested; that is a cheap os1-oracle check
(§6).

## 2. The options, with tradeoffs

Three decisions: the supplicant, the connection manager, and the DHCP
client. The controlling constraint is that this is a **headless,
single-SSID appliance** — KOReader as a kiosk, no desktop, no network
picker, a 4 GiB boot-slot budget (`doc/pinenote-flavors.md`), and a
deliberate **D-Bus-free release-slot policy** (same doc: "Slim, networked,
and minimal are service-level D-Bus-free bring-up targets").

### Supplicant: wpa_supplicant vs iwd

| | wpa_supplicant | iwd |
| --- | --- | --- |
| Fit with brcmfmac | The reference supplicant for this chip; what stock Debian/PNDeb use | Works with `mac80211` drivers but far less field history on this exact brcmfmac |
| Already integrated | Yes — `wpa-supplicant-service-type`, already in the `networked` flavor | New service integration; less common on Guix |
| Static single-SSID config | Trivial `wpa_supplicant.conf` | Needs `/var/lib/iwd/<ssid>.psk` files |
| D-Bus | Optional; `(dbus? #f)` already set | Talks to clients over D-Bus; standalone use is possible but less idiomatic |
| Built-in DHCP | No (needs a separate client) | Yes (can do DHCP itself) |
| Credentials-on-disk story | plaintext or PSK-hash in a conf file | its own `*.psk` store — arguably a *cleaner* provisioning target |

**Lean: wpa_supplicant.** It is the chip's reference supplicant, it is
already wired into a flavor, and a one-SSID appliance never exercises iwd's
advantages (roaming, agent UX). iwd's self-contained `*.psk` credential
store is genuinely attractive as a provisioning target and worth
reconsidering if we ever want on-device network management, but adopting it
now trades a proven path for a novel one to save little.

### Connection manager: what actually brings the link up

| Option | D-Bus | Closure cost | Fit for a 1-SSID headless appliance |
| --- | --- | --- | --- |
| `network-manager-service-type` | Yes (heavy) | Large (NM + GLib) | Overkill; roaming/UI logic we never use; violates the D-Bus-free policy |
| `connman-service-type` | Yes | Medium | Lighter than NM but still a daemon + D-Bus for a job that is one static network |
| `%base-services` static IP | No | Zero extra | Rigid (hard-coded IP); brittle across networks; fine only for a fixed lab LAN |
| **minimal `wpa-supplicant` + DHCP client** | No | Small | **Best fit** — exactly the appliance case, no D-Bus, already present |

**Lean: the minimal path.** `wpa-supplicant` (no D-Bus) associates,
`dhcpcd` gets a lease. This is precisely what `pinenote-networked` already
assembles; the only thing missing is credentials and a reason to run it on
the reader. NetworkManager/connman become the right answer only when a
future reader-*shell* needs a user-facing network picker (a §"Later" item,
consistent with `doc/pinenote-flavors.md`'s note that D-Bus stacks should
be added "deliberately when a concrete service needs it").

### DHCP client

`dhcpcd-service-type` (already chosen by the `networked` flavor) is a fine
default: it manages the interface, does v4+v6, and needs no static config.
Alternatives (`dhcp-client-service-type`/ISC dhclient, or a static address)
carry no advantage here. Keep `dhcpcd`.

## 3. The credentials problem

The rule (CLAUDE.md safety model): **never commit per-device secrets, never
bundle a generic one, fail visibly if absent rather than shipping a
default.** A Wi-Fi PSK is exactly this class of data, and there is an extra
wrinkle: the reader image is meant to be *shareable* — the optics tool's
whole premise is "portable to friends' PineNotes"
(`pinenote/tools/optics/README.md`). Baking one person's home PSK into the
distributed reader rootfs is doubly wrong.

The repo already has **two** established idioms for per-device data, and the
choice between them is the whole decision:

1. **Out-of-band file, consumed at boot** — the waveform pattern. The
   initrd copies the waveform from the device's own `waveform` partition,
   with a `/state/firmware/ebc.wbf` file fallback
   (`pinenote/images/pinenote-initramfs.scm`;
   `pinenote/packages/firmware.scm`). The secret never enters the repo or
   the image; it lives on the device.
2. **Build-time local staging, gitignored** — the fonts pattern.
   `pinenote-local-fonts` is `#f` on a fresh clone and only present when a
   licensed font is staged locally; the reader flavor folds it in only when
   non-`#f` (`pinenote/systems/pinenote-reader.scm`,
   `pinenote/packages/fonts.scm`). Convenient, but it **bakes the data into
   the world-readable store and the redistributable image**.

For a Wi-Fi PSK, pattern (2) is the wrong trade: the PSK would land in the
Guix store (readable by anything on-device), in the rootfs artifact staged
on os1, and in every copy of a "shareable" image. Pattern (1) keeps it off
the image entirely.

**Recommendation: an out-of-band credential file on a persistent
location, consumed by a first-boot provisioning one-shot.** Concretely:

- Store credentials at `/state/wifi/wlan0.conf` (mode `0600`), mirroring
  the existing `/state/firmware/ebc.wbf` fallback path exactly. `/state`
  should be a **persistent partition that survives os2 reflashes** — the
  natural candidate is the existing `data` partition (`/dev/mmcblk0p7`,
  label `data`, `doc/device-runbook.md`) or a dedicated `PNGuixState`
  partition (the label is already reserved in
  `pinenote/images/pinenote-partitions.scm` and documented, no-op, by
  `pinenote/services/state.scm`). Putting it on a persistent partition,
  rather than inside the rootfs, means re-flashing the reader never wipes
  the Wi-Fi config and the byte-exact readback-SHA of the os2 write
  (`doc/hardware-deploy.md`) is undisturbed.
- The file is placed **once**, out of band, from os1 over SSH (the same
  trusted channel the deploy protocol already uses) — never through the
  build.
- **Store the PSK hash, not the passphrase.** `wpa_passphrase <ssid>
  <pass>` emits the 256-bit `psk=` form; use that in the conf so the
  plaintext passphrase is not at rest. (Defense in depth only — anyone with
  the hash can still join — but it costs nothing and matches the "don't
  leave secrets lying around" posture.)
- The same mechanism carries the SSH authorized key
  (`/state/ssh/authorized_keys`) and, ideally, persistent SSH **host** keys
  (`/state/ssh/host/`), so the device's identity survives a reflash and the
  image stays generic (§5, §6).

Fallback for a single personal device that does not want to bother with a
`/state` partition yet: a gitignored build-time local module (the fonts
pattern, `#f` on a fresh clone) is *acceptable for your own device* as long
as it is understood that the image then contains the PSK and must not be
shared. Recommend the `/state` file as the default and document the
build-time-local option as the explicit "personal, non-shareable" shortcut.

## 4. Recommended approach + implementation sketch

> **UNPROVEN — for review.** None of the Scheme below has been built or
> booted. Field names and service wiring need a `make` gate and a hardware
> session. It is a sketch of intent, in ladder order (builds → QEMU where
> meaningful → hardware).

**Where it goes:** add networking to the **reader** flavor, gated so it is a
no-op when credentials are absent (the fonts pattern) — the reader is the
image we actually deploy, and it is what the optics recorder needs to be
reachable. Keep the standalone `networked` flavor as the size baseline.
(Alternatively a `reader-networked` variant if we want a networking-free
reader to stay buildable; a boolean on the reader OS constructor is
simpler.)

**Services to add to the reader flavor:**

1. A DHCP client on `wlan0` — `dhcpcd-service-type` (as in `networked`).
2. Wi-Fi association reading the out-of-band conf. Two shapes:
   - *Idiomatic-but-leaky:* the stock `wpa-supplicant-service-type` with a
     `config-file` — **rejected for the secret path**, because the stock
     service references its config-file as a store item, which would pull
     the PSK into the store. Fine only for a non-secret (open) network.
   - *Recommended:* a small custom shepherd service
     (`pinenote-wifi-service-type`) that waits for `wlan0`, checks
     `/state/wifi/wlan0.conf` exists and is `0600`, and execs
     `wpa_supplicant -i wlan0 -c /state/wifi/wlan0.conf`. No secret ever
     touches the store; absent file → the service logs and exits (no-op,
     device still boots to KOReader).
3. A remote-access listener — `openssh-service-type`, **key-only**
   (`(password-authentication? #f)`), reading the authorized key from
   `/state` and using persistent host keys from `/state` (see §3). This is
   the control channel §5 needs. Consider `dropbear-service-type` instead
   if closure size matters against the 4 GiB budget — dropbear is much
   smaller; OpenSSH is what os1 already speaks, so it is the lower-surprise
   default.

Sketch (schematic — names/fields to verify against the installed Guix):

```scheme
;; pinenote/services/wifi.scm  — UNPROVEN sketch
(define pinenote-wifi-conf "/state/wifi/wlan0.conf") ; out-of-band, 0600

(define (pinenote-wifi-shepherd-service _config)
  (list
   (shepherd-service
    (provision '(pinenote-wifi))
    (requirement '(udev user-processes))       ; wlan0 present after coldplug
    (respawn? #t)
    (start
     #~(lambda _
         ;; no credentials staged -> boot the reader anyway, just no net
         (if (and (file-exists? #$pinenote-wifi-conf))
             (fork+exec-command
              (list #$(file-append wpa-supplicant "/sbin/wpa_supplicant")
                    "-i" "wlan0" "-c" #$pinenote-wifi-conf))
             (begin (format #t "pinenote-wifi: ~a absent; skipping~%"
                            #$pinenote-wifi-conf)
                    #f))))
    (stop #~(make-kill-destructor)))))
```

```scheme
;; in pinenote/systems/pinenote-reader.scm  — UNPROVEN, added to services
(service pinenote-wifi-service-type)
(service dhcpcd-service-type)                      ; already used by `networked`
(service openssh-service-type
         (openssh-configuration
          (password-authentication? #f)
          (authorized-keys `(("root" ,(local-file "…"))))  ; better: read /state
          ;; point AuthorizedKeysFile / HostKey at /state for a generic,
          ;; reflash-surviving image (see §3)
          (extra-content "AuthorizedKeysFile /state/ssh/authorized_keys")))
```

Example `/state/wifi/wlan0.conf` (placed out of band, never committed):

```
country=US
network={
    ssid="MyNetwork"
    psk=<64-hex-from-wpa_passphrase>   # hash, not plaintext
}
```

**Minimal path to "reader joins a known Wi-Fi on boot and is reachable":**

1. Add `pinenote-wifi-service-type` + `dhcpcd` + `openssh` to the reader
   flavor (gated no-op when `/state` is empty).
2. Gate offline: `make` the reader flavor; run the QEMU-virt boot assertion
   (rung 4) to confirm the new services don't break Shepherd ordering.
   Wi-Fi association itself can't be proven on virt (no radio) — assert the
   services *start* and the reader still comes up.
3. On os1 over SSH: mount the persistent partition, write
   `/state/wifi/wlan0.conf` (`0600`, PSK-hash) and
   `/state/ssh/authorized_keys`; confirm the partition survives an os2
   reflash.
4. Hardware session: boot os2, confirm `wlan0` associates, gets a DHCP
   lease, and answers SSH on the key. Harvest the association dmesg and
   `iw`/`ip` output for the doc.

## 5. How this unblocks the optics recorder

The optics recorder's "next in build order" is explicit
(`pinenote/tools/optics/README.md`): *an on-device scenario player that
drives the test epub through KOReader (or raw `/dev/fb0`) **over the
network**, flips `rockchip_ebc` params per run, emits the sync pattern, and
logs timestamps + params.* Networking is the "over the network" precondition;
everything the player needs to actuate already exists on the device.

**Recommended control channel: SSH.** It gives the exact remote-exec surface
the player needs with zero new on-device code, key-auth security, and it is
the same channel the os1 oracle already uses. The player, running on the
capture host, drives the device by SSH-executing against surfaces that are
already there:

- **Drive the reader / draw pages:** run KOReader (the `reader-session`
  service) or write frames straight to `/dev/fb0` (proven reachable via
  deferred-io, `doc/status.md` first-light; `pinenote-ebc-test
  --draw-smoke` is a working reference).
- **Flip refresh params per run:** write
  `/sys/module/rockchip_ebc/parameters/*` — the exact knobs the
  `pinenote-ebc-params` one-shot already sets (`refresh_waveform`,
  `refresh_threshold`, `auto_refresh`, …; `pinenote/packages/firmware.scm`).
- **Trigger a global refresh:** the `GLOBAL_REFRESH` ioctl
  (`0xC0016440` on `/dev/dri/card0`), packaged as `pinenote-ebc-refresh`
  and hardware-validated 2026-07-04 (`pinenote/packages/ebc-test.scm`,
  `doc/status.md`). No compiled tool needed; it's a Guile FFI one-liner.
- **Harvest results:** pull `/var/log/reader-session.log` (the
  `[pn-refresh]` trace the phase-B workbench already consumes) back over
  SSH/`scp`.

A tiny HTTP trigger endpoint is *not* needed first — SSH covers the whole
matrix and is more flexible. An HTTP endpoint (or the `org.pinenote.ebc`
D-Bus service the ROADMAP tracks for community compatibility) is a later
nicety if unattended scripted runs want a narrower API.

**Complementary zero-credential channel: a USB ethernet gadget.** For our
*own* tethered optics sessions (and as a console-less debug path the ROADMAP
already wants — §2 "ECM/RNDIS ethernet gadget alongside the ACM console"),
a CDC-ECM gadget over the USB-C cable gives a reachable device with **no
Wi-Fi credentials at all** — ideal when the operator is right there with a
camera. Caveat found while writing this: the config currently has
`# CONFIG_USB_CONFIGFS_ECM is not set` (and `_ECM_SUBSET` off) in the
defconfig, so this needs a config addition plus an ECM gadget service
alongside the existing ACM one (`pinenote/services/usb-gadget.scm` is the
model). Wi-Fi remains the answer for untethered use and for friends'
devices; USB-ECM is the reliable tethered fallback.

## 6. What needs a hardware / os1-oracle check to validate

Everything in §§2–5 is offline reasoning. These assumptions can only be
confirmed on the device (cheap os1-oracle checks first, then an os2
session):

- **os1 reference (os1 oracle, read-only):** what supplicant and DHCP
  client stock Debian actually runs, and — crucially — the **interface
  name** it gives the BCM43455 (`ip link` / `iw dev`). The sketches assume
  `wlan0`; modern predictable-naming could differ, and Guix's own udev
  naming needs its own confirmation.
- **Association, not just firmware load.** Firmware/module load is proven
  (2026-06-11); that the module *associates* with a real AP under our
  chosen wpa_supplicant on the 7.0 kernel is not. This is the headline
  unknown.
- **Module autoload path.** brcmfmac is SDIO-attached and should coldplug
  via udev modalias, but Guix's kmod does not honor `LINUX_MODULE_DIRECTORY`
  and only the kernel *profile* carries `modules.dep`
  (`doc/kernel-forward-port.md`, hard-won lessons) — the same trap that
  broke gadget modprobes. Confirm `wlan0` appears without a manual
  `modprobe -d /run/booted-system/kernel brcmfmac`.
- **Regdomain / country.** The signed-regdb mechanism is present but the
  regdomain must be *set* (the `country=` line, or `iw reg set`). Verify the
  regdomain applies and that the intended channels/bands (esp. 5 GHz) are
  permitted.
- **rfkill soft-block.** With `CONFIG_RFKILL=m`, the radio may come up
  soft-blocked; check whether `rfkill unblock wifi` is needed at boot.
- **MAC address stability.** brcmfmac without a per-device MAC in NVRAM can
  present a random/locally-administered MAC per boot, which breaks DHCP
  reservations and any allow-listing. Confirm the shipped
  `...pine64,pinenote-v1.2.txt` NVRAM yields a stable MAC (or plan to pin
  one).
- **DHCP + reachability end to end.** Lease acquisition on `wlan0`, and SSH
  reachable on the key from the capture host.
- **SSH identity persistence.** Confirm host keys and authorized_keys read
  from `/state` survive an os2 reflash (the whole point of putting them on a
  persistent partition); otherwise every reflash changes the host
  fingerprint and re-locks the operator out.
- **/state partition reality.** `/state` is currently aspirational — the
  state service is a documented no-op and nothing mounts a `PNGuixState`
  partition today. Decide and validate the actual mount (reuse `data`
  p7, or create `PNGuixState`) before the credential file has a home.
- **(If pursued) USB-ECM gadget.** The defconfig change
  (`CONFIG_USB_CONFIGFS_ECM`) and an ECM gadget service are unbuilt and
  unproven; the RK3566 OTG role/`ep0out` history (`doc/status.md`) means the
  ECM path deserves the same bracketing the ACM path got.
