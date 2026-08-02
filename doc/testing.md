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
check` and every tool has a root-level convenience target.
Waveform-dependent tests need the per-device `.wbf` (never committed —
see the firmware policy): pass `WBF=/path/to/ebc.wbf`; without it those
tests skip with a clear message rather than fail.

| Tool | Ladder rung | What it validates | Run |
| --- | --- | --- | --- |
| `pinenote/tools/wbf` | 1 | PVI `.wbf` parsing/decode (header, modes, temperature bins, LUT decode) exactly as `rockchip_ebc` loads it; `--dump-lut` exports a decoded LUT for the simulator | `make wbf-check WBF=…` |
| `pinenote/tools/ebc-logic` | 2 + 7a | Rung 2 (`ebc-logic-test`): the driver's pure logic — XRGB8888/R4→Y4 blitters, damage split/collision scheduling, threshold/dither paths — vs independent references.  Rung 7a (`ebc-refresh-test`): *executes* the refresh state machine (probe, global/partial orchestration, LUT upload, DMA windowing, IRQ/completion, buffer switching) against a behavioral device model under ASan — with non-coherent DMA (the device reads only synced shadows, so a missing `dma_sync` fails a test) — incl. a drive-sequence differential vs rastersim's independent waveform decode and WBF-gated disable-tail caller/off-screen retention plus exact completion accounting.  Phase B (`ebc-replay`): replays KOReader `[pn-refresh]` traces through the same machine under candidate refresh policies — the display-quality workbench, results in `doc/refresh-policy.md` | `make ebc-logic-check WBF=…` |
| `pinenote/tools/ebc-barrier` | 1 | The separately invoked paint/barrier/restore diagnostic with fake framebuffer/DRM operations: strict fixed-width SUBMIT/WAIT ABI, high generation IDs, geometry/stride bounds, no-retry failure containment, exact restoration, cleanup precedence, double fail-closed reader ownership checks, and atomic pending/blocked signal acknowledgement. It never runs `--run` on the host | `make ebc-barrier-check` |
| `pinenote/tools/rastersim` | 3 | A standalone Gray8→Y4 raster library + waveform *simulator* (state model + LUT playback), with golden-image and convergence tests | `make rastersim-check WBF=…` |
| `pinenote/tools/koreader-input` | 2 | KOReader's *verbatim* `device/input.lua` + `gesturedetector.lua` (from the native `koreader-bin` bundle, under its own luajit) fed synthetic pen+touch evdev streams: reproduces the pen-hover tap-capture `quirk:` (finger tap → swipe), validates the `mixedrouter.lua` fix, checks exact `wilkbook-orientation` discovery plus source-gated MSC_RAW→MSC_GYRO translation, and pins cyttsp5 MT-axis normalization to five measured hardware targets | `make koreader-input-check` |
| `pinenote/tools/orientation` | 2 | Pure SC7A20 orientation classification: calibrated four-edge mapping, flat/diagonal/magnitude rejection, hysteresis, stable-sample dwell debounce, and duplicate suppression | `make orientation-check` |
| `pinenote/tools/power` | 1 | Read-only Guile snapshot/delta recorder against deterministic fake `/proc`/`/sys` roots; plus a closed, unimported provider constructor and pure injected-capability Lua coordinator with exact transaction/rollback traces, durable records, poisoning, and no filesystem/sysfs authority. Neither Lua module is production-wired | `make power-check`; capability/coordinator gates are in `make activation-positive-check` |
| `pinenote/tools/rockchip-pm` | 1 | Verbatim extracted BSP SIP/PM model and generic executor plus compiled-DTB donor/maximal fixtures: exact RK3568 bindings; standard OF metadata `compatible`, `name`, `status`; donor event ordering, GPIO/regulator limits, descriptive-only virtual-poweroff, fake-only unwind injection, strict source-tree validation, MEM-only production parsing, consumer-handle lifetime/locking, and proof that the real backend is linked while its active-driver `.prepare` edge is omitted | `make rockchip-pm-check` |
| suspend preflight | 1 | Fail-closed config/DT/KOReader qualification fixtures: exact PM config lines, effectively enabled cover+RK817 wake identities, exact disabled policy bytes, and restricted two-value KOReader policy evaluation; plus structural gates over the TPS65185 PM hunk and the fbdev resume barrier, the latter with its own mutation suite | `make suspend-check` |
| activation-positive composite | 1 | Runs the closed capability constructor, pure Lua coordinator, a separate compiled-DTB synthetic active Rockchip PM scenario through fake ops, and the unchanged production hard-off preflight in one gate. It cannot select the real backend or write `/sys/power/state` | `make activation-positive-check` |

Each tool's `README.md` documents what it does and does **not** cover.

A second caveat, learned on 2026-08-01: **the host harness compiles the
driver under its own config, so code behind an `#ifdef` the shim does not
define is invisible to it.** `rockchip_ebc.c`'s
`CONFIG_DRM_FBDEV_EMULATION` block — `defio_delay_ms` and the fbdev
resume barrier — compiles as the `#else` stub in every ebc-logic binary.
The suite can go fully green with that entire branch deleted. When you
touch code inside a config guard, the cross-build (`make kernel`) is the
compile gate and a structural gate over the patch is the behavioral one;
`validate-ebc-fbdev-resume-hunk.sh` and its mutation suite are the
worked example. Before trusting a harness result, check that the harness
actually compiles the lines you changed.

The recurring caveat: **none of this models electrophoretic optics.**
Ghosting, grayscale uniformity, temperature drift, DC balance, pen
latency — those stay on the hardware-only list. The tools validate
*bookkeeping and arithmetic*; the panel validates *physics*.

Getting the pulled waveform for local runs: on a booted device,
`base64 /lib/firmware/rockchip/ebc.wbf` over the console (or the backups
in `doc/device-runbook.md`). A verified copy from the 2026-07-04 session
lives at `~/pinenote-backup/2026-07-04-wbf-pull/ebc.wbf`.

## The validation ladder (toward hardware)

Run in order, stopping at the first failure. Rungs 1–5 are offline; only
6 touches the device. (See `doc/building.md` for the exact commands and
`ROADMAP.md` §3 for rungs not yet built, e.g. vkms writeback screenshot
tests.  The refresh machine now *executes* offline — rung 7a, part of
`make ebc-logic-check`, scoped in `doc/ebc-harness-spike.md`; the QEMU
device model, 7b, remains future work.)

1. **Host tool suites** — `make wbf-check ebc-logic-check ebc-barrier-check
    rastersim-check koreader-input-check orientation-check optics-check
    power-check rockchip-pm-check activation-positive-check suspend-check`
    (with `WBF=`). The Rockchip gate statically proves a zero-SMC production
    probe path while compiling the dormant typed model and parsing real DTBs
    carrying the donor property schema. Fast; catches
    driver-logic and waveform regressions.
2. **Static Guix builds** — `make kernel-drv` (cheap derivation gate),
   then `make kernel` / `make <flavor>` / `make rootfs-<flavor>`.
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
    normalization. It deliberately proves that suspend is
   still disabled, while firmware and physical sleep remain hardware-only.
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
