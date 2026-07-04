# Roadmap

Three tracks, in priority order, plus a cross-cutting offline-testing
ladder. Current hardware truth lives in `doc/status.md`; this file is
direction, not status. Domain background (waveforms, commercial stacks,
community state) lives in `doc/eink-research.md`.

Guiding principle for sequencing: **hardware sessions are the scarce
resource.** Everything below is ordered so that each UART/panel session
validates a maximal, pre-verified stack, and everything that *can* be
proven offline (host tests, QEMU, the os1 SSH oracle) is proven offline
first. The 2026-07-03 fix stack is the template: three device failures
were root-caused and fixed entirely from logs, the os1 oracle, chroot
tests, and adversarial review — before a single reboot.

## 1. Kernel currency

Goal: stay close to current mainline kernels while carrying the PineNote
display/pen stack as one explicit patch, with working firmware. Context:
nobody else publicly runs 7.0.x on the PineNote (community trees top out
at 6.19); we are the frontier, so expect to find issues first —
especially PREEMPT_RT interactions (see the RT watch list in
`doc/eink-research.md` §6).

- [x] Move `linux-pinenote` from the `linux-libre` base to vanilla
      kernel.org sources (2026-06-10). Wi-Fi firmware loading on the
      vanilla base hardware-confirmed 2026-06-11 (brcmfmac 7.45.234).
- [x] Validate the 2026-07-03 fix stack on hardware (2026-07-04 boot: panel
      text via fbcon, gadget console end-to-end with zero dwc3 errors,
      `PREEMPT_RT` untainted with no splats, waveform service clean —
      see `doc/status.md`). 7.0 now has display/gadget/RT parity.
- [ ] Patch-refresh discipline: record each refresh in
      `doc/kernel-forward-port.md` (base version, conflicts, config
      deltas). Rebase reference is now ayakael/hrdl 6.19 topic branches,
      not m-weigand 6.12.
- [ ] Cherry-pick from hrdl/ayakael 6.19 (value order): temperature
      clamp ≥ 19 °C; pixels-to-IDLE on waveform change; `fsleep` /
      `dma_sync` size fixes. Skip the NEON/`scoped_ksimd` blitters until
      we want their throughput (our copy has no NEON today).
- [x] Once 7.0 reaches parity with 6.6 on hardware, demote the 6.6
      package to a regression-isolation tool (2026-07-04: parity reached;
      docs repositioned).
- [ ] Later, low-cost upstream-friendly experiment: DRM self-refresh
      helper for idle panel power-down (the model reviewers pointed to in
      the 2022 RFC; better battery than suspend hacks for a reader).

## 2. Easy image building and deployment

Goal: one command from checkout to deployable artifact; deployment stays
deliberately manual (os2 only, os1 untouched rescue — this matches
community convention and stays).

- [x] `make rootfs-<flavor>` builds the image and extracts + inspects the
      validated `PNGuixRoot` rootfs (was implemented but unchecked here;
      README quick start already uses it).
- [ ] Re-measure flavor closure sizes; add the usb-console flavors to the
      `doc/pinenote-flavors.md` table (stale, predates firmware pkgs).
- [x] Broadcom firmware delivery story decided (2026-07-04): the packaged
      firmware in the OS firmware field is hardware-proven, so
      `pinenote-brcm-firmware-service-type` and the `/state/firmware/brcm`
      runtime helper were deleted.
