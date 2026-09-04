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
nobody else publicly runs 7.0.x on the PineNote (as of 2026-07, community
trees top out at 6.19); we are the frontier, so expect to find issues first —
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
- [ ] Re-measure flavor closure sizes in `doc/pinenote-flavors.md` (the
      usb-console flavors are in the table now; sizes predate the firmware
      packages, and the reader-debug flavor needs a row).
- [x] Broadcom firmware delivery story decided (2026-07-04): the packaged
      firmware in the OS firmware field is hardware-proven, so
      `pinenote-brcm-firmware-service-type` and the `/state/firmware/brcm`
      runtime helper were deleted.
- [ ] Add an ECM/RNDIS ethernet gadget flavor alongside the ACM console
      (community-standard debug path; survives console-less sessions;
      Debian's `usb-otg_eth.sh` is the configfs reference).
- [ ] A/B slot awareness (os1/os2) in the image tooling rather than
      manual dd; testable offline against the synthetic GPT disk.
- [x] **The update path (2026-09-02)**: one enabling reflash, then
      `make deploy DEVICE=<alias>` — a cross-built system as a Guix
      generation, sent as a delta, kexec'd as a trial, promoted after a
      health check, rollback the same move backwards; rig-proven in
      QEMU (rung 4u) and on one device (`doc/update-path.md`,
      `doc/hardware-deploy.md`).
- [ ] Retire the kexec-only `initcall_blacklist=rockchip_grf_init` with
      the kernel fix (a clock reference on the pipe GRF syscon;
      `doc/upstream-register.md` 22), then send it upstream.
- [ ] A ledger `pin` for known-good generations: `prune` keeps the
      newest, which are the least proven, and the only cold-booted
      generation is kept in the `KEEP` window by hand today
      (2026-09-04; the review's S5).
- [ ] A trial that dies after the helper's own Wi-Fi off (an EBC that
      never goes idle, a failed `kexec -l`) strands the reader stopped
      and silent, and the deployer misreads it as a dead trial the
      watchdog will reset; bring the radio and the reader back on those
      paths, or arm the watchdog earlier (`doc/hardware-deploy.md`).
- [ ] A trial cannot deliver a device tree (`kexec_file_load` ignores
      `--dtb`): a DT change is proven only by a cold boot, which the
      deployer cannot do without the UART. Either a `kexec_load`
      path that carries the DTB or a "cold boot required" gate in the
      deployer (`doc/update-path.md`).
- [ ] A second operator through the update path on their own device
      (the enabling reflash, the signing key on `/data`, the alias, the
      first kexec attended).
- [ ] Per-book filesystems / point-in-time restore for interactive
      books — deferred with its options in `doc/update-path.md`.

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
   - [x] **(a.2) Liveness is a first-class harness obligation** (added
         2026-07-29 after the barrier campaign):
         `ebc-logic/ebc-refresh-starvation-test` pins that a sustained damage
         supply starves the global-refresh/`REFRESH_BARRIER` path, and its
         period sweep shows the boundary is the waveform's phase count (starves
         at ≤38-frame supply, drains at 39) rather than any timeout. The rung-2
         and 7a suites had been *correctness*-complete and still missed a
         multi-minute hardware hang, because nothing asserted that
         `rockchip_ebc_refresh` ever **returns**. The backstop landed
         2026-07-30: `shim/fake-ebc.h`'s `FAKE_EBC_DEFAULT_FRAME_CAP` aborts
         with an actionable diagnostic instead of letting `make check` hang,
         verified by building the starvation test against an artificially low
         cap. `ebc-replay` opts out explicitly — it replays long traces under
         its own `max_hw_frames` bound.
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
      whole-panel GLOBAL_REFRESH; partial updates run at GC16 (~596 ms;
      DU is ~298 ms, A2 ~157 ms per the panel wbf at the driver's
      63.744 Hz frame clock); boot text lingered
      because nothing cleared the retained panel. Phase A (landed,
      hardware-validated): area-thresholded flash policy +
      `[pn-refresh]` intent tracing in the device target, panel
      blank+wash before KOReader spawns, and the rung-4v visual loop.
      Phase A.2 landed and was superseded by later reader images; the GL16
      global policy and input architecture are hardware-proven, and final4's
      autorotation/touch fixes were accepted 2026-07-19. Phase B workbench
      **built 2026-07-05**
      (`ebc-replay` in `pinenote/tools/ebc-logic/`, runs in
      `make ebc-logic-check`): replays `[pn-refresh]` traces through
      the verbatim driver's refresh thread under candidate policies —
      deferred-io band damage and the driver's auto-refresh accumulator
      modeled, washes/black-flash census/settle/staleness reported.
      First study in `doc/refresh-policy.md`: GL16-vs-GC16 quantified;
      full_refresh_count's scrub value collapses under GL16 (a GC16
      "deep clean" action becomes the load-bearing residue answer); the
      accumulator ignores manual washes (ebc-logic README finding 7).
      Real harvested traces and the first camera dataset now drive the findings
      in `doc/refresh-policy.md` and `doc/optics-dataset-2026-07.md`; the
      idle-washer/deep-clean policy is hardware-validated. Phase B next:
      tune candidates through the hardened recorder and keep DU-partial
      experiments behind optical evidence. Phase C: validate each winning
      policy's optics across controlled captures. The `org.pinenote.ebc`
      dbus/UAPI compatibility story
      stays in scope for phase B design.
