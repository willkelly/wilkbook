# Deploying to the PineNote (os2 workflow)

This is the workflow actually used for hardware sessions: build host-side,
write only the inactive `os2` slot, observe over UART, and keep stock Debian
on `os1` as the rescue path. Nothing here touches `waveform`, `uboot`,
`uboot_env`, the partition table, or persistent boot selection.

## Preconditions (every session)

- The backup checklist in `doc/device-runbook.md` is still satisfied (both
  backup roots verify against `SHA256SUMS`).
- Stock Debian `os1` is known to boot and is reachable over SSH
  (`user@192.168.86.141`).
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

- Power-cycle and pick **"Boot OS2 (part 6)"** from the stock U-Boot menu.
  OS selection is always manual at the menu; never `fw_setenv`/`saveenv`.
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

## Stop conditions

Stop before any write if backups do not verify, the rescue path is unclear,
or the step would persistently alter boot order, U-Boot environment,
partition layout, or any partition other than `os2`. Never write the
`raw-with-offset` disk image to the device whole — only the extracted
rootfs, only to `os2`.
