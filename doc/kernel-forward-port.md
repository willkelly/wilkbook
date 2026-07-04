# Kernel packaging and the forward-port workflow

Keeping the kernel current is a core goal of this project. The PineNote needs
a downstream display/pen stack that has never been mainlined, so every kernel
update means carrying those changes forward.

## The working reference: stock os1 (Debian, 6.12-pinenote)

Stock Debian on `os1` runs a 6.12 PineNote kernel with everything working;
it is the cheapest oracle for "is our build doing the right thing"
(harvested read-only over SSH, 2026-06-10):

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

## The two kernel packages

Both live in `pinenote/packages/kernel.scm`:

- `linux-pinenote-6.6.30` — the m-weigand PineNote tree, pinned by commit.
  Hardware-validated end to end (display, Wi-Fi, BT, USB gadget). Kept as the
  known-good baseline and for isolating regressions in newer kernels.
- `linux-pinenote` — vanilla kernel.org sources (nonguix's `linux` package,
  which tracks the same version as Guix's `linux-libre`) plus
  `pinenote/patches/linux-pinenote-7.0-forward-port.patch`, configured with
  `pinenote_defconfig`. This is the kernel-currency track. The channel
  therefore depends on nonguix (see `.guix-channel` / `channels.scm`).

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
  off. Unproven on hardware until the next session,
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
- the `eink,ed103tc2` panel entry for `panel-simple` (added 2026-07-03),
  taken verbatim from the hardware-validated m-weigand 6.6.30 tree (8
  refresh-rate modes, 1872x1404, DPI). Vanilla panel-simple only knows
  `eink,vb3300-kca`, so without this hunk the EBC probe — once past the
  temperature channel — parks forever in `-EPROBE_DEFER` at
  `devm_drm_of_get_bridge()` because nothing ever binds the panel node.
  (Found by adversarial review before it cost a hardware session.)

## Refreshing the patch for a new kernel

1. Check the current vanilla kernel version the package inherits:
   `guix build --source -L . -e '(@ (pinenote packages kernel) linux-pinenote)'`
2. In a disposable tree, unpack that source and apply the existing patch.
   Resolve rejects against the m-weigand/hrdl trees as reference
   (https://github.com/m-weigand/linux, branches like
   `branch_pinenote_6-12-11`).
3. Sanity-check the tree without building:
   `pinenote/scripts/preflight/inspect-kernel-source.sh /path/to/tree`
4. Regenerate `pinenote/patches/linux-pinenote-7.0-forward-port.patch` as a
   single diff against the pristine source.
5. Gate with derivation computation, then build:

   ```sh
   guix build -d -L . -e '(@ (pinenote packages kernel) linux-pinenote)' \
     --target=aarch64-linux-gnu
   ```

6. Verify the output contains uncompressed `Image`, modules, and
   `lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb`.

For a *single-file* edit (a cherry-pick, a pinned-quirk fix landing from
upstream) a full refresh is overkill: extract the file, edit it, and
splice it back with `pinenote/scripts/update-patch-file.py`, then verify
the extraction round-trips and gate in ladder order. The step-by-step
recipe with commands is `doc/worked-examples.md` case study 3.

## Cherry-picks from the community lineage (2026-07-04)

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
- `CONFIG_PREEMPT_RT=y` (2026-07-03, unproven on hardware yet): full RT
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
  (`earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off` plus the
  `rockchip_ebc` parameters).

## Known driver quirks pinned by the host test tools (2026-07-04)

The offline ladder (`pinenote/tools/ebc-logic`, `pinenote/tools/rastersim`)
compiles the verbatim driver sources out of the patch and surfaced seven
latent issues, all documented with patch line numbers in the tool READMEs
and pinned as `quirk:` tests so a future refresh that changes the behavior
turns a test red. None affect the shipped configuration paths in a
user-visible way today. Highlights, in upstream-fix priority order:

1. `rockchip_ebc_blit_pixels` odd-`x2` "preserve" writes byte `pitch-1`
   instead of the clip edge — a 1-byte kernel heap overrun
   (read-modify-write past the buffer) when a clip touches the last row
   with `x1 >= 2`; otherwise a silent no-op.
2. `rockchip_ebc_schedule_area`'s begin-together/wait paths ignore
   `do_not_start_before_frame`, so an area can start inside an overlapping
   area's refresh window (more likely with the shipped
   `split_area_limit=0`); deterministic reproducer in the tests.
3. `rockchip_ebc_ctx_free` kfrees queue nodes inside `list_for_each_entry`
   (UAF on teardown with queued damage).
4. `rockchip_ebc_blit_direct` reads the packed LUT transposed relative to
   the waveform-file semantics (only matters if `direct_mode=1` is ever
   enabled; we ship 0 — hardware LUT mode indexes correctly in silicon).
5. Assorted blit edge-case quirks: odd-x damage-edge preservation
   cross-wired under `panel_reflection`, `panel_reflection=0` drops the
   last damage row, odd-`x1` "preserve" is a no-op that leaks one
   out-of-clip column.

When refreshing the patch or cherry-picking from hrdl/ayakael, check
whether their trees already fix any of these before re-pinning.

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