- [x] Hardware-validate SC7A20 autorotation, disable/re-enable state replay,
      touch/pen-contact deferral, and cyttsp5 coordinate normalization (final4
      deployed and accepted 2026-07-19; exact evidence in `doc/status.md`).
- [x] **Awake power-policy program — concluded 2026-08-06.** The
      `conservative` governor is the validated awake default (2026-07-25);
      the vdd_cpu auto-PFM fix took awake reader idle ~174 → ~157 mA on
      the deployed image; DDR DVFS was built and then withheld — 324 MHz
      starves the EBC's phase-data fetch and corrupts the display
      silently (one-variable A/B, 2026-08-07), so `wilkbook_dmc` ships
      disabled and 528/780 MHz are untested; the domain teardown measured the remaining
      floor. On-demand Wi-Fi was deliberately deferred (2026-08-03).
      Ledger, numbers, and any future levers: `doc/power-management.md`.
- [x] **E-reader suspend program — mechanism proven; validation continues.**
      Deep suspend works on hardware (2026-08-02: BSP SIP activation live
      and bound, RTC wake, display recovery, VCOM held), and auto-suspend
      is deployed on os2 (2026-08-03: idle -> deep, power-button wake;
      since 2026-08-08 idle suspends to ultra and deep is superseded,
      charging inhibit, runtime `enabled=0` off-switch). Note on the old
      gate: this file previously required "repeated deep cycles with
      unplugged energy measurements" before any idle autosuspend; the
      2026-08-03 deployment superseded that gate, with the charging
      inhibit and the runtime disable knob as compensating controls — the
      unplugged multi-day soak was the outstanding validation rather than
      a precondition, and it ran clean 2026-08-15. Full history: `doc/status.md`; campaign records:
      `doc/power-management.md`.
- [ ] Suspend program, remaining direction: the week-scale unplugged soak
      is **done** (2026-08-15) — 6.17 days unplugged, 170 suspend cycles
      and zero failures, and standby measured end to end at last:
      **5.47 mA idle** and **10.07 mA as actually read**, projecting to
      ~30.5 and ~16.6 days from a 4000 mAh charge
      (`doc/artifacts/pinenote-ultra-soak-20260815/`). That retires the
      ~7.4 d arithmetic off the duty-cycle model and the ~28–36 d paper
      estimate off R12's single bracket alike; quote **both** measured
      numbers, never only the idle one. Still open: wake attribution and
      the cover wake source; the unexplained TPS `ENABLE` 2f->20 delta
      after deep; resume latency as a UX metric (~1.1 s kernel time
      today; measure one full wake+render+refresh cycle); and the awake
      term, which the soak showed is now the larger half of the standby
      answer — reading roughly halves the figure. Ultra suspend —
      ADOPTED 2026-08-08: hrdl's rails-off pair on the primary kernel,
      4.64 mA measured in a backstop-free bracket
      (`doc/artifacts/pinenote-ultra-r12-20260808/`), wake via
      RTC/power/charger and, unexpectedly, the cover (confirmed
      2026-08-09 — the pad supply is off-in-suspend, so the mechanism is
      unexplained); the pen cannot wake; the wake-collision gate was
      answered by adoption. Upstream TF-A stays a separate, later,
      recovery-qualified migration — never a hybrid.
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
- [ ] Later: wlroots session (sway, following hrdl's `pinenote-dist`
      architecture; `pinenote-nixos` is the structural checklist for a
      Guix port — NOT cage/KOReader-kiosk, which `doc/koreader-spike.md`
      §3 records as a dead end and whose module was deleted 2026-08-24);
      per-`app_id` refresh-mode policy (the Onyx pattern);
      `gud-gadget` (PineNote as USB e-ink monitor) as a display-debug
      path and party trick.

