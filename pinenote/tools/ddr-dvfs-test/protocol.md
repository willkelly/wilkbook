# The Rockchip DRAM SIP protocol on the PineNote (rk3566, DDR ATF v0x101)

Everything below is read out of the Rockchip BSP `develop-6.1` tree at
`/tmp/opencode/rockchip-kernel` (git remote `github.com/rockchip-linux/kernel`,
HEAD `b4ef083dc`, 2025-12-26), which is the reference implementation for the
firmware this device runs. The device-side facts (DDR ATF version 0x101,
SIP v2, pinned 1056 MHz) come from `pinenote/tools/ddr-sip-probe/README.md`.

The rk3566 uses the **rk3568 code path** throughout: the BSP compatible table
maps `rockchip,rk3568-dmc` (and rk3562, rv1126b) to `rk3568_dmc_init`
(`drivers/devfreq/rockchip_dmc.c:2140-2156`); rk3566 is the same die/firmware
family and there is no separate rk3566 entry — Rockchip's own rk3566 DTBs use
the rk3568-dmc compatible.

## 1. The share-memory dance

**Request.** `sip_smc_request_share_mem(page_num, page_type)` issues SMC
`SIP_SHARE_MEM` (0x82000009) with a1 = page count, a2 = page type, a3 = 0
(`drivers/firmware/rockchip_sip.c:168-184`, calling convention
`__invoke_sip_fn_smc` at `rockchip_sip.c:38-47`). Page types are the
`share_page_type_t` enum (`include/linux/rockchip/rockchip_sip.h:194-206`);
the DMC uses `SHARE_PAGE_TYPE_DDR` = **2**. The rk3568 path requests **2
pages** (`rockchip_dmc.c:1884`).

**Response.** a0 = status (0 = `SIP_RET_SUCCESS`), a1 = **physical address**
of the share region inside bl31-owned memory (`rockchip_sip.c:178`). The
firmware keeps a static per-type buffer; the BSP requests it once per boot and
never releases it — there is no release call. Re-requesting the same type
returns the same region, so insmod/rmmod cycles are safe.

**Mapping.** The BSP maps it with `sip_map()` (`rockchip_sip.c:130-166`): if
`pfn_valid(__phys_to_pfn(start))` the page lies inside the kernel's memmap
and is mapped with `vmap(pages, VM_MAP, pgprot_noncached(PAGE_KERNEL))`;
otherwise plain `ioremap`. On the PineNote the bl31 carve-out is not kernel
RAM, so the ioremap path is the expected one; the test module implements both,
verbatim.

**Layout.** Offset 0 of the region is `struct share_params`
(`rockchip_dmc.c:72-98`): `hz`, `lcdc_type`, `vop`, `vop_dclk_mode`,
`sr_idle_en`, `addr_mcu_el3`, `wait_flag1`, `wait_flag0`, `complt_hwirq`,
`update_drv_odt_cfg`, `update_deskew_cfg`, `freq_count`,
`freq_info_mhz[6]`, `wait_mode`, `vop_scan_line_time_ns` — all u32, in that
order. Bytes `4096..` are "dts parameters" on SoCs that pass DDR timings
(`rockchip_dmc.c:1387-1390`, `DTS_PAR_OFFSET` = 4096 at `rockchip_dmc.c:62`)
— **but not on rk3568**, see §5.

**Version gates — what applies at 0x101.** Each SoC init checks
`GET_VERSION` (sub-code 0x08 in a3; result a0 = status, a1 = version):

- `px30_dmc_init` requires **>= 0x103** (`rockchip_dmc.c:1379`) and uses the
  0x103-era contract: it writes the completion IRQ's hwirq number into
  `share_params->complt_hwirq` (`rockchip_dmc.c:1422-1424`) and its IRQ
  handler is a bare wake-up (`wait_complete_irq`, `rockchip_dmc.c:1116-1123`).
- `rk3568_dmc_init` requires only **>= 0x101** (`rockchip_dmc.c:1874`) and
  does **not** write `complt_hwirq`; completion is driven by the on-die DDR
  MCU (`wait_ctrl.dcf_en = 2`, `rockchip_dmc.c:1894`) and the IRQ handler
  itself issues `POST_SET_RATE` (`wait_dcf_complete_irq`,
  `rockchip_dmc.c:1125-1138`).

Our firmware reports exactly 0x101, the rk3568 floor. Everything below
describes the rk3568/v0x101 contract only; none of the px30/0x103 paths
apply.

