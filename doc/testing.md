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

All three build with `guix shell gcc-toolchain python -- make -C <dir>
check` and have a root-level convenience target. Waveform-dependent tests
need the per-device `.wbf` (never committed — see the firmware policy):
pass `WBF=/path/to/ebc.wbf`; without it those tests skip with a clear
message rather than fail.

| Tool | Ladder rung | What it validates | Run |
| --- | --- | --- | --- |
| `pinenote/tools/wbf` | 1 | PVI `.wbf` parsing/decode (header, modes, temperature bins, LUT decode) exactly as `rockchip_ebc` loads it; `--dump-lut` exports a decoded LUT for the simulator | `make wbf-check WBF=…` |
| `pinenote/tools/ebc-logic` | 2 + 7a | Rung 2 (`ebc-logic-test`): the driver's pure logic — XRGB8888/R4→Y4 blitters, damage split/collision scheduling, threshold/dither paths — vs independent references.  Rung 7a (`ebc-refresh-test`): *executes* the refresh state machine (probe, global/partial orchestration, LUT upload, DMA windowing, IRQ/completion, buffer switching) against a behavioral device model under ASan — with non-coherent DMA (the device reads only synced shadows, so a missing `dma_sync` fails a test) — incl. a drive-sequence differential vs rastersim's independent waveform decode | `make ebc-logic-check WBF=…` |
| `pinenote/tools/rastersim` | 3 | A standalone Gray8→Y4 raster library + waveform *simulator* (state model + LUT playback), with golden-image and convergence tests | `make rastersim-check WBF=…` |

Each tool's `README.md` documents what it does and does **not** cover.
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

1. **Host tool suites** — `make wbf-check ebc-logic-check rastersim-check`
   (with `WBF=`). Fast; catches driver-logic and waveform regressions.
2. **Static Guix builds** — `make kernel-drv` (cheap derivation gate),
   then `make kernel` / `make <flavor>` / `make rootfs-<flavor>`.
3. **Source + config inspection** —
   `pinenote/scripts/preflight/inspect-kernel-source.sh`.
4. **QEMU smoke** (`make qemu-smoke`) for generic ARM64 userspace, and
   **QEMU virt** — interactive (`make qemu-virt ROOTFS=…`) or the
   mechanized rung-4 gate (`make qemu-virt-check ROOTFS=…`) — which boots
   the *real* kernel/initrd/rootfs against a synthetic waveform+os2 disk.
   This catches the config/initrd/root-mount regression class (it's how the
   VIRTIO_MENU olddefconfig drop was caught): kernel + PREEMPT_RT boot,
   initrd waveform discovery + EBC module load, PNGuixRoot pre-root
   visibility, root mount, **udev completion, the post-udev one-shots**
   (waveform install, EBC params), **reader-session start, and a clean
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
5. **Mock helper + boot-bundle inspection** — the preflight scripts.
6. **Hardware deployment** — `doc/hardware-deploy.md`, backups per
   `doc/device-runbook.md` verified first. Write os2 only; os1 is the
   rescue path. Harvest `/var/log/messages` from os2 afterwards
   regardless of outcome — an unobserved boot is still diagnosable that
   way (that's how the 2026-06-11 findings were recovered).

## What only hardware can prove

Keep this list in mind when deciding whether a change *needs* a session:
waveform optics (ghosting, uniformity, mode tradeoffs); real panel
temperature behavior and LUT-bin switching; VCOM/power sequencing; pen
latency and PREEMPT_RT's actual effect; the dwc3 `ep0out` behavior
(`dummy_hcd` bypasses the broken layer); EBC frame timing under load; and
end-to-end reading feel. Everything else should be squeezed onto an
offline rung first.
