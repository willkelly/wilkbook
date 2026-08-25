# Wi-Fi and networking

The reading-first reader flavor now joins Wi-Fi from a per-device credential
file on the persistent `data` partition and exposes a key-only root SSH
endpoint. Association, DHCP, SSH, and `scp` were hardware-proven on
2026-07-24. This document preserves the option analysis that led to that
implementation and records the remaining work, including on-device network
selection and persistent SSH identity across reflashes.

This doc lays out the state of play, the option space with tradeoffs, a
credentials plan that respects the repo's "never commit/bundle per-device
secrets" culture, a concrete recommended approach with an implementation
sketch, and the short list of assumptions that only a hardware or os1-oracle
session can confirm. Resolved hardware questions are labelled with their
validation date; unlabelled items in §6 remain open.

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

### What Phase 1 added

- **Connection userland on the reader.** The reader flavor carries the
  one-shot `pinenote-wifi` service, `wpa_supplicant`, and `dhcpcd`; together
  they bring up `wlan0` when a credential file is present (§4.1).
- **A credentials story without repository secrets.** The service reads a
  mode-0600 PSK-hash configuration from the persistent `data` partition. No
  SSID, passphrase, or per-device credential is committed or bundled.
- **Remote access.** The current reader image exposes key-only root OpenSSH;
  association, DHCP, SSH, and `scp` were hardware-proven on 2026-07-24.
  Since 2026-08-06 the authorized key is **no longer baked into the
  image**: it is installed at every boot from
  `/data/ssh/authorized_keys` on the persistent data partition (§4.1),
  the same out-of-band channel as the Wi-Fi credentials.
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
(recorded in the `doc/device-runbook.md` ledger) — evidence that a
wpa_supplicant + DHCP + OpenSSH stack is exactly what a PineNote runs
happily. os1's manager stack has since been inventoried
(`doc/device-runbook.md`, 2026-06-10): D-Bus + NetworkManager driving
`wpa_supplicant`. Its exact interface name was never harvested, but the
question is moot for us — the reader image's own naming yields `wlan0`,
hardware-proven 2026-07-10 (§6).

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
  image stays generic (§5, §6). *[Both implemented 2026-08-06 — as
  `/data/ssh/authorized_keys` and `/data/ssh/host/`, `/data` being
  where the shipped image mounts the data partition; see §4.1.]*

Fallback for a single personal device that does not want to bother with a
`/state` partition yet: a gitignored build-time local module (the fonts
pattern, `#f` on a fresh clone) is *acceptable for your own device* as long
as it is understood that the image then contains the PSK and must not be
shared. Recommend the `/state` file as the default and document the
build-time-local option as the explicit "personal, non-shareable" shortcut.

## 4. Historical design sketch (superseded by §4.1)

> **Historical, not current status.** This was the pre-implementation review
> sketch. The implemented and hardware-proven Phase 1 design starts at §4.1;
> code below is retained only to show the decisions considered beforehand.

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
   `/state` *(implemented 2026-08-06, §4.1)* and using persistent host
   keys from `/state` *(implemented 2026-08-06, §4.1)* (see §3). This is
   the control channel §5 needs. Consider `dropbear-service-type` instead
   if closure size matters against the 4 GiB budget — dropbear is much
   smaller; OpenSSH is what os1 already speaks, so it is the lower-surprise
   default.

Sketch (schematic — names/fields to verify against the installed Guix):

