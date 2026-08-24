# `dclk_select=1` reaches 79.68 Hz with no code change — and no corruption was detectable (2026-08-24)

Device: author's PineNote, os2, Linux 7.0.11 `PREEMPT_RT`, plugged in,
operator present. Issue #23.

## Headline

**Issue #23's implementation plan is unnecessary.** It scopes ~2 DT lines
plus ~10 driver lines to reclock `CPLL_333M` to 250 MHz so the
divider-less `DCLK_EBC` mux can select it. The reclock is already done in
hardware:

```
pll_cpll   1000000000
  cpll_333m  250000000     <- NOT 333.  The CRU divider sits at /4, not /3.
dclk_ebc     200000000  parent=gpll_200m
             possible parents = gpll_400m  cpll_333m  gpll_200m
```

`doc/refresh-policy.md` concluded a 250 MHz request "rounds **down** to
200" because `DCLK_EBC` is `COMPOSITE_NODIV` with no
`CLK_MUX_ROUND_CLOSEST`. That is true, and it is only *fatal* if
`cpll_333m` sits at 333 — where round-down lands on `gpll_200m`. At 250
there is an exact match. Confirmed by doing it:

```
dclk_select=0 ->  dclk_ebc=200000000  parent=gpll_200m
dclk_select=1 ->  dclk_ebc=250000000  parent=cpll_333m
```

So the whole change is **one module parameter**, already runtime-writable
(`module_param(dclk_select, int, 0644)`). That is 1.25x on every mode we
ship: GL16/GC16 596 -> 477 ms, DU 298 -> 239 ms, A2 157 -> 126 ms, and it
moves us from 75% to 94% of the waveform's authored 85 Hz design point.

## How the parameter is applied

Both `dclk_select` call sites are on the **mode-set path** — the timing
programmer, and `rockchip_ebc_crtc_atomic_check` gated on
`crtc_state->mode_changed`. A runtime write is therefore inert until a
mode set. A **suspend/resume cycle applies it**, via
`drm_mode_config_helper_resume()` on the resume path. That was used here
as the transition mechanism and worked in both directions, three times.

## The DDR gate is far wider than #23 assumes

#23 frames the risk as "this change pushes on exactly that margin",
citing the 2026-08-07 A/B where the EBC's phase fetch starved at **324
MHz** DDR. But 324 MHz is not what we ship — DDR DVFS ships `mode=off`
*because of* that result:

```
clk_scmi_ddr        1056000000
clk_ddrphy1x_src     528000000
/sys/class/devfreq/  no dmc node at all — DVFS is not registered, not merely parked
```

**1056 MHz is 3.26x the proven starvation point**, against a 1.25x rise in
EBC demand (~335 -> ~419 MB/s). The right reading of the DDR gate is
"verify on the rig", not "we are pushing on a margin we have already
broken". Those are different risk postures.

## The visual check, and exactly how weak it is

No optics rig was available. A webcam on a cluttered desk was, and #23's
gate is *"does it silently corrupt"* — a gross failure — not photometry.
So: ABBA, three frames per state, one suspend/resume per transition, the
page held static throughout.

| comparison | SSIM | YAVG (mean abs diff /255) |
|---|---|---|
| within-state, 11 pairs | 0.929 – 0.934 | 2.76 – 3.22 |
| **across-state** A1↔B4 | 0.910 | 3.22 |
| **across-state** B4↔A2 | 0.927 | 3.64 |
| **drift control** A1↔A2 (*same clock*) | **0.898** | **3.78** |

**The largest difference in the dataset is between two captures at the
same clock rate.** On both metrics the ordering is within <= across <=
drift, so the across-state numbers are entirely inside what elapsed time
alone produces. Mean absolute difference ~3/255 is 1.3% of full scale —
webcam noise on textured paper.

The drift control is what makes this interpretable. Without it, 0.910
across versus 0.930 within invites a story about a small real effect; the
control shows time alone does worse.

`dmesg` across the whole sequence: `rockchip_ebc_suspend` ->
`rockchip_ebc_resume` -> `plane_reset` -> `ctx_release`/`ctx_free`, no
errors, no underruns. 4 suspend cycles, 0 failures. The only `fail`-
matching line is the once-per-resume cyttsp5 handshake of #24.

### What this does NOT establish

- **Not an optics measurement.** ~1.17 camera px per panel px, uncontrolled
  non-uniform lighting (a shadow across the top), keystone from an angled
  view, JPEG. The SSIM noise floor is 0.93, not 0.99, so anything subtler
  than roughly a 7% structural change is invisible here.
- **Nothing about optical quality.** The 94%-vs-75%-of-authored-phase-rate
  argument is a photometric claim and this rig cannot address it at all.
- **One page, one temperature, one session.** The 2026-08-07 corruption was
  content- and bandwidth-dependent; a static text page is a mild load. A2
  and DU modes, fast page-turn sequences, and a cold panel are untested.

The honest statement is: **no gross corruption was detectable at ~1.17
camera px per panel px, and no clock-attributable difference was found
above a drift-controlled noise floor.** That is real evidence and it is
weaker than the rig would give. It should not be read as clearance to ship.

## Restored

`dclk_select=0`, `dclk_ebc=200000000 parent=gpll_200m`,
`autosuspend.conf` back to `enabled=1 idle=300 backstop=3600`, probes
deleted from `/tmp`.