## 2. GET_FREQ_INFO — reading the supported-rate table

Call: `sip_smc_dram(SHARE_PAGE_TYPE_DDR, 0, ROCKCHIP_SIP_CONFIG_DRAM_GET_FREQ_INFO)`
i.e. SMC 0x82000008 with a1 = 2, a2 = 0, a3 = **0x0e**
(`rockchip_dmc.c:1196-1197`; sub-code from
`include/soc/rockchip/rockchip_sip.h:24`).

Results land **in the share page**, not in registers: a0 is the only register
output (status). The firmware fills `share_params->freq_count` and
`share_params->freq_info_mhz[0..freq_count-1]`, units **MHz**; the BSP
validates `0 < freq_count <= 6` and converts with `* 1000000`
(`rockchip_dmc.c:1204-1211`). The table is the set of frequency setpoints the
boot-time DDR blob trained; SET_RATE targets must come from it.

Ordering: the BSP always calls GET_FREQ_INFO *after* DRAM_INIT
(`rockchip_dmc.c:1916-1928`); see §5.

## 3. GET_RATE / ROUND_RATE — the v1/v2 quirk

The device speaks SIP **v2** (`SIP_SIP_VERSION` returned a1 = 2; probe
README:15). The two conventions differ and must not be mixed:

- v1 (legacy, `rockchip_ddrclk_sip_recalc_rate`,
  `drivers/clk/rockchip/clk-ddr.c:73-84`): a1 = 0, a2 = 0, a3 = 0x05; the
  **rate comes back in a0** (no separate error).
- v2 (`rockchip_ddrclk_sip_recalc_rate_v2`, `clk-ddr.c:140-151`): a1 =
  `SHARE_PAGE_TYPE_DDR`, a2 = 0, a3 = 0x05; **a0 = error, a1 = rate in Hz**.

ROUND_RATE (a3 = 0x02) in v2 form takes the candidate rate via
`share_params->hz` and returns the rounded rate in a1
(`clk-ddr.c:153-170`). It changes nothing in hardware and is a useful
pre-flight check that the firmware will run at exactly the requested rate.

Note the rk3568 devfreq driver itself never uses SIP GET_RATE — it reads the
rate through the SCMI `dmc_clk` clock (`clocks = <&scmi_clk 3>`,
`arch/arm64/boot/dts/rockchip/rk356x.dtsi:2261`, read back at
`rockchip_dmc.c:507`). The SIP GET_RATE is still implemented (clk-ddr v2 and
the dmcdbg driver rely on the same underlying state) and is the right tool
for a self-contained module; the test module prints raw a0/a1 so a v1-style
firmware response (huge a0, a1=0) would be recognized immediately.

## 4. SET_RATE — call shape, units, synchronicity, return codes

Reference: `rockchip_ddr_set_rate()` (`rockchip_dmc.c:340-357`), used because
rk3568 sets `is_set_rate_direct = true` (`rockchip_dmc.c:1929`).

Write into the share page:

- `hz` = target rate **in Hz** (u32; `ddr_psci_param->hz = target_rate` where
  target_rate is an OPP rate in Hz — `rockchip_dmc.c:344`; the freq table's
  MHz entries are multiplied by 1e6 before ever being compared with it).
- `lcdc_type` = the active display type (`rk_drm_get_lcdc_type()`,
  `rockchip_dmc.c:307-338`). On a board with no VOP-attached DRM connector
  this is `SCREEN_NULL` = 0 (`include/soc/rockchip/rockchip_dmc.h:19`); the
  PineNote's EBC is not a VOP output, so 0 is the faithful value.
- `vop_scan_line_time_ns` = VOP scanline time for the vblank-window
  calculation (`rockchip_dmc.c:346`); 0 with no VOP.
- `wait_flag1 = 1`, `wait_flag0 = 1` (`rockchip_dmc.c:347-348`) — tell the
  firmware to use its display-safe wait protocol where applicable.

Then: SMC 0x82000008, a1 = `SHARE_PAGE_TYPE_DDR` (2), a2 = 0, a3 = **0x01**
(`rockchip_dmc.c:350-351`).

**Synchronicity.** Two outcomes (`rockchip_dmc.c:353-354`):

