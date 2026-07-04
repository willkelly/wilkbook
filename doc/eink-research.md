# E-ink domain notes for wilkbook

Research digest, 2026-07-03. Curated from a deep-research pass over primary
sources (E Ink mode declarations, dri-devel archives, downstream PineNote
trees, KOReader sources, commercial-device teardowns). Load-bearing claims
were cross-checked against primary sources; treat single-source details as
leads, not gospel. This is background for planning — the actionable items
are folded into `ROADMAP.md`.

## 1. EPD fundamentals that constrain everything

- Electrophoretic panels are bistable and have no intrinsic grayscale.
  Every optical transition is a *waveform*: a per-(from-gray, to-gray)
  sequence of 2-bit drive codes (neutral / drive-black / drive-white /
  no-op) played over ~20–40 scan frames at the panel's frame rate (85 Hz
  for the PineNote's ED103TC2, 1872×1404 Carta glass).
- Particle mobility varies with temperature, so waveform LUTs are
  temperature-indexed. This is why `rockchip_ebc` reads the TPS65185
  temperature on *every* refresh to pick the LUT bin — and why its probe
  hard-depends on the IIO channel (the exact 2026-06-11 failure).
  Commercial firmware does the same; nothing here is optional if we want
  clean grayscale across room temperatures. hrdl's tree later added a
  "clamp temperature reads below 19 °C" workaround — bad temperature
  reads select wrong LUTs and show up as artifacts, worth remembering
  when debugging.
- Waveforms are proprietary, tuned per panel *production batch*, and
  shipped with the device (PineNote: the eMMC `waveform` partition; we
  extract to `/lib/firmware/rockchip/ebc.wbf` in the initrd). Treat the
  blob as immutable device identity — never bundle a generic one. Kindle
  and Kobo do exactly the same staging-before-driver-bind dance.
- DC balance matters: drivers/waveforms keep net charge ≈ 0 per
  transition pair; violating it (e.g. by hand-synthesizing pulses)
  degrades the film. Never drive the panel outside the shipped LUTs.
- The driver's `prev` (Y4) buffer must always match true panel state:
  every LUT lookup assumes the "from" level is physically on the glass.
  Any divergence (suspend/resume, waveform-family switch) produces wrong
  drive integrals → ghosting. This is what the driver's
  `globre_convert_before` / off-screen logic is about, and why every
  distro does a full refresh after resume.

## 2. Waveform modes and the reader policy they imply

Official E Ink modes (AF waveform, mode-version 0x19 layout — the
PineNote's; dmesg `Loaded 4-bit PVI waveform version 0x19` confirms):

| Mode | What | Time @25°C | Ghosting | Use for |
| --- | --- | --- | --- | --- |
| INIT | full erase, flashes, ends white | ~2000 ms | resets | cold boot, corruption recovery |
| DU | any gray → B/W only | ~260 ms | low | menus, touch feedback |
| DU4 | any gray → 4 tones | ~290 ms | moderate | menu text, fast UI |
| GC16 | full 16-gray, flashy on full update | ~450 ms | very low | page turns (quality), periodic deghost |
| GL16 | 16-gray for text on white, less flash | ~450 ms | medium | reading-flow page turns |
| GLR16/GLD16 | = GL16 unless E Ink's licensed REGAL preprocessor injects hint states | ~450 ms | low | treat as GL16 (no REGAL license) |
| A2 | fastest, B/W only, no flash | ~120 ms | medium | scrolling, pen strokes |

E Ink's own bracketing rule: enter A2 through a DU-to-white transition,
exit A2 through white → GC16. The driver's `prepare_prev_before_a2`
parameter handles the entry half; the exit half is userland policy
(global refresh ioctl).

Cross-vendor UX convergence (Kobo/Kindle/PocketBook/Boox): partials in a
GL16-class mode while reading, with a **counter- or area-based full
refresh** (every N page turns / chapter), DU for UI chrome with a
flash-on-close, A2 reserved for pan/pen with strict bracketing. Boox's
per-app refresh-mode persistence is the UX pattern worth copying
eventually (map wlroots `app_id` → EBC hint values).

## 3. Controller landscape: where the EBC sits

- Dedicated controllers (IT8951, Epson S1D13541, SSD1677): waveform
  storage + update queue in silicon; host sends pixels + mode hints.
- SoC-integrated EPD controllers: NXP i.MX EPDC (Kobo, Kindle, rM1,
  PocketBook, Tolino) — up to 64 concurrent per-region LUTs with hardware
  collision handling; the richest of the breed, and its `mxcfb` ioctl
  contract `{damage rect, waveform mode, partial/full, completion
  marker}` is the de facto industry userspace API (15 years of software
  speaks it: KOReader, FBInk).
- Rockchip EBC (RK3566/PX30): much simpler — a LUT engine with one
  update in flight, diff mode, three-window partial refresh, and a
  direct (software-waveform) mode. The downstream driver compensates in
  software: area queue, damage splitting, per-refresh temperature LUT
  selection. `mxc_epdc_fb.c` remains the best reference implementation
  for policy questions (update merging, collision resubmission).
- reMarkable 2 is the existence proof that a *pure software TCON* on a
  generic SoC reaches pen-grade latency — shipped on an RT-patched
  kernel with a dedicated refresh thread. Our PREEMPT_RT choice on the
  7.0.x track is the same substrate; rM2 validates it in production.

## 4. Mainline status: plan for the patch to be permanent

- The only e-paper driver upstream is the tiny SPI `repaper`; there is
  no EPD infrastructure in mainline DRM.
- Samuel Holland's April 2022 RFC (16 patches: `drm_epd_helper` +
  `rockchip_ebc`) got substantive review (Vetter, Ripard, Kemnade) and
  was never reposted. The sticking points it left unresolved — waveform
  UAPI, EPD timings semantics, kernel-side blitting — are precisely what
  our forward-port carries downstream.