- [ ] Add an ECM/RNDIS ethernet gadget flavor alongside the ACM console
      (community-standard debug path; survives console-less sessions;
      Debian's `usb-otg_eth.sh` is the configfs reference).
- [ ] A/B slot awareness (os1/os2) in the image tooling rather than
      manual dd; testable offline against the synthetic GPT disk.

## 3. Offline testing ladder (cross-cutting)

Goal: shrink what only a hardware session can prove down to optics,
latency feel, and electrical behavior. Rungs in build order — each is
independently useful, and 1–3 start roadmap track 4 without hardware:

1. [x] **.wbf parser as a host tool** (done 2026-07-04:
       `pinenote/tools/wbf/`, `make wbf-check WBF=…`). Compiles the
       verbatim `drm_epd_helper.[ch]` out of the forward-port patch
       against a small shim and inspects a waveform exactly the way
       `rockchip_ebc` does. All tests pass against the device's own
       waveform (pulled over the ACM console, SHA-verified): mode-version
       0x19, 5-bit LUTs, ED103TC2 panel string, 13 temperature bins with
       GC16 at 131 phases @0 °C vs 38 @≥24 °C, A2=10 phases. Its decoded
       LUTs are the ground truth for rung 3.
2. [x] **EBC driver logic as host unit tests** (done 2026-07-03:
       `pinenote/tools/ebc-logic/`, `make ebc-logic-check [WBF=…]`).
       Compiles the verbatim `rockchip_ebc.c` from the forward-port patch
       against a kernel-API shim and tests the XRGB8888/R4→Y4 blitters
       (odd-x/stride edge cases vs an independent reference), damage
       split/collision scheduling (coverage-bitmap checker), and the
       threshold/dither paths — over the exact module params
       `pinenote/services/ebc.scm` ships. With `WBF=` it also pins the
       phase-0xff/last-phase-neutral assumption against the device's own
       waveform. Surfaced six driver quirks incl. a 1-byte kernel heap
       overrun in `blit_pixels` and a scheduler dead-zone hole — see the
       tool README's Findings before the next patch refresh.
3. [x] **Gray8→Y4 raster library + waveform simulator with golden-image
       tests** (done 2026-07-03: `pinenote/tools/rastersim/`, `make
       rastersim-check [WBF=…]`). librastersim (plain C, no deps) covers
       Y4 pack/blit ops, the driver's quantization modes plus
       Floyd–Steinberg, the prev/next damage model, and phase-by-phase
       LUT application over rung 1's new `wbf-info --dump-lut` exports.
       GC16@25 °C converges for all 256 (from,to) pairs; goldens pin
       quantization and overlapping-damage == full-redraw. Deriving the
       LUT axes pinned real-waveform facts (GC16/GL16 drive from==to;
       A2 only 0↔15) and turned up two driver quirks (`blit_direct`
       reads the LUT transposed — unused path on our config; odd-x1
       `blit_pixels` edge leak), see the rastersim README. Still later:
       pair with the driver's `EXTRACT_FBS` ioctl as a
       hardware-differential oracle.
4. [ ] **Mechanized qemu-virt assertions** (~2–4 days). Wrap the
       existing `make qemu-virt` rung (expect-script over the PL011
       console, or a Guix marionette test): assert initrd waveform
       install, PNGuixRoot mount, `pinenote-waveform` ordering after
       udev, gadget modprobes resolving via `-d`, debugfs mounted. This
       is the bug class already hit twice (waveform/udev race, modprobe
       path); make regressions red before they cost a UART session.
       Includes fixing the doc/building.md overstatement: the v3 gadget
       service won't bind on virt (no `fcc00000.usb`) — either document
       the manual dummy_hcd configfs walk or add a virt-aware bypass.
5. [ ] **vkms writeback screenshot tests** (~1–3 days, after rung 3
       exists to screenshot). Validates DRM clients: atomic commits,
       `FB_DAMAGE_CLIPS` emission (what the EBC consumes), pixel-exact
       reader UI rendering. vkms can't do Y4/EBC semantics — that half
       stays with rung 3's simulator.
6. [ ] **Reader prototype offline** (see track 4): MuPDF loop against
       SDL/vkms in days; KOReader Guix packaging as a separate timeboxed
       spike (LuaJIT + vendored deps is the real risk, not the device).
7. [ ] **QEMU EBC device model** (days-to-weeks of QEMU C; keep gated on
       display debugging actually demanding it). Register block +
       stub IIO temperature provider so the real driver probes end to
       end in the VM; render Y4 frames to PNG. The only offline way to
       run the actual driver. Full RK3566 emulation stays a non-goal.

Hardware-only validation set (the checklist scarce sessions exist for):
waveform optics (ghosting, grayscale uniformity, mode tradeoffs); real
temperature behavior on the panel; VCOM/power sequencing; pen latency and
PREEMPT_RT's actual effect; the dwc3 `ep0out` fix (dummy_hcd bypasses the
broken layer); EBC frame timing under load; end-to-end refresh feel.

## 4. E-ink userland

Goal: a reading-first device. Rungs 1–3 and 6 of the testing ladder *are*
the start of this track — no panel required. Policy background in
`doc/eink-research.md` §2 and §5.

- [ ] Raster library + simulator (= ladder rung 3), replacing the
      `pinenote-ebc-test` placeholder; then the on-device render harness
      (grayscale ramps, partial updates, A2/DU4/GC16 comparison) driven
      by the same code.
- [ ] Refresh-policy layer: damage clips + `GLOBAL_REFRESH` + hint
      params, mirroring the cross-vendor policy (GL16-class partials
      while reading, counter-based full refresh, DU for chrome, A2 only
      bracketed). Keep UAPI compatibility with the PNDeb/hrdl ecosystem
      (`org.pinenote.ebc` dbus service, exact ioctl numbers) so community
      tooling runs unmodified; package or port `pinenote_dbus_service`
      early.
- [ ] Reader decision, de-risked offline: (a) MuPDF prototype loop
      (render → Gray8 → Y4 harness → vkms/SDL) in days; (b) KOReader
      packaging spike, timeboxed — KOReader is proven on PineNote via
      hrdl's image, and two open upstream issues are cheap wins (#14017
      full-refresh → `GLOBAL_REFRESH`; #14694 stylus libinput tags).
      Decide on evidence, not vibes.
- [ ] Wi-Fi credentials/networking story for the device (the networked
      flavor has no credential handling yet).
- [ ] Later: wlroots session (sway or cage/KOReader-kiosk, following
      hrdl's `pinenote-dist` architecture; `pinenote-nixos` is the
      structural checklist for a Guix port); per-`app_id` refresh-mode
      policy (the Onyx pattern); pen fast path via driver hints;
      `gud-gadget` (PineNote as USB e-ink monitor) as a display-debug
      path and party trick.
