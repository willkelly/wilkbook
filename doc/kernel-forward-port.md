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
  matching the driver's documented CRTC-disabled invariant. Hardware
  proof of the whole fix waits for the next boot's ladder retry.
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
  the host suite, after touching it. Hardware-unproven; the instrument
  is `pinenote/tools/power/fb-damage-gates.sh` and the four-gate
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
- the cyttsp5 touchscreen DTS node (added 2026-07-05, **unvalidated on
  hardware**): `touchscreen@24` (`cypress,tt21000`) on `&i2c5` plus the
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

### Regenerating the BSP SIP compatibility patch

Do not regenerate the forward-port patch for a BSP PM edit. From the applied
7.0.11 worktree, require base
`5e2c0c5659cc3909cd7d99b5fb1dab60e0ae6bb2`, verify that its changed-path set
is exactly `PATHS` in `pinenote/tools/rockchip-pm/check.py`, then generate the
canonical full-index diff only over that inventory:

```sh
base=5e2c0c5659cc3909cd7d99b5fb1dab60e0ae6bb2
tree=/tmp/opencode/linux-7.0.11-executor-work
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
  (`earlycon console=tty0 console=ttyS2,1500000n8 fw_devlink=off`).
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
  Still open: `CONFIG_DYNAMIC_DEBUG`, `CONFIG_MAGIC_SYSRQ_SERIAL`, and
  `CONFIG_DETECT_HUNG_TASK` are all off (the last two also block the
  qemu-virt udev-hang diagnosis).

## Known driver quirks pinned by the host test tools (2026-07-04)

The offline ladder (`pinenote/tools/ebc-logic`, `pinenote/tools/rastersim`)
compiles the verbatim driver sources out of the patch and surfaced seven
latent issues, all documented with patch line numbers in the tool READMEs
and pinned as `quirk:` tests so a future refresh that changes the behavior
turns a test red. None affect the shipped configuration paths in a
user-visible way today. Items 1, 2 and the odd-`x1` leak in 5 were
**fixed in-tree 2026-07-12** by porting hrdl's own fixes (cherry-pick
record above); their pins now assert the *fixed* behavior, so they still
guard rebases. Highlights, in upstream-fix priority order:

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
