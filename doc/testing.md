# Testing

This project's hardest constraint is that **hardware sessions are the
scarce resource** — a UART/panel session needs the physical PineNote, a
charged battery, a debug cable, and a human watching. So the testing
strategy is built to answer as much as possible *without* the device, and
to make each hardware session validate a maximal, pre-verified stack.

There are two layers: **host-side tools** (no device, no VM — plain C
compiled on your workstation) and **the validation ladder** (Guix builds,
QEMU, then hardware). New contributors should understand both.

## Why host tools at all

The e-ink display driver (`rockchip_ebc`) and the waveform helper
(`drm_epd_helper`) are carried as a forward-port patch on a vanilla
kernel. That patch is the single most rebase-fragile thing in the repo:
every kernel bump can silently break the blitters, the damage scheduler,
or the waveform decode, and the *only* way we'd historically have noticed
is a bad pixel on a panel during a scarce hardware session.

The insight that makes offline testing possible: large parts of that
driver code are **pure functions over memory** — XRGB8888→Y4 conversion,
LUT decoding, damage-rectangle math. They have heavy-looking kernel
`#include`s but the hot logic never touches hardware. So we compile the
*verbatim* driver source (extracted from the patch at build time, never
hand-copied) against a small kernel-API shim and test it on the
workstation.

Two rules keep this honest:

1. **Verbatim source, extracted at build time.** Each tool runs
   `pinenote/tools/wbf/extract-from-patch.py` against
   `pinenote/patches/linux-pinenote-7.0-forward-port.patch` and `#include`s
   the result. Tests therefore exercise exactly the code the kernel ships;
   they cannot drift from it. Never copy driver code into a test.
2. **Independent references, not copies.** A test that compares the driver
   against a re-paste of the driver proves nothing. References are written
   from the code's *specification* (read the intent, re-derive it), then
   compared on randomized + corner-case inputs with a fixed seed. When a
   reference and the driver disagree, assume the reference is wrong first
   (the driver is hardware-validated) — but if it's a real driver bug,
   record it as a `quirk:` finding and do **not** silently fix the driver
   in the patch.

This is how we found seven latent driver bugs (heap overrun, scheduler
hole, teardown UAF, …) from the desk — see `doc/driver-findings-report.md`
and `doc/kernel-forward-port.md`.

## The host tools (`pinenote/tools/`)

The C tools build with `guix shell gcc-toolchain python -- make -C <dir>
check` and every host suite has a root-level convenience target.
**`make check-host` is the one-command green state**: it runs every
suite that needs no hardware and no waveform.
Waveform-dependent tests need the per-device `.wbf` (never committed —
see the firmware policy): pass `WBF=/path/to/ebc.wbf` (to `check-host`
too, which then also runs `wbf-check`); without it those tests skip
with a clear message rather than fail.

