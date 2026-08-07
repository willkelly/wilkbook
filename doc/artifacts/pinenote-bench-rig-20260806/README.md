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

The 11-agent analysis (5 traces, each adversarially re-derived, plus a
synthesis) ranked the causes. Two candidates it ELIMINATED from source,
which is why the service changed shape rather than gaining more waiting:

- *Late unguarded switch* (p=0.03). `wilkbook_dmc` cannot defer — no
  clock, regulator or OPP phandle, synchronous probe, and the switch
  happens inside `devfreq_add_device()`, which unregisters the device if
  it fails. A live devfreq node IS a completed, firmware-verified switch.
- *Blank/unblank desyncing the gray4 cache* (p=0.06). Every EBC hook is
  gated on `crtc_state->mode_changed`; an fbdev DPMS blank sets only
  `active_changed`. No park, no ctx realloc, no off-screen wash. The
  blank was therefore deleted outright rather than measured — it bought
  no quiescing while committing a damage-clip-less full-plane update at
  the moment the service believed it was quiescing.

The **leading hypothesis (p=0.34) is the ungated RESTORE half**: `bind 1`
repaints the whole visible console, and fbcon damage reaches the panel
immediately — `defio_delay_ms` governs only the mmap path, not fbcon's
`schedule_work` — so the service handed a still-driving panel to
reader-session, whose GC16 boot wash then interleaved with it. The
service now waits for EBC idle *after* the rebind too, and logs a
`restore-drained` checkpoint. Runner-up (p=0.2): the boot wash itself is
inherently fragile and the DMC window merely changed the timing that
exposes it — on that reading the corruption reproduces with `mode=off`.

So, from one boot, read the `cp=` lines in `/var/log/messages`:

1. `unbound -> ebc-idle`: how much EBC work was still draining when the
   old code would already have switched (it demanded one 500 ms pair;
   `protocol.md` asks for "several seconds").
2. `console-restored -> restore-drained`: the size of the repaint burst
   the old code walked away from. If this is tens of IRQs, the leading
   hypothesis is confirmed mechanically.
3. `trans=` must read 1 from `switched` onward, at every later
   checkpoint. A 2 anywhere is a DDR switch nobody ordered.
4. `devfreq=` reports the driver's own rate with no debugfs involved —
   the thing whose absence produced the v3 false negative.

Then flip `/data/wilkbook/dmc.conf` to `noswitch` and boot again: same
window, same repaint, no switch, rate left at the boot value. Clean there
and dirty under `normal` convicts the switch or the rate; dirty both ways
exonerates this service and points at the wash (p=0.2). `off` is the
third leg — no window at all.

## RESOLVED 2026-08-07: the switch was escaping the guarded window

The first instrumented os2 boot settled it from two dmesg lines:

    [10.601371] wilkbook-dmc memory-controller: DDR now 324 MHz (100634 us wall)
    [11.466365] Console: switching to colour dummy device 80x25   <- service unbinds fbcon
    [11.985670] Console: switching to colour frame buffer device 234x87

The DDR switch lands **865 ms before the guarded window opens**, with
fbcon actively painting the boot console. udev coldplugs the module and
the probe-time SET_RATE stalls every AXI master for 100.6 ms in the
middle of live EBC scans. The service's quiescing was never guarding the
event it exists to contain — it opened afterwards, every boot.

`/etc/modprobe.d/wilkbook_dmc.conf` was installed and did nothing:
eudev's kmod builtin loads by modalias without applying modprobe.d
blacklists. Fixed by clearing the device's `MODALIAS` in
`60-wilkbook-dmc-noautoload.rules`, before `80-drivers.rules` runs, so
only the service's explicit modprobe-by-name loads it.

**The failure is glass-side, and GC16 heals it.** `corruption-on-glass.jpg`
is the panel after that boot: vertical banding across the page, a dark
vertical bar at the right, a corrupted block top-right — with the
frontlight raised so it is unambiguous. `corruption-cleared-by-gc16.jpg`
is the same panel seconds later after ONE global refresh forced to GC16
(1 IRQ, 668→669). Completely clean.

That before/after is the diagnosis, not just a symptom: had the driver's
gray4 buffers been corrupted, a faithful global would have re-rendered
the corruption. They were not. The *glass* held voltages the driver never
commanded — exactly what a stall inside an active drive produces
(`ddr-dvfs-test/protocol.md`: "wrong voltages on some pixel region"). It
also explains the persistence: GL16 is neutral wherever belief agrees, so
every later wash was a no-op over it, while GC16 drives every pixel
through a full cycle.

