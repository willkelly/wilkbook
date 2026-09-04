# Kernel packaging and the forward-port workflow

Keeping the kernel current is a core goal of this project. The PineNote needs
a downstream display/pen stack that has never been mainlined, so every kernel
update means carrying those changes forward.

Hardware-proof notes in this doc are dated snapshots; when a note here
says "unproven" and `doc/status.md` records a later proof, status.md
wins — it is the single source of hardware truth.

## The working reference: stock os1 (Debian, 6.12-pinenote)

Stock Debian on `os1` runs a 6.12 PineNote kernel with everything working;
it is the cheapest oracle for "is our build doing the right thing"
(harvested read-only over SSH, 2026-06-10; the standing access
conventions — slot disambiguation, host-key policy, console discipline,
post-mortem harvest — are `doc/device-access.md`):

- Healthy EBC probe signature to expect in dmesg: several deferred
  `rockchip_ebc_probe start` lines, then
  `Loaded 4-bit PVI waveform version 0x19`,
  `Initialized rockchip-ebc 0.3.0 for fdec0000.ebc`, and an
  `fb0: rockchip-ebcdrm frame buffer device`. If a 7.0 boot lacks the
  waveform line, the failure is before/at waveform load, not in DRM.
- brcmfmac first requests `brcmfmac43455-sdio.pine64,pinenote-v1.2.bin`
  (Debian doesn't ship it; -2), then falls back to
  `brcmfmac43455-sdio.bin`, which loads. BT loads plain
  `brcm/BCM4345C0.hcd`. Our firmware packages cover both names.
- Its live `rockchip_ebc` parameters match our modprobe options; useful
  extra defaults: `default_waveform=4`, `refresh_waveform=4`,
  `diff_mode=Y`.
- USB config parity: 6.12 uses `USB_DWC3_DUAL_ROLE=y`,
  `USB_CONFIGFS=m`+`CONFIGFS_ACM=y`, `F_ACM/U_SERIAL/LIBCOMPOSITE=m`,
  `USB_ROLE_SWITCH=y` — identical resolution to our built 7.0 config, so
  the `ep0out` gadget failure is runtime (role timing/DT/driver
  regression), not a config gap.
- Gadget bracketing (2026-06-10): our exact configfs ACM recipe, run live
  on os1's 6.12, binds to `fcc00000.usb`, enumerates as 0525:a4a7, and
  passes data with no dwc3 errors; and the dwc3/usb2phy/type-C DT nodes
  are identical (modulo phandles) between the 6.12 DTB and ours. The
  `ep0out` failure is a 6.12→7.0 kernel driver regression. Next angles:
  diff `drivers/usb/dwc3/` (especially ep0/gadget) and
  `phy-rockchip-inno-usb2` between those versions, or test an
  intermediate kernel.
- 6.12 runs `GPIO_ROCKCHIP=m` with early initrd loading; our `=y` achieves
  the same probe ordering more bluntly.

## The three kernel packages

All live in `pinenote/packages/kernel.scm`:

- `linux-pinenote-6.6.30` — the m-weigand PineNote tree, pinned by commit.
  Hardware-validated end to end (display, Wi-Fi, BT, USB gadget). Kept as the
  known-good baseline and for isolating regressions in newer kernels.
- `linux-pinenote` — vanilla kernel.org sources (nonguix's `linux` package,
  which tracks the same version as Guix's `linux-libre`) plus the patch
  stack inventoried below, configured with `pinenote_defconfig`. This is
  the kernel-currency track. The channel therefore depends on nonguix
  (see `.guix-channel` / `channels.scm`).
- `linux-pinenote-debug` — `linux-pinenote` plus stacked debug patches
  (currently `linux-pinenote-debug-extract-fbs.patch`, which implements
  the `EXTRACT_FBS` belief-dump ioctl the primary kernel stubs with
  `-EOPNOTSUPP`). A separate inheriting variant so the primary stays
  byte-identical; debug patches are deleted as their investigations
  close.

## Patch inventory — what `linux-pinenote` actually applies

`%linux-pinenote-patches` in `pinenote/packages/kernel.scm` is the
authoritative list; the comments there carry each patch's rationale and
revert instruction. As of 2026-09-03 it is fourteen patches, applied in list
order on top of the vanilla source (items 8–11 are the direct-mode
driver and our fixes on it; item 12 is the mfd rk8xx kexec fix that
makes the update path's watchdog self-reset work; item 14 is a further
correctness pass on the direct-mode driver from a third-party audit):

1. `linux-pinenote-7.0-forward-port.patch` — the EBC display stack,
   WS8100 pen, PineNote DTS, `pinenote_defconfig`; the permanent core
   (this doc, "What the forward-port patch carries").
2. `linux-pinenote-7.0-bsp-sip-probe.patch` — the BSP SIP suspend
   compatibility layer, a narrow port of donor `72127ca` (next section;
   `doc/power-management.md`).
3. `linux-pinenote-7.0-st-accel-pm.patch` — ST accelerometer
   system-sleep support: mainline has no `.pm`, so a powered-down
   suspend leaves DRDY asserted, the kernel kills the IRQ ("nobody
   cared"), and autorotation dies until reboot
   (`doc/upstream-register.md` item 8).
4. `linux-pinenote-7.0-cpuidle-psci.patch` — rk356x CPU idle-states so
   a cpuidle driver exists at all. Marked **EXPERIMENTAL** when written
   (2026-08-05: unproven on this SoC by anyone; a firmware that accepts
   the state parameter but cannot wake the core **wedges the device**),
   **since hardware-proven** the same day — 4/4 deep cycles with
   idle-states active, and deployed in the current os2 image
   (`doc/status.md`, `doc/power-management.md`).
5. `linux-pinenote-7.0-vdd-cpu-auto-pfm.patch` — vdd_cpu (TCS4525)
   automatic PFM/PWM instead of the boot-forced PWM nothing ever
   clears: ~30 mA at idle, measured on glass 2026-08-06; carries the
   fan53555 NORMAL-branch fix (`doc/power-management.md`,
   `doc/upstream-register.md` item 10).
6. `linux-pinenote-7.0-dmc-static-low.patch` — `wilkbook_dmc`: holds
   DDR at the firmware table's lowest rate (324 MHz) over the DRAM SIP,
   ~25 mA saved quiesced, measured 2026-08-06 (`doc/power-management.md`).
7. `linux-pinenote-7.0-ultra-rails.patch` — ultra suspend, hrdl's
   configuration adopted whole: the standing
   `rockchip,suspend-state-override = <5>` **and** the three `*_pmu`
   rails off-in-suspend + `sdmmc1 cap-power-off-card` + the cyttsp5
   resume workaround. A MATCHED PAIR that must never be split (either
   half alone is proven broken — the 2026-08-07/08 ultra hardware sessions
   R10/R11 (rails-on: no wake) vs R12 (rails-off: wakes); records under
   `doc/artifacts/pinenote-ultra-*/`); `make
   ultra-coupling-check` enforces it, and this patch must apply **after**
   the bsp-sip patch whose `/rockchip-suspend` node it extends. 4.64 mA
   suspend measured on glass 2026-08-08
   (`doc/artifacts/pinenote-ultra-r12-20260808/`); as shipped, with the
   hourly RTC backstop, idle standby is **5.47 mA** over a 6.17-day
   unplugged soak with 170 cycles and no failures
   (`doc/artifacts/pinenote-ultra-soak-20260815/`).
8. `linux-pinenote-7.1-hrdl-direct-mode.patch` — hrdl's direct-mode EBC
   driver, swapping out the forward-port patch's `rockchip_ebc.c`
   (per-pixel software TCON, NEON blitters, offline CLUT; the swap's own
   `cpll_333m` DT hunk). Embraced 2026-09-02 (`doc/direct-mode-adoption.md`).
9. `linux-pinenote-7.1-ebc-parallel-advance.patch` — ours: the banded
   parallel NORMAL advance (18.4 → 11.9 ms full-panel, glass 2026-08-26)
   and its instruments; `queue_work`'s return checked.
10. `linux-pinenote-7.1-rect-hints-bounds.patch` — ours: the RECT_HINTS
    ioctl bounded (`doc/upstream-register.md` 24; `make direct-rect-hints-check`).
11. `linux-pinenote-7.1-probe-unwind.patch` — ours: the probe unwinds when
    `drm_init` fails (item 23; `make direct-probe-quirk-check`).
12. `linux-pinenote-7.1-rk8xx-kexec-sleep-pin.patch` — mfd rk8xx: adds
   `if (kexec_in_progress) return;` at the top of `rk8xx_shutdown()`
   (`drivers/mfd/rk8xx-core.c`, `#include <linux/kexec.h>`). Without it,
   `kernel_kexec()`'s `device_shutdown()` call runs the same shutdown
   hook a power-off uses, which switches the RK817 PMIC's SLEEP pin to
   its power-down function (`SYS_CFG3` bit pattern `NULL_FUN` → `DN_FUN`)
   and nothing in the new kernel restores it — so any SoC-level reset
   after a kexec that asserts that pin (the watchdog's global reset does)
   powers the chip off instead of rebooting it, register-proven
   2026-09-03 (`doc/upstream-register.md` item 25, `doc/status.md`).
    **Glass-proven 2026-09-03 17:05** (a halted trial kernel was reset by
    the armed watchdog and DEFAULT booted hands-off; the GRF bus-wedge
    hang is the one class the reset cannot recover — the blacklist
    prevents it). Merged 2026-09-03.
13. `linux-pinenote-7.1-sdio-pwrseq-delay.patch` — arm64 dts: 100 ms
    `post-power-on-delay-ms` on the PineNote's `sdio_pwrseq` (the
    Quartz64's value; mainline's PineNote DTS has none). With
    `cap-power-off-card` every resume re-enumerates the Wi-Fi card from
    cold and one resume in ten timed out on the first control exchange
    after the firmware download (2026-09-03, `doc/networking.md` §8).
    Written for upstream. Glass proof pending (the cycle rig).
14. `linux-pinenote-7.1-direct-correctness.patch` — ours, on top of
    hrdl's: four correctness fixes from the 2026-09-03 third-party audit
    (`doc/reviews/2026-09-03-third-party-audit.md`): the parallel
    advance no longer runs a band inline when `queue_work()` returns
    false (`WARN_ON_ONCE` instead — that return means the work is
    already queued and owns the completion); the 32×32 dither's second
    16-byte half now loads 16 bytes into the row instead of repeating
    the first half, in all three pixel-format copies;
    `rect_hint_batch` is validated (1..4096) and the rectangle count is
    capped at 65536 (`-E2BIG`); `OFF_SCREEN`/`EXTRACT_FBS` return
    `-EFAULT` on any short user copy instead of leaking a byte count or
    OR-ing residuals with errnos. Compiled clean
    (`mwycbl5a…-linux-pinenote-7.1.8-pinenote.drv`); no host harness
    executes the direct-mode driver's actual source (`ebc-logic`
    compiles only the forward-port patch's LUT-walk driver), so this is
    unexercised even by the offline ladder; glass proof pending.

`linux-pinenote-debug` stacks `linux-pinenote-debug-extract-fbs.patch`
on top of the same seven.

**A patch refresh must carry all seven.** The refresh procedure below
regenerates only the forward-port patch — the other six are separate
files that a refreshed `kernel.scm` still applies, and nothing in the
procedure touches them, so the failure mode is *omission*: forgetting
they exist, or rebasing the forward-port onto a base where one of them
no longer applies. After any base change, `git apply --check` each of
the seven against the new source before building, and re-read the
kernel.scm comments — several are deliberate, revertable experiments,
not permanent carry.

The BSP SIP compatibility milestone is a second, separately applied patch:
`linux-pinenote-7.0-bsp-sip-probe.patch`. It is a narrow port of Samuel
Holland's donor `72127ca`, not a port of its DRAM, shared-memory, FIQ, secure
register, or SCMI machinery. The 2026-07-25 probe-only
boot rejected its private legacy version-query gate with `-EOPNOTSUPP`; that
gate is retired rather than firmware-compatibility evidence. The corrected
architecture now production-links the strict OF parser, typed model, unwind-safe
executor, exact-node regulator consumer API with locked suspend wrappers, and
narrow SIP/regulator/CPU/modern-PSCI backend. A separate activation object owns
the active platform driver and its device-PM `.prepare`/executor edge; hidden
exact-default-n Kconfig omits it. Production accepts only MEM regulator policy
and rejects virtual-poweroff. CPU/PSCI methods remain linked but dormant. The
policy-free source/compiled DT has `compatible` and `status`; Linux OF adds its
standard `name` property to the live node. The first activation-hard-off boot
rejected that omitted metadata exception with `-EINVAL` before binding. The
corrected parser accepts exactly `compatible`, `name`, and `status` as metadata,
is host-validated, and booted and bound dormant on 2026-07-26 with activation
compiled out and zero firmware calls; that bind makes no firmware-compatibility
claim.
Regulator provider identities are deduplicated, and exact prior suspend settings
are restored after local failure, PM completion, and driver teardown. Kconfig
requires `SUSPEND`, closing the ARM64 `CPU_PM` dependency for the linked backend.
Host fixtures exercise the same model and executor with fakes only.
It does not change Linux 7.0's `ROCKCHIP_SLEEP_PD_CONFIG=0xff` pmdomain ABI.

**The direct-mode driver is in the shipping list since the embrace
sweep's S1 (2026-09-03):** items 8–11 below. `linux-pinenote-hrdl-direct`
and `linux-pinenote-debug` are retired (the direct driver registers
`EXTRACT_FBS` natively); `linux-pinenote-debug-extract-fbs.patch` stays
only as the ebc-logic harness's dbg fixture over the retained forward-port
driver source (`doc/embrace-sweep-plan.md`, decision 4).

## What the forward-port patch carries

- the `rockchip_ebc` DRM driver (EBC e-ink controller),
- the WS8100 pen driver,
- PineNote DTS/DTSI additions (`rk3566-pinenote.dtsi`, `rk356x-base.dtsi`):
  EBC/eink-tcon nodes, panel, pen SPI, `#io-channel-cells = <1>` on the
  `ebc_pmic` node (added 2026-07-03; see below), and
  `snps,dis_u3_susphy_quirk` on `&usb_host0_xhci` (added 2026-07-03): since
  6.15 (`cc5bfc4e16fc` "usb: dwc3: Set SUSPENDENABLE soon after phy init",
  in stable) dwc3 sets `GUSB3PIPECTL.SUSPHY` at core init; with the RK3566
  OTG's USB3 PIPE phy unwired, the first ep0out `DEPCFG` command then times
  out — the exact `dwc3: failed to enable ep0out` gadget failure seen since
  the 7.0 bring-up. USB3 is unused on the PineNote, so suspend-phy stays
  off. Hardware-proven 2026-07-04: the gadget enumerates and passes
  data with zero dwc3 errors (`doc/status.md`),
- `arch/arm64/configs/pinenote_defconfig`,
- a minimal IIO temperature provider added to mainline
  `drivers/regulator/tps65185.c` (added 2026-07-03): mainline exposes the
  EPD PMIC temperature via hwmon only, but `rockchip_ebc` selects waveform
  LUTs through `devm_iio_channel_get()`/`iio_read_channel_processed()`
  (millicelsius). Without the IIO channel + the DT property, the EBC probe
  dies with `-EINVAL: Failed to get temperature I/O channel` — the exact
  failure of the 2026-06-11 os2 boot. The downstream 6.12 tree solves this
  with a full IIO rewrite of the driver (events, triggers); we carry a
  ~70-line additive hunk against mainline instead, to keep future rebases
  cheap.
- The EBC system-sleep worker bracket (added 2026-08-01): the DRM helper
  invokes `atomic_disable`/`atomic_enable` only for an ACTIVE CRTC, while
  the `mode_changed`-gated ctx swap always runs across a system sleep —
  so a blanked fbdev CRTC had its refresh context freed under a
  never-parked worker and every post-resume refresh was a silent
  zero-frame no-op (hardware-measured twice; inherited structure, see
  `doc/driver-findings-report.md`). Our fix factors the two hook bodies
  into idempotent `rockchip_ebc_quiesce_worker`/`rockchip_ebc_wake_worker`
  helpers (park-once bracket via `worker_parked`, `kthread_park` return
  consumed, unpark only when a ctx exists, PM-side ctx read under the
  CRTC lock) that the system PM callbacks call unconditionally; hook-path
  behavior is bit-identical to the hardware-proven active path. Also:
  first-poison now logs one line, and `runtime_suspend` logs a failed
  supply disable (both observability-only). The bracket is pinned by
  `ebc-suspend-bracket-test` in the ebc-logic suite (not
  waveform-gated), and the ebc-logic kthread shim now returns int from
  `kthread_park` matching the real API. Note the deliberate visible
  change on the blank path: suspend now parks the worker, so a
  blanked-CRTC suspend runs the park-tail wash (glass to white) —
  matching the driver's documented CRTC-disabled invariant.
  Hardware-proven: the 2026-08-01 evening ladder session showed the
  bracket converting the old hard wedge into a
  recoverable-without-reboot state, and on 2026-08-02 suspend-ladder
  rungs 1 and 2 PASS on s2idle with post-resume damage painting a full
  pass at both blanked and unblanked CRTC states (`doc/status.md`).
- The work-item drain gate (added 2026-08-24, issue #22): one small
  helper, `rockchip_ebc_work_item_pending()`, read once per frame at the
  top of `rockchip_ebc_partial_refresh`'s `for (frame = 0;; frame++)`
  body, gating **only** the mid-frame `list_splice_tail_init(&ctx->queue,
  &areas)` inside the `spin_trylock` retry loop. The loop's sole exit is
  an empty area list and it re-spliced the queue every frame, so a damage
  supply arriving faster than one area lifetime kept it non-empty
  forever: a queued global refresh never launched, and the
  `kthread_park()` that `rockchip_ebc_quiesce_worker()` **blocks on**
  never completed — a system-suspend stall the original 2026-07-29
  finding did not notice. With the gate the list can only shrink, so the
  loop returns within one area lifetime. This is hrdl's fix
  (`~hrdl/linux` `v6.19_ebc_custom` @ `819ba1724a6f`) adapted to this
  driver's area list, and it converts CLAUDE.md's sustained-damage
  standing lesson from a procedure into a structural guarantee — the
  cmdline `vt.global_cursor_default=0` and the campaign fbcon unbind stay
  in place but stop being load-bearing.
  Deliberately narrow: `frame == 0`'s splice is **not** gated (it is this
  refresh's own starting set, and the thread has already consumed any
  work item pending when it chose a partial over a global), and the
  buffer switch / `ctx->final` retarget stay unconditional so the EBC
  never reads a stale final buffer. Pinned by `ebc-drain-gate-test` in
  the ebc-logic suite (waveform-gated), whose ungated build must FAIL;
  `ebc-refresh-starvation-test` keeps the inherited `quirk:` record
  against `mutate-drain-gate.py`'s gate-removed copy. **Not hardware-
  proven** — no panel has run this; what a busy producer's extra wash
  looks like on glass is still open.
- The fbdev-client resume barrier (added 2026-08-01): four lines in
  `rockchip_ebc_resume()` plus one small helper. Vanilla
  `drm_fb_helper_set_suspend_unlocked(helper, false)` defers the
  un-suspend to `helper->resume_work` whenever `console_trylock()`
  fails, and *nothing* on the resume path waits for it — until it lands
  `info->state` is `FBINFO_STATE_SUSPENDED` and
  `drm_fb_helper_damage_work()` drops every damage submission with no
  error anywhere. We call the same helper a second time after a
  successful `drm_mode_config_helper_resume()`, using its own opening
  `flush_work(&fb_helper->resume_work)` as the barrier; when the first
  call already took the console lock it returns immediately and costs
  nothing. Ordered after `rockchip_ebc_wake_worker()` so damage the
  un-suspend releases has a live consumer. It reuses the
  `rockchip_ebc_defio_helper` static that `defio_delay_ms` already
  keeps; PM callbacks and `remove()` are serialised by the device lock,
  so no extra locking is needed there. The block is inside
  `#ifdef CONFIG_DRM_FBDEV_EMULATION` with a no-op `#else` stub — which
  is what the ebc-logic harness compiles, so **the cross-build is the
  only compile gate for the live branch**; run `make kernel`, not just
  the host suite, after touching it. (Since 2026-08-04
  `ebc-fbdev-order-test` defines `CONFIG_DRM_FBDEV_EMULATION` and
  executes this barrier — the lone exception to the harness's
  config-guard blindness; see `doc/testing.md`.) Hardware-proven
  2026-08-02: `fb0.state=0` after resume — the deferred un-suspend now
  completes, which is exactly what the barrier was added for
  (`doc/status.md`). The instrument is
  `pinenote/tools/power/fb-damage-gates.sh` and the four-gate
  analysis is in `doc/power-management.md`.
- TPS65185 suspend/resume register restoration, same file (added
  2026-08-01, dormant until the suspend ladder reaches `deep`): snapshot
  the nine programmable non-VCOM registers at suspend, wait out the
  chip's 50 ms post-wake EEPROM reload window, and rewrite them bit-exact
  at resume via cache-through `regmap_write` (a `regcache_sync` restore
  would be masked by `REGCACHE_MAPLE`). VCOM is deliberately never
  written — its power-up default *is* the NVM-stored per-device
  calibration (never-bundle class); TMST1 is excluded because
  `READ_THERM` is a write-trigger; ENABLE restores last so rails never
  power up under stale sequencing. Snapshot-not-defaults matters:
  U-Boot's e-ink splash programs sequencing (measured UPSEQ0 0xe1 vs
  datasheet 0xe4). Evidence chain and the known-working m-weigand
  template: `doc/power-management.md`, "Evidence pass (2026-08-01)".
  Structurally gated by
  `pinenote/scripts/preflight/validate-tps65185-pm-hunk.sh` (in
  `make suspend-check`), negative-tested four ways. This diff section is
  now regenerated with `diff -u` rather than hand-edited; the old
  96-line section grew to 212.
- the `eink,ed103tc2` panel entry for `panel-simple` (added 2026-07-03),
  taken verbatim from the hardware-validated m-weigand 6.6.30 tree (8
  refresh-rate modes, 1872x1404, DPI). Vanilla panel-simple only knows
  `eink,vb3300-kca`, so without this hunk the EBC probe — once past the
  temperature channel — parks forever in `-EPROBE_DEFER` at
  `devm_drm_of_get_bridge()` because nothing ever binds the panel node.
  (Found by adversarial review before it cost a hardware session.)
- the cyttsp5 touchscreen DTS node (added 2026-07-05; hardware-proven
  the same day — finger-navigable KOReader — and coordinates under
  rotation validated 2026-07-19, final4; `doc/status.md`):
  `touchscreen@24` (`cypress,tt21000`) on `&i2c5` plus the
  `ts_int_l`/`ts_rst_l` pinctrl entries, taken from the m-weigand 6.6.30
  tree. Context: `CONFIG_TOUCHSCREEN_CYTTSP5=m` was already in the
  defconfig, but neither mainline's `rk3566-pinenote.dtsi` nor hrdl's
  v6.19 tree carries a node, so the driver never probed — first light
  (2026-07-05) had pen input but no finger touch. We keep the **vanilla
  mainline driver**; m-weigand's tree additionally patches
  `cyttsp5.c` with DT-property fallbacks (`touchscreen-size-x/y`,
  `touchscreen-max-pressure` overriding chip-reported sysinfo, plus
  zero-guards) that mainline lacks. The node carries those properties
  anyway (mainline ignores them), so if hardware shows a probing
  touchscreen with zero/garbage ABS ranges, the missing fallbacks are
  the first suspect — that would become a pinned quirk, not a silent
  driver fork.
- the PineNote battery and RK817 charger DTS nodes (backported verbatim from
  upstream Linux commit `1d608a269e24285eb399e08f0b47c2020b8c719a`,
  *arm64: dts: rockchip: Add battery and charger on rk3566-pinenote*, Samuel
  Holland, 2026-02-24). This is the exact 26-line DTS-only upstream change:
  the root `simple-battery` profile and its `monitored-battery` RK817 child.
  It deliberately carries no RK817 driver, Kconfig, defconfig, governor, or
  policy change, and does not treat the OCV table, charge limits, or resistor
  value as a per-device calibration to tune. `inspect-kernel-source.sh` checks
  the source values; `inspect-pinenote-battery-dtb.sh` also checks the compiled
  DTB and resolves its compiler-assigned phandle relationship.

  **Mainline caught up: drop BOTH nodes on any 7.1+ rebase.** Commit
  `1d608a269e24` is in mainline as of 7.1, so `rk3566-pinenote.dtsi`
  now carries the battery profile and the charger child itself.
  Building against a channel set whose `nongnu:linux` has moved to
  7.1.x therefore fails in `dtbs`:

  ```
  rk3566-pinenote.dtsi:433.11-438.5: ERROR (duplicate_node_names):
    /i2c@fdd40000/pmic@20/charger
  ```

  Both hunks collide — the root `battery: battery { … }` node near the
  top of the forward-port patch **and** the `charger { … }` child
  further down. **dtc stops at the first error**, so dropping only the
  `charger` hunk moves the failure to `battery` rather than fixing it.

  Verified directly against the mainline source rather than inferred
  from the commit: in `linux-7.1.5`'s
  `arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi`,

  ```
   43:	battery: battery {
   44:		compatible = "simple-battery";
  287:		charger {
  288:			monitored-battery = <&battery>;
  ```

  so on a 7.1+ rebase **both** backported hunks must go, and what
  remains to check is whatever else moved behind that first dtc error.
  Measured 2026-08-14 (issue #13); `make kernel-version-check` now
  detects the drift in ~0.6 s instead of at `dtbs` failure time.

### RK817 battery first boot is supervised

The backport can cause the existing RK817 driver to probe for the first time;
that driver programs charge limits and persistent gauge state during probe.
Consequently, the first `os2` boot is a supervised, human-present hardware
step, preferably unplugged and observed on UART, after the offline patch,
source, and generated-DTB checks are green. It is not a claim that telemetry
is calibrated or that charging is hardware-proven. Keep `os1` untouched as the
rescue system, use the normal os2-only deployment protocol, and collect the
telemetry qualification described in `doc/power-management.md` before making
any policy decision.

## EBC lifecycle boundary

The EBC is a static base-DT device on the PineNote, not a supported dynamic
hotplug or unbind topology. Its driver sets `suppress_bind_attrs`, and a
timeout pins the module along with the active DMA/context ownership. If a
timeout makes that ownership uncertain, every suspend/resume boundary retains
power and returns `-EBUSY`; shutdown stops the worker and returns because a
reboot follows. An unexpected `.remove` first stops and rechecks the worker,
then panics rather than returning into driver-core devres teardown. That panic
is the last-resort fail-stop boundary for an impossible supported topology, not
a claim that dynamic EBC removal is safe or supported.

## Upgrading the kernel: the base is pinned to a SERIES

`%linux-pinenote-base` (`pinenote/packages/kernel.scm`) is bound to
**`nongnu:linux-7.1`** (since the 2026-08-15 series bump), not to
`nongnu:linux`.

It used to be the floating alias, and that meant the kernel this repo
built was chosen by *when the developer last ran `guix pull`* rather
than by anything in the repo. On 2026-08-14 the alias reached 7.1 and
`make kernel` stopped working outright — mainline had picked up
`1d608a269e24`, the battery/charger DTS backport this patch set also
carries, and dtc rejected the duplicate nodes (issue #13).

Two consequences, and the distinction between them is the whole policy:

- **A point release inside 7.1.x arrives on its own.** Security fixes
  should not need a commit here, and mainline does not touch arch DTS in
  a point release.
- **Leaving 7.1.x is a project, not a bump**, and cannot happen by
  accident. `make kernel-version-check` asserts the series in ~0.6 s
  without building anything — in its *ambient* form; under
  `TIME_MACHINE=1` it currently fails, because `channels.scm` still
  pins a nonguix that predates `linux-7.1` (bumping that pin is its own
  reviewed change — `doc/building.md`).

**The hardware-proven version for the shipping driver is 7.0.11**
(`doc/status.md`), and that is what the deployed reader image runs.
7.1.8 has run on glass only in the direct-mode *study* configuration
(2026-08-25: hrdl's EBC driver swapped in, our other patches intact);
the shipping-driver 7.1 build has never driven a panel.

### Accepting a point release (cheap, offline)

Do this when `kernel-version-check` passes but the resolved version has
moved — e.g. 7.0.11 → 7.0.14:

1. Fetch the source:
   `guix build -S --no-grafts -e '(@ (nongnu packages linux) linux-7.0)'`
2. Unpack to a disposable tree and dry-run **every** patch, in the order
   `%linux-pinenote-patches` lists them, applying each for real between
   dry-runs so the next one sees the right tree.
3. All seven must apply. If any rejects, stop — that is a series-bump
   problem wearing a point-release costume.
4. `make check-host` (the display trio compiles the *verbatim* driver
   source out of the patch, so it is the gate that notices a silent
   semantic change).

**Record, 7.0.11 → 7.0.14 (2026-08-15):** all seven patches apply
cleanly, and 7.0.14's `rk3566-pinenote.dtsi` carries neither the
`simple-battery` node nor the `charger` child, so the 7.1 collision does
not exist there. Verified by dry-run and by inspecting the mainline
DTSI. **Not** verified: a full build, a DTB compile, or anything on
glass. 7.0.11 remains the proven version.

### Bumping the series (7.0 → 7.1+): expect to delete patch, not write it

1. Change `%linux-pinenote-base` and update `KERNEL_EXPECT` in the
   `Makefile`. Expect `kernel-version-check` to be the first thing that
   moves.
2. Dry-run all seven patches. **Failures here are the deliverable**, not
   an obstacle — each one is either a hunk mainline absorbed (delete it)
   or a hunk that needs rebasing (do that).
3. **Known for 7.1:** mainline carries `1d608a269e24`, so **both** the
   root `battery: battery { … }` hunk and the `charger { … }` child hunk
   must be dropped. dtc stops at the first error, so dropping only
   `charger` moves the failure rather than removing it. Confirmed
   against the 7.1.5 source — see the patch-inventory entry above.
4. Build. dtc and the compiler will name the *next* collision; the list
   is not knowable in advance because each error hides the ones after it.
5. `make check-host` green, then `make qemu-virt-check`.
6. A hardware session. A kernel that boots in QEMU virt has not proven
   the display, suspend, or wake paths — see "What only hardware can
   prove" in `doc/testing.md`.
7. Update `doc/status.md` with the new proven version, and this section's
   "hardware-proven version" line.

## Refreshing the patch for a new kernel

1. Check the current vanilla kernel version the package inherits:
   `guix build --source -L . -e '(@ (pinenote packages kernel) linux-pinenote)'`
2. In a disposable tree, unpack that source and apply the existing patch.
   Resolve rejects against the m-weigand/hrdl trees as reference
   (https://github.com/m-weigand/linux, branches like
   `branch_pinenote_6-12-11`).
3. Sanity-check the tree without building:
   `guix shell git python -- pinenote/scripts/preflight/inspect-kernel-source.sh
   /path/to/tree /path/to/build/.config` (from the full checkout)
4. Regenerate `pinenote/patches/linux-pinenote-7.0-forward-port.patch` as a
   single diff against the pristine source.
5. Gate with derivation computation, then build:

   ```sh
   guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' \
     --target=aarch64-linux-gnu
   ```

6. Verify the output contains uncompressed `Image`, modules, and
    `lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb`.

### Refresh record

ROADMAP's patch-refresh discipline: every refresh gets a row here —
base version, notable conflicts, config deltas. No refresh has happened
yet; the current row is the state everything above applies to. The base
tracks whatever nonguix's `linux` pins, so step 1's guix command is
always the live answer.

| date | base | conflicts | config deltas | notes |
| --- | --- | --- | --- | --- |
| (current, 2026-08-06) | 7.0.11 (nonguix `linux`, vanilla kernel.org) | — | — | all six inventory patches apply; BSP worktree base commit `5e2c0c5659cc` (below) |

### Regenerating the BSP SIP compatibility patch

Do not regenerate the forward-port patch for a BSP PM edit. From the applied
7.0.11 worktree, require base
`5e2c0c5659cc3909cd7d99b5fb1dab60e0ae6bb2`, verify that its changed-path set
is exactly `PATHS` in `pinenote/tools/rockchip-pm/check.py`, then generate the
canonical full-index diff only over that inventory.

Constructing the applied worktree (it is a throwaway; nothing here is
machine-specific): check out vanilla 7.0.11, apply the forward-port
patch, and commit — the `base` commit's tree is vanilla + forward-port
(proof: the BSP patch's dtsi pre-image blob `fafdedb2c463…` is the
forward-port's post-image). Then `git apply` the current
`linux-pinenote-7.0-bsp-sip-probe.patch` so the BSP edits sit on top as
uncommitted changes, and make your edit. A freshly built commit will not
reproduce the pinned hash (commit metadata differs), so substitute your
own HEAD for `base` after verifying the tree state; the path-set
comparison below is the guard that actually protects the patch.

```sh
base=5e2c0c5659cc3909cd7d99b5fb1dab60e0ae6bb2   # or your own worktree's HEAD, see above
tree=/path/to/linux-7.0.11-bsp-work             # the applied worktree you constructed
patch="$PWD/pinenote/patches/linux-pinenote-7.0-bsp-sip-probe.patch"
test "$(git -C "$tree" rev-parse HEAD)" = "$base"
paths=$(python3 -c 'from pathlib import Path; ns = {}; exec(Path("pinenote/tools/rockchip-pm/check.py").read_text(), ns); print("\n".join(ns["PATHS"]))')
diff -u <(printf '%s\n' "$paths") <(git -C "$tree" diff --name-only "$base" | sort)
git -C "$tree" diff --check "$base" -- $paths
git -C "$tree" diff --no-ext-diff --full-index "$base" -- $paths >"$patch"
git -C "$tree" apply --check "$patch"
```

The path-set comparison is the unrelated-drift guard. Follow it with
`make rockchip-pm-check` and preserve the resulting patch's full-index form.

For a *single-file* edit (a cherry-pick, a pinned-quirk fix landing from
upstream) a full refresh is overkill: extract the file, edit it, and
splice it back with `pinenote/scripts/update-patch-file.py`, then verify
the extraction round-trips and gate in ladder order. The step-by-step
recipe with commands is `doc/worked-examples.md` case study 3.

## Cherry-picks from the community lineage (2026-07-04)

### EBC refresh-barrier containment (2026-07-27)

The permanent EBC patch now carries a local, fail-closed refresh-completion
contract: command `DRM_COMMAND_BASE + 0x03` uses fixed-width UAPI fields
(`version`, `op`, `request_id`, `timeout_ms`, `result`, reserved words) for
submit/wait generations.  It leaves the existing boolean `GLOBAL_REFRESH`
ABI intact.  The worker serializes physical starts, snapshots a generation
batch before each global, and publishes completion only after the global's
hardware and bookkeeping are complete.  A partial or global hardware timeout
poisons the instance permanently with `-ETIMEDOUT`; no later hardware start is
allowed and a late DSP_END cannot recover it.  Accepted submits and finite
wait queries use `result=-EINPROGRESS` until terminal publication; malformed
requests return an ioctl error.  `make ebc-logic-check WBF=…`
executes this against the verbatim extracted driver, including the pre-existing
debug extraction.  This is display-driver containment only: it does not
enable suspend, activation, a coordinator, or claim optical validation.

The ROADMAP's four cherry-pick candidates from hrdl's v6.19 tree
(`git.sr.ht/~hrdl/linux`, branch `v6.19_ebc_custom`) were evaluated
against their actual diffs. Important context: that branch is hrdl's
60–85 Hz driver **rework** (per-pixel scheduler state, NEON, early
cancellation) — structurally far from our m-weigand-lineage copy — so
nothing applies cleanly; ports are translations and rejections need
evidence, not vibes.

**Ported into the forward-port patch:**

- `99b4841ca12` *replace usleep_range with fsleep* — applied to our
  three sites (the partial-refresh queue-lock retry loop and both
  `atomic_update` pacing delays). `fsleep()` picks the appropriate
  sleep mechanism per duration; the old `[min, max]` ranges were
  arbitrary.
- `28d9ca7b518` *shrink dma_sync size* — translated to our area-list
  partial refresh: each frame accumulates the row span actually
  blitted (`sync_y1`/`sync_y2`, tracking `area->clip` at the same
  sites that blit), and the three per-frame
  `dma_sync_single_for_device` calls now clean only those rows
  (`phase_pitch/4` in direct mode) instead of the full ~1.3–2.6 MB
  buffers. Untouched rows were published by `dma_map_single`'s
  map-time clean at refresh start. **Validated offline** by the
  refresh harness's non-coherent DMA model (the fake device reads
  per-mapping shadows that only map/sync_for_device update): the
  256-transition waveform differential, the goldens, and the
  in-bounds sync checks all stay green — an under-synced row would
  fail visibly, not silently.
- `11c358d1ca7a` *rockchip_ebc_blit_pixels: fix adjustment for odd
  clips* (ported 2026-07-12, **applied verbatim**) — fixes findings 1
  and 7 of `doc/driver-findings-report.md` in one commit: odd-`x1`
  edge preservation now saves the *dst* nibble (was a src-read no-op
  that leaked one out-of-clip column), and odd-`x2` preservation
  targets byte `width-1` instead of `pitch-1` (wrong byte for
  partial-width clips; 1-byte heap overrun on last-row clips with
  `x1 >= 2`). At the commit's parent our `blit_pixels` was
  byte-identical to his, so the diff applies cleanly — no
  translation needed. The rung-2 quirk pins (QUIRK C/D) flipped to
  fix-regression guards, the blit soak's reference is now true
  both-edge preservation, and the formerly OOB-forbidden corner is
  exercised deliberately. rastersim's `rs_y4_blit` already
  implemented the fixed behavior, so its "driver diverges" caveat is
  gone.
- `59b2113e8b9c` *fix scheduling issues due to overlapping areas*
  (ported 2026-07-12, **minimal translation**) — fixes finding 2:
  the pending-vs-pending begin-together path now honors
  `do_not_start_before_frame` (an area chained through staggered
  begin-togethers defers past *every* overlapping window instead of
  starting mid-window), forward moves of `frame_begin` are monotone,
  and the window arithmetic is end-exclusive (deferred areas start
  at `other_end`, one frame earlier; the rung-7a `conflicts == 0`
  checks prove the earlier handoff is phase-clean — an area's last
  two phase writes are neutral 0xff and successors splice later in
  the list). Deliberately NOT adopted from the commit: its
  replacement of the two containment drops with
  `!drm_rect_intersect(...)` (dead once overlap is established —
  the commit message misreads `drm_rect_intersect`'s return value —
  and it silently disables redundant-area dropping, changing drive
  counts). Keeping our containment drops also keeps the overlap
  serialization the *single* changed variable for the corruption
  A/B (`doc/hrdl-evaluation.md` §5). QUIRK E's pins (rung 2
  deterministic + rung 7a device-visible) flipped to fix guards; the
  rung-2 soak now asserts pairwise no-conflict. Expected replay
  shifts on the A.2 trace: `hw-frames 1569 -> 1558`, `active
  2542 -> 2531`, `settle max 154 -> 152`; px-phases/decisions/washes
  byte-identical.

**Rejected, with evidence:**

- `5d6e5b43360` *emergency fix: don't allow temperatures < 19* — the
  commit's own rationale is that **their** early-cancellation feature
  corrupts the display on DU sequences longer than 29 phases. Our
  copy has no early cancellation (no cancellation path at all), and
  the clamp would throw away the waveform's cold temperature bins —
  per-device calibration data — for no benefit. Backed by the
  harness's `wbf cold` test: at 0 °C the driver selects the 131-phase
  GC16 cold bin and orchestrates it cleanly. Revisit only if we ever
  adopt their early-cancellation/rework.
- `7e85b4ff0ea` *set all pixels to IDLE when changing waveforms* —
  resets the rework's per-pixel scheduler state
  (`packed_inner_outer_nextprev`) so pixels can't get stuck WAITING
  (soft-lockup with `redraw_delay<=0`). Our driver has no per-pixel
  scheduler state, and the LUT never changes mid-flight:
  `partial_refresh` drains its area list before returning and the LUT
  is set in the `refresh()` preamble. There is no equivalent state to
  reset. (Runtime waveform-swap ghosting is separately handled by the
  existing `prepare_prev_before_a2` logic.)

The NEON/`scoped_ksimd` blitters remain skipped per the ROADMAP (our
copy has no NEON). When a future rebase lands on their tree, the two
rejections above should be re-evaluated against whatever driver
structure we are carrying then.

## Hard-won configuration lessons

Record anything that took a hardware session to discover:

- `CONFIG_GPIO_ROCKCHIP=y` (built-in, not module). As a module, boot dies in
  a mass deferred-probe storm (regulators, sdhci, dwc3 extcon, EBC
  temperature channel all waiting on GPIO) and root never appears.
- `CONFIG_DEBUG_FS=y`. The 2026-06-11 boot had it off: Guix's
  `/sys/kernel/debug` file-system service loops on EPERM, and the gadget
  service cannot reach the dwc3 debugfs `mode` file, so the role-gated
  gadget never binds.
- `CONFIG_PREEMPT_RT=y` (2026-07-03; hardware-proven 2026-07-04:
  `#1 SMP PREEMPT_RT`, taint zero, no atomic/sleeping-function splats —
  `doc/status.md`): full RT
  preemption for pen/refresh latency. arm64 has mainline RT support since
  6.12, so this only exists on the 7.0 track — 6.6's olddefconfig will
  silently drop the symbol, which is fine for the regression-isolation
  baseline.
- Loading modules from userspace on Guix needs
  `modprobe -d /run/booted-system/kernel`: Guix's kmod does *not* honor
  `LINUX_MODULE_DIRECTORY`, and only the kernel profile (not the kernel
  package) contains `modules.dep`. Discovered by chroot-testing the os2
  rootfs from os1 (2026-07-03) after every gadget modprobe failed on the
  2026-06-11 boot.
- The TPS65185 module is named `tps65185-regulator` in newer kernels but
  `tps65185` in 6.6; the initrd module lists in
  `pinenote/images/pinenote-initramfs.scm` differ for exactly this reason.
- Use the uncompressed `Image`; older PineNote U-Boot may not load
  `Image.gz`.
- Kernel arguments that matter are centralized in
  `pinenote/images/pinenote-initramfs.scm`
  (`earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off`).
- **kexec on the RK3566 needs two things (2026-09-02, glass).**
  `irqchip.gicv3_nolpi=1` on every flavor: the GICv3 LPI tables are not
  reserved across a non-EFI kexec and this GIC cannot clear
  `EnableLPIs`, so a kexec'd kernel otherwise boots on corrupted tables
  (nothing on the PineNote uses LPIs). And, on the kexec command line
  only, `initcall_blacklist=rockchip_grf_init`: the running kernel gates
  `pclk_pipe` as unused, U-Boot leaves it on, and the next kernel's GRF
  init writes the PIPE GRF into the unclocked block and hangs the bus at
  0.12 s with no message. The generation helper adds it; cold boots keep
  the init. Proper fix and evidence: `doc/upstream-register.md` 22,
  `doc/update-path.md` "Glass notes".
- **`module.param=` cmdline tokens are inert for our modules**
  (2026-07-05, found live on the A.2 boot): the kernel only applies
  cmdline parameters to *built-in* modules; for loadable ones it is
  modprobe that reads `/proc/cmdline` — and the Guix initrd raw-loads
  `rockchip_ebc` with `load-linux-modules-from-directory`, which passes
  no parameters at all. The A.2 image shipped
  `rockchip_ebc.refresh_waveform=6` on the cmdline and booted with the
  driver default (4). EBC parameters must go through the
  `pinenote-ebc-params` one-shot (`pinenote/packages/firmware.scm`),
  which writes and verifies them via sysfs post-boot; rung 4 asserts
  the live value from inside the guest (`VIRTCHK-WF-6`).
- `console=tty0` + `ignore_loglevel` means every kernel message redraws
  fbcon on the e-ink panel, and the fbdev emulation's flushes overwrite
  whatever userspace put there (2026-07-05 first-light root cause). Any
  service that owns the panel must unbind fbcon
  (`/sys/class/vtconsole/vtcon1/bind`) — the reader-session service does.
  Related trap: `drm.debug=0x2` works without `CONFIG_DYNAMIC_DEBUG`
  (drm has its own gate) but its printk lines land on fbcon and feed a
  redraw→commit→log feedback loop; expect ~8 Hz of full-frame blits
  while it's on.
- Driver-observability wishlist for a future debug kernel config: the
  7.0 port stubs the `EXTRACT_FBS` ioctl (`-EOPNOTSUPP`) — **closed
  2026-07-12 for the debug kernel**: `linux-pinenote-debug` implements
  it via `linux-pinenote-debug-extract-fbs.patch` (offline-proven by
  the ebc-logic dbg suite; grabber/decoder in
  `pinenote/tools/ebc-logic`; the primary kernel keeps the stub).
  Still open: `CONFIG_DYNAMIC_DEBUG` and `CONFIG_DETECT_HUNG_TASK` are
  off (the latter also blocks the qemu-virt udev-hang diagnosis;
  `MAGIC_SYSRQ_SERIAL` came off this list 2026-08-26, below).
- `CONFIG_MAGIC_SYSRQ_SERIAL=y` +
  `CONFIG_MAGIC_SYSRQ_SERIAL_SEQUENCE="sysrq"` +
  `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x0` (2026-08-26; the third
  symbol added the same night after a live test corrected the model).
  The inherited defconfig had serial sysrq explicitly off, so when the
  study image hung mid-shutdown with the UART plumbed in — kernel
  echoing keystrokes, userspace dead — there was NO software rescue:
  BREAK was inert, and recovery cost a user-present power-button cycle
  (`doc/status.md` 2026-08-26 part 4). The likely reason it was off is
  the floating UART RX line (no cable attached in normal use), where
  noise can register as a BREAK. **Semantics learned the empirical
  way** (first on-glass test fired an Emergency Sync with the `s` of
  the sequence itself): `MAGIC_SYSRQ_SERIAL_SEQUENCE` is NOT a per-use
  guard — while sysrq is *enabled*, BREAK + any single char fires
  immediately and the sequence is never consulted. The sequence is an
  **arming toggle for when sysrq is disabled**: with `kernel.sysrq=0`,
  BREAK followed by the literal bytes `sysrq` enables sysrq (logged:
  "SysRq is enabled by magic sequence 'sysrq' on serial"), after which
  BREAK + key fires. Hence `DEFAULT_ENABLE=0x0`: ship with sysrq
  masked off, so line noise must spell `sysrq` before anything arms —
  and `/proc/sysrq-trigger` still works regardless (its handler
  bypasses the mask). Rescue recipe from the host, cable attached, two
  stages: (1) BREAK, then type `sysrq` — arms; (2) BREAK, then the key
  (`s` sync, `u` remount-ro, `b` reboot). The whole chain is
  **glass-proven 2026-08-26** on the deployed study image (arming
  logged, `h` printed the full key table); that image predates the
  `DEFAULT_ENABLE=0x0` line, so its runtime was parked at
  `kernel.sysrq=0` by hand — images built after the fix boot that way.

## Known driver quirks pinned by the host test tools (2026-07-04)

The offline ladder (`pinenote/tools/ebc-logic`, `pinenote/tools/rastersim`)
compiles the verbatim driver sources out of the patch and has surfaced
**nine** findings so far (the last found on hardware 2026-07-29 and
reproduced offline the same day), all documented with patch line numbers
in the tool READMEs and pinned as `quirk:`/`fix:` tests so a future
refresh that changes the behavior turns a test red. The ebc-logic
README's findings list is the authoritative count, and its numbering
(with `doc/driver-findings-report.md` for the community-facing writeups)
is the one to cite outside this file — the highlight numbers below are
local, in upstream-fix priority order, and do **not** match the README's.
Most findings do not affect the shipped configuration paths in a
user-visible way; the exception is the refresh-starvation hang (item 7
below), which cost the 2026-07-29 hardware session. Items 1, 2 and the
odd-`x1` leak in 5 were
**fixed in-tree 2026-07-12** by porting hrdl's own fixes (cherry-pick
record above); their pins now assert the *fixed* behavior, so they still
guard rebases. Highlights:

1. **(fixed in-tree, `11c358d1ca7a`)** `rockchip_ebc_blit_pixels`
   odd-`x2` "preserve" wrote byte `pitch-1` instead of the clip edge — a
   1-byte kernel heap overrun (read-modify-write past the buffer) when a
   clip touched the last row with `x1 >= 2`; otherwise a silent no-op.
2. **(fixed in-tree, `59b2113e8b9c` translation)**
   `rockchip_ebc_schedule_area`'s begin-together/wait paths ignored
   `do_not_start_before_frame`, so an area could start inside an
   overlapping area's refresh window (more likely with the shipped
   `split_area_limit=0`); the deterministic reproducer in the tests now
   pins the fix.
3. **(fixed in-tree and ASan-pinned)** `rockchip_ebc_ctx_free` kfreed queue
   nodes inside `list_for_each_entry` (UAF on teardown with queued damage);
   it now unlinks with the safe iterator before freeing.
4. `rockchip_ebc_blit_direct` reads the packed LUT transposed relative to
   the waveform-file semantics (only matters if `direct_mode=1` is ever
   enabled; we ship 0 — hardware LUT mode indexes correctly in silicon).
5. Assorted blit edge-case quirks: odd-x damage-edge preservation
   cross-wired under `panel_reflection`, `panel_reflection=0` drops the
   last damage row, and — **fixed in-tree by `11c358d1ca7a`** —
   odd-`x1` "preserve" was a no-op that leaked one out-of-clip column.
6. **Historical/latent QUIRK F (2026-07-12):** Source review identified a
   plausible zero-gap straggler-truncation race when the `auto_refresh=1`
   threshold path chains a global refresh after a partial burst. Instrumented
   corrupting-class workloads subsequently produced no straggler credits,
   early waits, or frame timeouts and **refuted this mechanism as the observed
   corruption cause on this silicon**. The threshold/ioctl optical correlation
   remains campaign evidence, not proof that ioctl launches are inherently
   immune; the corruption investigation returned to content bookkeeping.
   `quirk F` now pins latent handshake hardening and current containment:
   reinitialize before every physical start and terminally poison on timeout,
   so a late END cannot heal or start later work. The superseded hypothesis,
   instrumented refutation, and current evidence are recorded in
   `doc/driver-findings-report.md`. Shipped mitigation remains
   `auto_refresh=0` (`ebc.scm`); PNDeb's defaults remain exposed.
7. **A sustained damage supply starves the global-refresh /
   `REFRESH_BARRIER` path indefinitely, silently** (found on hardware
   2026-07-29, reproduced offline the same day; ebc-logic README
   finding 9). `rockchip_ebc_partial_refresh`'s frame loop exits only
   when its area list drains but re-splices `ctx->queue` every frame,
   so damage arriving faster than one area lifetime (fbcon's cursor
   blink, at 63 Hz) keeps `rockchip_ebc_refresh_thread` from ever
   reaching the `do_one_full_refresh` read — nothing times out (every
   frame lands inside the 25 ms `EBC_FRAME_TIMEOUT`) and nothing is
   logged. Inherited verbatim from the `dd99c3f` import, so it was
   reported in `doc/driver-findings-report.md` rather than patched, and
   the shipped mitigations were policy-level (fbcon unbind before
   barrier use, `vt.global_cursor_default=0`).
   **(fixed in-tree 2026-08-24, hrdl `819ba1724a6f` adapted, issue #22.)**
   `rockchip_ebc_work_item_pending()` is read once per frame and skips
   **only** the mid-frame `ctx->queue` splice while a global refresh is
   queued or the kthread is being parked/stopped, so the area list can
   only shrink and the loop returns within one area lifetime. `frame ==
   0`'s splice is deliberately NOT gated (it is the refresh's own
   starting set, and gating it made a partial a zero-frame no-op in a
   state only the harness reaches). The park term also fixes a stall the
   original finding missed: `rockchip_ebc_quiesce_worker()` blocks in
   `kthread_park()`, so sustained damage stalled **system suspend** too.
   `ebc-refresh-starvation-test` still pins the inherited behaviour, now
   against `build/nogate` (`mutate-drain-gate.py`'s gate-removed copy,
   verified byte-identical to the pre-gate source);
   `ebc-drain-gate-test` pins the guarantee against the shipping driver
   and must FAIL against `build/nogate`. The finding stays open in
   `doc/upstream-register.md` — the lineage should own the fix.
   **Nothing about this has run on glass.** The README's own
   finding 7 — manual global washes never reset the auto-refresh
   accumulator, a policy-level inefficiency under `auto_refresh=1` —
   is also absent from this list; we ship `auto_refresh=0`.

When refreshing the patch or cherry-picking from hrdl/ayakael, check
whether their trees already fix any of these before re-pinning.

**Direct-mode driver (hrdl's tree), found by source reading 2026-09-02,
pinned by `make direct-probe-quirk-check`:** the probe's error path after
a failed `rockchip_ebc_drm_init` is a bare `return ret` — hrdl's patch
replaced `goto err_stop_kthread` and deleted that label — so a probe that
fails there leaves runtime PM enabled and the parked refresh kthread
alive. On the direct image the *first* probe fails by construction
(no CLUT until the one-shot compiles it), and the rebind's second
`pm_runtime_enable` prints `Unbalanced pm_runtime_enable!` on every boot.
**Correction from glass, 2026-09-04 (generation 14, the probe-unwind
patch applied):** the boot's first probe does not fail at `drm_init` —
it fails earlier, in `rockchip_ebc_waveform_init` (`Direct firmware
load for rockchip/custom_wf.bin failed`, `*ERROR* Unable to load
custom_wf.bin`, 2.8 s), whose bare `return ret` the unwind patch does
not reach, so the rebind still logs `Unbalanced pm_runtime_enable!`
(8.2 s) and that path still leaks the two plain vmallocs
(`hints_ioctl`, `packed_inner_outer_nextprev`, ~10 MB) and the runtime-PM
count — the audit's item 2, glass-confirmed (`doc/status.md`). Each
*successful* probe additionally leaks `lut_custom.luts` (one
`vzalloc`, 228 kB for this device's 14 temperature bins, freed
nowhere): the rebind ×5 slope of the same session. Both are once per
boot in the product and reclaimed at the next boot. The driver's
lineage owns the fix (`doc/upstream-register.md` item 23, which now
records the real failure site).

## Why the base is vanilla, not linux-libre (history)

The forward-port originally sat on Guix's `linux-libre`. That can never
support the PineNote's Wi-Fi: the deblob pass does not just omit firmware
files, it disables non-free firmware *loading* by rewriting request paths to
`/*(DEBLOBBED)*/`. Observed on hardware:

- brcmfmac Wi-Fi firmware was rejected at runtime even with the files
  present under the exact requested names. Packaging firmware
  (`pinenote-broadcom-wifi-firmware`) could not fix it, and partially
  restoring the driver in the forward-port patch (firmware name strings plus
  the `request_firmware`/`firmware_request_nowarn` call sites) still hit
  "Missing Free firmware (non-Free firmware loading is disabled)" — the
  loading machinery itself is gated, not just the names.
- The Bluetooth `BCM4345C0.hcd` path survived once the PineNote v1.2 device
  alias was provided.

On 2026-06-10 the package moved to nonguix's `linux` (vanilla kernel.org
source, same version as linux-libre), and the deblob-restoration hunks
(brcmfmac `sdio.c`/`firmware.c`, `btbcm.c`) were dropped from the
forward-port patch — vanilla sources never lost those paths. If the patch is
ever regenerated from a linux-libre-derived tree again, keep those three
files out of it.
