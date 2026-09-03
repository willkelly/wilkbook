# Deploying to the PineNote (os2 workflow)

This is the workflow actually used for hardware sessions: build host-side,
write only the inactive `os2` slot, observe over UART, and keep stock Debian
on `os1` as the rescue path. Nothing here touches `waveform`, `uboot`,
`uboot_env`, the partition table, or persistent boot selection.

## Preconditions (every session)

- The backup checklist in `doc/device-runbook.md` is satisfied **for the
  device you are about to write** (both backup roots verify against
  `SHA256SUMS`). First session on a new device: run the runbook's
  "Provisioning a new device" section first — it creates that backup
  set.
- Stock Debian `os1` is known to boot and is reachable over SSH
  (`user@<os1-addr>` — record your device's concrete address and host
  key in your device ledger; access conventions are in
  `doc/device-access.md`).
- The UART console is connected and logging **before** booting os2: USB-C
  SBU1/SBU2 debug cable (per Pine64 wiki) into a CH340 adapter, `ttyS2`,
  **1500000 baud 8N1** (not 115200 — earlycon output becomes unreadable
  garbage at the wrong rate). Capture the whole session, e.g. picocom inside
  tmux.
- A power-cycle/recovery procedure is at hand; sessions have ended with the
  device stuck before the U-Boot menu, needing a manual reset with the
  operator physically present.

## Write protocol

1. Build the flavor image and extract the validated `PNGuixRoot` rootfs per
   `doc/building.md` (extraction, inspection, matched boot bundle).
2. Stage the rootfs on the device via stock Debian (`os1`) over SSH; verify
   the staged file's SHA-256 matches the host artifact.
3. Confirm `os1` is the running root (`/dev/mmcblk0p5`) and `os2`
   (`/dev/mmcblk0p6`) is unmounted.
4. `dd` the artifact to `/dev/mmcblk0p6` only, with an exact sector count.
5. Read back exactly the written byte range and compare SHA-256 against the
   artifact.
6. Record what was written (artifact, hash, flavor, kernel) in
   `doc/status.md`.

## Boot and observe

- Pick **"Boot OS2 (part 6)"** from the stock U-Boot menu; never
  `fw_setenv`/`saveenv`.
  **Slot selection is scriptable over UART as of 2026-08-02** — the menu
  is a normal serial UI and the countdown is ~15 s:

  ```
    *** U-Boot Boot Menu ***
       Search for extlinux.conf on all partitions   <- default/highlighted
       Boot OS1 (part 5)
       Boot OS2 (part 6)
       U-Boot console
    Hit any key to stop autoboot: 15 14 13 ...
  ```

  With the host port at 1500000 raw, send one DOWN per entry then ENTER:
  `printf '\033[B' > <uart-dev>; sleep 0.4; printf '\r' > <uart-dev>`
  (`<uart-dev>` is your host's adapter node — typically `/dev/ttyUSB0`
  for the CH340; record yours in your device ledger, and see
  `doc/device-access.md` for the port setup)
  selects OS1 (one down); two DOWNs select OS2. Any key stops the
  countdown, so the arrow both stops and moves. Watch the capture and
  react — do not fire blind.
  Caveat: keystrokes sent after the kernel is up land on the ttyS2 getty,
  so a stray arrow shows up as a failed login. Harmless, but send `\003\r`
  to clear the prompt afterwards.
  This means a hung os2 no longer strictly needs a human to get back to
  os1. A **hard** hang (no U-Boot at all) still needs the PMIC long-press.
  **Scope, measured 2026-08-02: this helps only while the device is
  BOOTING.** It does not wake a sleeping one. os1 auto-deep-suspends on
  idle, and from that state the UART is silent, ping fails, and serial
  keystrokes do nothing — serial is not an armed wake source under
  `wakeup-config = <0x10>`. Waking still needs a physical button press.
  So the honest rule is: UART removes the need for a human at the *menu*,
  not the need for a human at the *device*.
