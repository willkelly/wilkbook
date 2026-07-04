# Executing the real EBC driver offline — scoping spike (2026-07-04)

Question: can the *hardware-facing half* of `rockchip_ebc` — probe, the
refresh state machine, LUT upload, DMA windowing, the IRQ path — be
exercised without a PineNote? Rungs 1–3 of the testing ladder cover the
driver's pure functions (blitters, scheduling, waveform decode); this
spike scopes the two candidate harnesses for everything *behind* the
regmap: (a) executing the refresh machine inside the existing host shim,
and (b) a QEMU device model for the EBC block. Evidence below is from
reading the verbatim driver as carried in the forward-port patch
(extract it with `pinenote/tools/wbf/extract-from-patch.py`; line numbers
refer to that extraction).

**Headline: the driver's hardware surface is far smaller than the DT
node suggests, and both harnesses are cheaper than feared.** (a) is
~2–4 days on top of `pinenote/tools/ebc-logic`; (b) is a 1–2 week
project. Recommendation at the end.

## 1. The probe dependency chain (lines 2664–2766)

Everything `rockchip_ebc_probe` acquires, with the cheapest stub each
needs in a harness:

| Dependency | Driver call | Fatal? | Cheapest stub |
| --- | --- | --- | --- |
| MMIO window | `devm_platform_ioremap_resource` + `devm_regmap_init_mmio` (0x5000 bytes) | yes | (a) RAM array behind the shim regmap; (b) one QEMU `MemoryRegion` |
| Clocks `hclk`, `dclk` | `devm_clk_get` ×2 | yes | two `fixed-clock` DT nodes — **`clk_set_rate` return values are ignored** (lines 1686–1691), so fixed clocks are safe |
| Temperature | `devm_iio_channel_get(dev, NULL)` | yes | (a) shim already stubs IIO; (b) ~40-line stub IIO provider as an *out-of-tree module* in the harness initramfs (no new forward-port hunk) |
| Supplies `panel`, `vcom`, `vdrive` | `devm_regulator_bulk_get` (2641–2645) | yes | three `regulator-fixed` DT nodes (or rely on regulator-core dummies) |
| IRQ | `platform_get_irq(pdev, 0)` + `devm_request_irq` | yes | (a) call the driver's own `rockchip_ebc_irq()` from the fake device; (b) one GIC SPI |
| Panel | `devm_drm_of_get_bridge` in `rockchip_ebc_drm_init` (2499) | yes (EPROBE_DEFER) | port graph to a panel node bound by `panel-simple` — the `eink,ed103tc2` entry is already in the patch |

**What the driver never touches, despite the DT node carrying them:**
no GRF/syscon access, no reset controls (the DTSI's `resets =` are
unused — `ebc->reset_complete` is just the `skip_reset` module param),
and power domains only via the platform core (omit the property and
runtime PM works standalone). No pinctrl dependency beyond the default
dummy. This is what makes a harness DTB ~100 lines instead of an SoC
model.

## 2. The device contract (what a model must actually do)

Register behavior, enumerated from the driver:

- **Config registers** (`rockchip_ebc_configure`, 1712–1768): EPD_CTRL,
  DSP_CTRL, DSP_H/VTIMING*, DSP_ACT_INFO, WIN_CTRL, WIN_VIR/ACT/DSP,
  WIN_DSP_ST — write-and-store; no behavior needed.
- **LUT upload** (1390–1394): `regmap_bulk_write(EBC_LUT_DATA, …)` —
  store; the LUT region and status regs are the volatile/uncached set
  (`rockchip_ebc_volatile_reg`, 2618: DSP_START, INT_STATUS,
  CONFIG_DONE, VNUM, and everything above WIN_MST2; the rest is
  REGCACHE_FLAT).
- **Framebuffer addressing** (1420–1432): the driver `dma_map_single`s
  its `prev`/`next` Y4 buffers and writes the bus addresses to
  WIN_MST0/WIN_MST1; in partial (three-window) mode each frame also
  writes the phase buffer to WIN_MST2 (or MST0 in direct mode)
  (1232–1234).