- Kemnade's parallel i.MX EPDC DRM attempts have stayed out of tree for
  4+ years despite a persistent maintainer. Lesson: **treat
  `linux-pinenote-*.patch` as a permanent artifact**, and preserve the
  helper/driver layering (generic waveform code vs Rockchip TCON code)
  in case upstreaming ever revives.
- Review feedback worth honoring in our tree: no fake vblank events —
  send the DRM event on refresh completion; and the DRM self-refresh
  helper is the sanctioned model if we ever want idle panel power-down
  without custom suspend hacks (plausible small experiment on our
  track).

## 5. The PineNote community, mid-2026

- Kernel lineage: smaeul → **m-weigand** (dormant since ~Feb 2025;
  6.12.11 is what stock os1 Debian runs) → **hrdl**
  (git.sr.ht/~hrdl/linux, topic-branch stacks up to v6.19: 60–85 Hz
  operation, NEON A2 blitters, pixel scheduling, `scoped_ksimd()`
  conversion) → **ayakael** (Forgejo fork feeding postmarketOS: v25.12 =
  6.18.x, edge = 6.19.x, built as *vanilla tarball + one big patch* —
  structurally identical to our approach).
- **Nobody publicly runs 7.0.x; wilkbook is ahead of the whole
  community.** For the next patch refresh, diff against
  ayakael/hrdl 6.19 branches, not m-weigand 6.12.
- Cherry-pick candidates from hrdl/ayakael 6.19, in value order:
  temperature clamp ≥ 19 °C; "set all pixels to IDLE when changing
  waveforms" (ghosting on runtime waveform swap); `fsleep`/`dma_sync`
  size fixes (latency wins under RT). The `scoped_ksimd()` conversion
  only matters if we adopt their NEON blitters (our current driver copy
  has no NEON).
- Userland reference stack: hrdl's `pinenote-dist` (sway + squeekboard +
  dbus service + koreader-bin), not the factory GNOME image.
  `WeraPea/pinenote-nixos` is the closest analogue to a Guix port — its
  module layout (kernel pkg, waveform activation, sway session,
  cross-built image) maps ~1:1 onto Guix services and is a useful
  checklist. `pinenote_dbus_service` (`org.pinenote.ebc`) is the
  smallest piece that makes refresh UX scriptable; keep our driver's
  ioctl numbers/param names compatible so it and the community tooling
  run unmodified.
- KOReader: proven on PineNote via hrdl's image. Two open upstream
  issues are cheap wins: #14017 (route Dispatcher full-refresh to
  `DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH`) and #14694 (stylus reported
  as finger; fixable with libinput/udev tags in the image). Long-term, a
  native `framebuffer_rockchip.lua` (dumb buffer + damage clips + hint
  property + global-refresh ioctl) would give KOReader its usual
  refresh-policy control.
- USB: the community standardized on ECM/RNDIS ethernet gadget + ssh
  rather than our ACM serial console — worth offering both (the Debian
  `usb-otg_eth.sh` is a configfs reference). `gud-gadget` (PineNote as
  USB e-ink monitor) is a compelling later feature and doubles as a
  display-debug path.
- Suspend/resume on 6.x needs the `rk_suspend_driver` topic branch *and*
  a known-good U-Boot (factory batch-2 U-Boot silently breaks suspend);
  every distro does a full EBC refresh after resume. For a reader,
  aggressive runtime PM + panel-off may matter more than S3.

## 6. RT-specific watch list (we are the first RT PineNote)

PREEMPT_RT + 7.0.x + rockchip_ebc is unexplored territory. Expect to be
first to hit:

- refresh-kthread spinlock contention (hrdl's "move spin lock into
  conditional" hints where);
- if NEON blitters are ever adopted: `scoped_ksimd()` regions are
  preemptible under RT — verify mid-frame preemption is safe or pin the
  EBC kthread priority;
- threaded EBC IRQ changing frame-timing assumptions.

First-boot checks: `uname -v` shows `PREEMPT_RT`; watch dmesg for
"sleeping function called from invalid context"; later, tune the refresh
kthread's scheduling class before chasing pen latency.

## 7. Implications distilled (what actually changes our plans)

1. The temperature-IIO fix and the waveform staging discipline are not
   PineNote quirks — they are the industry-standard shape of every
   working e-ink stack. We now match it.
2. Userland refresh policy (mode choice per interaction, flash cadence)
   is where reading quality is won; the driver already exposes the
   needed knobs (damage clips honored, 3 ioctls, ~20 module params).
   Build the reader against **damage clips + GLOBAL_REFRESH + hint
   params** and the KOReader integration transfers.
3. Keep UAPI compatibility with the PNDeb/hrdl ecosystem rather than
   inventing our own; pick one lineage (hrdl/ayakael) when cherry-picking.
4. Rebase reference forward: ayakael 6.19 tree, then 7.x when they get
   there (or they rebase onto our work — we're first).
5. The mxcfb-shaped contract is worth emulating *faithfully or not at
   all* (PocketBook B288 cautionary tale) if we ever add a compat shim.