- Boot config inside the slot is `/boot/extlinux/extlinux.conf` with
  `/boot/Image`, an explicit `FDT /boot/rk3566-pinenote-v1.2.dtb` line
  (`FDTDIR` has proven unreliable with this U-Boot), `/boot/initrd.cpio.gz`,
  and `APPEND root=PNGuixRoot ...`. The root argument is Guix's literal
  label shorthand — never `root=LABEL=...` and never a raw `/dev/mmcblk*`
  path.
- Watch the UART log for: eMMC probe, initrd waveform install from `p2`,
  `PNGuixRoot` root mount, Shepherd start, getty on `ttyS2`, and (usb-console
  flavors) the ACM gadget binding `ttyGS0`.
- On the host, a successful ACM gadget enumerates as `/dev/ttyACM*`
  (gadget id 0525:a4a7) on the USB-C cable, with an auto-login `reader`
  shell (passwordless sudo). `pinenote-diagnostics` and the read-only default
  `pinenote-ebc-test` report remain available. Do **not** use the older
  `pinenote-ebc-test --draw-smoke` during the barrier campaign: it lacks the
  reader-ownership, generation-barrier, and signal/restoration safeguards of
  the dedicated command.
- After the session, power-cycle back to `os1` and confirm the rescue path
  still works.

## EBC barrier campaign (one supervised run)

**The campaign ran 2026-07-30 and PASSED all five acceptance criteria;
the generation barrier is hardware-proven** (generations 1 and 2, exact
restore, exit 0, clean reader repaint, four benign dmesg lines all
session — `doc/status.md`). The damage producer is measured, the
2026-07-29 panel question is closed, and the deployed cmdline now
carries `vt.global_cursor_default=0`
(`pinenote/images/pinenote-initramfs.scm`) — verify it in
`/proc/cmdline` on the running image instead of rediscovering the
cursor-damage failure mode. **This section stays as the replay
procedure.**

Before writing, record the exact manifest/rootfs SHA-256 and require
`inspect-rootfs-image.sh` plus the rootfs-matched bundle inspection to pass;
these bind `/boot/Image`, `/boot/config`, DTB, initrd, diagnostic, dormant Lua
modules, disabled suspend policy, and production no-import state to one ext4
identity. After boot, capture pre-run `dmesg`, then run only:

```sh
sudo herd stop reader-session
# fbcon MUST be unbound before the diagnostic — see "Why fbcon must be
# unbound" below.  reader-session re-binds it on stop, which starves the
# refresh thread and makes the barrier unserviceable.
echo 0 | sudo tee /sys/class/vtconsole/vtcon1/bind
pgrep -af 'reader[.]lua'             # must print nothing (escape the dot!)
sudo pinenote-ebc-sleep-frame-test --run
# after visible card, Enter restoration, and zero exit:
echo 1 | sudo tee /sys/class/vtconsole/vtcon1/bind
sudo herd start reader-session
```

Capture UART and `dmesg` through reader restart. Accept only a fully visible
card, two nonzero generation IDs, exact visible restoration, zero exit, and a
normal reader repaint. Any initial failure ends the campaign without retry;
any restore failure or EBC timeout/poison/uncertain-ownership signature requires
a reboot before further display work. This is not suspend permission.

**While the diagnostic is blocked at its prompt, the fb0 golden-hash
cross-check is free.** (This is how the 2026-07-29 panel question was
settled on 2026-07-30: fb0 matched the offline golden byte-for-byte, so
the paint was always correct.) It is *not* resolvable offline: the
mmap→`fsync`→deferred-io→damage path is `drm_fbdev_shmem`/`fb_defio`, DRM core,
which the ebc-logic harness does not compile. From a **second** session, while
the run is parked waiting for Enter (this does not consume the one-shot run):

