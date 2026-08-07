# Device access and diagnosis conventions

How to reach and safely use a PineNote running this stack — the SSH
oracle on os1, the ACM console, UART, post-mortem log harvest, and the
traps each of these has already cost sessions to learn. These conventions
were previously tribal knowledge; they are repo policy now. Concrete
per-device values (addresses, fingerprints, VCOM) live in each operator's
device ledger — see `doc/device-runbook.md`; this file stays generic.

Convention: the reader's static LAN address is deliberately **not**
written into repo docs. Find it via the router / `ip neigh` (hostname
`pinenote-reader`) and record it in your own ledger.

## Which slot am I on?

Both slots can answer at the same LAN address (os1 as `user@`, the os2
reader as `root@`). **Always verify the slot before acting**:

```sh
findmnt -n -o SOURCE /    # …p5 = os1 (stock Debian), …p6 = os2 (ours)
```

Host-key policy: on images built before 2026-08-06, os2's host key is
regenerated on every reflash — use a dedicated known-hosts file and
`StrictHostKeyChecking=accept-new`. Images carrying the host-keys sync
(post-v3; in tree since late 2026-08-06) persist the identity on the
data partition (`/data/ssh/host/`, `doc/networking.md` §4.1): the
fingerprint changes once more at such an image's first boot, then stays
stable across reflashes — pin it in your ledger then (`accept-new`
remains a fine default either way). os1's
archived host-key fingerprint (ledger) is the identity check before any
os2 write.

## os1 as a read-only oracle