1. a0 = 0 and a1 != -6: the switch completed synchronously inside EL3.
2. a0 = 0 and `(int)a1 == SIP_RET_SET_RATE_TIMEOUT` (-6,
   `include/linux/rockchip/rockchip_sip.h:92`): the firmware has *prepared*
   the switch and parked it on the on-die DDR MCU. The kernel must then run
   `rockchip_dmcfreq_wait_complete()` (`rockchip_dmc.c:1140-1186`): with
   `dcf_en == 2` it issues `ROCKCHIP_SIP_CONFIG_MCU_START` (a3 = 0x0c, a1 =
   a2 = 0, `rockchip_dmc.c:1161`), which actually starts the MCU sequence,
   then waits up to `wait_time_out_ms = 17*5 = 85 ms`
   (`rockchip_dmc.c:1898`) for the "complete" interrupt (GIC SPI 10 on
   rk356x, `rk356x.dtsi:2258-2259`), whose handler issues
   `ROCKCHIP_SIP_CONFIG_DRAM_POST_SET_RATE` (a3 = 0x09,
   `rockchip_dmc.c:1130-1133`). On IRQ timeout the same POST_SET_RATE is
   issued to stop the MCU (`rockchip_dmc.c:1175-1180`). Either way exactly
   one POST_SET_RATE follows one MCU_START.

The test module handles both outcomes. For (2) it does not register the
completion IRQ (that requires the dmc DT node); it sleeps a fixed 100 ms — 
longer than the BSP's entire 85 ms IRQ budget — then issues POST_SET_RATE,
then verifies via GET_RATE. It deliberately makes **no** SMC while the MCU
sequence may be in flight.

**Return codes.** a0 uses the `SIP_RET_*` space
(`include/linux/rockchip/rockchip_sip.h:86-92`): 0 success, -1 SMC_UNKNOWN,
-2 NOT_SUPPORTED, -3 INVALID_PARAMS, -4 INVALID_ADDRESS, -5 DENIED,
-6 SET_RATE_TIMEOUT (only ever seen in a1).

**Unsupported rate.** The BSP never sends one: every caller aligns the target
to the GET_FREQ_INFO table (via OPPs pruned against it,
`rockchip_dmc.c:1233-1259`) before SET_RATE, so `rockchip_dmc.c` contains no
explicit unsupported-rate error branch — there is no documented firmware
behavior to lean on. The plausible outcomes are `SIP_RET_INVALID_PARAMS` or a
silent internal round; neither is worth discovering on hardware. The test
module therefore (a) refuses any target not exactly in the firmware's own
table and (b) additionally requires v2 ROUND_RATE to echo the target back
unchanged before issuing SET_RATE.

### What rockchip_dmc.c does around SET_RATE that the test module skips

From `rockchip_dmcfreq_opp_set_rate()` (`rockchip_dmc.c:380-557`) and
friends, in the order they occur, with an honest per-item assessment for
*this* board (no VOP display, EBC e-ink, supervised single-shot test):

1. **OPP voltage scaling** (`rockchip_dmc.c:457-470` scale-up before,
   `517-528` scale-down after; supplies = vdd_center/mem). The BSP raises the
   DMC logic rail for high rates. We touch no regulator. **Safe under one
   rule:** never target a rate above the boot rate. The boot voltage was
   chosen for 1056 MHz; every lower setpoint needs less, not more. (Also
   standing repo landmine: `fan53555_set_mode()` corrupts the TCS4525's
   active VSEL — nothing here may ever call regulator_set_mode; we call no
   regulator API at all. `git show 9a5432a`.)
2. **cpus_read_lock() hotplug exclusion** (`rockchip_dmc.c:425`). Exists to
   avoid lock-order deadlocks with cpufreq policy locks the BSP also takes.
   We take no such locks and nothing hotplugs CPUs on this image. Skip: safe.
3. **CPU-frequency pinning** (`min_cpu_freq`, `rockchip_dmc.c:427-455`,
   restore at 546-552). Guarantees the set_rate completes *within a VOP
   vblank window*. No VOP, no vblank deadline. Skip: safe (the EBC constraint
   is handled by idling the EBC instead, below).
4. **`rockchip_dmcfreq_write_trylock()`** (`rockchip_dmc.c:479-480`, sem in
   `rockchip_dmc_common.c:18-48`). Excludes concurrent VOP bandwidth/msch
   readlatency requests during the switch. Our kernel has no callers of that
   sem. Skip: safe.
5. **lcdc_type / scanline refresh + wait flags** (`rockchip_dmc.c:483-487`).
   We set the same fields with the values a display-less board yields.
   Not skipped — mirrored.
6. **msch readlatency machinery** (`rk3399_set_msch_readlatency`,
   `rockchip_dmc.c:1734-1743`; `set_msch_rl`, `rockchip_dmc_common.c:50-61`).
   rk3399-only (`info.set_msch_readlatency` is set nowhere in the rk3568
   path). Skip: not applicable.
