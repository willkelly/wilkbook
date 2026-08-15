# Boot RAM, measured (2026-08-15)

The README's headline pitch number — "RAM in use at boot, ~164 MB, the
whole OS, KOReader included" — had no source in the repo. Issue #1 asked
for provenance. This is it.

Device: author's PineNote, os2 (`/dev/mmcblk0p6`), Linux 7.0.11
PREEMPT_RT, image `9a08803e…`. Operator rebooted and selected
"Boot OS2 (part 6)" at the U-Boot menu (an unattended reboot lands in
os1 — `doc/device-access.md`). Agent read over SSH; nothing written.

## Result

| when | `used` (`free -m`) | note |
|---|---:|---|
| t+20.0 s | 181 MiB | `reader-session` 5 s old, still allocating |
| **t+118.5 s** | **162 MiB** | settled |

`MemTotal` is 3,814,716 kB (3725 MiB) — the 4 GB part.

**The measurement includes the observer.** The SSH session used to take
it accounts for **14,672 kB (~14 MiB)** across two `sshd-session`
processes. So the settled figure is:

- **~162 MiB** with an SSH session attached, and
- **~148 MiB** for the device as it actually runs, unattended.

Either way the README's `~164 MB` is **confirmed and slightly
conservative**. The observer effect is larger than the discrepancy, so
quoting a tighter number than "~164 MB" would be false precision.

What is included: the whole OS with KOReader painted, Wi-Fi associated
(`wpa_supplicant`, `dhcpcd`), shepherd, udev and sshd. Largest RSS
consumers at t+20 s were `shepherd` (47.7 MB) and `luajit` (38.5 MB, the
reader). RSS double-counts shared pages, so those do not sum to the
total and are indicative only.

## What this does not establish

- **Not a minimal-boot floor.** It is the reader as it actually runs,
  network up. A figure taken before Wi-Fi association would be lower and
  would not describe the product.
- **One device, one boot.** No variance estimate.
- The t+20 s reading is *not* a second data point for the same quantity
  — it is the same quantity before KOReader settled, and it is recorded
  to show the settling rather than to be averaged with the other.