Vertical banding is itself corroborating — a stall corrupts a contiguous
span of a scan, not a scattered set of pixels.

### The fix, verified on the next boot

Same three lines, before and after the udev MODALIAS clear:

    BEFORE  [10.601] wilkbook-dmc: DDR now 324 MHz     <- switch
            [11.466] Console: switching to dummy       <- window opens 865 ms LATE
            [11.985] Console: switching to frame buffer

    AFTER   [10.662] Console: switching to dummy       <- window opens FIRST
            [14.886] wilkbook-dmc: DDR now 324 MHz     <- switch, 4.2 s inside
            [15.214] Console: switching to frame buffer

The switch moved from 865 ms *before* the guarded window to 4.2 s
*inside* it. That 4.2 s gap is itself a result: it is the EBC-idle gate
waiting for the first time in this service's history — with `read-line`
resolving, `ebc-irq-count` finally returns a number instead of #f, so
`wait-ebc-idle` stops interpreting "unreadable" as "no EBC present,
nothing to wait for".

### What the live checkpoint table shows (first boot with working instruments)

    cp=entry            irq=209  thr=D  devfreq=absent     trans=absent
    cp=unbound          irq=211  thr=D  devfreq=absent     trans=absent
    cp=ebc-idle         irq=271  thr=I  devfreq=absent     trans=absent
    cp=switched         irq=271  thr=I  devfreq=324000000  trans=1
    cp=console-restored irq=271  thr=I  devfreq=324000000  trans=1
    cp=restore-drained  irq=388  thr=I  devfreq=324000000  trans=1

Every number earns its place:

- **`devfreq=absent` until `switched`** proves the udev rule works: the
  module is no longer loaded before this service runs. On the previous
  boot the same field read `324000000` at `cp=entry`.
- **`thr=D` at entry and unbound** — the refresh thread was
  *uninterruptible*, i.e. actively driving the panel, when the service
  started. The old code would have switched right there.
- **The entry gate did real work**: 211 → 271 is **60 more interrupts**
  after the fbcon unbind before the panel went quiet and the thread
  reached `I`. The switch then happened at `irq=271` — unchanged, thread
  idle. Perfectly guarded, and measurably so.
- **The restore gate did more**: 271 → 388 is a **117-interrupt** repaint
  burst from `bind 1`. The old code walked away mid-burst and handed a
  driving panel to reader-session — the leading hypothesis, now
  quantified and closed.
- **`trans=1` throughout** — exactly one DDR transition, inside the
  window, never repeated.

### On glass

`after-fix-clean-boot.jpg` is a boot with no suspend in between (the
earlier photos were all post-resume, which confounded them): the heavy
vertical striping is **gone**. A residual dark vertical bar remains, and
`after-fix-plus-gc16.jpg` shows one GC16 global clearing that too — so it
is also glass-side residue, introduced somewhere after the boot wash and
not healed by it. Smaller than the original defect and still open.

### Belief vs glass: the measurement that should have come first

`belief-vs-glass.jpg` — left is `/dev/fb0` rendered, right is the camera
view of the same instant. The operator's idea, and it retires an entire
class of argument: judging the panel by eye off a dim webcam frame, which
produced two wrong "it looks clean" calls from the agent in one session.

The framebuffer is **immaculate** — crisp text, clean logo, the thin
horizontal progress bar at the bottom reading 1 / 11. The glass carries
the same page **plus a thick dark vertical bar down the right edge that
appears nowhere in the framebuffer**, plus vertical striping. Both frames
are upright and the bottom progress bar lands in the same place in each,
so the orientations agree and the bar is a genuine extra rather than a
rotation artifact.

That is the whole diagnosis in one image: **the driver's belief is right
and the glass is wrong.** Repainting from that framebuffer can never fix
it, which is exactly why GL16 washes are no-ops over it (neutral wherever
belief agrees) and only GC16 — which drives every pixel through a full
cycle regardless of belief — clears it.

The tool is in `pinenote/tools/optics/belief-vs-glass.sh`. Run it at any
suspicious moment; it needs only ssh and the webcam.

### Chasing the residual bar (2026-08-07, still open)

What is established, each from a measurement rather than an argument:

1. **It is glass-side, not content.** A framebuffer dump
   (`dd if=/dev/fb0`, 1872x1404 XRGB8888) profiled by row shows only
   text lines — every dark run is 1-20 rows at 200-219 against a mean of
   240. There is no dark band anywhere in the content, yet the panel
   plainly shows one.
2. **One GC16 global clears it** (1 IRQ), and the panel afterwards is
   uniformly white under a full white fill — so the hardware is fine and
   the driver's belief is right; only the glass disagrees.
3. **Ordinary refreshes do not create it.** Clean the panel with GC16,
   then fire a GL16 global (the shipped waveform, 1 IRQ): the page comes
   back clean, no bar. The bar is specific to the boot sequence.
4. **It is not the DDR rate — at least not via the restart path.**
   `herd restart reader-session` reliably wrecks the panel far worse
   than boot does (it parks inverted and striped), and it does so
   **identically at 324 MHz and at 1056 MHz**. That also means the
   restart is *not* a faithful proxy for the boot path; it is a separate,
   harsher bug worth its own investigation.
5. **Geometry points at a time slice.** A vertical bar on screen is a
   horizontal ROW band in framebuffer space, and the EBC scans by rows —
   so the affected pixels are contiguous *in scan time*, which is what a
   stall or an interrupted drive looks like, not what a content bug looks
   like.
6. **A 1 fps camera pass over the boot** shows the shape of it: the wash
   flashes the panel white, the panel then goes DARK with vertical
   striations for ~8 s, returns light with heavy striping, and finally
   settles carrying the bar. The bar is the residue of that long messy
   sequence rather than of one discrete event.

The obvious next experiment — boot with the DDR switch suppressed and
compare — was blocked by the selector bug in the section above and is now
unblocked.

Two instrument bugs were fixed to get here, and both had been hiding
their own failure:

- **`use-modules` inside a shepherd gexp lambda does not import.** The
  service file is compiled, and the import does not reach the environment
  the compiled toplevel references resolve against. `read-line` and
  `scandir` threw *Unbound variable* on every call — inside `catch #t`
  handlers that turned each throw into a plausible `#f`. The tell was in
  the checkpoint line: `devfreq`, whose reader uses `read` rather than
  `read-line`, was the only field that ever reported a value. Fixed with
  explicit `(@ (ice-9 rdelim) read-line)`.
- Consequently the v3 boot's "FAILED: DDR did not reach 324000000" was
  **this**, not the unmounted debugfs it was attributed to above (and
  which an 11-agent analysis confirmed with high confidence). The
  debugfs reasoning was sound and the conclusion was still wrong: a
  simpler failure sat closer to hand, and the confirmation only checked
  the story, not the ground.

## Where the earlier session ended (historical)

The device auto-suspended in os1 while a transfer was in flight and
became unreachable — no UART, no network, no way to wake it without a
finger on the power button. So:

- **os2 currently holds v5** (`6d64fa34…`), which is bootable and
  instrumented but predates three fixes the analysis then produced.
- **The image you actually want is built on the host** and is NOT
  deployed. Deploy it before booting os2, or the boot spends itself on a
  service that still has the counterproductive `rmmod` branch, the inert
  fb blank, and the ungated restore that is the leading suspect.

Order of operations when you're back:

1. Flip the USB-C debug plug, then confirm with
   `sudo cat /proc/tty/driver/serial | grep '^2:'` — `rx` must climb as
   you type into the console.
2. From os1, stage and write the current artifact, verifying the SHA on
   both sides and reading back exactly the written range, per
   `doc/hardware-deploy.md`. It is already built:

       /tmp/opencode/pinenote-rootfs-artifacts/pinenote-reader-PNGuixRoot-20260806.ext4
       sha256 238f24a430215adadd9c6b14ac68f9a67ccb7662497895ad7ee2978536f5d589
       1946185728 bytes = 475143 x 4096   (bs=4096 count=475143)

   (`make rootfs-reader` reproduces it from this commit if the host copy
   is gone; the build is cached, so it costs minutes not hours.)
3. Leave `/data/wilkbook/dmc.conf` at `mode=normal` for boot 1.
4. Boot os2 from the U-Boot menu with the camera running, then read the
   `cp=` table out of `/var/log/messages`.

## Lesson worth keeping

Before an unattended session, prove the console link end to end — the
`tx`/`rx` counter check above takes one command and would have caught
this before the operator left. A rig is only as autonomous as its
weakest channel, and here that channel silently determined which OS
could be booted at all.