- **The go sequence**: `CONFIG_DONE` → `DSP_START | FRM_START`, then the
  driver blocks on `wait_for_completion_timeout(&ebc->display_end)` —
  once per whole refresh in global/LUT mode (652–664), **once per
  frame** in partial mode (1235–1272).
- **The IRQ contract** (2647–2662) is one bit: set
  `DSP_END_INT_ST` in EBC_INT_STATUS and raise the line; the handler
  completes `display_end` and writes the clear bit back.

So a behavioral model is: store registers; on DSP_START-with-FRM_START,
read the Y4/phase buffers from memory at MST0/1/2 per the configured
geometry, optionally apply LUT playback semantics (librastersim already
implements this), emit a PNG, set DSP_END, raise the IRQ. No timing
model needed — the driver paces itself off the completion.

## 3. Option (a): execute the refresh machine in the host shim

`pinenote/tools/ebc-logic` already compiles the verbatim driver against
a shim whose regmap section is explicitly **inert** (`shim/kernel-shim.h`
"regmap (INERT)"), and whose `completion` is a synchronous flag — so a
fake device implemented *inside* `regmap_write` (populate INT_STATUS,
call the driver's real `rockchip_ebc_irq()`) completes `display_end`
before the driver's wait even runs. **No threads required.** The seam:

1. Back the regmap stubs with a `uint32_t regs[0x5000/4]` array.
2. Hook DSP_START: snapshot MST0/1/2, read the driver's own buffers
   (shim `dma_map_single` is identity), hand frames to librastersim for
   LUT playback, render PNG goldens.
3. Drive `rockchip_ebc_refresh()`/the thread body from tests, under
   ASan, over the shipped module params.

Coverage gained over rungs 1–3: the refresh orchestration (global vs
partial sequencing, per-frame register order, CONFIG_DONE discipline),
LUT upload path, MST addressing arithmetic, the
buffer-switch/queue-splice logic around 1246–1268, and
teardown-with-queued-damage (finding 3's UAF class) — all executed, not
just compiled. Estimate: **2–4 days.** Limits: no real probe, no DRM
core, no UAPI ioctls, no kthread/RT semantics.

## 4. Option (b): QEMU device model

A ~300–500 line QEMU sysbus device (MemoryRegion + IRQ + DMA reads +
PNG writer), carried as a patch to Guix's QEMU package. Boot shape per
the 2026-07-04 decision: **no virtio, no distro, no udev** — the
`linux-pinenote` kernel + a purpose-built DTB + a tiny initramfs that
modprobes the driver, loads `ebc.wbf` from the initramfs
`/lib/firmware`, and runs a small DRM client. Placement: instantiate on
the virt machine's dynamic-sysbus platform bus, then merge the node into
a `dumpdtb` snapshot with `dtc` (pin a versioned `-M virt-N.M` so the
memory map is stable). The DTB fragment needs: the ebc node (reg, one
SPI, hclk/dclk fixed-clocks, io-channels → stub IIO node, three
fixed regulators, port graph), the panel node, nothing else.

Coverage gained over (a): the **real probe path**, real DRM atomic core
and module lifecycle, and the **real UAPI** (GLOBAL_REFRESH, damage
clips) — the only offline target a reader/compositor can be developed
against with the true ioctl contract. Estimate: **1–2 weeks**, the tail
risk being DTB/probe friction, which §1 has now bounded tightly.
Sidesteps the qemu-virt udev hang entirely (no Guix userspace).

**Honesty limit (both options, especially b):** the model's register
semantics come from reading this driver and the RK3566 TRM, so these
harnesses validate that the driver is *consistent with our
understanding* — they cannot prove it drives the silicon correctly. The
ground-truth complement remains the on-device `EXTRACT_FBS`
hardware-differential (ROADMAP rung 3 note). Optics stay hardware-only.

## 5. Recommendation

Do (a) first — days, no new infrastructure, immediately extends the
regression net over the refresh machine and renders end-to-end goldens
(driver blit → scheduler → LUT playback → PNG). Do (b) when the reader
track (ROADMAP §4) actually needs a UAPI-true offline target, using this
spike's dependency map as the build plan. Neither replaces the other:
(a) is the cheap regression net, (b) is the integration target.
