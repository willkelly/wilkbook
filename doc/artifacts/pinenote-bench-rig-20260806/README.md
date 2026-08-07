# Unattended bench rig, 2026-08-06 night: what works and what doesn't

The operator went AFK leaving the device in a camera box with a UART
cable attached, authorising reboots and os2 writes. Half the rig worked.
This is the record of which half, and the evidence harvested with it.

## Camera: WORKS, and can watch a boot

`/dev/video0` (1920x1080) looks down into the box at the panel; a second
camera on `/dev/video2` sees the same scene smaller. The panel is
**reflective**, so nothing is visible without the frontlight — the first
captures were black frames with a single LED dot until the frontlight was
raised over SSH.

Capture recipe that worked (no `v4l2-ctl`, no `fswebcam` on this host):

```sh
ffmpeg -f v4l2 -video_size 1920x1080 -i /dev/video0 \
       -vsync 0 -frames:v 25 -update 1 frame.jpg     # let AE settle
ffmpeg -i frame.jpg -vf transpose=2 rot.jpg          # panel is 90° in frame
```

Grab ~25 frames and keep the last: the first several are underexposed
while auto-exposure settles. For a boot, `-t 150 -vf fps=1` into numbered
files, then tile them into a contact sheet
(`-vf "transpose=2,scale=200:-1,tile=5x5:padding=4:color=red"`).

`os1-boot-contact-sheet.jpg` is such a sheet: an os1 reboot, one frame
per second, reading left-to-right, top-to-bottom. Frames 1–4 the desktop,
frame 5–6 the PINE64 "Booting…" splash, and **from frame ~11 onward the
panel is simply dark** — the frontlight goes off during boot and stays
off until KOReader's powerd sets a level. That blind window is exactly
where the boot-time display corruption under investigation appears, which
is why `pinenote/services/frontlight.scm` now lights the panel early.

The repo's real instrument for this rig is `pinenote/tools/optics` (it
takes `--camera /dev/video0`, uses the frontlight as the illuminant, and
classifies ghosting deterministically). The framing here meets its
requirement — whole panel in frame with margin — though the mount is at
an angle rather than straight down; the test card's corner fiducials are
what correct for that.

## UART: DEAD both directions — physical, not configuration

Host `/dev/ttyUSB0` (CH340) received **zero bytes at both 1500000 and
115200** while the device transmitted 200 marker lines. A wrong baud
gives garbage, not silence, so this was never a clock problem.

The SoC's own counters localised it in one command:

```
2: uart:16550A mmio:0xFE660000 irq:19 tx:8252 rx:0 RTS|DTR   (before)
2: uart:16550A mmio:0xFE660000 irq:19 tx:9843 rx:0 RTS|DTR   (after 50 lines)
```

`tx` climbing proves bytes left the SoC; `rx:0` proves the device never
received one either, all boot. Device-side `/dev/ttyS2` was correctly at
1500000 with a getty, and `/proc/consoles` listed it enabled. Both
directions dead at once is the **flipped USB-C plug** signature: SBU1 and
SBU2 swap with connector orientation, which swaps TX and RX. The port
refusing to charge is *not* evidence the link works — the debug cable
occupies the port either way. Fix is physical: flip the connector at the
device end.

**Consequence, confirmed empirically:** with no UART there is no way to
choose a boot slot. A reboot was issued and the device came back on
`/dev/mmcblk0p5` in 47 s — os1. The U-Boot menu is serial-only, its
default entry searches all partitions and finds p5 first (os1 carries
`/boot/extlinux/extlinux.conf`), and p3 `uboot_env` is an empty FAT12
with no file-based selector to write. Deploying to os2 stays safe and
useful; *booting* it needs the cable fixed or a human at the menu.

## What the harvested v3 logs say

`v3-boot-dmc-window.log` is the boot window from the v3 image, pulled off
p6 by mounting it read-only from os1 **before** overwriting the slot.
The ordering is the finding:

    23:30:31  Starting service pinenote-dmc...
    23:30:35  pinenote-dmc: FAILED: DDR did not reach 324000000 Hz within ~3 s
    23:30:35  [ddr-boost] node=/sys/class/devfreq/memory-controller floor=324000000
    23:30:36  Starting service pinenote-usb-acm-gadget...

The gadget service is what mounts debugfs, and it starts *after* dmc —
while ddr-boost, in the same second as the failure, found the devfreq
node already registered. The old check read the rate only from
`/sys/kernel/debug/clk/clk_summary`. So the "FAILED" line is most likely
a report about the **instrument**, not the switch: the module had loaded
and its devfreq device existed. Verification now reads devfreq first
(`pinenote/services/dmc.scm`), which needs no debugfs at all.

## What the next os2 boot should settle

v5's `pinenote-dmc` logs a checkpoint at `entry`, `blanked`, `ebc-idle`,
`switched`/`removed`, and `console-restored`, each carrying the EBC
interrupt count and the rate from both devfreq and clk_summary. Three
questions fall out of one boot:

1. **Does the fb blank cost a full-screen refresh?** Two independent
   source analyses agree the blank does NOT park the worker or disable
   the CRTC in any way this driver acts on — every EBC hook is gated on
   `mode_changed`, which an fbdev DPMS blank never sets. But the commit
   carries no damage blob, so the still-visible plane is committed as
   one area covering the whole 1872x1404 panel, and whether that area is
   dropped is a runtime data condition (`final_atomic_update` is seeded
   0xff white while the shmem fbdev buffer is zero/black, and fbcon's
   damage work races the blank). If `entry -> blanked -> ebc-idle` shows
   the count climbing by ~38-46, the blank is driving a full-screen
   **GC16 partial** — `default_waveform`, not the shipped GL16 — for
   0.6-1 s. That is pure cost: the fbcon unbind is what actually stops
   the damage producer, so the blank should then be deleted from the
   quiesce rather than waited out. (`echo 0 > blank` is a true no-op by
   the same analysis, asymmetrically, because the blit writes the
   destination buffer even when it reports "unchanged".)
2. **Was the EBC actually idle when the switch landed?** `ebc-idle`
   vs `switched` answers it directly, and the gate now demands 2.5 s of
   unchanged count rather than a single 500 ms pair.
3. **Did the switch ever fail, or only fail to be seen?** `devfreq=` on
   every checkpoint reports the driver's own view with no debugfs
   involved.

Then flip `/data/wilkbook/dmc.conf` to `noswitch` and boot again: same
blanking, same everything, no DDR switch and the rate left at 1056. If
the panel is clean there and dirty under `normal`, the switch (or the
rate) is convicted; if it is dirty both ways, this service is exonerated
and the cause is elsewhere in the v2+ images.

## Lesson worth keeping

Before an unattended session, prove the console link end to end — the
`tx`/`rx` counter check above takes one command and would have caught
this before the operator left. A rig is only as autonomous as its
weakest channel, and here that channel silently determined which OS
could be booted at all.