7. **cpu_latency_qos 0 during the wait** (`rockchip_dmc.c:1155,1182`). Keeps
   CPUs out of deep idle so the completion FIQ/IRQ is serviced fast. We poll
   nothing and wait longer than the whole budget; IRQ latency is irrelevant.
   Skip: safe.
8. **Post-change rate readback via clk** (`rockchip_dmc.c:507-515`). We
   verify via SIP GET_RATE instead. Equivalent.
9. **Devfreq/monitor/system-status bookkeeping** — pure kernel-side policy.
   Skip: safe.

### The EBC question: what a retraining stall does to an in-flight frame

During the actual frequency change every AXI master's DRAM accesses stall at
the memory controller — CPUs included; that is why the BSP needs no
CPU-quiescing. The display machinery above exists because a long stall
*underruns scanout FIFOs*: the BSP hides the stall inside a VOP vblank.

The PineNote's scanout engine is the EBC. During a refresh it performs bursty
DMA reads of phase data and drives waveform phases to the panel;
`EBC_FRAME_TIMEOUT` is 25 ms per frame
(`pinenote/patches/linux-pinenote-7.0-forward-port.patch:2980`), and a GC16
pass is ~46 frames of it. There is no vblank-wait integration for the EBC in
any firmware — `lcdc_type = SCREEN_NULL` means the firmware switches
*immediately*, mid-scan if a scan is running. Consequences of a stall landing
inside an active EBC frame:

- A stall short enough for the EBC line FIFO: nothing.
- A longer stall: the EBC underruns its phase-data fetch. The frame it drives
  is corrupt — wrong voltages on some pixel region for one frame (ghosting
  artifact; not damaging, the panel tolerates single wrong phases).
- Pathological stall (near the MCU budget, tens of ms): the frame-done IRQ
  can arrive after the 25 ms `EBC_FRAME_TIMEOUT`
  (patch:4434), the driver takes its timeout path, and — post-barrier — a
  setup/hardware failure during a barrier'd start is *terminal poison* until
  reboot (CLAUDE.md, "generation-addressed barrier"). That would burn the
  session's display for a test that didn't need it running.

**Conclusion: SET_RATE runs only with the EBC idle.** This costs nothing —
the EBC-idle precondition (reader stopped, fbcon unbound, EBC IRQ delta 0
over several seconds, refresh thread in `I`) is exactly the proven barrier
campaign discipline (`doc/hardware-deploy.md:139-145,178-180`). It is an
OPERATOR precondition; the module does not attempt to detect display state
(per design), including at rmmod-restore time.

## 5. The critical question: does SET_RATE depend on DRAM_INIT / SET_PARAM?

**DRAM_INIT: yes — and the module performs it.** The BSP's rk3568 sequence is
strictly ordered inside `rk3568_dmc_init()` (`rockchip_dmc.c:1864-1934`):

    GET_VERSION → SHARE_MEM(2 pages, DDR) → memset(page, 0, 8192)
      → DRAM_INIT (a1=2, a3=0x00)  (rockchip_dmc.c:1916)
      → GET_FREQ_INFO              (rockchip_dmc.c:1924 via 1196)
      → later, any number of SET_RATE

GET_FREQ_INFO and SET_RATE are only ever reached after a successful
DRAM_INIT; the BSP treats a DRAM_INIT failure as fatal for the whole driver
(`rockchip_dmc.c:1918-1922`). What DRAM_INIT needs from Linux is *nothing
but the zeroed share page*: it locates the training/setpoint data the
boot-time DDR blob left behind and initializes the EL3 dram driver state.
The test module replicates the sequence exactly, so "SET_RATE without the
init dance" never occurs. (`dram_init=0` exists for a deliberately more
conservative first probe; it hard-disables set_rate.)

**SET_PARAM / DT timing: no — rk3568 has none.** This is the decisive
finding for the premise:

- The SoCs that pass DDR timing from DT do it either by filling
  `share_page + 4096` with a `*_ddr_dts_config_timing` blob before DRAM_INIT
  (px30 `rockchip_dmc.c:1399`, rk3328 `:1715`, rv1126 `:2057`, etc.) or by
  streaming words via `ROCKCHIP_SIP_CONFIG_DRAM_SET_PARAM` (0x07) before
  DRAM_INIT (rk3399 only, `rockchip_dmc.c:1760-1774`).