## 5. Interaction: the pen, and documents that do things

The direction the display work now serves, settled 2026-08-24/25 and
recorded across `doc/direct-mode-adoption.md` and `doc/configuration.md`;
gathered here because ROADMAP is where direction lives. **Decided
2026-09-02: direct mode is tentatively embraced by both operators**,
barring new information (`doc/direct-mode-adoption.md`); the embrace
sweep is the display track's next work item.

**Handwriting is a product direction, not a feature**: continuous
note-taking, then drawn UIs inside books, then handwritten code that
executes. That ordering matters because each stage needs the previous
one's latency. The current LUT-path floor is ~290 ms nib-to-ink
(132–140 ms software + A2's 157 ms); handwriting needs the ~11.7 ms
class, which only hrdl's direct-mode rework reaches (`DRIVER_MODE_FAST`).

- [ ] **The direct-mode experiment** (`doc/direct-mode-adoption.md`).
      Status: compiles and links in our kernel package with
      `pinenote_defconfig`; CLUT compiler byte-identical in C
      (`wbf-clut`); nothing has ever run. Carried by a temporary
      `reader-direct` flavor that is SCAFFOLDING, not a product line:
      **we ship one image.** The gate is embrace-or-reject on glass —
      embrace means the reader flavor moves to the direct kernel and the
      scaffolding is deleted; reject means the same deletion and the
      shipping driver stays. Either way the next tag is `reader`, singular.
- [ ] **Stroke capture** (#20): capture, storage, vectorization —
      independent of the panel path, rung-1 testable, can start any time.
      The digitizer is proven capable: 12-bit pressure, ±90° tilt, hover,
      at 11.2× panel resolution, all confirmed emitted on glass
      (2026-08-24).
- [ ] **The settings book** (`doc/configuration.md` §5): settings as a
      real document with plugin-supplied live regions — the first
      instance of the drawn-UIs-in-books machinery, arriving early
      because configuration needs it first. Its index requires the
      schema-declared config system (#12), which is why that work is on
      the critical path of the vision and not a chore.
- [ ] **Capabilities and sharing** (1.0, deliberately under-specified):
      shareable interactive books mean sandbox-by-default, per-book
      capability grants, image signatures. Recorded so nearer work does
      not foreclose it; the config API's filterable read path is the
      part that must be designed in from the start.
- [ ] **1.x — audio, deferred with intent (2026-08-24, #18).** The
      hardware and kernel are ready and were verified on glass: ALSA card
      0 `simple-card` registers at boot with every codec module loaded.
      What is missing is userland — `aplay`/`amixer` are not on `PATH`,
      there is no mixer state, and the KOReader bundle carries no TTS
      plugin and no audio decoder at all. Two directions, and they
      compose rather than compete: **TTS** (works on any book, no content
      pipeline, accessibility) and **audiobook position handoff** —
      bundling metadata that maps a position in a DRM-free book to a
      position in a DRM-free audiobook of the same work. The second is
      the one a phone structurally cannot do, because the commercial
      ecosystems that offer it only do so inside their own DRM.
      Playback needs a power state the device does not have (panel and
      frontlight down, CPU alive) and suspend inhibition, which
      `autosuspend.lua` has no concept of — it idles on input activity,
      and a listener touches nothing. **Draining battery while actively
      listening is fine**: it is opt-in, it costs nothing when unused, and
      it does not touch the idle-standby figures the reader story rests
      on. The constraint is that it must not surprise anyone.