```scheme
;; pinenote/services/wifi.scm  — historical pre-implementation sketch
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
;; in pinenote/systems/pinenote-reader.scm  — historical sketch
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
   `/state/ssh/authorized_keys` *(implemented 2026-08-06 as
   `/data/ssh/authorized_keys`)*; confirm the partition survives an os2
   reflash.
4. Hardware session: boot os2, confirm `wlan0` associates, gets a DHCP
   lease, and answers SSH on the key. Harvest the association dmesg and
   `iw`/`ip` output for the doc.

### 4.1 Phase 1 — implemented (2026-07-10), hardware-proven 2026-07-24

The Wi-Fi userland now ships on the **reader** flavor and is gated through
`guix system build pinenote-reader` (derivation graph sound) with the boot
script `sh -n` + shellcheck clean and its no-op path verified. Association,
DHCP, key-only root SSH, and `scp` are hardware-proven on the current reader
image (2026-07-24; §6 and `doc/status.md`).

- `pinenote/services/wifi.scm` — `pinenote-wifi-service-type`, a one-shot
  that runs a boot script (a `computed-file`, so no secret and no edit to the
  rebase-fragile `firmware.scm`). It finds the persistent `data` partition
  (`/dev/disk/by-partlabel/data`, sysfs `PARTNAME=data` fallback), mounts it
  read-only, and if `…/wifi/wlan0.conf` exists: `rfkill unblock` (best-effort),
  waits for the SDIO-coldplugged `wlan0`, then `wpa_supplicant -B -i wlan0 -c
  <conf>`. **Every missing piece is a graceful no-op** — no partition, no conf,
  or no `wlan0` and the reader boots exactly as before (which is what keeps
  QEMU-virt and a credential-less device booting cleanly).
- `pinenote/systems/pinenote-reader.scm` — adds `pinenote-wifi-service-type`
  + `dhcpcd-service-type` to the services and `wpa-supplicant` (brings
  `wpa_supplicant` **and** `wpa_cli` into the profile — Phase 2 needs the
  latter) to the packages.
- **The SSH authorized key comes from the data partition** (implemented
  2026-08-06; previously baked into the image, the "generic, shareable
  image" gap §3 warned about). `pinenote-ssh-authorized-keys-service-type`
  (`pinenote/services/ssh-keys.scm`) is a boot one-shot that copies
  `/data/ssh/authorized_keys` over `/root/.ssh/authorized_keys` (0600,
  root-owned) every boot — so the key survives os2 reflashes (`/root`
  does not, `/data` does), the image contains no per-operator state, and
  a hand edit of `/root/.ssh/authorized_keys` is overwritten at the next
  boot (edit `/data/ssh/` instead). Deleting the file on a *mounted*
  `/data` revokes the installed key at the next boot; an unmounted
  `/data` (virt, transient mount failure) leaves the last-installed key
  alone so a mount hiccup can never lock SSH out. CRs are stripped
  during install, so a key file edited on Windows still parses.
  The copy is deliberately scoped to
  root: pointing sshd's `AuthorizedKeysFile` at a shared non-`%u` path
  would authorize the same keys for the `reader` user (which has
  passwordless sudo). With no staged key the device boots normally and
  root SSH is simply unreachable — the ACM/UART consoles remain the way
  in, and a key can be appended over the CDC-ACM console's passwordless
  `sudo` shell (write it to `/data/ssh/authorized_keys` so it persists).
  Stage the key the same way as the Wi-Fi credentials (provisioning
  note below):

  ```sh
  sudo mkdir -p /data/ssh
  printf '%s\n' 'ssh-ed25519 AAAA… you@host' | sudo tee /data/ssh/authorized_keys
  ```

  **Persistent host keys** (same one-shot, same partition): `/etc/ssh`'s
  `ssh_host_*_key` files are synchronized with `/data/ssh/host/` as a
  union in which `/data` wins per key type — every reflash's freshly
  generated keys are overwritten by the persistent identity, and any
  type missing from `/data` (first boot, or a future Guix adding a key
  type) is seeded into it. A key that fails an `ssh-keygen -y` validity
  check (empty, truncated, garbage) is never installed in either
  direction — the boot log says so and the one-shot exits nonzero — and
  seeds are `sync`ed so a power cut cannot persist a truncated
  identity; an invalid file already on `/data` is re-seeded over from
  the valid `/etc/ssh` key, so persistence self-heals. No valid key
  *file* is ever deleted from `/etc/ssh` (only crash-orphaned temps and
  directories squatting on key paths), so
  there is no keyless window even on failure, and sshd runs inetd-style
  (a fresh sshd per connection) so no ordering against the listener is
  needed. Host-key deletion is not revocation: to rotate the device
  identity, delete the type from both `/data/ssh/host/` and `/etc/ssh`
  and reboot. Exposure tradeoff, accepted: host *private* keys sit
  0600 root-owned on the shared unencrypted p7 (which os1 mounts at
  `/home`) — the same class as the Wi-Fi PSK hash already staged there,
  on a single-trust-domain device whose console users have passwordless
  sudo anyway.

  Offline evidence (2026-08-06): reader closure builds; the built
  sshd_config honors `.ssh/authorized_keys` and carries no `HostKey`
  override; the image's `/etc` carries no authorized key; the one-shot
  is in the shepherd graph; the exact store script passed sandboxed
  seed / restore-after-reflash / union / revocation / CRLF /
  failure-injection runs. Hardware-unproven until the next deployed
  image — see the migration note in `doc/status.md`.

**Provisioning (once, over the USB serial console — no Wi-Fi required).** The
reader user has passwordless `sudo` (its sudoers), so this works over the
cdc-acm console or the UART. Write the credential file to the `data` partition
(survives os2 reflashes), storing the **PSK hash**, not the passphrase:

```sh
# hash the passphrase (use the psk= hex line; discard the #psk= plaintext):
wpa_passphrase "YourSSID" "your-passphrase"

