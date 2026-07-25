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
- [x] Cherry-pick from hrdl/ayakael 6.19 (evaluated against the actual
      diffs 2026-07-04; record in `doc/kernel-forward-port.md`). Ported:
      `fsleep` conversion and the `dma_sync` size shrink (translated to
      our area list, proven by the refresh harness's new non-coherent
      DMA model). Rejected on evidence: the ≥19 °C temperature clamp and
      pixels-to-IDLE are workarounds for their 60–85 Hz rework's early
      cancellation / per-pixel scheduler state, which our copy doesn't
      have — the clamp would discard the waveform's cold bins (a new
      `wbf cold` harness test pins 131-phase GC16@0 °C working). The
      NEON/`scoped_ksimd` blitters stay skipped until we want their
      throughput (our copy has no NEON today).
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
4. [x] **Mechanized qemu-virt assertions** — `make qemu-virt-check`, built
       2026-07-04, completed 2026-07-05. Boots the real
       kernel/initrd/rootfs on virt with the console on a socket chardev,
       asserts the boot milestones through Shepherd start from the console
       log (kernel + PREEMPT_RT, initrd waveform install + EBC module
       load, PNGuixRoot pre-root visibility, root mount) plus the absence
       of panic / RT-splat / root-not-found / PNGuixRoot-not-visible, then
       **logs in as root over the console socket and asserts the post-udev
       service stack from inside the guest** (udev completion, the
       pinenote-waveform and pinenote-ebc-params one-shots, the orientation
       service plus its named evdev node, reader-session start, clean poweroff)
       — the Shepherd service-ordering regression
       class that cost the first two hardware sessions.
   - [x] **Diagnose the qemu-virt udev "deadlock".** Root-caused
         2026-07-05: there was no deadlock. Shepherd's messages divert
         from /dev/kmsg (console-visible) to /var/log/messages the moment
         its system-log service starts listening on /dev/log (~t+5 s), so
         the console goes dark while the boot completes normally
         underneath — udev, one-shots, and KOReader all come up on virt.
         Hence the in-guest assertions above. See `doc/status.md`
         2026-07-05.
5. [ ] **vkms writeback screenshot tests** (~1–3 days, after rung 3
       exists to screenshot). Validates DRM clients: atomic commits,
       `FB_DAMAGE_CLIPS` emission (what the EBC consumes), pixel-exact
       reader UI rendering. vkms can't do Y4/EBC semantics — that half
       stays with rung 3's simulator.
6. [x] **Reader prototype** (done, and it leapfrogged offline: KOReader
       reached the panel natively on 2026-07-05 — see track 4). For
       offline UI testing, `koreader-bin` still runs headless via
       `SDL_VIDEODRIVER=offscreen` on a workstation; the native fbdev
       path could additionally be exercised against vkms/vfb later.
7. [ ] **Execute the real driver's refresh machine offline** — scoped
       2026-07-04, see `doc/ebc-harness-spike.md` for the evidence
       (probe dependency chain, register/IRQ/DMA contract, effort
       pricing). Two stages, cheapest first:
   - [x] **(a) Shim-executed refresh harness** (done 2026-07-04, same
         day as the spike: `pinenote/tools/ebc-logic/ebc-refresh-test`,
         part of `make ebc-logic-check`).  The shim's regmap became a
         RAM register file with a behavioral device model behind it
         (`shim/fake-ebc.h`): CONFIG_DONE latching, LUT/three-window
         frames, DSP_END raised through the driver's own IRQ handler.
         Executes (under ASan) probe, global/partial orchestration, LUT
         upload, DMA windowing, mid-refresh buffer switching, the
         scripted refresh-thread body, and — with `WBF=` — a
         drive-sequence differential proving all 256 Y4 transitions
         match rastersim's independent waveform decode.  Also executed
         (not just read): the rung-2 teardown UAF (ASan-verified
         reproducer) and scheduler QUIRK E made device-visible as
         phase-index regressions.  Two PGM goldens committed.
   - [ ] **(b) QEMU EBC device model** (~1–2 weeks; build when the
         reader track needs a UAPI-true offline target): ~300–500 line
         sysbus device carried as a Guix QEMU patch, bespoke ~100-line
         DTB (fixed clocks, fixed regulators, stub-IIO out-of-tree
         module, ed103tc2 panel), tiny initramfs — no virtio, no
         distro, no udev. Real probe, real DRM core, real
         GLOBAL_REFRESH/damage UAPI. Full RK3566 emulation stays a
         non-goal; optics stay hardware-only; the on-device
         EXTRACT_FBS differential remains the ground truth.

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
- [x] Reader decision — **KOReader, running natively on the
      framebuffer**. First light 2026-07-05: quickstart guide on the
      panel, pen- and finger-navigable UI (cyttsp5 touch validated on
      hardware the same day; `doc/status.md`). The cage/SDL kiosk
      architecture was abandoned on hardware evidence (SDL3 cannot
      present on Wayland without GL/Vulkan — `doc/koreader-spike.md`
      §3); the shipped stack is `koreader-bin` + a wilkbook-authored
      pinenote device target (fbdev output, pure-Lua evdev input,
      `GLOBAL_REFRESH` ioctl for full refreshes) run directly by the
      `reader-session` service. `wlroots-pixman`/`cage-pixman` stay in
      the repo (cross-building, unused).