```sh
dd if=/dev/fb0 bs=7488 count=1404 iflag=fullblock status=none | sha256sum
# expect 7d94be719f99c6684485f9f073d46c1a68fbdbe8b3461f62b7ad389bcf6acd97
```

That value is generated by `pinenote/tools/ebc-barrier/ebc-card-reference`
from the *same* `ebc_barrier_paint_card()` the device runs, and is pinned as a
golden by `make ebc-barrier-check`. Also grab `cat
/sys/class/graphics/fbcon/cursor_blink` and the EBC IRQ rate while you are
there — that names the damage producer (measured 2026-07-30:
`cursor_blink=1` and ~63 Hz with fbcon bound, exactly 0 Hz with it
unbound).

| fb0 hash | Means |
| --- | --- |
| matches | the paint reached framebuffer memory; any missing card on the glass is damage propagation or the panel, not the diagnostic |
| differs | the card never landed in fb0 — suspect the diagnostic's own paint/`fsync`, or something else writing fb0 (fbcon must be unbound, or its cursor mutates the buffer under the comparison) |

Before starting, confirm the EBC is actually idle:
`ps -o stat= -C ebc-refresh` (or by name) must show **`I`**, not `D`, and the
EBC IRQ line in `/proc/interrupts` must be roughly static. A `D` thread or a
tens-of-Hz interrupt rate means a refresh is already in flight and the barrier
cannot be serviced — fix that before spending the run.

**Why fbcon must be unbound.** `rockchip_ebc_partial_refresh` loops
`for (frame = 0;; frame++)` and exits only when its area list drains
(patch:4244-4247), while re-splicing `ctx->queue` into that list every frame
(patch:4269-4286). `rockchip_ebc_refresh_thread` reads `do_one_full_refresh`
only at the top of that outer loop (patch:4616-4626), so any sustained damage
source starves the global refresh the barrier depends on — silently, because
each individual frame completes and the 3 s `EBC_REFRESH_TIMEOUT` never fires.
`reader-session` unbinds fbcon precisely to avoid this and **re-binds it on
stop** (`pinenote/services/reader-session.scm:20`), so `herd stop` alone hands
the panel back to a blinking console cursor. This is what failed the
2026-07-29 campaign with `-110` and an entirely silent kernel log; see
`doc/status.md` and `doc/driver-findings-report.md`. Re-running under the
corrected sequence is a *new* campaign against a known cause, not the
forbidden blind retry of an unexplained failure.

**Optics-box sessions.** KOReader owns both frontlight channels and zeroes
them on exit, so after `herd stop reader-session` set
`backlight_cool`/`backlight_warm` to 153 again or the box is pitch black. Let
the camera's auto-exposure settle — grab a burst and keep the last frame; a
single grab after an idle period comes back black.

## defio_delay_ms sweep session (first boot of the publish-on-call image)

Goal: choose the shipped `defio_delay_ms` value and prove the single-pass
portrait page turn (`doc/refresh-policy.md`, "publish-on-call"). The
deployed image must carry the parameter — check
`/sys/module/rockchip_ebc/parameters/defio_delay_ms` exists before spending
any session time; if absent, the wrong image is running.

All over SSH; a UART observer is only needed for the boot itself.

```sh
# preconditions (same discipline as the barrier campaign)
sudo herd stop reader-session
echo 0 | sudo tee /sys/class/vtconsole/vtcon1/bind   # stop re-binds fbcon
pgrep -af 'reader[.]lua'                             # must print nothing
# EBC idle: IRQ delta over 6 s must be 0 (teardown repaint needs a few
# seconds to drain first)

LUAJIT=/run/current-system/profile/lib/koreader/luajit  # or koreader-bin store path

# 1. sweep: for each value, the corrected repaint-duration must show the
#    150/250/400 ms rows collapse to ONE pass once the window exceeds the span
for v in 50 250 1000; do
  echo $v | sudo tee /sys/module/rockchip_ebc/parameters/defio_delay_ms
  $LUAJIT repaint-duration.lua        # from pinenote/tools/ebc-damage-probe/
done
echo 50 | sudo tee /sys/module/rockchip_ebc/parameters/defio_delay_ms  # restore

# 2. re-run fsync-band.lua at the raised value: the fsync path must be
#    unchanged (publish is timer-independent); the timer path lengthens.

# 3. restore reader, then the real proof: with the chosen value applied,
#    drive portrait page turns (uinput injector) and count EBC IRQ bursts —
#    accept exactly ONE pass (one waveform's worth of frames) per turn.
#    The reader image now publishes via fsync at every refresh call, so
#    this exercises fsync + raised window + ioctl drain together.
echo 1 | sudo tee /sys/class/vtconsole/vtcon1/bind
sudo herd start reader-session
```