# then, on the device:
sudo mount /dev/disk/by-partlabel/data /mnt
sudo mkdir -p /mnt/wifi
sudo tee /mnt/wifi/wlan0.conf >/dev/null <<'EOF'
ctrl_interface=/run/wpa_supplicant
update_config=1
country=US
network={
    ssid="YourSSID"
    psk=<64-hex-from-wpa_passphrase>
}
EOF
sudo chmod 600 /mnt/wifi/wlan0.conf
sudo umount /mnt
sudo herd start pinenote-wifi          # or reboot
```

`ctrl_interface` + `update_config=1` are inert for Phase 1 but are what
Phase 2 (KOReader's own Wi-Fi UI) drives `wpa_cli` against, so networks you
later pick *on-device* are written back to this same file and persist.

## 5. How this unblocks the optics recorder

**Update (2026-07-10):** the recorder is no longer *blocked* on Wi-Fi. Its
device-driving is now factored into a Transport × RenderBackend matrix
(`pinenote/tools/optics/driver.py`), and the **`SerialTransport` over the USB
CDC-ACM console drives a real capture tethered, today, with no network at
all** — the device in the camera box is reachable over the same USB-C cable
that powers it, via the `/dev/ttyGS0` shell `usb-gadget.scm` already exposes.
Wi-Fi/`SSHTransport` is the answer for **friends' devices and untethered use**.
The key-only `root@` endpoint, `scp` round-trip, association, DHCP, and host
reachability are hardware-proven on the current reader image (2026-07-24; see
`doc/status.md`). The KOReader-vs-framebuffer
backend split (measuring KOReader's own influence on the optics) is orthogonal
to the transport. The rest of this section describes the SSH channel that
`SSHTransport` now targets.

The optics recorder's SSH path is the "over the network" surface;
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
  (`0xC0016440` on the EBC's DRM card node, resolved by
  `DRIVER=rockchip-ebc` in sysfs — the index is not stable across
  images), packaged as `pinenote-ebc-refresh`. The ioctl itself is
  hardware-validated 2026-07-04; the by-driver-name resolution is
  2026-08-25 and offline-proven only (`pinenote/packages/ebc-test.scm`,
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

## 6. Hardware / os1-oracle validation ledger

Sections 2–3 preserve the design reasoning; §4 records the implementation,
§5 its recorder use, and §7 the clock (issue #27). Resolved checks below carry dates and evidence links. The
remaining unlabelled checks — regdomain selection, SSH identity
persistence, the `/state` partition, and the USB-ECM gadget — are the open
ledger and still need a decision or an os2 session:

- **os1 reference — RESOLVED (2026-06-10 inventory; naming question moot
  2026-07-10).** os1's supplicant/manager are inventoried in
  `doc/device-runbook.md` ("Active integration services: D-Bus,
  NetworkManager, `wpa_supplicant`, …" — NetworkManager also supplies its
  own DHCP). os1's exact interface name was never read out, and no longer
  needs to be: the sketches' `wlan0` assumption was validated on our own
  image — the reader's udev naming yields `wlan0`, hardware-proven
  2026-07-10 (`doc/status.md`).
- **Association — RESOLVED 2026-07-10.** The radio associates *and* completes
  WPA (DHCP lease + ping) — but only with **`brcmfmac.feature_disable=0x82000`**.
  Without it, the Apr-2021 BCM4345/6 firmware mis-negotiates its WPA offloads
  with wpa_supplicant 2.11 (the reader ships 2.11; Debian os1 has 2.10) and the
  firmware-side 4-way handshake times out on both WPA2-PSK and WPA3-SAE. A known
  brcmfmac bug (Red Hat #2302577, raspberrypi/linux #4976), fixed via the module
  option in the `pinenote-wifi` service + kernel cmdline (A.2.4). Full evidence:
  `doc/status.md` (2026-07-10). The stuck-WORLD-regdomain / `set_channel reason
  -52` symptoms were benign red herrings.
- **Module autoload path — RESOLVED 2026-07-10.** brcmfmac coldplugs via
  udev modalias and `wlan0` appears with no manual `modprobe` on the
  reader image (`doc/status.md`, 2026-07-10: "`wlan0` autoloads"). The
  reason this was worth checking — Guix's kmod does not honor
  `LINUX_MODULE_DIRECTORY` and only the kernel *profile* carries
  `modules.dep` (`doc/kernel-forward-port.md`), the same trap that broke
  gadget modprobes — did not bite here.
- **Regdomain / country.** The signed-regdb mechanism is present but the
  regdomain must be *set* (the `country=` line, or `iw reg set`). Verify the
  regdomain applies and that the intended channels/bands (esp. 5 GHz) are
  permitted.
- **rfkill soft-block — RESOLVED 2026-07-10.** The radio comes up
  unblocked (`doc/status.md`, 2026-07-10: "`wlan0` autoloads, is
  unblocked, scans"), and the `pinenote-wifi` service does a best-effort
  `rfkill unblock` anyway (§4.1), so a future soft-block cannot strand a
  boot.
- **MAC address stability — RESOLVED 2026-07-10.** The shipped
  `...pine64,pinenote-v1.2.txt` NVRAM yields a stable MAC
  (`doc/status.md`, summary table: "wlan0 autoloads, unblocked, stable
  MAC, scans 6 APs").
- **DHCP + reachability end to end — RESOLVED 2026-07-24.** Lease acquisition
  on `wlan0`, key-only `root@` SSH, and an `scp` round-trip are hardware-proven
  from the capture host; exact evidence is in `doc/status.md`.
- **SSH identity persistence — IMPLEMENTED IN TREE 2026-08-06,
  hardware-unproven.** Both halves now persist on `/data`: the
  authorized key is installed from `/data/ssh/authorized_keys` every
  boot, and host keys are synchronized with `/data/ssh/host/` (union,
  `/data` winning per key type — §4.1). Remaining validation, at the
  next deployed image: confirm on hardware that the fingerprint is
  stable across an os2 reflash. Note the fingerprint changes **once
  more** at the first boot of the first deployed image that carries the
  sync (fresh keys are generated, then seeded) — pin the new
  fingerprint in your ledger then. The v3 image (see `doc/status.md`,
  the 2026-08-06 entries) written to os2 on 2026-08-06 predates the sync: its first boot changes the fingerprint
  without persisting it.
- **/state partition reality — RESOLVED (reuse `data` p7).** The reader
  flavor mounts p7 rw at `/data` (books, Wi-Fi credentials, SSH state
  all live there); no `PNGuixState` partition was ever created, and the
  state service (`pinenote/services/state.scm`) remains a documented
  no-op. The design's `/state/…` paths read as `/data/…` in the shipped
  image.
- **(If pursued) USB-ECM gadget.** The defconfig change
  (`CONFIG_USB_CONFIGFS_ECM`) and an ECM gadget service are unbuilt and
  unproven; the RK3566 OTG role/`ep0out` history (`doc/status.md`) means the
  ECM path deserves the same bracketing the ACM path got.
- **Time from the network — IMPLEMENTED IN TREE (issue #27),
  hardware-unproven, and SHIPPED INERT.** The shape questions are
  answered and the code exists: `pinenote/services/timesync.scm` +
  `pinenote/tools/timesync/timesync.lua`, described in §7 below. The
  reader flavor carries the service with **no servers configured**, so
  the shipped image still makes no outbound connection and the clock is
  still whatever the RTC holds — configuring a server is a deliberate,
  documented act. Rung 1 is green (`make timesync-check`: verbatim
  protocol/policy extraction plus a real loopback round trip against the
  daemon) and the reader system evaluates both with and without a server
  configured. **Nothing has been booted and no clock has been set on a
  device.** Remaining validation, at the next deployed image with a
  server configured: that a step actually lands, that `hwclock --systohc`
  succeeds against `rtc0`, that the interval-preserving alarm re-arm
  behaves as reasoned, and that a device with no Wi-Fi shows exactly one
  log line and no further activity.

## 7. Time from the network (issue #27)

The build-time timezone landed with issue #6; **the clock itself did
not**. The RTC was the only source, and every method this project
reconstructs a session with is a timestamp — dated `doc/status.md`
entries, the auto-suspend daemon's per-resume `charge_now` series (the
2026-08-15 soak's entire result is that series divided by its own
intervals), the `[pn-refresh]` traces whose analysis is inter-arrival
times, the post-mortem log harvest in `doc/device-access.md`. A drifted
or reset RTC does not announce itself. It makes all of that read
*plausibly* wrong, which is worse than reading obviously wrong.

`pinenote-timesync` is the answer. It is deliberately small: one LuaJIT
SNTP client (`pinenote/tools/timesync/timesync.lua`) under the same
interpreter the reader and the auto-suspend daemon already run, wrapped
by a Guix service with a configuration record. It adds **nothing** to the
image closure — no `ntp`, no `chrony`, no `openssl` — and its protocol
and policy logic is extracted verbatim by the rung-1 suite.

### 7.1 The five decisions

**One-shot or daemon?** A daemon, shaped like a one-shot that re-arms.

A *boot* one-shot is far too rare to be useful: measured 2026-08-24, this
device's uptime was 831901 s (9.6 days), so "once per boot" means "about
once a fortnight, if Wi-Fi happened to be up in the first minute of it".

A one-shot at `wpa_supplicant` CONNECTED is the right instinct — Wi-Fi
dies across ultra suspend (`vcca_1v8_pmu` feeds VCCIO4) and the card
re-associates on every resume, so association is naturally frequent. It
fails on two counts. The only exec hook `wpa_supplicant` offers is
`wpa_cli -a`, which needs a `ctrl_interface`; §4.1's provisioning recipe
does set one, but that file is **operator data on the data partition**,
not ours, and a device provisioned by hand or before that line existed
will not have it — a clock that silently works only on
correctly-provisioned devices is exactly the failure mode this repo keeps
writing gates against. And decisively: CONNECTED fires *before* DHCP, so
anything hanging off it has to wait for a route anyway. "One-shot at
association" therefore collapses into "something that waits for a usable
route", which is what the daemon is, minus the dependency on a file we do
not own.

What it is *not* is an NTP daemon. It does not discipline the clock, keep
a drift file, or touch adjtime. At a ~1.5 % awake duty cycle (2026-08-24:
uptime 831901 s against a newest printk timestamp of 12619 s; printk stops
across suspend, so the difference is awake time) disciplining is
meaningless — the thing being disciplined is asleep 98.5 % of the time and
its oscillator is the RTC's regardless. It **steps** an unanchored clock
and says so, in the log and in `/dev/kmsg`, so that a later analyst reading
a discontinuity in a trace can *see* the step instead of inferring it.

**Which servers?** None, by default, and the default is the decision.
This image otherwise makes no outbound connections; adding a public pool
silently would change what the device does on someone's network without
anyone choosing it. The `servers` field is an ordinary Guix service
configuration field:

```scheme
(service pinenote-timesync-service-type
         (pinenote-timesync-configuration
          (servers '("192.168.1.1"))))
```

The recommendation is a server on the LAN you already chose to join — a
router almost always is one. An IPv4 literal takes the `inet_pton` path,
so the daemon generates no DNS traffic either; a hostname goes through
`getaddrinfo` and does. `pool.ntp.org` works and is a perfectly
reasonable choice; it is simply not one the image makes for you.

*Considered and rejected as a default:* taking the server from the DHCP
lease (option 42). Convenient, and exactly the silent implicit
destination this issue exists to avoid — the device would talk to
whatever host the network nominated, chosen by nobody. A future
`dhcp-servers?` field could offer it as an explicit opt-in.

**No Wi-Fi at all** — the common case — is free and silent, and that is a
*power-safety* property, not a nicety. Ultra suspend measures 5.47 mA
idle standby and the hourly RTC backstop alone accounts for ~0.83 mA of
it (`doc/artifacts/pinenote-ultra-soak-20260815/`), so a daemon that
forced wakes or retried hard would spend from a budget a 6.17-day soak
had to be run to establish. Concretely:

- every wait is `poll(NULL, 0, ms)` — a CLOCK_MONOTONIC timeout, which is
  **not a wakeup source** and does not advance across suspend. The daemon
  is frozen with everything else and resumes mid-wait. A consequence
  worth naming: the poll interval is therefore in *awake* seconds, so at
  a 1.5 % duty cycle a 120 s poll is roughly one check every two hours of
  wall time and several per session in which the device is being read —
  it looks for a network exactly when one is likely to be there;
- `/proc/net/route` is read before any socket is opened, and a
  loopback-only table is "no network". With no Wi-Fi a poll is two file
  reads;
- a configured server that does not answer backs off `poll` → 2× → … →
  cap (default 1 h). That is the whole of "must not retry-loop itself
  awake";
- with **no servers** the process logs one line and exits, which is why
  the shepherd service sets `respawn? #f`.

**Does it interact with the RTC backstop?** Yes, and sharply enough to be
worth stating twice. `autosuspend.lua` arms the backstop by reading the
RTC's *own* clock (`/sys/class/rtc/rtc0/since_epoch`) and writing
`since_epoch + N` to `wakealarm` — an **absolute** value in RTC seconds.
Two consequences:

- **A wrong system clock never misplaces the alarm.** The arming
  arithmetic never reads the system clock at all, so an unanchored device
  still wakes on schedule. Worth knowing before anyone "fixes" it.
- **Writing the RTC does.** Step the RTC forward past a pending alarm and
  the compare never matches, so that wake *silently never happens*; step
  it backward and it fires that much later.

What the backstop *means* is an interval — "wake within the hour if
nothing else does" — so the daemon preserves the **interval**, not the
instant: it reads `wakealarm` and `since_epoch` before the write, writes
the RTC, then re-arms at the new `since_epoch` plus the remaining time.
`rearm_alarm_value()` is that arithmetic and the host suite pins it in
both directions.

*Residual, stated rather than papered over:* the two daemons do not lock
against each other, so a sync landing inside the ≤10 s window between
`arm_backstop()` and the `/sys/power/state` write inside `suspend_once()`
can still leave that **one** cycle without a working alarm. Every
subsequent suspend re-arms from scratch, so it self-heals at the next
cycle, and the primary wake (the power button) is hardware-proven. Set
`(set-rtc? #f)` if you would rather not carry even that.

**Write back to the RTC?** Yes, default `#t`. Without it the correction
dies at the next cold boot, and a device that syncs once and then never
sees Wi-Fi again — entirely plausible for a reader — keeps nothing.
`hwclock --systohc --utc --noadjfile` does the write, by absolute store
path rather than a `PATH` lookup, because shepherd services start with an
essentially empty environment on this device and a silent failure branch
here would mean the RTC quietly never gets written while every gate
stayed green.

### 7.2 The other daemon this changed

Stepping the clock is not free elsewhere. `autosuspend.lua` measures
idleness as a difference of `os.time()` readings, and a step does not add
a small error to that measurement — it destroys it, in whichever
direction the clock moved. Backwards, the delta goes negative,
`remaining` exceeds the whole idle period, and the device holds at
~157 mA until somebody touches it — on a device that was just put down,
the exact case auto-suspend exists for. Forwards, the delta reads as
years of idleness and the device suspends under the reader's fingers.

So `idle_elapsed()` now sits between the two: a negative delta re-bases
with no threshold at all, and a forward delta beyond twice the idle
period (floored at an hour, so that shortening `idle=` at runtime is not
mistaken for a step) does too. `make power-check` pins both directions
plus the two cases that must *not* re-base. This is a change to a
shipping daemon that no hardware has run; it is arithmetic, extracted
verbatim and tested, but it is not proven on glass.

One smaller residual is deliberately **not** guarded: `power_ignore_until`
— the grace period that stops the press which woke the device from
immediately re-suspending it — is also wall-clock arithmetic, so a large
backward step suppresses press-to-suspend until the clock catches up.
That costs a convenience feature, not a wake and not a battery, it is
re-set after every resume, and guarding it would mean threading a second
clock through the daemon for very little. Recorded here so it is a known
tradeoff rather than a surprise.

### 7.3 What this is not

SNTP is unauthenticated: whoever can answer on the path can set this
clock, within the sanity window (`not-before`, default 2026-01-01, and a
20-year `horizon-seconds`). That window is a junk filter — it catches the
1970 of a reset RTC — **not** authentication, and it cannot catch an
attacker who answers with a plausible date. That is the protocol, not an
oversight, and it is part of why the default server list is empty.
Nothing on the reader makes a security decision on the clock today (SSH
is key-only and time-blind), but do not build one on this without saying
so first.

`not-before` is a constant rather than the build date on purpose:
stamping the build date into a default would make the derivation
unreproducible. It therefore ages, and the field is how you move it.