| Tool | Ladder rung | What it validates | Run |
| --- | --- | --- | --- |
| `pinenote/tools/wbf` | 1 | PVI `.wbf` parsing/decode (header, modes, temperature bins, LUT decode) exactly as `rockchip_ebc` loads it; `--dump-lut` exports a decoded LUT for the simulator | `make wbf-check WBF=…` |
| `pinenote/tools/ebc-logic` | 1 | `ebc-logic-test`: the driver's pure logic — XRGB8888/R4→Y4 blitters, damage split/collision scheduling, threshold/dither paths — vs independent references.  `ebc-refresh-test` (ROADMAP §3's rung 7a): *executes* the refresh state machine (probe, global/partial orchestration, LUT upload, DMA windowing, IRQ/completion, buffer switching) against a behavioral device model under ASan — with non-coherent DMA (the device reads only synced shadows, so a missing `dma_sync` fails a test) — incl. a drive-sequence differential vs rastersim's independent waveform decode and WBF-gated disable-tail caller/off-screen retention plus exact completion accounting.  **Liveness** (issue #22, waveform-gated): `ebc-refresh-starvation-test` pins the inherited sustained-damage starvation against `build/nogate` (the extraction with the work-item drain gate removed), and `ebc-drain-gate-test` pins the guarantee against the shipping driver — a queued global launches, and a `kthread_park` completes, within one area lifetime, while a no-work-item control proves the mid-frame splice is otherwise untouched; the same source against `build/nogate` must FAIL.  Phase B (`ebc-replay`): replays KOReader `[pn-refresh]` traces through the same machine under candidate refresh policies — the display-quality workbench, results in `doc/refresh-policy.md` | `make ebc-logic-check WBF=…` |
| `pinenote/tools/ebc-barrier` | 1 | The separately invoked paint/barrier/restore diagnostic with fake framebuffer/DRM operations: strict fixed-width SUBMIT/WAIT ABI, high generation IDs, geometry/stride bounds, no-retry failure containment, exact restoration, cleanup precedence, double fail-closed reader ownership checks, and atomic pending/blocked signal acknowledgement. It never runs `--run` on the host | `make ebc-barrier-check` |
| `pinenote/tools/rastersim` | 1 | A standalone Gray8→Y4 raster library + waveform *simulator* (state model + LUT playback), with golden-image and convergence tests | `make rastersim-check WBF=…` |
| `pinenote/tools/koreader-input` | 1 | KOReader's *verbatim* `device/input.lua` + `gesturedetector.lua` (from the native `koreader-bin` bundle, under its own luajit) fed synthetic pen+touch evdev streams: reproduces the pen-hover tap-capture `quirk:` (finger tap → swipe), validates the `mixedrouter.lua` fix, checks exact `wilkbook-orientation` discovery plus source-gated MSC_RAW→MSC_GYRO translation, and pins cyttsp5 MT-axis normalization to five measured hardware targets.  It also **pins three inherited upstream slot-number warts** (`doc/upstream-register.md` item 11) against a one-variable slot-number A/B: a finger handed kernel slot 4 shares `ev_slots` with the pen and its tap leaves as a swipe (`quirk:pen-slot-collision`; the pen's own stroke is lost too), and two fingers in slots `{0,2}` are two swipes rather than a spread because upstream buddies only slots 0 and 1 (`quirk:buddy-slots-0-1-only`).  `mixedrouter.lua` is neutral on all three by design, which `compare_streams` pins.  **Continuous-gesture cost** (issue #26): `test-continuous-gesture-cost.lua` replays multi-frame pinches/spreads through the same verbatim stack and pins that upstream already coalesces *at the gesture-detection layer* — one terminal `pinch`/`spread` per interaction across a 1..40 intermediate-frame sweep with an invariant `distance`, the per-frame `inward_pan`/`outward_pan`/`two_finger_pan*` variants having no consumer in a 482-file scan of the bundle plus our overlay, the verbatim `gesToFontSize` yielding one frame-count-independent delta, the shipped pinch→`decrease_font` binding shape, the reachability of all five terminal two-finger gestures from slots {0,1}, and `quirk:slow-pinch-is-a-silent-no-op` (the 900 ms `SWIPE_INTERVAL_MS` ceiling above which a pinch emits nothing a consumer sees) | `make koreader-input-check` |
| `pinenote/tools/orientation` | 1 | Pure SC7A20 orientation classification: calibrated four-edge mapping, flat/diagonal/magnitude rejection, hysteresis, stable-sample dwell debounce, and duplicate suppression | `make orientation-check` |
| `pinenote/tools/optics` | 1 (checks) / 6 (capture) | The camera-in-a-box optical-defect instrument: deterministic flash/ghost/settle/double-flash classifiers over captured page-transition clips. The check suite validates the classifiers against synthetic clips with known injected defects — no camera, no device; real capture/ingest is a hardware session (`RECORDING.md`).  `audit.py` reconstructs the 2026-07-12 evidence audit's four passes (validity / per-frame-own-fit geometry self-check / event window / patch-strip detector) — those need a bundle's gitignored `capture.mkv`, so `test_audit.py` validates them on synthetic footage with injected defects; its `dataset` pass re-checks the audit against the **committed** `doc/datasets/2026-07-optics` (43/43 published numbers reproduce) and prints the register of claims that need the videos | `make optics-check`; `make optics-audit-dataset` for the committed-data half alone (stdlib only) |
| `pinenote/tools/power` | 1 | Read-only Guile snapshot/delta recorder against deterministic fake `/proc`/`/sys` roots; plus a closed, unimported provider constructor and pure injected-capability Lua coordinator with exact transaction/rollback traces, durable records, poisoning, and no filesystem/sysfs authority. Neither Lua module is production-wired.  `test-autosuspend-policy.lua` is the one production-wired suite here: it extracts `suspend_once()` and the post-wake branch *verbatim* from the live `autosuspend.lua` and runs them on a virtual clock, pinning that an RTC-backstop wake re-suspends after a short settle while a button wake keeps the whole idle period, plus the resulting duty-cycle arithmetic and daemon/service default agreement | `make power-check`; capability/coordinator gates are in `make activation-positive-check` |
| `pinenote/tools/rockchip-pm` | 1 | Verbatim extracted BSP SIP/PM model and generic executor plus compiled-DTB donor/maximal fixtures: exact RK3568 bindings; standard OF metadata `compatible`, `name`, `status`; donor event ordering, GPIO/regulator limits, descriptive-only virtual-poweroff, fake-only unwind injection, strict source-tree validation, MEM-only production parsing, consumer-handle lifetime/locking, and proof that the real backend is linked while its active-driver `.prepare` edge is omitted | `make rockchip-pm-check` |
| suspend preflight | 1 | Fail-closed config/DT/KOReader qualification fixtures: exact PM config lines, effectively enabled cover+RK817 wake identities, exact disabled policy bytes, and restricted two-value KOReader policy evaluation; plus structural gates over the TPS65185 PM hunk and the fbdev resume barrier, the latter with its own mutation suite | `make suspend-check` |
| activation-positive composite | 1 | Runs the closed capability constructor, pure Lua coordinator, a separate compiled-DTB synthetic active Rockchip PM scenario through fake ops, and the unchanged production hard-off preflight in one gate. It cannot select the real backend or write `/sys/power/state` | `make activation-positive-check` |
| `pinenote/tools/manuals` | 1 | The man/info -> EPUB converter behind the reader's manuals shelf (issue #17, `doc/manuals.md`), run as the shipped file rather than a copy: magic-byte decompression including the `quirk:` that an undecodable **zstd** frame must RAISE (Guix now compresses man pages with zstd, and mandoc converts a zstd frame to plausible garbage and exits 0); discovery that takes `share/man/manN` and never `share/man/<locale>/manN`, resolves `.so` aliases and orders split `foo.info-N` numerically; the five mandoc post-processing transforms against a committed fragment of mandoc's own output; the info block classifier (reflowed paragraphs, verbatim examples, `@table` -> `<dl>`, menus -> links, `*note` resolution) including the `quirk:` that the XML sanitizer must NOT eat US, the node separator; and EPUB structure -- mimetype first and stored, manifest/spine/archive agreement, **every internal link resolving to an anchor that exists**, cross-chapter NCX nesting, and byte-identical output across two runs.  It also **executes** the staging one-shot (`pinenote/services/manuals-stage.sh`) against a fake library through every branch -- first copy, no-op when current, refresh that leaves a user's own book alone, a user-deleted shelf staying deleted, an unmounted root -- which is why that script takes its mount root as an explicit argument.  It renders nothing: no KOReader engine runs here | `make manuals-check` |
| `pinenote/tools/refresh-episodes` | 1 (analysis) / 4vc (capture) | Episode analysis for `[pn-refresh]` traces, from a qemu-virt campaign or a copy of a device's `reader-session.log`: discovers the panel extent from the traces (KOReader emits over-panel rects like `-28,0,1460,1872`, so anchoring on max area alone scores every real page turn as not-full-panel), then reports a gap-threshold **sweep** rather than a single sub-second count, runs of >2 rapid refreshes, and the issue-#14 menu antecedent — a flash\*/global wash **and** a full-panel `ui/partial` within 15 s — against its own base rate, with both halves also reported separately. `test-refresh-episodes.py` replays a fixture reconstructed from the issue's published structure and requires the published answers back (5 episodes, largest 8 in 2.26 s, 13 sub-second gaps, 4/5 antecedent, 131 ms floor) | `make refresh-episodes-check`; capture via `make qemu-pageturn-campaign` |
| `pinenote/tools/ebc-damage-probe` | 6 (device-side) | Supervised LuaJIT probes that write chosen patterns into the mmapped framebuffer and count EBC IRQs — isolates deferred-io/damage-scheduling behavior from KOReader entirely (the instrument behind the fbcon-starvation and publish-on-call findings, and the `defio_delay_ms` sweep) | no `make` target; copy to the device, see its README and `doc/hardware-deploy.md` |
| `pinenote/tools/ddr-sip-probe` | 6 (device-side) | Read-only go/no-go for the bl31 DRAM-frequency SIP: an out-of-tree module that issues version *queries* only and returns `-ENODEV` so it never stays loaded. Answered GO on 2026-08-06 (SIP v2, DRAM version 0x101) | no `make` target; cross-built and insmodded supervised, see its README and `doc/power-management.md` |
| `pinenote/tools/ddr-dvfs-test` | 6 (device-side) | Supervised DDR `SET_RATE` campaign tool against the same SIP; performed this board's first DDR rate change (324 MHz, 2026-08-06, EBC quiesced for every switch). No `README.md` yet — its `procedure.md`/`protocol.md` are the coverage record | no `make` target; supervised sessions only, see `procedure.md` and `doc/power-management.md` |

The rung column indexes **the validation ladder below** (1 = offline
host suite, 6 = needs the device). ROADMAP §3's build-order rungs are a
*different* numbering and appear here only with an explicit "ROADMAP"
qualifier (e.g. rung 7a, the offline refresh-machine executor inside
`ebc-logic-check`).

Each tool's `README.md` documents what it does and does **not** cover
(`ddr-dvfs-test` has no README yet; its `procedure.md` and `protocol.md`
serve that role).

A second caveat, learned on 2026-08-01: **the host harness compiles the
driver under its own config, so code behind an `#ifdef` the shim does not
define is invisible to it.** The suite can go fully green with such a
branch deleted outright. When you touch code inside a config guard, the
cross-build (`make kernel`) is the compile gate and a structural gate over
the patch is the behavioral one; `validate-ebc-fbdev-resume-hunk.sh` and
its mutation suite are the worked example. Before trusting a harness
result, check that the harness actually compiles the lines you changed.

**`CONFIG_DRM_FBDEV_EMULATION` is now the exception (2026-08-04.)**
`ebc-fbdev-order-test` defines it and exercises all four guarded blocks —
`defio_delay_ms`, the fbdev probe wrapper, the resume barrier, the
deferred-io drain in `ioctl_trigger_global_refresh`, and the static
cleared on remove. Deleting that branch now turns the suite red. The
general warning above still stands for every *other* config guard.

Two things that test earned, worth stealing:

- **A single-stack harness cannot test an ordering that depends on
  preemption.** The first version of the drain test passed against *both*
  orderings — with one stack, `wake_up_process()` cannot let the refresh
  thread run *inside* the ioctl, which is exactly where the two orderings
  differ, so the flag was always set before the thread got to run. It
  needs the thread on a second pthread with a strict baton handoff (one
  runnable task at a time, control moving only at `wake_up_process` and
  `schedule`). Verify a new concurrency test by making it **fail** on the
  broken ordering before believing it passes on the fixed one.
- **A deterministic baton models preemption, not a race.** The real system
  runs a SCHED_FIFO refresh thread against a SCHED_OTHER kworker. The
  harness pins *ordering*; it cannot show the absence of a race window.
  Never read a green run as race-freedom.

A third thing, learned while fixing the sustained-damage starvation
(issue #22, 2026-08-24): **a correctness-complete suite can be blind to a
liveness bug, and the fix for one can be broken by the harness's own
unrealistic state.** Nothing in the suite asserted that
`rockchip_ebc_refresh` ever *returns*, so a multi-minute hang went unseen.
And when the drain gate was first written to also skip the `frame == 0`
splice, five direct-call tests went red — not because the driver was
wrong, but because `harness_ebc` leaves `probe`'s initial
`do_one_full_refresh = true` latched and those tests drive
`run_refresh_synth` without the thread that would have cleared it. The
harness was modelling a state the driver never reaches. The fix was to
model the thread's read-and-clear in `run_refresh_synth` *and* to narrow
the gate to the mid-frame splice, which is the only one that is "new
damage". When a new gate makes old tests red, ask which side is
unrealistic before assuming it is the driver.

A third limit, found while trying to reproduce the post-resume dead-write
window offline (2026-08-02): **the rung-7a harness drives
`rockchip_ebc_refresh(ebc, ctx, …)` with an explicitly passed `ctx`, and
never runs `rockchip_ebc_refresh_thread()` itself.** It can therefore
validate refresh *mechanics* to a very high standard, but it structurally
cannot reproduce any defect about *which* context the thread picked up —
the thread's outer-loop `ctx = to_ebc_crtc_state(READ_ONCE(ebc->crtc.state))->ctx`
read, its park/unpark boundary, and the ctx handoff across a system sleep
are all outside what the harness executes. Closing that gap means running
the thread body against terminating `kthread_should_park`/`_stop` shims
(the bracket test's shim is the starting point). Until then, thread-ctx
lifecycle questions are hardware or code-reading questions, and the
harness going green says nothing about them.

The recurring caveat: **none of this models electrophoretic optics.**
Ghosting, grayscale uniformity, temperature drift, DC balance, pen
latency — those stay on the hardware-only list. The tools validate
*bookkeeping and arithmetic*; the panel validates *physics*.

Getting the pulled waveform for local runs: on a booted device,
`base64 /lib/firmware/rockchip/ebc.wbf` over the console (or the backups
in `doc/device-runbook.md`). Use your own device's waveform backup — the
per-operator ledger (`doc/device-runbook.md`) records where yours lives.

## The validation ladder (toward hardware)

Run in order, stopping at the first failure. Rungs 1–5 are offline; only
6 touches the device. (See `doc/building.md` for the exact commands and
`ROADMAP.md` §3 for rungs not yet built, e.g. vkms writeback screenshot
tests.  The refresh machine now *executes* offline — rung 7a, part of
`make ebc-logic-check`, scoped in `doc/ebc-harness-spike.md`; the QEMU
device model, 7b, remains future work.)

1. **Host tool suites** — `make check-host` (the aggregate; with `WBF=`
    it also runs `wbf-check` and the waveform-gated tests, which a
    reader candidate requires). The Rockchip gate statically proves a zero-SMC production
    probe path while compiling the dormant typed model and parsing real DTBs
    carrying the donor property schema. Fast; catches
    driver-logic and waveform regressions.
2. **Static Guix builds** — `make kernel-drv` (cheap derivation gate:
   ~0.6 s, and cheap *only* because of `--no-grafts`; with grafting,
   `guix build -d` has to realize the ungrafted output and performs a
   real cross kernel build), `make reader-system-drv` (the only gate
   that reads `services/*.scm` and `systems/*.scm` **as Scheme** — rung
   1 never evaluates them, so a broken gexp is invisible until here),
   and `make kernel-version-check` (asserts the resolved kernel is
   still 7.0.x; it *fails by design* on drifted channels and passes
   with `TIME_MACHINE=1` — see `doc/kernel-forward-port.md` and issue
   #13). Then `make kernel` / `make <flavor>` / `make rootfs-<flavor>`.
   Add `TIME_MACHINE=1` to build against `channels.scm` rather than
   your last `guix pull`.
3. **Source + config inspection** —
   `guix shell git python -- pinenote/scripts/preflight/inspect-kernel-source.sh
   SOURCE RESOLVED_CONFIG` from the full checkout,
   followed by `inspect-pinenote-battery-dtb.sh` on the generated PineNote DTB.
   Run `make suspend-check`, then run
   `inspect-pinenote-suspend-gates.sh RESOLVED_CONFIG DTB SUSPEND_POLICY_LUA
   KOREADER_DEVICE_LUA` against the built artifacts. This verifies the exact
   disabled policy module and uses restricted false/true injection to prove the
    returned device class follows it. Its fixtures explicitly accept the three
    standard metadata properties and reject any lookalike or policy property;
    source/compiled DT coverage is distinct from Linux's live-OF `name`
    normalization. It deliberately proves the KOReader-side suspend
   policy module is still the exact disabled fixture (`return false` —
   suspend is owned by the standalone autosuspend daemon, not KOReader)
   and that the DT carries exactly the reviewed PM policy; firmware and
   physical sleep remain hardware-only.
4. **QEMU smoke** (`make qemu-smoke`) for generic ARM64 userspace, and
   **QEMU virt** — interactive (`make qemu-virt ROOTFS=…`) or the
   mechanized rung-4 gate (`make qemu-virt-check ROOTFS=…`) — which boots
   the *real* kernel/initrd/rootfs against a synthetic waveform+os2 disk.
   This catches the config/initrd/root-mount regression class (it's how the
   VIRTIO_MENU olddefconfig drop was caught): kernel + PREEMPT_RT boot,
   initrd waveform discovery + EBC module load, PNGuixRoot pre-root
   visibility, root mount, **udev completion, the post-udev one-shots**
   (waveform install, EBC params), **orientation bridge readiness before
   reader-session start, and a clean
   poweroff** — the Shepherd service-ordering class that cost the first
   two hardware sessions. Because shepherd's messages divert from the
   console (/dev/kmsg) to /var/log/messages once its system-log service
   is up (~t+5 s — the source of the retracted 2026-07-04 "virt
   deadlocks entering udev" finding; see `doc/status.md` 2026-07-05),
   the harness asserts the post-udev milestones by logging in as root
   over the console socket and grepping the guest's own
   /var/log/messages, emitting VIRTCHK-\* sentinels into the console
   log. The ACM gadget service still can't succeed on virt (no dwc3),
   and `dummy_hcd`/`vkms` are built for a later rung but aren't
   reachable through this boot.
   **4v. QEMU virt visual loop** (`make qemu-virt-visual ROOTFS=…`) — the
   same boot plus a virtio-gpu framebuffer at panel resolution
   (1872x1404) and virtio tablet/keyboard. The KOReader pinenote device
   target is selected via the harness-only `wilkbook.force_device=
   pinenote` cmdline token; QMP screendumps assert KOReader actually
   paints (non-uniform frame) and a scripted tap asserts the input path
   moves pixels. This is where UI behavior, damage patterns, and the
   `[pn-refresh]` intent traces iterate without hardware — what the
   e-ink *optics* do with those updates stays on hardware and rung 7's
   simulators.
   **4vc. Page-turn / menu campaign** (`make qemu-pageturn-campaign
   ROOTFS=…`) — the same boot driven for minutes instead of one tap.
   A persistent QMP driver walks a generated plan of page turns at
   three cadences with menu open/dismiss cycles interleaved (the
   antecedent 4 of the 5 issue-#14 field episodes share), logging a
   host-clock ledger of every action; a console harvester then cats the
   guest's own `[pn-refresh]` lines out of
   `/var/log/reader-session.log`, and
   `pinenote/tools/refresh-episodes/refresh-episodes.py` scores them
   with the field analysis's own signature logic — threshold sweep,
   episode runs, menu-antecedent rate against base. Coordinates are
   MEASURED, not assumed: `CAMPAIGN_PROBE=1` writes a 3x3 grid plan and
   dumps a screendump per tap. KOReader renders portrait into the
   landscape framebuffer, so `logical_x = 1403 - fb_y`,
   `logical_y = fb_x`, and the top-right dogear zone overrides the menu
   zone (fb(160,120) toggles a bookmark, it does not open a menu).
   **What this rung cannot show:** virtio-gpu absorbs a full-panel blit
   in microseconds where the panel takes ~300 ms, and issue #14's 131 ms
   floor argues the repeated refresh is waiting on the previous e-ink
   pass — so any mechanism gated on real panel service time is absent
   here. Reproducing an episode is strong evidence; not reproducing one
   is weak.

The orientation bridge is both offline- and hardware-validated (2026-07-19):
the PineNote production self-test delivered MSC_RAW through its real evdev node,
and all four physical edges drove distinct, correct KOReader orientations. It
samples coherent buffered XYZ scans, never independently polled axis files.
The same session measured cyttsp5's inverted MT axes at five visible targets;
the source-gated min/max mirror passed a live A/B and is pinned in the host
input suite. The final baked image passed os2 write/readback, first boot, all
four poses, toggle/replay, contact deferral, and bridge-restart recovery in the
same session; the exact hardware record is in `doc/status.md`.
5. **Mock helper + boot-bundle inspection** — the preflight scripts.
   `inspect-rootfs-image.sh` requires the exact ext4 to carry `/boot/config`
   beside `/boot/Image`, proves Rockchip activation is compiled out in that
   embedded config, resolves the packaged diagnostic and KOReader store
   targets, requires all four dormant modules, hashes the exact disabled
   policy, and rejects dormant imports in packaged `device.lua`. The
   rootfs-matched bundle carries the same config and repeats the activation
   check, so these facts share one rootfs identity rather than unrelated build
   paths.
6. **Hardware deployment** — `doc/hardware-deploy.md`, backups per
   `doc/device-runbook.md` verified first. Write os2 only; os1 is the
   rescue path. Harvest `/var/log/messages` from os2 afterwards
   regardless of outcome — an unobserved boot is still diagnosable that
    way (that's how the 2026-06-11 findings were recovered).
   The EBC barrier sub-rung is one supervised run only: stop the reader, prove
   `reader.lua` absent, capture pre/post UART and `dmesg`, use only
   `pinenote-ebc-sleep-frame-test --run` (never the older `--draw-smoke`), and
   accept only two nonzero generations plus visible card/restoration, zero
   exit, and normal reader repaint. First failure is terminal for that boot;
   no suspend is requested.

## What only hardware can prove

Keep this list in mind when deciding whether a change *needs* a session:
waveform optics (ghosting, uniformity, mode tradeoffs); real panel
temperature behavior and LUT-bin switching; VCOM/power sequencing; pen
latency and PREEMPT_RT's actual effect; the dwc3 `ep0out` behavior
(`dummy_hcd` bypasses the broken layer); EBC frame timing under load; and
end-to-end reading feel. Deep suspend adds TF-A/U-Boot compatibility, DDR
retention, wake routing, PMIC/EBC rail state, post-resume display repair, and
actual suspend current to this hardware-only set. Everything else should be
squeezed onto an offline rung first.

## EBC IRQ counts: global and partial are not the same unit

Verified from the driver's register programming, 2026-08-02. Every EBC
frame measurement in this repo depends on it:

- **Global refresh** (`rockchip_ebc.c`, the `EBC_DSP_START` write carrying
  `DSP_FRM_TOTAL(num_phases - 1)`): the whole waveform runs as **one**
  hardware transaction with a single `wait_for_completion(&display_end)`.
  It costs **1 IRQ**, whatever the phase count.
- **Partial refresh** (the `EBC_DSP_START_DSP_FRM_START` write with no
  total, inside the per-frame loop with its own `reinit_completion` /
  `wait_for_completion`): drives frame by frame and costs **1 IRQ per
  frame** — 38–46 for one pass, temperature-dependent.

So an IRQ delta of `1` is a *completed global refresh*, not "one stray
frame", and a delta of `~46` is one partial pass. Reading a small delta as
"almost nothing happened" inverts the meaning: on 2026-08-01 and
2026-08-02 the suspend/resume cycle's "exactly 2 frames" was in fact **two
successful global refreshes** — the pre-park off-screen wash and the
post-resume restore — i.e. evidence that the global path *works* after
resume, not that the panel was dead.

Corollary for acceptance tests: never compare a global-path count with a
partial-path count, and never compare partial counts across a thermal
window (the phase count is temperature-compensated; 38 and 46 are both
one pass).

## Absence of an error is not a passing test

From the SC7A20 deep-suspend work, 2026-08-03
(`doc/artifacts/pinenote-sc7a20-resume-fixed-20260803/`). The first fix
removed a loud, obvious failure and replaced it with a silent one that
every cheap check called healthy:

| check | verdict | reality |
|---|---|---|
| no `nobody cared` in dmesg | PASS | storm genuinely gone |
| IRQ `ddepth=0` | PASS | genirq genuinely fine |
| control registers read back correct | looks fine | chip genuinely configured |
| **interrupt rate after resume** | **0/s** | **autorotation dead** |

The rules this earned:

- **Test the positive behaviour, not the absence of the symptom.** "The
  error stopped" and "the thing works" are different claims. Measure the
  rate, the output, the effect — something that is *zero* when broken and
  *non-zero* when working.
- **Baseline on both sides of the transition, over equal windows.** A
  post-resume rate means nothing without the same measurement taken
  before, on the same device, in the same state.
- **A zero baseline invalidates the run.** Report `INVALID`, never a
  score. Here an earlier *failed* suspend had already broken the sensor,
  so `pre=0` — comparing against it would have manufactured a pass.
- **Confirm the precondition actually happened.** The first run reported
  "no storm after resume" when the device had never suspended: dwc3
  returned `-EAGAIN` because the USB gadget was still bound
  (`last_failed_dev=fcc00000.usb`). Any suspend test must assert
  `suspend_stats/success` incremented before it interprets anything.
- **A device-side check that shells out to a missing tool reports
  "absent", not "untestable".** `readelf`, `nm`, `objdump` and `strings`
  do not exist on the reader image; a module-verification script using
  them declared the correct image "WRONG". Use `grep -a` on the binary, or
  verify from the host with the cross binutils in the store.

Sensor-specific but worth stealing: `STATUS_REG` reading all-ones
(`0xff` — data-ready **plus** overrun on every axis) is the signature of
"sampling fine, nobody consuming" — a dead interrupt path wearing a
healthy register dump.

## Rung 4d — QEMU-virt with a data partition (2026-08-07)

`make qemu-data-check ROOTFS=<rootfs.ext4> [FIXTURE=...]`

The same boot as rung 4, on a synthetic p7 built rootless by
`pinenote/scripts/qemu/make-data-fixture.sh`. It exists because every rung
before it booted a disk with **no p7 at all**, so the entire library and
migration story — the thing an alpha user meets first — was testable only
on the one physical device.

The panel is deliberately not in scope. Whether pixels land on e-ink or on
nothing at all does not change the startup flow, and the startup flow is
the question: *do we come up pointed at the right place, on a disk someone
has already been using?*

Three fixtures, with **different** correct answers — asserting one set
against all three would pass the case it was written for and say nothing
about the others:

| `FIXTURE=` | the disk | must happen |
|---|---|---|
| `os1-used` (default) | a lived-in stock-Debian home, no library | library created; `Debian home` pointer added, **relative**, resolving to a real book; os1's home untouched |
| `with-library` | an existing `/books` with a book and its `.sdr` | **nothing changes** — no pointer, contents intact |
| `empty` | no Debian home at all | library created, **no** pointer |

The `with-library` case is the one guarding the author's device: `/root`
does not survive a reflash, so the one-shot re-runs on every deploy and
must not decorate a library someone is using.

Common to all three: p7 mounts, the seeded profile points at the library,
the quickstart is suppressed, and **KOReader is still running** at probe
time.

Evidence the probes discriminate rather than always agreeing — the same
three sentinels across the three runs:

    os1-used      LIB-PTR-../user  LIB-COUNT-1  LIB-KEPT-no   DEB-DOCS-3
    with-library  LIB-PTR-none     LIB-COUNT-2  LIB-KEPT-yes  DEB-DOCS-3
    empty         LIB-PTR-none     LIB-COUNT-0  LIB-KEPT-no   DEB-DOCS-0

**What it still cannot tell you.** There is no panel, so nothing here
speaks to what the first screen looks like, only to what it is pointed at.
And `ls`-shaped assertions catch a directory gaining entries, not a file
being rewritten in place.