Expectations and traps, from the 2026-08-01 validation and sweep sessions
(`doc/status.md`). **The sweep ran 2026-08-01: 250 won and is pinned; this
section stays as the replay procedure.**

- One pass = the current temperature bin's phase count (38 and 46 both
  observed, and the bin can move mid-session); count passes against a
  same-session baseline, never a constant.
- Probe writes must flip against current content or `diff_mode` masks them.
  The document-level form of the same trap: a forward-only page-turn run
  silently pages past a short document's end and reads as ZERO frames —
  alternate KEY 158/159 and confirm content motion with fb0 hashes.
- `repaint-duration.lua`'s `settle()` waits for 400 ms of IRQ quiet; any
  window under test **larger than that** needs the patience raised past the
  window (sed `stable<400` up, e.g. 1300 for a 1000 ms window) or rows
  alias into their neighbors and read 0 frames.
- The idle-start pipeline floor is ~132–140 ms damage→first-frame; do not
  read it as publish latency.
- Start the optics injector BEFORE reader-session (KOReader enumerates
  input once, at init), and expect `QUIT` to restart the reader: destroying
  a held input device is the required-device-loss path, by design.
- Wash-ordering signature if a full refresh ever shows stale content:
  drain working = one wash of new content; drain broken = old-content wash
  plus a trailing non-flash partial of the new (`doc/refresh-policy.md`).
- Winner gets pinned in `pinenote-apply-ebc-params`
  (`pinenote/packages/firmware.scm`) and recorded in `doc/status.md`.

## The update path (after the enabling reflash)

Since 2026-09-02 the write protocol above is needed **once**: to put an
image that carries the update path on os2 (any reader image built from
this tree after that date does — the guix importer daemon, kexec, the
`wilkbook-generation` helper, first-boot root growth and the signing-key
ACL; `doc/update-path.md`). After that, a new build reaches the device
over Wi-Fi as a Guix system *generation*: registered, kexec'd as a
trial, health-checked, and promoted only then. A trial that never
answers leaves the boot menu's default on the last good generation.

**Once, per workstation:**

- `sudo guix archive --generate-key` (an interactive terminal; it
  writes `/etc/guix/signing-key.{pub,sec}`). The device's daemon accepts
  only nars signed by a key in its ACL.
- Stage that public key on the data partition as
  `wilkbook/guix/authorized-keys/<your-name>.pub` (from os1, where p7
  is `/home`: `/home/wilkbook/guix/authorized-keys/…`, `sudo install
  -m 0444`). The `pinenote-guix-acl` one-shot authorizes every `*.pub`
  there at each boot.
- An ssh alias for the reader that carries the per-slot known-hosts
  file, because both slots answer at one address with different keys
  (`doc/device-access.md`):

  ```
  Host pinenote-os2
    HostName <the reader's address>
    User root
    UserKnownHostsFile ~/.ssh/known_hosts_pinenote
    StrictHostKeyChecking yes
  ```

- A UART for the first kexec on a device (`doc/device-access.md`): a
  hung trial is recovered by the power button and the U-Boot menu, and
  the menu is driven by `pinenote/scripts/uart/uboot-pick-slot.sh`.