- [ ] **Refresh-policy program (started 2026-07-05).** Root causes of
      the first-light rough edges are known (see `doc/status.md`):
      menu flashing was flashui/flashpartial cascading into the
      whole-panel GLOBAL_REFRESH; partial updates run at GC16 (~450 ms;
      DU is ~224 ms, A2 ~118 ms per the panel wbf); boot text lingered
      because nothing cleared the retained panel. Phase A (landed,
      hardware-validated): area-thresholded flash policy +
      `[pn-refresh]` intent tracing in the device target, panel
      blank+wash before KOReader spawns, and the rung-4v visual loop.
      Phase A.2 (landed, awaiting the os2 write): GL16 globals + the
      input-architecture rework. Phase B workbench **built 2026-07-05**
      (`ebc-replay` in `pinenote/tools/ebc-logic/`, runs in
      `make ebc-logic-check`): replays `[pn-refresh]` traces through
      the verbatim driver's refresh thread under candidate policies —
      deferred-io band damage and the driver's auto-refresh accumulator
      modeled, washes/black-flash census/settle/staleness reported.
      First study in `doc/refresh-policy.md`: GL16-vs-GC16 quantified;
      full_refresh_count's scrub value collapses under GL16 (a GC16
      "deep clean" action becomes the load-bearing residue answer); the
      accumulator ignores manual washes (ebc-logic README finding 7).
      Phase B next: replay a real harvested trace, design the
      deep-clean trigger, DU-partial experiments.
      Phase C: one hardware session validates the winning policy's
      optics. The `org.pinenote.ebc` dbus/UAPI compatibility story
      stays in scope for phase B design.
- [x] Hardware-validate SC7A20 autorotation, disable/re-enable state replay,
      touch/pen-contact deferral, and cyttsp5 coordinate normalization (final4
      deployed and accepted 2026-07-19; exact evidence in `doc/status.md`).
- [ ] **Awake power-policy program.** RK817 telemetry, two cable-free static
      ABBAs, and the realistic reader-energy ABBA are complete (2026-07-24/25).
      Static draw tied at about 180--181 mA for `powersave`/`conservative`; on
      the exact 45-turn reader workload, conservative averaged 13.072 mAh and
      176.5 s versus powersave's 15.910 mAh and 209.0 s, with 45 fresh traces
      per leg at 26 C. The forward-port defconfig now selects conservative as
      the awake default; verify readback on the next ordinary reader-image boot.
      Measure Wi-Fi-down savings separately, then decide whether an awake-only
      activity policy on `idlewasher`'s timer seam adds value beyond the adaptive
      governor. Do not couple this to suspend qualification; see
      `doc/power-management.md`.
- [ ] **E-reader suspend program.** Keep KOReader's exact disabled policy
       bound to `canSuspend` while firmware inventory and the supervised PM-test
       -> one real `s2idle` -> `deep` ladder are completed (`freeze` is Linux's
       suspend-to-idle, not a separate mode). The fail-closed offline gate and
       RK817 telemetry boot are complete (2026-07-24). Firmware comparison on
       2026-07-25 proved the backup already byte-matches Pine64/PNDeb's stable
       1056-MHz idblock/FIT and identified its 2022 downstream BSP ATF; reflashing
       it would change nothing. First retain that recovery-known firmware and
       forward-port the complete Rockchip SIP/config/DT compatibility contract
       into the os2 kernel, with mocked ABI/DT gates and a non-suspending UART
       bind/probe boot before PM-test. Upstream TF-A is a separate later
       recovery-qualified migration, never a hybrid. A future userspace contract needs
       checkpointing, refresh-timer and
       frontlight/Wi-Fi handling, explicit wake attribution, and display repair;
       it cannot currently retain a static sleep cover because `rockchip_ebc`
       overwrites the panel with `off_screen` during disable and supplies no
       userspace completion contract. No cover-triggered or idle autosuspend
       until an EBC contract and repeated deep cycles with unplugged energy
       measurements pass. See `doc/power-management.md`.
- [ ] Reader polish, next: refresh-policy tuning (KOReader's
      partial/UI/full hints → EBC behavior; the `org.pinenote.ebc`
      dbus/UAPI compatibility story remains relevant for community
      tooling); pen buttons + #14694 stylus tags; unprivileged-user
      hardening; a books-directory convention; upstreaming the device
      target to KOReader.
- [x] Phase-1 Wi-Fi credentials/networking: the reader's out-of-band `data`
      partition config, wpa_supplicant + dhcpcd, and key-only root SSH/scp are
      hardware-proven (2026-07-24). On-device network selection and persistent
      SSH identity across reflashes remain follow-ups in `doc/networking.md`.
- [ ] Later: wlroots session (sway or cage/KOReader-kiosk, following
      hrdl's `pinenote-dist` architecture; `pinenote-nixos` is the
      structural checklist for a Guix port); per-`app_id` refresh-mode
      policy (the Onyx pattern); pen fast path via driver hints;
      `gud-gadget` (PineNote as USB e-ink monitor) as a display-debug
      path and party trick.
