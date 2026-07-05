# Hardware status

Last updated: 2026-07-05. This is the single place to record what has actually
been proven on the device. Update it after every hardware session; the
detailed evidence lives in session logs, not in git.

**2026-07-05: reader first light, then the appliance path.** KOReader
renders and is pen- and finger-navigable on the panel, running
**natively on the framebuffer** (no compositor, no SDL — the cage/SDL
plan died on hardware; see the session section below and
`doc/koreader-spike.md`). Same day, the final image passed the
**unattended-boot test**: power-on → KOReader, no console intervention.

**2026-07-04: the 7.0 forward-port reached hardware parity on the
kernel-currency goals.** The 2026-07-03 fix-stack boot succeeded on every
axis: fbcon text on the panel, USB ACM gadget console working end-to-end
(this session's diagnostics were gathered *over that console*), full
`PREEMPT_RT`, untainted kernel, zero dwc3 errors, zero RT splats.

## Summary

| Area | 6.6.30 (m-weigand) | 7.0 forward-port (vanilla via nonguix) |
| --- | --- | --- |
| Boots to Guix userspace on os2 | yes | yes (needs `CONFIG_GPIO_ROCKCHIP=y`) |
| Waveform install (initrd + post-boot service) | yes | yes (2026-07-04: `ebc.wbf` installed; service `running #t` after the udev-ordering fix) |
| EBC display output | yes | **yes** (2026-07-04: healthy probe signature — waveform 0x19, `rockchip-ebc 0.3.0`, `fb0` — and fbcon text visible on the panel) |
| EBC temperature channel (TPS65185 IIO) | yes | **yes** (2026-07-04: `iio:device0` = tps65185, `in_temp_input` = 28000 m°C, via the forward-ported IIO provider) |
| UART console (ttyS2, 1500000) | yes | yes |
| USB ACM gadget console (ttyGS0) | yes | **yes** (2026-07-04: enumerates as `PineNote Guix Gate6 ACM Console`, reader shell works, zero dwc3 errors — `snps,dis_u3_susphy_quirk` fixed `ep0out`) |
| PREEMPT_RT | n/a (not supported on 6.6) | **yes** (2026-07-04: `#1 SMP PREEMPT_RT`, tainted=0, no sleeping-function/atomic splats) |
| Bluetooth firmware (BCM4345C0.hcd) | yes | yes (2026-06-11: `BCM4345C0.pine64,pinenote-v1.2.hcd` patch applied, build 0382) |
| Wi-Fi firmware (brcmfmac43455) | yes | yes (2026-06-11: brcmfmac 7.45.234 loaded on vanilla base — deblob problem confirmed solved) |
| KOReader on the panel (reader flavor) | n/a | **yes** (2026-07-05: native fbdev + evdev, pen- and finger-navigable, frontlight, MB Type fonts; unattended boot validated) |

The `pinenote-usb-console-linux-6-6` flavor is the fully working baseline.
The `pinenote-usb-console` flavor (7.0 forward-port) is the kernel-currency
track with the open issues below.

## 7.0 forward-port: findings so far

- The original pre-root stall was a mass deferred-probe failure ("GPIO not
  available": regulators, sdhci vmmc, dwc3 extcon, EBC temperature channel).
  Building the GPIO driver in (`CONFIG_GPIO_ROCKCHIP=y`) fixed it; 7.0.x now
  reaches Shepherd with root mounted from `PNGuixRoot`.
- Wi-Fi could not work on the original linux-libre base: the deblob pass
  disables non-free firmware loading (`/*(DEBLOBBED)*/` request paths in
  brcmfmac), and restoring the names/call paths in the patch was not
  enough. As of 2026-06-10 `linux-pinenote` builds from vanilla kernel.org
  sources via nonguix instead. **Confirmed fixed on hardware** (2026-06-11
  boot): brcmfmac loads firmware `BCM4345/6 wl0 ... version 7.45.234` on the
  vanilla base.
- Bluetooth firmware (`BCM4345C0.pine64,pinenote-v1.2.hcd`) loads despite the
  deblob, after the device-specific alias was added. Reconfirmed on the
  2026-06-11 vanilla-base boot (chip build 0382 after patch).
- 2026-06-10 bracketing experiment: the identical configfs ACM recipe run
  on stock os1 (6.12) binds, enumerates on the host as 0525:a4a7, and
  passes data both ways with zero dwc3 errors. The dwc3, usb2phy, and
  wusb3801/type-C DT nodes are identical (modulo phandle renumbering)
  between the working 6.12 DTB and our 7.0 DTB. The regression is
  therefore in kernel driver code between 6.12 and 7.0 (dwc3 core,
  inno-usb2 phy, or role-switch timing), not in DT and not in our
  userspace sequence.

## 2026-06-11 os2 boot (7.0.11 vanilla, v3 gadget) — log recovered 2026-07-03

The boot reached Shepherd with root on `PNGuixRoot`; UART/tty services,
Wi-Fi, Bluetooth, stylus (w9013 + ws8100_pen) all came up. Four distinct
failures, all root-caused on 2026-07-03 with fixes staged in this repo:

1. **EBC display (the panel blocker)**: `rockchip_ebc` probe failed hard:
   `OF: /ebc@fdec0000: could not get #io-channel-cells for
   /i2c@fe5c0000/pmic@68` → `error -EINVAL: Failed to get temperature I/O
   channel` (terminal, no deferral). Cause: the EBC driver reads panel
   temperature through an IIO channel on the TPS65185 EPD PMIC. The stock
   6.12 downstream kernel patches the TPS65185 driver to register an IIO
   temperature channel and its DTB carries `#io-channel-cells` (verified
   live on os1: `iio:device0` = `3-0068` with `in_temp_input`). Mainline's
   `drivers/regulator/tps65185.c` (new in ~2025) exposes the temperature
   as **hwmon only** — visible in the log as `hwmon hwmon2: temp1_input not
   attached to any thermal zone`. Fix: the forward-port patch now adds a
   minimal IIO temperature provider to mainline `tps65185.c` and
   `#io-channel-cells = <1>` to the `ebc_pmic` DT node.
2. **Waveform post-boot service**: `no waveform source found` — the
   shepherd service only required `root-file-system` and ran before udev
   created `/dev/disk/by-partlabel/waveform`. Fix: require `udev` and add a
   sysfs `PARTNAME=waveform` scan fallback (same discovery as the initrd).
   The initrd-side install (which feeds the in-initrd EBC probe) was fine.
3. **Gadget modprobes all failed**: `modprobe: FATAL: Module ... not found
   in directory /lib/modules/7.0.11`. Two-part cause, verified by chroot
   into the os2 rootfs from os1: Guix's kmod ignores
   `LINUX_MODULE_DIRECTORY` (the setenv in the service did nothing), and
   the raw kernel package has no depmod database — only the kernel
   *profile* (`/run/booted-system/kernel`) carries `modules.dep`. Fix:
   `modprobe -d /run/booted-system/kernel` (chroot-verified to resolve
   libcomposite).
4. **debugfs**: the defconfig had `# CONFIG_DEBUG_FS is not set`, so the
   Guix `/sys/kernel/debug` file-system service looped on EPERM and the
   gadget service could not reach the dwc3 debugfs mode path — the v3
   role-gate then (correctly) refused to bind, so `ep0out` was never
   retested this boot. Fix: `CONFIG_DEBUG_FS=y` in the defconfig.

Also staged 2026-07-03:

- `CONFIG_PREEMPT_RT=y` (full RT preemption is a project goal for
  pen/refresh latency; arm64 supports mainline RT since 6.12). Confirmed to
  survive olddefconfig; built kernel banner reads `#1 SMP PREEMPT_RT`.
- The `eink,ed103tc2` panel-simple entry (see
  `doc/kernel-forward-port.md`) — without it the EBC probe would clear the
  temperature channel and then park forever in `-EPROBE_DEFER` waiting for
  a panel driver that vanilla 7.0 does not have. Caught by adversarial
  review of the fix stack, not by a hardware session.
- `snps,dis_u3_susphy_quirk` on the dwc3 node — targets the `ep0out`
  root cause identified by research: mainline `cc5bfc4e16fc` (6.15,
  stable-backported) sets `GUSB3PIPECTL.SUSPHY` at core init while the
  RK3566 OTG's USB3 PIPE phy is unwired, timing out the first ep0out
  endpoint command. Explains cleanly why vanilla 6.12 worked and 7.0
  failed with identical DT. Note the 6-11 boot also revealed
  `/sys/class/usb_role` is empty on this DT (wusb3801 registers no role
  switch), so the v3 gate passes vacuously and proceeds to the debugfs
  mode write once debugfs exists.

## Current os2 contents

os2 currently holds the 2026-07-05 **evening (phase A) build**, SHA
`f4e0cd5d745a5e963aadc69f4a0e40a9c8b914c054e93755d9334d6fce0e9c98`,
written and readback-verified from os1 the same evening — **boot
pending**. It supersedes two same-day predecessors that were each
booted and validated: the midday build (`0a8a55c2…` — unattended boot,
touch, pen, frontlight, MB Type fonts all validated; see the session
records) and the morning build (`40393404…` — touchscreen probed, but
KOReader white-screened on the missing KO_HOME; hotfixed live).

Phase A adds over the validated midday build (offline gates green,
optics judgment pending): the >=60%-area flash policy (menus stop
washing the whole panel), the pre-KOReader panel blank+wash (boot text
no longer lingers), `[pn-refresh]` intent tracing to
/var/log/reader-session.log, and the virt-only virtio-gpu/input
modules + probe token for the rung-4v visual loop.

Contents carried over from the earlier 2026-07-05 builds:

- KOReader **native fbdev** device target grafted into `koreader-bin`
  (pen input via pure-Lua evdev backend, frontlight/battery powerd,
  full refresh = EBC `GLOBAL_REFRESH` ioctl); reader-session service
  runs `luajit reader.lua` directly and unbinds fbcon for the session.
  cage/seatd are gone from the image.
- Boot fixes for everything recovered by hand on 2026-07-04: gadget
  service requires `file-systems` (debugfs EBUSY race); waveform +
  ebc-params scripts export a PATH (shepherd runs them env-empty);
  koreader.sh shebang no longer x86_64-mangled (shebang phases deleted).
- **cyttsp5 touchscreen DTS node** (`cypress,tt21000` on i2c5 +
  pinctrl) added to the forward-port patch — driver was already `=m`
  but mainline's DTS has no node (neither does hrdl's tree; taken from
  m-weigand's). **Validated on hardware 2026-07-05**: native screen
  coordinates, finger navigation works.

First-boot checklist for the phase A (`f4e0cd5d…`) artifact: boot text
washes to clean white before KOReader appears; menu open/close updates
without a whole-panel flash; ghosting from un-flashed overlays stays
tolerable (note where it does not — that calibrates the phase B
workbench); everything from the midday build still works (unattended
boot, touch, pen, frontlight, fonts). Harvest
`/var/log/reader-session.log` afterwards — it now carries the
`[pn-refresh]` intent trace.

The previously deployed `pinenote-reader-PNGuixRoot-20260704.ext4` (SHA
`23e597fd…`) was **booted and live-debugged 2026-07-04/05** — session
record below; its staged copy remains on os1 for rollback.

## 2026-07-04/05 reader first light (os2 boot of the 20260704 artifact)

The boot validated the base system again (kernel 7.0.11 PREEMPT_RT
tainted=0, cherry-picked driver healthy, gadget console up after manual
recovery) and produced a chain of findings that ended with KOReader
working. Everything below was diagnosed and worked around **live over
the ACM console**, then turned into the staged fixes above.

Boot-time service failures (all now fixed in-repo):

- The gadget service raced the fstab mounts to `EBUSY` on debugfs,
  cascading into every dependent service; recovered live with
  `umount`/`herd start`. Fix: require `file-systems`.
- `pinenote-ebc-params` died with exit 127: shepherd one-shots run with
  an empty environment and the script needs `cat`. The waveform script
  only survived by luck (its early-exit path is all shell builtins).
  Fix: both scripts export PATH.
- KOReader couldn't launch via `bin/koreader`: cross `patch-shebangs`
  had rewritten `koreader.sh`'s `#!/bin/sh` to a build-machine x86_64
  bash ("Exec format error"). Fix: delete the shebang phases.

The display mystery (why the panel showed console text while the kiosk
"ran"), root-caused in three layers — full narrative in
`doc/koreader-spike.md` §3:

1. **fbcon stomps the compositor.** `console=tty0 ignore_loglevel`
   means every kernel message redraws fbcon, and the DRM fbdev
   emulation's flushes commit over the compositor's frames (observed
   as 1872×1392 full-frame blits at ~8 Hz with `drm.debug=0x2`, which
   itself feeds the loop). cage's own frames *were* reaching the
   panel — and being immediately overwritten. Unbinding fbcon
   (`vtcon1/bind=0`) gave cage the panel: uniform gray + software
   cursor, confirmed visually.
2. **SDL3 first-frame deadlock under wlroots** (frame callback
   requested on a surface that's then unmapped; wlroots never fires
   it; SDL parks in `ppoll` forever, 0 CPU).
3. **SDL3 cannot present on Wayland without GL/Vulkan** — SDL3 has no
   software present path (SDL2 did). The device has neither; the
   renderer cascade fails and KOReader ignores the failure and runs
   blind. This killed the kiosk architecture, not just a configuration.

The pivot, built and validated the same session: KOReader's own e-ink
architecture (fbdev + evdev, as on Kobo). Verified `/dev/fb0` mmap
writes reach the panel via deferred-io (luajit one-liner, black band
visible) before writing the port. Then the native device target
(`pinenote/packages/koreader-device/`) brought first light:

- `initializing for device PineNote`; quickstart guide rendered on the
  panel after a `GLOBAL_REFRESH` wash; **pen taps navigate the UI**
  (w9013 axes 20966×15725 auto-scaled to 1872×1404, no axis swap
  needed); user exited KOReader from its own menu.
- Frontlight confirmed working this session via the sysfs backlights
  (cool=60/warm=140 were set live; powerd now drives the same knobs).
- **No finger touch**: `/proc/bus/input/devices` shows no touchscreen —
  `CONFIG_TOUCHSCREEN_CYTTSP5=m` was set but no DTS node exists in
  mainline (or hrdl); node now staged from m-weigand's tree.
- Driver observability gaps found while debugging, for the config
  wishlist: `EXTRACT_FBS` ioctl is stubbed `-EOPNOTSUPP` in the 7.0
  port (the buffer-dump oracle is unavailable on-device) and
  `CONFIG_DYNAMIC_DEBUG` is off (`drm.debug` sufficed).
- The pen pressure warning `w9013 … Ignoring pressure offset greater
  than 50%` appears whenever libinput handles the pen (cage runs);
  KOReader's evdev path doesn't involve libinput. Park for the pen
  polish pass.

Previous os2 contents (2026-07-03, hardware-validated 2026-07-04):
`pinenote-usb-console-PNGuixRoot-20260703.ext4`, SHA
`4cab03b25c2c80ae6a3c22147f30c1022fcfe3e9f787ab302d8dbc9e034ea43e` —
staged copy still on os1 if a rollback write is wanted.
- Contains the full 2026-07-03 fix stack: TPS65185 IIO +
  `#io-channel-cells`, `eink,ed103tc2` panel-simple entry,
  `snps,dis_u3_susphy_quirk`, `CONFIG_PREEMPT_RT=y`,
  `CONFIG_DEBUG_FS=y`, waveform-service udev ordering + sysfs fallback,
  gadget `modprobe -d` fix.
- This replaces the 2026-06-10 artifact whose boot produced the
  2026-06-11 log above. Next os2 boot is the first observation of the
  whole stack.

## 2026-07-04 boot session (fix-stack validation — all green)

The os2 boot of `pinenote-usb-console-PNGuixRoot-20260703.ext4` validated
the entire 2026-07-03 fix stack. Diagnostics gathered live over the ACM
gadget console itself (the strongest possible evidence for the gadget
fix):

- `uname -a`: `Linux pinenote-usb-console 7.0.11 #1 SMP PREEMPT_RT 1
  aarch64`. `tainted = 0`. No RT splats in dmesg.
- EBC: `rockchip_ebc_probe start` → `Loaded 4-bit PVI waveform version
  0x19` → `Initialized rockchip-ebc 0.3.0` → `fb0: rockchip-ebcdrm` —
  identical to the healthy 6.12 signature; fbcon text visible on the
  panel. Benign residue: `panel-simple: Expected bpc in {6,8} but got: 4`
  (warning only) and a missing optional
  `rockchip_ebc_default_screen.bin` (could ship one later).
- Temperature: `iio:device0` = `tps65185`, `in_temp_input` = 28000
  (28 °C) — the forward-ported IIO provider feeding per-refresh LUT
  selection.
- Gadget: host enumerates `PineNote Guix Gate6 ACM Console`
  (1d6b:0104 composite); `dmesg | grep -iE "dwc3|ep0"` is **empty** —
  the `snps,dis_u3_susphy_quirk` DT fix eliminated the `ep0out` failure.
- Services: `pinenote-waveform`, `pinenote-usb-acm-gadget`,
  `pinenote-usb-acm-console`, `pinenote-ebc-params` all
  `running`/`#t`; `/lib/firmware/rockchip/ebc.wbf` installed this boot.
- Remaining dmesg errors, both known/benign: `No available vop found`
  (PineNote has no VOP — EBC is the display) and the pre-existing
  `ws8100_pen` status-property `-74` quirk (also present on 6.6).

## 2026-07-04 display exercise (same boot, over the ACM console)

- `pinenote-ebc-test --draw-smoke`: white square drawn and restored.
- 16-step grayscale ramp written to `/dev/fb0` (XRGB8888, 1872×1404,
  stride 7488) with plain `dd`/`tr` — all 16 levels rendered.
- `GLOBAL_REFRESH` ioctl (`0xC0016440` on `/dev/dri/card0`) triggered
  successfully **from stock Guile via the FFI** — no compiled tools
  needed on the device. Packaged as `pinenote-ebc-refresh` in
  `pinenote-ebc-test` for future images.
- The device's own waveform was pulled over the ACM console (base64,
  ~1.5 s for 2 MiB) and SHA-verified against the device copy
  (`ba3d4883…`); preserved at
  `~/pinenote-backup/2026-07-04-wbf-pull/` and used as the input for the
  new host-side parser tests (`pinenote/tools/wbf/`, ladder rung 1 —
  all tests pass; see `pinenote/tools/wbf/README.md` for what the
  waveform contains).

## 2026-07-05 (evening, offline) refresh-policy phase A built — NOT yet on hardware

Built and offline-validated the first refresh-policy pass plus its
tooling; **no hardware validation yet** (the deployed os2 image predates
these changes). New artifact `pinenote-reader-PNGuixRoot-20260705.ext4`
SHA `f4e0cd5d745a5e963aadc69f4a0e40a9c8b914c054e93755d9334d6fce0e9c98`
carries: (1) device-target refresh policy v1 — flashui/flashpartial no
longer always fire the whole-panel GLOBAL_REFRESH; they wash only when
damage covers >=60% of the panel, so menu open/close stops blinking the
screen (ghosting is cleared by KOReader's every-N-pages full refresh);
(2) every refresh intent traced as a `[pn-refresh]` line in
/var/log/reader-session.log (the capture side of the replay workbench);
(3) reader-session blanks the panel white + one global wash before
KOReader spawns, so retained boot text disappears immediately; (4)
kernel gains virtio-gpu/virtio-input modules (virt-only, invisible on
hardware) and the KOReader probe honors the harness-only
`wilkbook.force_device=pinenote` token. Offline gates: rung 4 all green
on the new image, and the new **rung 4v visual loop** (`make
qemu-virt-visual`) passed first try — QMP screendumps show the KOReader
quickstart rendered in Equity at 1872x1404 on the virt framebuffer, and
a scripted tap dismissed a toast (input path proven; shots in the run
directory). **os2 write done same evening** (full protocol, readback-SHA verified
byte-exact); boot + optics judgment pending — the visible tests are (1)
boot text washes to white before KOReader appears, (2) menu open/close
no longer flashes the whole panel, (3) where ghosting from un-flashed
overlays actually bothers a reader.

## 2026-07-05 os2 write: final reader image deployed (unattended boot pending)

Wrote `pinenote-reader-PNGuixRoot-20260705.ext4` (SHA
`0a8a55c253119249da44ef8421f538deb82b2d1899beb3164cc318ad68a1894c`,
1 903 083 520 bytes) to `/dev/mmcblk0p6` from os1 over SSH with the full
protocol (os1-root confirmed, p6 unmounted, dd with fsync, readback-SHA
verified byte-exact). This supersedes the first-light build that was on
os2, which predates the KO_HOME fix and white-screens on unattended
boot. What's new in this image vs. what os2 held: KO_HOME set by
reader-session (fixes the cache-init crash loop), MB Type fonts staged
with Equity A / Concourse 4 / Triplicate A Code defaults (Noto
fallbacks), cyttsp5 finger-touch DTS node, and the three boot-service
fixes. All offline gates green at deploy time, including the completed
rung 4 (full service stack + clean poweroff asserted in-guest, 2×
consecutive).

**Unattended boot: VALIDATED same day.** Will booted os2 with no console
intervention and KOReader appeared on the panel. Read-only ACM check
confirmed the reader process (`luajit reader.lua`, PID 318 — a low PID,
i.e. one clean start, no respawn churn). The ACM console on this image
lands in the unprivileged reader shell (`pinenote-acm$`), so root-side
herd/syslog checks need the UART or os1 post-mortem instead. This
closes the appliance-path milestone: power-on → reader, hands off.

**Validated in the same session:** frontlight brightness, finger touch
(cyttsp5), pen, and the **MB Type reading fonts** — Will confirmed
Equity A active in the book view (the UI chrome stays Noto Sans by
design; only the reading fonts are seeded). Known rough edge, expected:
**page turns flash** — the driver global-refreshes past
`refresh_threshold=60` and a page turn damages ~100% of the panel, so
every turn is a full refresh. That is the refresh-policy tuning work
(ROADMAP §4), not a regression.

## 2026-07-05 the qemu-virt "udev deadlock" was never a deadlock — rung 4 now asserts the full service stack

The 2026-07-04 "virt deadlocks entering udev" finding (below) is
**retracted**. The guest boots to completion every time; what stops is
the *console log*, deterministically, by design:

- Shepherd (PID 1) routes its messages through `call-with-syslog-port`
  (`comm.scm`): it first tries to connect to **/dev/log** and only falls
  back to `/dev/kmsg` (which is what reaches the serial console) when
  that fails. Shepherd 1.0's built-in **system-log service starts
  listening on /dev/log ~5 s into boot**, and from that moment every
  shepherd message — including `Service udev has been started` and the
  one-shot completions — goes to **/var/log/messages** and the console
  goes dark. All nine captured boot logs stop at the exact same place
  (the loopback/udev-logger lines at guest t≈5.2 s). 100% deterministic;
  there was never a per-boot race.
- What looked like "login unsticks the wedge" was observability, not
  causation: logging into a "wedged" guest and running `herd status
  udev` showed *"It is running since … (3 minutes ago)"* — it had
  completed long before, on its own. `ps` in the same guest showed the
  whole stack up: udevd, nscd, six gettys, and the reader-session
  **luajit process running** (KOReader). /var/log/messages holds all
  the "missing" lines.
- The theory-killing experiment: the interim harness poked a quiet
  guest with four *clean* root-login/`herd`/`exit` cycles — every one
  executed perfectly (login, prompt, herd reply, logout, getty respawn),
  proving shepherd's SIGCHLD handling, process monitor, and control
  socket were all healthy — yet the console still never showed udev
  completing. That ruled out the shepherd lost-wakeup theory the pokes
  were built on and pointed the investigation at the logging path.
- The earlier exonerations stand (kernel, eudev `settle`'s hard 120 s
  deadline, entropy, signalfd) — but the conclusion is stronger: nothing
  was ever stuck. There is **no upstream shepherd bug to file** (the
  kmsg→/dev/log switchover is intended behavior, if a spooky-quiet one).
- New virt-only finding while validating: with no EBC framebuffer on
  virt, KOReader's luajit **spins a vCPU**, which under TCG starves the
  guest enough to produce soft-lockup/RCU-stall splats and a sluggish
  console. Harmless on virt, absent on hardware (fb exists); the
  harness stops reader-session once its start is confirmed to keep the
  guest responsive.

The assertion harness (`run-virt-assertions.sh`) was redesigned around
this: the console lives on a socket chardev (qemu `logfile=` tees the
capture; anything can connect for post-mortem debugging), and once the
login prompt appears the harness **logs in as root over the socket and
asserts the post-switchover milestones from inside the guest** — it
greps /var/log/messages for udev completion, the pinenote-waveform and
pinenote-ebc-params one-shots, and reader-session start, echoing
VIRTCHK-\* sentinel lines that land in the console log; then it powers
the guest off cleanly and requires `reboot: Power down`. Since
reader-session's shepherd requirements are `(udev user-processes
pinenote-waveform pinenote-ebc-params)`, its start line transitively
proves the whole service-ordering chain that cost the first two
hardware sessions. Rung 4 now covers power-on → full service stack →
clean shutdown, unattended.

## 2026-07-04 qemu-virt rung 4 (offline) — mechanized boot assertions + a udev-hang finding

*(Superseded 2026-07-05, above: the "deadlock" was a console-logging
artifact — shepherd's messages divert from /dev/kmsg to /var/log/messages
once the system-log service is up. The boot completes; the one-shots DO
run on virt.)*

Built the mechanized qemu-virt gate (`make qemu-virt-check`, offline ladder
rung 4). Booting the real 2026-07-03 artifact on QEMU `virt` with the pulled
waveform, it asserts and passes all boot milestones **through Shepherd
start**: kernel 7.0.11 `PREEMPT_RT`, `root=PNGuixRoot`, initrd waveform
install from `/dev/vda1`, EBC display module load, `PNGuixRoot` visible
pre-root at `/dev/vda2`, root fsck-clean mount, `Service root-file-system
running #t`, and reaching `Starting service udev`; and no panic / RT
sleeping-in-atomic / root-not-found / `PNGuixRoot`-not-visible. The whole
run is ~45 s (quiescence-terminated).

**Finding:** the virt boot then *deadlocks entering the `udev` service.*
After `Starting service udev` → udevd starts → shepherd `waiting for
udevd...` → loopback up, the console goes silent at guest t≈12.3 s and never
advances. CPU sampling of the QEMU process shows **0.5 % of one core** (13 s
of CPU over 6+ min elapsed) — the guest is idle-blocked, a genuine deadlock,
not TCG slowness. So the post-udev one-shot services (`pinenote-waveform`,
the ACM gadget, `pinenote-ebc-params`) **never run on virt** — correcting the
earlier doc claim that "the one-shot services run." Consequently the
service-ordering regressions (waveform/udev race, gadget `modprobe -d`) are
*not* covered by qemu-virt and stay on the host tools + hardware. Diagnosing
the hang is blocked on visibility: the defconfig ships
`CONFIG_MAGIC_SYSRQ_SERIAL` and `CONFIG_DETECT_HUNG_TASK` **off**, so no
serial-SysRq or automatic blocked-task backtrace is available — a debug
kernel enabling both (or a gdbstub attach) is the next step (ROADMAP §3
rung 4). This does not affect hardware, where all of these services are
confirmed working (2026-07-04 above).

## 2026-07-04 refresh harness rung 7a (offline) — the refresh machine executes on the host

Built spike option (a) from `doc/ebc-harness-spike.md` the same day it was
scoped: `pinenote/tools/ebc-logic/ebc-refresh-test` runs the **verbatim**
driver's probe, global/partial refresh orchestration, LUT upload, DMA
windowing, IRQ/completion contract, mid-refresh buffer switching, and the
refresh-thread body against a behavioral EBC model (`shim/fake-ebc.h`),
under ASan, as part of `make ebc-logic-check`. All green against the
device's own waveform, including the strongest check: all 256 Y4 (from,to)
drive sequences observed at the fake device match rastersim's independent
decode of the same `.wbf` (GC16@25 °C, 38 phases). Two rung-2 findings are
now *executed*, not just read: the `ctx_free` teardown UAF (ASan-verified
reproducer, asserted by the test runner) and scheduler QUIRK E (chained
begin-together produces device-visible phase-index regressions —
conflicting waveform data on hardware). The differential also re-confirmed
from the hardware side that `blit_direct` (unused, `direct_mode=0`) reads
the LUT transposed. Hardware truth unchanged: the model encodes our
understanding of the silicon; the on-device `EXTRACT_FBS` differential
remains the ground-truth complement.

## 2026-07-04 hrdl 6.19 cherry-picks (offline) — two ported, two rejected on evidence

The ROADMAP's four cherry-pick candidates were read as actual diffs from
`git.sr.ht/~hrdl/linux` `v6.19_ebc_custom` (full record:
`doc/kernel-forward-port.md`). Ported into the forward-port patch:
`usleep_range`→`fsleep` (three sites) and the `dma_sync` size shrink,
translated to our area-list partial refresh (per-frame blitted-row spans
instead of full ~1.3–2.6 MB buffer cleans — RT latency win). Rejected:
the ≥19 °C temperature clamp and pixels-to-IDLE, both workarounds for
their 60–85 Hz rework's early-cancellation / per-pixel scheduler state,
which our m-weigand-lineage copy does not have. To make the shrink
provable and the clamp rejection evidence-backed, the refresh harness
grew a **non-coherent DMA model** (the fake device reads per-mapping
shadow buffers that only `dma_map_single`/`dma_sync_single_for_device`
publish — an under-synced CPU write is now a test failure, not a silent
pass) and a **cold-bin test** (0 °C selects and cleanly orchestrates the
131-phase GC16 waveform). All host suites green before and after the
patch edit; `make kernel-drv` computes; validated only offline — the
shrunken syncs ride along for hardware validation next session.

## 2026-07-04 KOReader packaging spike (offline) — reader track started, KOReader first

Track 4 reprioritized: KOReader leads (an external user wants to run
it). Spike result (`doc/koreader-spike.md`): `koreader-bin` packaged
from the upstream `linux-arm64`/`linux-x86_64` release tarballs
(`pinenote/packages/koreader.scm`, gnu-build-system + patchelf; the
bundle is self-contained except glibc and the Wayland client libs its
SDL3 dlopens). Proven offline: the x86_64 variant boots the complete
KOReader frontend headless (`SDL_VIDEODRIVER=offscreen` — the bundled
SDL3 has wayland/offscreen/dummy backends only, so the device needs a
Wayland compositor) and sits in its UI loop; the aarch64 variant
cross-builds with correct target interpreter/rpath (and its luajit
executes under qemu-user). The kiosk was built the same day: stock
wlroots propagates mesa, which does not cross-compile, so
`pinenote/packages/kiosk.scm` carries `wlroots-pixman`/`cage-pixman`
(no mesa/vulkan/Xwayland — the EBC has no GPU path; pixman on dumb
buffers), plus `reader-session.scm` (respawning root kiosk,
`LIBSEAT_BACKEND=builtin`) and the `reader` flavor (usb-console +
kiosk). Validated offline: full system closure cross-builds;
`make rootfs-reader` produces a preflight-clean
`pinenote-reader-PNGuixRoot-20260704.ext4`; the exact
compositor+client pairing (cage-pixman nested in a live session,
KOReader inside) runs end-to-end. One isolated offline-only failure:
under a *headless* wlroots backend SDL3 segfaults on the
zero-capability seat (no input devices) — can't occur on device
(touch+pen always present); verify at first light. Next: panel/pen
validation on hardware.

## Next sessions

- ~~Diagnose the qemu-virt udev deadlock~~ Done offline 2026-07-05 (no
  deadlock — a console-logging artifact; see that section). Rung 4 now
  asserts the full service stack unattended, no debug kernel needed.
- Wi-Fi on 7.0 end-to-end (firmware load is proven; the usb-console
  flavor has no networking userland — needs the networked flavor or a
  credentials story). Consider the community-standard ECM ethernet
  gadget alongside ACM.
- RT characterization under load (refresh + pen input; watch the EBC
  refresh kthread).
- First boot with the cherry-picked driver (fsleep + shrunken dma_sync):
  confirm partial refreshes stay artifact-free — the offline harness
  proves the bookkeeping, only the panel proves the cache/DMA physics.
- First cage+KOReader session on the panel once the `reader` flavor
  exists: page turn, refresh behavior, pen/touch (KOReader stack:
  `doc/koreader-spike.md`).

## Device facts

See `doc/device-runbook.md` for the full inventory and backup ledger.
Highlights:

- Pine64 PineNote v1.2; stock Debian rescue on `os1` (`/dev/mmcblk0p5`),
  experiments on `os2` (`/dev/mmcblk0p6`), waveform partition on
  `/dev/mmcblk0p2`, data on `/dev/mmcblk0p7`.
- VCOM: 1430000 microvolts (recorded, backed up).
- UART: 1500000 baud, 8n1, via CH340 adapter on ttyS2.
- Backups (waveform, uboot, uboot_env, logo, GPT head) verified in two
  locations, 2026-05-08 and 2026-05-10 sets.