**Every update:**

```
make deploy DEVICE=pinenote-os2 [FLAVOR=reader-direct] [KEEP=3]
```

builds the flavor (cross, `--no-grafts`), sends only the store paths
the device lacks (guix's signed nar stream over plain OpenSSH; a
KOReader change is megabytes, a kernel ~100 MB), registers generation
N+1 (`add`: profile link, `/boot/gen-N+1/{Image,initrd,dtb,append}`,
the extlinux menu re-rendered with `DEFAULT` unchanged), kexecs into
it (`trial`: the reader stopped INT-first, Wi-Fi off, gadget unbound,
EBC quiescent, then `kexec -e`; the panel goes idle and the ssh link
dies with the old kernel — by design), waits for the new generation to
answer, runs `health` (`/run/current-system` is the new system, the
broker is ready, the reader started), and only then `promote`s it and
prunes to KEEP generations plus the promoted and booted ones, then
`guix gc`. Every refusal is printed as `NOT PROMOTED: …` and the
default is untouched. Expect the device to be silent for ~30 s around
the kexec; the reader is back with the page it had.

**On the device**, `wilkbook-generation list | add | trial N | health
[--expect S] | promote N | demote | prune --keep K` are the same
verbs; `deploy.sh DEVICE --rollback N` is trial+health+promote of an
existing generation.

**Rules learned on glass (2026-09-02, `doc/update-path.md` "Glass
notes"):**

- A kexec on this SoC needs what the helper now does: it appends
  `initcall_blacklist=rockchip_grf_init` to the *kexec* command line
  (the running kernel gates `pclk_pipe`; the next kernel's GRF init
  would write into the unclocked block and hang the bus at 0.12 s), and
  every flavor boots with `irqchip.gicv3_nolpi=1`. Cold boots are
  untouched by the first and need nothing else.
- The trial runs the helper the *target* generation ships. A
  generation older than the fix cannot be trialled *into* by kexec —
  cold-boot it from the menu instead, or prune it.
- A hung trial cannot be reset over the UART (it stalls before the
  serial driver is up; the debug cable has no reset line). The helper arms the SoC watchdog before `kexec -e` so that a
  kernel that never reaches its drivers would reset itself into U-Boot;
  through a kexec the armed watchdog expired without resetting the
  chip, twice (2026-09-02/03), yet the identical arm sequence **does**
  reset the chip when armed on a running kernel with no kexec involved
  (2026-09-03 runtime test, `doc/status.md`) — so the kexec transition
  itself defeats it, not the watchdog's configuration; the enabler is
  not the PX30-style `CRU_GLB_RST_CON` route bits (already set here).
  Ranked candidate mechanisms are in `doc/upstream-register.md` item 25.
  Until the kexec-path mechanism is found, a hung trial still needs the
  power button. U-Boot's default is os1, so: with
  the cable attached and `WILKBOOK_UART=/dev/ttyUSB0` set, `make deploy`
  drives the menu back to os2 itself and reports the device back on the
  previous `DEFAULT`; without the cable, a failed trial ends on stock
  os1 with SSH — change the default from there if you want
  (`rescue-generation.sh`), and pick os2 at the on-device menu. Before
  the watchdog: the power button, then `uboot-pick-slot.sh --slot os2`.
- Anything that changes early boot (kernel, DTB, command line) wants
  both proofs: the kexec trial and a cold boot from the menu.
- While a session needs stable SSH, pause auto-suspend
  (`/data/wilkbook/autosuspend.conf` = `enabled=0`) — and remember
  that with the pause in place KOReader's sleep screen still paints;
  the device is *not* asleep. Remove the file afterwards.

## Stop conditions

Stop before any write if backups do not verify, the rescue path is unclear,
or the step would persistently alter boot order, U-Boot environment,
partition layout, or any partition other than `os2`. Never write the
`raw-with-offset` disk image to the device whole — only the extracted
rootfs, only to `os2`.