- `rk3568_dmc_init` does **neither**. It zeroes the whole 8 KiB and calls
  DRAM_INIT (`rockchip_dmc.c:1889-1917`). The rk356x `dmc` DT node carries
  no timing properties at all (`rk356x.dtsi:2256-2298`) — only devfreq
  policy. SET_PARAM has no rk3568 caller anywhere in the tree.
- The separate `dmc_fsp` node (`rockchip,rk3568-dmc-fsp`,
  `rk356x.dtsi:2300-2311`) references per-DDR-type parameter blobs, but its
  driver does not exist in this BSP checkout (no match for `dmc-fsp` under
  `drivers/`), and nothing in `rockchip_dmc.c` gates on it. It is an
  optional PHY-tuning add-on in some vendor branches (it uses its own
  `SHARE_PAGE_TYPE_DDRFSP` page), not a SET_RATE prerequisite. rk3568 boards
  running this exact BSP tree do DDR DVFS without it.

So: on this SoC family, bl31 + the boot-time DDR blob are self-sufficient.
The frequency setpoints were trained by the TPL ("ddr bin") at boot; if the
PineNote's TPL trained only the single 1056 MHz setpoint, GET_FREQ_INFO will
say so (freq_count = 1, or an error) and the experiment ends safely at the
read-only step. That is the go/no-go the first insmod answers.

**Residual unknowns, stated honestly:** (a) whether this device's TPL trained
more than one setpoint — answered read-only by GET_FREQ_INFO; (b) whether
v0x101 on this particular bl31 build takes the synchronous or the MCU (-6)
SET_RATE path — both are handled; (c) whether DRAM_INIT on a bl31 whose DDR
SIP has never been driven does anything beyond state setup — mitigated by
UART supervision and by announcing every SMC before issuing it, so a hang
pinpoints the exact call.

## 6. Interaction with system suspend

Three separate concerns, all bounded:

- **Different SIP function.** The repo's BSP-SIP suspend stack talks to
  `SIP_SUSPEND_MODE` (0x82000003,
  `pinenote/patches/linux-pinenote-7.0-bsp-sip-probe.patch:439` uses
  `ROCKCHIP_LEGACY_SIP_SUSPEND_MODE`); the DMC path is 0x82000008. No shared
  arguments, no shared share-page (suspend uses `SHARE_PAGE_TYPE_SLEEP`).
  Runtime SET_RATE does not arm, configure, or alter any suspend state.
- **SET_AT_SR** (a3 = 0x03, `sr_idle_en` in the page,
  `rockchip_ddr_set_auto_self_refresh`, `rockchip_dmc.c:1093-1102`) is how
  the BSP enables auto-self-refresh when entering `SYS_STATUS_SUSPEND`
  (refresh flag set at `rockchip_dmc.c:2558-2562`, applied at `:2614-2618`).
  The test module never issues it; self-refresh idle policy is untouched.
- **suspend_rate / deep_suspend_rate** are kernel-side devfreq policy
  (`rockchip_dmc.c:141-142`, `devfreq->suspend_freq` at `:3154`) — no
  firmware state involved.
- **Our proven suspend path is s2idle** (rungs 1-2, 2026-08-02), which never
  enters bl31 at all — a runtime rate change cannot interact with it. The
  deep (rung 3) path is activation-hard-off and hangs in bl31 for unrelated
  reasons (zero PM config word). For hygiene: BSP fleets suspend at
  *deliberately lowered* DDR rates every day, so a changed rate at suspend
  entry is a supported firmware condition — but the procedure still restores
  the boot rate before rmmod and forbids suspend while the test module holds
  a non-boot rate, so the question never arises on hardware.

## 7. Constraints that shaped the test module

1. **v0x101 = the rk3568 floor.** Only the rk3568/MCU contract applies:
   2-page share mem, zeroed page, DRAM_INIT before anything, GET_FREQ_INFO
   results in the page (MHz), SET_RATE via `hz` in Hz with the possible
   -6/MCU_START/POST_SET_RATE completion dance.
2. **The table is the law.** SET_RATE targets must be exact GET_FREQ_INFO
   entries (BSP behavior; no defined unsupported-rate semantics), gated
   additionally by ROUND_RATE echo.
3. **No display integration exists for the EBC** in any firmware, so the
   only display-safe window is "EBC idle" — an operator precondition, and
   the reason `lcdc_type = SCREEN_NULL` is both faithful and sufficient.
4. **No voltage scaling** → never exceed the boot rate; first target is the
   lowest table entry.