Stock Debian on os1 (6.12-pinenote, everything working) is the cheapest
"is our build doing the right thing" check: live `/proc/device-tree`,
`/sys/bus/iio`, dmesg signatures, gadget bracketing. Use it before
theorizing. Two limits: os1 drives its display through KMS, so it is
**not** an oracle for the fbdev damage path; and os1 auto-deep-suspends
on idle — if ssh/ping fails it is probably asleep, not broken (wake it;
don't debug connectivity).

Related patterns, all proven:

- **Post-mortem harvest**: after an unobserved os2 boot, mount
  `/dev/mmcblk0p6` read-only from os1 and read `/var/log/messages`.
- **Chroot testing**: `sudo chroot /mnt/os2 <store-path>` runs the Guix
  aarch64 binaries natively — proves deployed-binary behavior without a
  boot.
- **os2's /tmp is on-disk, but Guix WIPES it when os2 boots.** Evidence
  under /tmp survives a hang + power-cycle *only if you boot os1 next*:
  boot os1, mount p6 `ro,noload`, harvest, sha256-verify, unmount — then
  reboot os2. Re-staged scripts must be re-copied every os2 boot.

## The ACM gadget console

Host side, the device enumerates as an ACM tty (descriptor
`Pine64 PineNote Guix … ACM Console`); check `udevadm info` before
assuming a `/dev/ttyACM*` node is the PineNote. I/O pattern:

```sh
(timeout N cat /dev/ttyACM1 > log &  sleep 0.3; printf 'cmd\r' > /dev/ttyACM1; wait)
```

- With the host tty in `stty raw`, terminate lines with `\r` (CR), not
  `\n` — `\n` alone leaves the shell at a `>` continuation prompt. Lead
  each command with Ctrl-C (`\003`) + `\r` to clear any partial line.
  Avoid `!` in commands (history expansion).
- On the reader flavor the console user is unprivileged `reader` with
  **passwordless sudo** — `sudo -n <cmd>` for sysfs/mount ops.
- Binary transfer: base64 payload, sha256-verify on device (~2 MB in
  seconds). One-line script placement:
  `printf %s '<base64>' | base64 -d > /tmp/x.sh`.

## UART

The UART **works** at 1500000 baud — host `/dev/ttyUSB0` (CH340 on the
USB-C SBU debug cable):

```sh
stty -F /dev/ttyUSB0 1500000 cs8 -cstopb -parenb -crtscts clocal -echo raw
```

Two traps that defeated every early attempt (the long-standing "receives
nothing from ttyS2" claim was a test artifact, retracted 2026-08-02):

1. The **device-side** `/dev/ttyS2` termios defaults to **9600**, and on
   an 8250 the console shares the port divisor — console output leaves at
   9600 while you listen at 1500000. Run `stty -F /dev/ttyS2 1500000` on
   the device (agetty uses `--keep-baud`).
2. A **passive listen after boot** cannot tell a dead cable from a quiet
   console. Test method: transmit a known marker from the device while
   sweeping host bauds, and grep for it.

For a trace through suspend entry, `no_console_suspend` on the cmdline is
required — the runtime `console_suspend=N` knob does not hold the 8250 up
through its own dev_pm_ops. UART gives passwordless root whenever the
device is awake; it is the recovery channel if auto-suspend misbehaves.

### Proving the link end to end (2026-08-06)

Silence on the host does not say *where* the link is broken. The SoC's
own counters do, and they cost one SSH command:

```sh
sudo cat /proc/tty/driver/serial | grep '^2:'
# 2: uart:16550A mmio:0xFE660000 irq:19 tx:8252 rx:0 RTS|DTR
```

Transmit a marker to `/dev/ttyS2` and read it again: **tx climbing**
means bytes really left the SoC, so any host-side silence is the cable or
the adapter, not the device. **`rx:0`** means the device has never
received a byte since boot — if it stays 0 while you send from the host,
that direction is dead too.

**Both directions dead at once is the signature of a flipped USB-C
plug.** SBU1/SBU2 swap when the connector is inserted the other way up,
which swaps TX and RX; the port still refuses to charge (the debug cable
occupies it), so "not charging" is *not* evidence the link works. Flip
the connector at the device end and re-test. Observed 2026-08-06: SoC
`tx` climbing normally, `rx:0`, host receiving nothing at either 1500000
or 115200 — a dead line, not a baud mismatch (a wrong baud gives
garbage, not zero bytes).

**Consequence when the UART is down: you cannot choose a boot slot.** The
U-Boot menu is serial-only, and its default entry ("Search for
extlinux.conf on all partitions") finds p5 first because os1 carries
`/boot/extlinux/extlinux.conf` — so every unattended reboot lands in
**os1**. p3 (`uboot_env`) is an empty FAT12 filesystem, not a raw env, so
there is no file-based slot selector to write either. Deploying to os2 is
still safe and useful without UART; *booting* it needs either a working
UART or a human at the menu.

## SSH to the deployed reader

- Key-only `root@<reader-addr>`; scp works. Each reflash wipes `/root`
  (re-push test assets). On pre-2026-08-06 images each reflash also
  regenerates the host key (`accept-new`); newer images restore both the
  authorized key and the host identity from `/data/ssh/` at boot.
- **Auto-suspend makes SSH intermittent**: the device is only reachable
  for the idle window after the last input, and Wi-Fi re-association eats
  several seconds of it after each wake. To work on the device, first
  write `enabled=0` to `/var/lib/pinenote/autosuspend.conf` (re-read
  before every idle wait; no restart needed).
- **Wake it with the power button, not by waiting for the RTC.** Since
  2026-08-07 an RTC-backstop wake re-suspends after ~20 s (nobody is
  present when the alarm fires — `doc/power-management.md`, "The idle
  duty cycle"), and neither an SSH session nor UART traffic counts as
  activity: only `/dev/input` events do. A button press still grants the
  full idle window, which is the one you want for a login. The runtime
  pause on `/data/wilkbook/autosuspend.conf` survives reflashes and is
  writable from os1, so set it there before a deploy rather than racing
  a 20 s window afterwards.
- After a broken scp, sshd's `PerSourcePenalties` can temporarily ban the
  host — pings fine, TCP accepted, handshake drops. Rapid retries DEEPEN
  the ban: stop for 5+ minutes, then one clean try.

## Misc proven patterns

- **Cross-compiled one-offs**: `aarch64-linux-gnu-gcc` from the Guix store
  with `-I <linux-libre-headers-cross> -I <glibc-cross>
  -Wl,--dynamic-linker=<glibc-cross>/lib/ld-linux-aarch64.so.1
  -Wl,-rpath,<glibc-cross>/lib` runs on the device as-is.
- **Live-editing a store bundle on device**: `cp -rL` (NOT `cp -a`) —
  profiles are symlink forests; `cp -a` copies the symlinks and later
  edits fail through them into the read-only store.
- `drm.debug=0x2` works without CONFIG_DYNAMIC_DEBUG, but with
  `console=tty0` its printks redraw fbcon and feed a commit/log feedback
  loop — turn it off after capturing.
- **Never put KOReader in portrait via `copt_rotation_mode=1` on a
  diagnostic image**: it can wedge the EBC (panel ignores all fb writes;
  only a reboot recovers — see `doc/driver-findings-report.md`). Use
  landscape-native test cards.
- Diagnose "blank page" issues by dumping `/dev/fb0` (32bpp XR24, stride
  7488) and looking at it — separates render-side from glass-side
  instantly.

## What stays manual, and per-operator permissions

Destructive steps — dd to os2, reboots (which need a human to pick the
U-Boot slot), anything touching waveform/U-Boot/partition table — are
user-present, per the safety model in `CLAUDE.md`. Standing permissions
(e.g. letting an agent run the os2 write protocol autonomously) are
**per-operator grants, not repo facts**: each operator decides what their
own tooling may do on their own device, after their ledger's backups
exist.

**Why this file exists:** hardware sessions are scarce. These read-only
patterns have root-caused multiple device bugs without a single reboot,
and the ACM patterns carried entire debug sessions without UART. Exhaust
the oracle, the log harvest, and chroot tests before proposing a session.
