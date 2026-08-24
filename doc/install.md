# Installing wilkbook on a PineNote that isn't the author's

`doc/hardware-deploy.md` is the **write protocol**: it assumes backups
already verify, a UART already works, and you already know which slot you
are on. This page is what has to be true *before* that protocol applies —
the path from "I have a PineNote and this repo" to "os2 boots my build".

**No second person has done this.** Every hardware claim in this repo
comes from one PineNote v1.2 and one operator (`doc/status.md`, entries
are labelled per device/operator). This page is derived from the repo's
own code and procedures; it is not the record of a replayed install.
Where the repo genuinely does not answer something, it is marked
**open** rather than smoothed over. Read the disclaimer in `README.md`
first: this writes to a partition on a device most people cannot easily
re-flash.

## 1. What you need

**Hardware**

- A **PineNote v1.2**. The packaged boot bundle names
  `rk3566-pinenote-v1.2.dtb` and that is the only DTB built
  (`pinenote/packages/boot.scm`, `pinenote/packages/kernel.scm`). The
  repo has no path for, and no evidence about, other board revisions.
- A **USB-C SBU debug cable** (per the Pine64 wiki) into a serial
  adapter — a CH340 here — run at **1500000 baud 8N1**, not 115200
  (`doc/device-access.md`). Section 2 is why this is not optional.
- Two independent places to keep backups (e.g. workstation + NAS).
- A charger, and the knowledge that you cannot use it at the same time
  as the cable: the PineNote has **one USB-C port**, the debug cable
  occupies it, and the port then refuses to charge
  (`doc/device-access.md`). Charge to ~100 % *before* the cable goes on;
  that is the standing rule for supervised sessions
  (`doc/artifacts/pinenote-ultra-handshake-20260807/PROCEDURE.md`).

**Host**

- An x86_64 GNU/Linux machine with Guix (package manager on any distro
  is fine; Guix System is not required) and the nonguix channel. Guix is
  the only host dependency. `doc/building.md` opens with a from-zero
  section.
- Disk and patience: a full image pulls tens of GB into `/gnu/store`,
  and without nonguix substitutes the cross-built kernel alone is an
  hours-long build (`doc/building.md`).

**Time and posture.** This is a supervised sitting with a serial console
capturing, not an unattended install. Sessions have ended with the device
stuck before the U-Boot menu, needing a manual reset with the operator
physically present (`doc/hardware-deploy.md`).

## 2. What the debug cable is for (and what it is not)

Not for comfort — for control and recovery. From `doc/device-access.md`:

- **The cable is your recovery console and your only window into a bad
  boot** — a root shell when SSH is gone, and the only place U-Boot,
  the kernel, and firmware narrate. It is *not* how you pick a boot
  slot: the U-Boot menu is interactable on the device itself — a person
  present can always pick "Boot OS2 (part 6)" by touch, no cable, ~15 s
  countdown. An untouched reboot defaults to os1, the rescue slot. An
  AI agent or unattended process has no fingers or eyes, so *it* needs
  the cable to drive the menu over serial. (Corrected 2026-08-07 by
  direct observation at the device; earlier versions of this page and
  `doc/device-access.md` asserted the menu was serial-only.)

  What remains true is the **default**: the highlighted entry ("Search
  for extlinux.conf on all partitions") finds p5 first, because os1
  carries `/boot/extlinux/extlinux.conf`, so an *unattended* reboot —
  one where nobody touches the menu — lands in **os1**. p3 (`uboot_env`)
  is an empty FAT12 filesystem, not a raw env, so there is no file-based
  slot selector to write instead. Observed twice (2026-08-06, and the
  2026-08-07 ultra recovery boot). This matters for anything that must
  come back up on os2 by itself — see the hibernation note in
  `doc/power-management.md`.
- **It is the recovery channel.** The UART gives a root shell whenever
  the device is awake, which is what you want when auto-suspend, a
  wedged service, or a bad image misbehaves.
- **Serial is not an armed wake source.** Under `wakeup-config = <0x10>`
  a suspended device is silent on the UART and ignores keystrokes;
  waking it needs a physical button press (`doc/hardware-deploy.md`,
  measured 2026-08-02). The cable removes the need for a human at the
  *menu*, not at the *device*.

Two traps that have each cost sessions:

- The **device-side** `/dev/ttyS2` termios defaults to 9600 and the 8250
  shares the port divisor, so console output can leave at 9600 while you
  listen at 1500000.
- **A flipped USB-C plug swaps SBU1/SBU2**, killing both directions at
  once. "It isn't charging" is *not* evidence the link works — the debug
  cable occupies the port either way. Prove the link with the SoC's own
  counters (`/proc/tty/driver/serial`, the `tx`/`rx` fields) rather than
  a passive listen.

## 3. Your os1 must already be a working stock system

This repo installs into the **inactive** OS slot and never touches the
other one. That only works if the other one already works.

- Assumed baseline: the community PineNote Debian image family (PNDeb),
  Debian trixie with a `-pinenote` kernel, on the GPT layout used
  throughout this repo — `uboot` p1, `waveform` p2, `uboot_env` p3,
  `logo` p4, `os1` p5, `os2` p6, `data` p7 (`doc/device-runbook.md`).
  If `lsblk` shows a different layout, stop and reconcile before
  anything else.
- os1 is three things at once: the **rescue path** you fall back to, the
  **staging host** you `dd` from (the write protocol runs *on the
  device*, from os1, over SSH), and the **read-only oracle** that
  answers "is our build doing the right thing" without a reboot
  (`doc/device-access.md`).
- Enable SSH on stock os1 and record its address and host-key
  fingerprint in your ledger before anything else.

Consequently: if your device does not currently boot a stock system on
p5, this repo has no path for you. Getting a stock image onto a PineNote
is out of scope here — that is PNDeb's territory.

## 4. Back up before anything (your ledger)

`doc/device-runbook.md` is two documents in one: the generic checklist,
and the author's filled-in ledger as the worked example. Run its
**"Provisioning a new device"** section on your own device, from stock
os1, and keep your own ledger with your own values. The deploy
preconditions in `doc/hardware-deploy.md` require *your* checklist
satisfied with *your* numbers — never the author's.

The short version of what that section takes, all read-only `dd if=`:
raw `waveform` (p2), `uboot_env` (p3), `uboot` (p1), `logo` (p4), and
the first 16 MiB of `mmcblk0` (GPT + early eMMC), duplicated to two
independent roots with `sha256sum -c SHA256SUMS` verifying in both.

**`waveform_p2.img` is the irreplaceable one**: ~2 MiB of per-device
e-ink calibration that exists nowhere else. If you take one backup, take
that one, twice.

Also record, per the runbook: your partition map with PARTUUIDs, the
current kernel cmdline, and your VCOM value — the last one somewhere
offline too, because paper survives dead disks.

## 5. The two per-device things: waveform and VCOM

The repo's hard rule (`CLAUDE.md`) is that per-device calibration is
never bundled and never substituted with a generic value; the build
fails visibly instead. Concretely:

**Waveform.** The image contains no `.wbf`. At boot the initrd copies
2 MiB from the partition GPT-named `waveform` into
`/lib/firmware/rockchip/ebc.wbf` before the root switch, so
`rockchip_ebc` can bind early, and the `pinenote-waveform` one-shot does
the same afterwards from `/dev/disk/by-partlabel/waveform` or
`/state/firmware/ebc.wbf` (`pinenote/images/pinenote-initramfs.scm`,
`doc/building.md`). On a stock PineNote that partition is populated from
the factory, so a fresh device needs **no action** — but see section 4
about backing it up anyway.

If it is absent, the failure is visible rather than silent: the initrd
logs `waveform partition not found; EBC console may stay unavailable`
and continues, and the `pinenote-waveform` service fails rather than
installing a substitute. A device that boots with no waveform has no
working panel; it does not get a generic one.

**VCOM.** The image does not supply VCOM at all. It lives in the
TPS65185's NVM as that chip's power-up default — the per-device factory
calibration — and the driver deliberately **never writes it**, including
across the suspend/resume register save/restore, precisely because it is
calibration data (comment in
`pinenote/patches/linux-pinenote-7.0-forward-port.patch`, TPS65185 PM
hunk; `doc/power-management.md` "VCOM is NVM-safe"). So there is nothing
to configure. Record your device's value anyway
(`/sys/class/regulator/regulator.*` with `name` = `vcom`) so that you can
tell if anything ever changes it. Never copy another device's number
anywhere: the author's `1430000 µV` is *that panel's* number.

## 6. Build

`doc/building.md` is the authority; the shape of it:

```sh
guix pull -C channels.scm      # nonguix is required, with its introduction
guix describe                  # record this next to any image you deploy
make rootfs-reader             # the product: KOReader reader image
```

Notes that bite:

- Artifacts land under `/tmp/wilkbook`, which does **not** survive a host
  reboot. Rebuild or copy out anything a later deploy session references.
- A fresh clone builds with KOReader's fallback fonts. The images
  `doc/status.md` validated bundle personally-licensed fonts staged from
  a gitignored directory (`pinenote/fonts/README.md`), and the seeded
  KOReader profile names one of them (`cre_font = "Equity A"`);
  KOReader's built-in fallback chain remains in effect beneath it. Your
  build will look typographically different from the validated images.
- Run the offline ladder before writing anything — `make check-host`
  (add `WBF=/path/to/your/ebc.wbf` from your own backup to include the
  waveform-gated suites, which a reader candidate requires), then
  `make qemu-virt-check ROOTFS=…`. `doc/testing.md` explains the rungs.
  This is cheap and it is the whole reason hardware sessions here are
  rare.

## 7. Stage your own state on the data partition — before the first boot

The image is deliberately generic: no keys, no credentials, no library
in it. Everything per-operator lives on the persistent `data` partition
(p7), which the reader mounts read-write at `/data` and which survives
os2 reflashes. On the author's stock os1, p7 is mounted at `/home`
(`doc/device-runbook.md` inventory), so you can write all of this from
os1 before you ever boot os2 — mount it by partlabel if your os1 does
not mount it.

Paths are relative to the partition root (`/data/…` as the reader sees
them):

- `wifi/wlan0.conf`, mode `0600` — the Wi-Fi credential file. Store the
  **PSK hash** from `wpa_passphrase`, not the passphrase, and include a
  `country=` line. Exact format and the association caveats
  (`brcmfmac.feature_disable=0x82000` is already handled in tree) are in
  `doc/networking.md` §4.1. Absent file = graceful no-op; the reader
  boots without networking.
- `ssh/authorized_keys` — your public key. A boot one-shot installs it
  to `/root/.ssh/authorized_keys` every boot, so it survives reflashes
  (`/root` does not). With no key staged, root SSH is simply unreachable
  and your way in is the console.
- `wilkbook/autosuspend.conf` — **optional, and the single easiest way
  to end up with a device that never sleeps.** Writing `enabled=0` here
  pauses auto-suspend for first-boot debugging; **whoever writes it owns
  undoing it** (`enabled=1`, or delete the file — re-read before every
  idle wait, no reboot). Skip it and suspend works out of the box.
  What it controls: auto-suspend sleeps the device to
  ultra suspend (rails-off; **5.47 mA idle standby measured** across a
  6.17-day unplugged soak, 170 cycles and zero failures, 2026-08-15)
  after 5 minutes of no *input* (an SSH session does not count). Waking
  takes the power button, the RTC backstop, plugging in a charger, or
  opening the cover (confirmed 2026-08-09); the serial console cannot
  wake it. The daemon reads this file first and the
  `/var/lib/pinenote/autosuspend.conf` runtime knob second (so a same-boot
  change there still wins), and unlike `/var/lib` it survives reflashes
  and is writable from os1 — which is exactly why it exists
  (`pinenote/tools/power/autosuspend.lua`, `doc/device-access.md`).
- `books/` — your library. The seeded KOReader profile hardcodes
  `home_dir = "/data/books"` (`pinenote/systems/pinenote-reader.scm`).

  `/data/books` is created automatically on first boot when absent
  (`pinenote/services/library.scm` — with a relative pointer to an
  existing stock-Debian home when one is present, and never touching an
  existing library). Tested offline by `make qemu-data-check`
  (`doc/testing.md` rung 4d) — proven in QEMU fixtures, not yet on a
  second device. Put a real book in it before first boot if you want
  more than an empty library.

Note that p7 also comes to hold the device's **private** SSH host keys
(`ssh/host/`, so the fingerprint survives reflashes). Any backup of p7
therefore contains private key material and belongs with your protected
backups, not anywhere shared.

## 8. Write to os2, then boot it

Follow `doc/hardware-deploy.md` exactly: preconditions, then stage the
rootfs on os1 over SSH, confirm os1 is the running root
(`/dev/mmcblk0p5`) and os2 (`/dev/mmcblk0p6`) is unmounted, `dd` to p6
only with an exact sector count, read back that byte range and compare
SHA-256, then record what you wrote in your own `doc/status.md` entry.

Its stop conditions are the load-bearing part: stop before any write if
backups do not verify, if the rescue path is unclear, or if the step
would alter boot order, U-Boot environment, partition layout, or any
partition other than os2. Never write the `raw-with-offset` disk image
whole — only the extracted `PNGuixRoot` rootfs, only to os2.

Boot with the UART capturing from before power-on. Pick
"Boot OS2 (part 6)" (the countdown is ~15 s; any key stops it). Watch
for: eMMC probe, initrd waveform install from p2, `PNGuixRoot` root
mount, Shepherd start. Afterwards, power-cycle back to os1 and confirm
the rescue path still works.

If the boot was unobserved or went wrong, you are not blind: boot os1,
mount p6 read-only, and read `/var/log/messages` off it
(`doc/device-access.md`). Note that os2's `/tmp` is on disk but Guix
wipes it when os2 boots, so harvest before rebooting os2.

## 9. What the repo does not know about your first boot

Stated plainly, because the alternative is implying a tested path.

- **No device without a prior wilkbook install has ever booted this
  image.** "Fresh-clone first boot must survive" is an open alpha
  blocker (`doc/alpha-checklist.md` §5), and it is open for the
  *author's* device. On a second device it is open twice over.
- **`/data/books` is auto-created on first boot** (section 7); a missing
  data partition falls back to a readable placeholder rather than a
  broken browser — proven in QEMU, not on a second device.
- **If the device never sleeps, you paused it.** No suspend banner,
  Wi-Fi stays up, the power button and the cover do nothing, and the
  battery drains at reading speed — that is auto-suspend paused, not
  broken. Check, in this order:
  `cat /data/wilkbook/autosuspend.conf` (the persistent one, on p7, that
  survives reflashes) and `cat /var/lib/pinenote/autosuspend.conf` (the
  runtime one, read *second*, so it wins for the current boot). Either
  containing `enabled=0` pauses everything. Set `enabled=1` or delete
  the file; it is re-read before every idle wait, so no restart is
  needed. **This is the most likely first-boot symptom**, because an
  earlier version of this page recommended creating that file with
  `enabled=0` and never said to undo it. `herd status
  pinenote-autosuspend` showing the daemon *running* is not evidence it
  is enabled — a paused daemon runs normally and, as of 2026-08-09, does
  not say so in its startup log (GitHub issue #7).
- **The SSH host-key fingerprint changes once**, at the first boot of an
  image carrying the host-key sync, and is stable across reflashes after
  that. Pin it in your ledger *then*, not before (`doc/networking.md`
  §4.1).
- **Boot-slot behaviour** rests on one observation (section 2).
- **Reader acceptance is per-image.** The reading experience recorded in
  `doc/status.md` was validated on specific artifacts on one device;
  your build from a fresh clone is not that artifact. `doc/status.md`
  is the only place that says what has actually been seen on glass, and
  its entries are labelled per device — add your own, never overwrite
  someone else's.
- Anything power-related: every measured number in this repo is from one
  device, and the ones that are arithmetic rather than measurement are
  labelled as such (`doc/alpha-checklist.md`, "The numbers alpha may
  state"). Do not expect your device to reproduce them. In particular
  the standby *days* — ~30 idle, ~16 as actually read — are projections
  from a **measured draw** (5.47 / 10.07 mA over 6.17 unplugged days,
  `doc/artifacts/pinenote-ultra-soak-20260815/`) onto a 4000 mAh
  charge. Nobody has run this device flat from full; your battery's
  real capacity, and how much you read, both move the answer.

## 10. Root posture — what you are actually installing

Be clear-eyed about this before you decide to keep the device on a
network you care about. Both builds below are *this repo's* posture, not
a recommendation.

**The default reader build** (`make rootfs-reader`, no flags):

- No USB gadget console shell and no passwordless `sudo` for the
  `reader` account — both are gated behind the opt-in flag below.
- SSH is key-only (`password-authentication? #f`,
  `permit-root-login 'prohibit-password'`), with the authorized key
  coming from your data partition, so a device with no staged key is not
  reachable over SSH at all.
- **But no account password is set anywhere in the system definitions**,
  and `%base-services` runs a getty on the kernel console
  (`console=ttyS2`). The recorded, relied-upon behaviour is that "UART
  gives passwordless root whenever the device is awake"
  (`doc/device-access.md`) — that is the recovery channel, by design.
  So "default" means *not reachable over a USB data cable*, not
  *locked down*: anyone holding the SBU debug cable is root.
- The eMMC is not encrypted. The Wi-Fi PSK hash and the SSH host private
  keys sit 0600 root-owned on p7, which stock os1 mounts at `/home` — an
  accepted tradeoff on a single-trust-domain device
  (`doc/networking.md` §4.1).

**The convenience build** (`WILKBOOK_VERY_INSECURE_FOR_CONVENIENCE=1`,
or that line in a gitignored `local.mk`) additionally ships:

- the USB **ACM gadget console**, which execs a shell on `/dev/ttyGS0`
  with no login prompt at all, and
- **passwordless `sudo` for `reader`**, which is what makes that shell
  root-equivalent.

They are gated together on purpose (`pinenote/insecure.scm`). The
consequence is worth stating without euphemism: **any USB-C cable is an
unauthenticated root shell.** For bring-up on a device with one port and
no serial wake source, that is the difference between a five-minute fix
and a teardown — which is why it exists — but it is not a thing to leave
on a device you carry around.

Either way, the reader image writes `/etc/wilkbook-build`
(`WILKBOOK_BUILD=default` or `…=very-insecure-for-convenience`), so a
mounted image or a running system answers the question without inferring
from behaviour. **Scope**: that marker and that gate are on the *reader*
flavor. The bring-up flavors — `usb-console` in particular — carry the
unauthenticated ACM console and `reader NOPASSWD: ALL` unconditionally
and write no marker (`pinenote/systems/pinenote-usb-console.scm`). They
are debug images; treat them accordingly.

## 11. Living with it

- **There is no update mechanism.** A new build is the same write
  protocol again: rebuild, extract, verify backups, `dd` to os2,
  readback-SHA. There is no `guix system reconfigure` path on the
  device and no package management in the release flavors.
- **A reflash wipes `/`, including `/root`.** Your books, Wi-Fi
  credentials, SSH keys, and the `/data/wilkbook` knobs survive (p7);
  KOReader's global settings live in `/root/.config/koreader/` and do
  not. The reader flavor re-seeds that profile at activation *only* when
  the file is absent, so a reflash silently returns you to the seeded
  defaults.
- **Auto-suspend makes SSH intermittent** — the device is reachable only
  for the idle window after the last *input* event, and Wi-Fi
  re-association eats several seconds of it. Pause it before working on
  the device (section 7); wake it with the power button rather than
  waiting for the RTC backstop.
- **os1 remains yours.** Nothing here writes it, and the recorded
  practice is to power-cycle back to it and confirm it still works after
  every session.
