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
**That passwordless serial getty is a standing security item, not yet
decided** — flagged 2026-09-03 after a session that leaned on it for
hours; see `doc/alpha-checklist.md` for the open decision.

3. (2026-08-26) **A hung shutdown answers the UART like a live system —
   and reconnecting over ssh is what causes the hang.** Root-caused
   from the device's own log
   (`doc/artifacts/pinenote-shutdown-wedge-20260826/`): the halt kills
   the ssh session that issued `reboot`, so that client exits nonzero;
   anything that treats the nonzero exit as failure and reconnects hits
   shepherd's inetd listener — still armed mid-halt — which accepts the
   connection and *restarts the stopped networking service* to serve
   it, wedging the halt permanently (upstream register item 20). The
   rule: **one reboot attempt, exit status ignored, and no connection
   to the device between issuing `reboot` and seeing U-Boot on the
   UART.** The wedged state's signature: keystrokes **echo** (kernel
   tty alive) but nothing ever responds — no password prompt, no getty
   respawn — and sshd flips to connection-refused while ping still
   answers (the restarted dhcpcd). A `login:` prompt seen after
   `reboot` can be the DYING session's getty, and *typing a login name
   at it is destructive*: login(1) consumes the last getty, execs into
   the half-torn-down system, and never returns — closing the only
   interactive door. Before trusting a post-reboot prompt, ask it for
   `uptime` (or watch for U-Boot/kernel chatter in the capture); a boot
   you didn't see happen didn't happen. Recovery from the fully-wedged
   state is the power button on kernels before the 2026-08-26
   forward-port revision (the inherited defconfig unset
   `MAGIC_SYSRQ_SERIAL`, so BREAK is inert there). Kernels built after
   that date carry serial sysrq shipped disabled, with a break-sequence
   arming toggle — glass-proven: **(1)** send BREAK, then type the
   literal bytes `sysrq` (arms; the kernel logs "SysRq is enabled by
   magic sequence"); **(2)** send BREAK again, then the key — `s`
   sync, `u` remount-ro, `b` reboot. From the host:
   `python3 -c 'import termios,os;
   fd=os.open("/dev/ttyUSB0",os.O_RDWR); termios.tcsendbreak(fd,0)'`
   then write the bytes to the port. Details and the semantics trap
   behind the two-stage shape: `doc/kernel-forward-port.md`.

4. (2026-09-03) **Unplugging the cable kills the host-side reader, and
   two readers on one port split the bytes.** Discovered mid-session on
   the embrace branch's glass proof: the debug cable is physically
   fragile and had to come out for a rotation test, which killed the
   `cat` process reading `/dev/ttyUSB0` and left the UART watcher
   (`uboot-pick-slot.sh`) unable to pick a slot for the next reboot —
   U-Boot's default landed on os1 instead. Restart the host-side reader
   after any unplug: `stty -F /dev/ttyUSB0 1500000 raw -echo -crtscts`
   then `cat /dev/ttyUSB0`. Keep to exactly **one** reader per port —
   the slot picker starts its own listener, so a leftover manual `cat`
   splits the output between the two and neither sees a complete
   stream. And the watcher needs the UART plugged in and live for the
   whole reboot it is meant to catch, not just at the start.

5. (2026-09-03) **A suspended console swallows typed input.** KOReader's
   idle timer suspended the device (UART: `PM: suspend entry (deep)`)
   while a script was launched over the serial console; the launch did
   nothing — the operator's press woke the device, but the console had
   not queued the keystrokes, it had simply not been listening. Pause
   auto-suspend (`enabled=0` in `/data/wilkbook/autosuspend.conf`)
   before any console-driven procedure, the same rule as for SSH below.

6. (2026-09-03) **Wi-Fi may not survive a power-button suspend/resume.**
   Observed on the reader-direct study flavor (generation 8): after
   resume, UART showed `brcmfmac: brcmf_sdio_bus_rxctl: resumed on
   timeout` then `brcmfmac: brcmf_sdio_firmware_callback: brcmf_att…`
   (attach failed) — the SDIO firmware did not reload. A second
   suspend/resume cycle on the same boot did not recover it either; SSH
   stayed unreachable for the rest of that boot. A cold boot restores
   it. Observed once, on one flavor; not yet root-caused.

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

**Consequence when the UART is down: the DEFAULT boot slot is os1 — but
you can still choose.** The U-Boot menu is interactable on the device
itself; picking "Boot OS2 (part 6)" does not require a serial console.
(Corrected 2026-08-07 by direct observation at the device. Earlier
versions said the menu was serial-only; that error propagated into
`doc/install.md`.)

Its default entry ("Search for
extlinux.conf on all partitions") finds p5 first because os1 carries
`/boot/extlinux/extlinux.conf` — so every *unattended* reboot lands in
**os1**. p3 (`uboot_env`) is an empty FAT12 filesystem, not a raw env, so
there is no file-based slot selector to write either. Deploying to os2 is
still safe and useful without UART. os2 never comes up on its own — an
unattended reboot always lands on os1. Booting os2 takes either a human
at the menu (on-device, no cable) or an agent driving the menu over
UART, since an agent has no fingers or eyes. The old text: needs either a working
UART or a human at the menu.
`pinenote/scripts/uart/uboot-pick-slot.sh LOG --slot os2 [--reboot
<os1-ssh-dest>]` is that agent: one reboot attempt, no reconnect until
the menu is drawn, two DOWNs + ENTER, and the capture keeps running so
the whole boot lands in LOG (it used to live in a session scratchpad and
was lost with it; 2026-09-02 it picked os2 at poll 23 and recorded the
first kexec on glass).

## SSH to the deployed reader

- Key-only `root@<reader-addr>`; scp works. Each reflash wipes `/root`
  (re-push test assets). On pre-2026-08-06 images each reflash also
  regenerates the host key (`accept-new`); newer images restore both the
  authorized key and the host identity from `/data/ssh/` at boot.
- **One ssh alias per slot** in `~/.ssh/config`, each carrying its own
  `UserKnownHostsFile` (the os2 reader as `root@`, os1 as `user@`,
  different files), is the documented way to address the device; the
  deployer takes the alias (`make deploy DEVICE=pinenote-os2`,
  `doc/hardware-deploy.md`). The default `known_hosts` hard-fails on
  the two slots' colliding keys.
- **Never `accept-new` a host key against the shared address until the
  slot you mean is the one answering** (2026-09-02): the two slots share
  one IP and have different host keys, so a watcher that reconnects
  with `StrictHostKeyChecking=accept-new` during an os1 window pins
  os1's key, and the next os2 boot fails strict checking — which looks
  identical to "no network" from the workstation. Purge with
  `ssh-keygen -R` and re-pin once the right slot is up.
- **Auto-suspend makes SSH intermittent**: the device is only reachable
  for the idle window after the last input, and Wi-Fi re-association eats
  several seconds of it after each wake. To work on the device, first
  write `enabled=0` to `/data/wilkbook/autosuspend.conf` (the
  platform-controls broker re-reads it continuously; no restart needed;
  the `/var/lib/pinenote/…` path recorded here until 2026-09-04 does not
  exist on the device). Restore `enabled=1` as the LAST step of a
  session, never earlier: with `enabled=1` on battery the reader sleeps
  15 idle minutes later and the only hands-off windows after that are
  the hourly backstop's ~20 s (2026-09-04: a rig that ended with
  `enabled=1` cost an operator two button presses). If that has already
  happened, arm a 2 s ssh poll that writes `enabled=0` and ask for a
  button press. On generations before 15, a button wake inside a stale
  RTC settle window re-suspended the reader seven seconds later — press
  again; from 15 on the broker clears the deadline on any non-RTC wake.
- **Wake it with the power button, not by waiting for the RTC.** Since
  2026-08-07 an RTC-backstop wake re-suspends after ~20 s (nobody is
  present when the alarm fires — `doc/power-management.md`, "The idle
  duty cycle"), and neither an SSH session nor UART traffic counts as
  activity: only `/dev/input` events do. A button press still grants the
  full idle window, which is the one you want for a login. The runtime
  pause on `/data/wilkbook/autosuspend.conf` survives reflashes and is
  writable from os1, so set it there before a deploy rather than racing
  a 20 s window afterwards.
- **`enabled=0` also inhibits the power button and the cover, by
  design** (2026-09-03, on the embrace branch's broker + direct-driver
  session, `doc/status.md`): the platform-controls broker reads the
  same `enabled=0` before honouring *any* transaction, not just the
  autosuspend timer, so a power tap while paused logs "accepted=false
  detail=globally inhibited" and does nothing — closing the cover does
  nothing either. If the button or the cover stops responding, check
  `/data/wilkbook/autosuspend.conf` before assuming a hang; set
  `enabled=1` to get them back.
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
- **Never read a regmap debugfs dump wholesale.** A glob over every
  `registers` file under `/sys/kernel/debug/regmap/` hung the device
  (2026-09-03, 13:55 MDT): the glob includes
  `dummy-syscon@fdc50000`, the PIPE GRF whose `pclk` is gated on this
  board — reading it wedges the bus exactly like the item-22 kexec hang
  (`doc/upstream-register.md`), except this time nothing was kexec'd at
  all, just read. Power button needed. Name the one regmap you want
  (`/sys/kernel/debug/regmap/0-0020/registers` for the RK817 PMIC, etc.)
  and never `cat`/`grep -r` the directory.

## Launching KOReader by hand (bypassing reader-session)

When shepherd's reader-session is in the way (crash-loop diagnosis, a
specific book, extra CLI flags like `-d` for input tracing), launch the
bundle directly — but replicate the service's environment EXACTLY.
`env -i` with only HOME/KO_HOME *works* and *lies*: KOReader comes up,
renders, turns pages — on its bundled fallback fonts, because
`EXT_FONT_DIR` is gone. An entire 2026-08-26 session's quality
judgments carried that confound before the operator caught it on video
(the tell: guile.epub paginates to 3716 pages under fallbacks, 3804
under the seeded fonts). The full recipe, matching
`reader-session.scm`:

```
KO=$(ls -d /gnu/store/*-koreader-bin-*/lib/koreader | head -1)
cd $KO && env -i \
  HOME=/root KO_HOME=/root/.config/koreader \
  PATH=/run/current-system/profile/bin \
  LC_ALL=en_US.UTF-8 \
  EXT_FONT_DIR=/run/current-system/profile/share/fonts/local \
  LD_LIBRARY_PATH=$KO/libs:$KO \
  ./luajit reader.lua [-d] [/path/to/book.epub]
```

Stop the service first (`herd stop reader-session` — it does NOT stop
the orientation bridge, which is a dependency, not a dependent). Kill a
manual reader with `pkill -f "luajit reader[.]lua"` — the bracket dodge
matters, and never in the same shell invocation that also *spells out*
a launch command containing the plain string, or pkill matches your own
command line and kills the session (three times, 2026-08-25/26).

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
