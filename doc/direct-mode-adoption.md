# Adopting direct mode: the plan

**Status: plan, with its first glass results — not a decision record.**
Written 2026-08-24, after the operator named handwriting as a product
direction that the current display path cannot support. Built: P1's CLUT
compiler and installer one-shot, P2's `linux-pinenote-hrdl-direct` kernel
package, P2a's modprobe options — and, since 2026-08-25, the
`reader-direct` flavor instantiates all of it, with the per-boot rebind
(the D7 answer) as the one-shot's final stage. **The driver has run on
glass** (2026-08-25, `doc/status.md`): D1–D4 passed with the wiring's job
done *by hand* — the deployed image predated the wiring — D9 was
measured, D5 (rotation) is unresolved, and the operator confirmed on
video the flashing-per-turn cost that makes P4 the next display work.
The wired image booted hands-off on 2026-08-26: CLUT compiled at boot,
rebind at 10.1 s, reader up via shepherd with no crash-loop, washes on
the resolved card, and reader-idle power at parity with shipping
(155.3 vs 156.9 mA — `doc/status.md`). Later the same night: **D5
resolved and proven** (all four orientations on glass; the lever is
`closed_rotation_mode`, pinned by `test-rotation-decision.lua`), **D6
passed** (ultra rails-off suspend/resume with this driver; one dwc3
gadget caveat, registered), and real-turn power measured (+59 mA at
20 turns/min, ~41.5 frames/turn — the untuned hint is a power cost
too). P4 onwards is still a plan, and
the bail-out criteria at the bottom still apply.

Read `doc/hrdl-evaluation.md` first — this document assumes it.

**Decision (operator, 2026-08-25): we ship ONE image.** The
`reader-direct` flavor is **scaffolding for the experiment, not a product
line**. The gate is embrace-or-reject, decided on glass: *embrace* means
the `reader` flavor itself moves to the direct-mode kernel and the
scaffolding is deleted; *reject* means the same deletion with the
shipping driver unchanged. Either way, the next prealpha tag ships
`reader`, singular — never a direct/non-direct pair. Nothing
direct-mode-related may therefore grow roots the deletion would tear:
no doc may tell a user to choose between flavors, and no service may
exist only in the direct flavor without a note that it dies or graduates
with the decision.

## Why now

`doc/hrdl-evaluation.md` rejected the driver swap with an explicitly
conditional verdict:

> **Verdict: not now.** … Re-evaluate when the corruption hunt closes,
> when pen latency becomes the active track …, or when a community
> rebase forces a structural decision anyway.

**Both of the first two have fired.** The corruption hunt closed; pen
latency is now the active track, because handwriting — note-taking,
drawn UIs in books, handwritten code that executes — is a stated product
direction rather than a nice-to-have. Handwriting also adds *recognition*
latency on top of ink latency, so the panel budget matters more, not
less.

**The current path cannot get there.** Ink latency floor today:

| | |
|---|---|
| software path, damage → publish | 132–140 ms (measured) |
| A2, the fastest LUT-mode waveform | 10 phases = 157 ms |
| **floor** | **~290 ms** |

For scale, reMarkable claims ~21 ms. At 290 ms the ink trails a third of
a second behind the nib. #23's reclock takes A2 to 126 ms — real, and
nowhere near enough. `DRIVER_MODE_FAST` reaches **~11.7 ms to first
motion**, and it is structurally unavailable in 3WIN/LUT mode: it needs
the driver to own per-frame phase bytes.

## What the swap buys, beyond FAST mode

| | |
|---|---|
| `DRIVER_MODE_FAST` | ~11.7 ms to first motion (1-bit, visible smear) |
| **85 Hz** | needs `SDCLK_DIV=0`, direct-mode-only — **100 %** of the waveform's authored rate |
| phase buffer 2 bits/px | **~6× less DDR** (56 vs 335 MB/s) — cheaper on our one confirmed failure mode |
| per-pixel state | no areas, no queue, no `split_area_limit` — **area-collision bugs cease to exist as a class** |

That last one deletes the bug class issue #22 lives in. **The drain gate
we landed on 2026-08-24 is a fix for the driver we would be leaving.** It
stays correct and stays owed to the m-weigand lineage; it simply does not
port, because there is no queue to drain.

## What today's probe changed

The evaluation's strongest ground for rejecting was that the offline
harness dies:

> **Host tools — the big one.** … the entire offline refresh-machine
> harness and the replay workbench stop compiling on the workstation.
> Recovery options, none cheap …

Measured 2026-08-24 (`907efce`): the harness cross-compiles to aarch64
and runs under `qemu-aarch64` with **identical results** — drain-gate
31 PASS/0 FAIL, refresh-test **with ASan** 148 PASS/0 FAIL, ~3× wall
time. Cost: **one typedef**. Residual: LeakSanitizer does not work under
qemu-user, and qemu *emulates* NEON.

So the objection that killed the swap is now priced, and it is cheap.

## The blockers, and the decision each needs

### D1. `custom_wf.bin` has no producer we can run — **the hard one**

hrdl's driver `request_firmware`s `rockchip/custom_wf.bin` and **probe
fails `-EINVAL` if it is absent**. It is compiled from the device's own
`ebc.wbf` by `wbf_to_custom.py`; ayakael's first-boot recipe runs that
**on the device**.

**We cannot.** The reader image has no Python, no Perl, no standalone
Lua — verified 2026-08-24; KOReader's bundled `luajit` is the only
interpreter (`doc/artifacts/pinenote-input-clocks-20260824/`).

Three options:

1. **Reimplement the CLUT compiler in C, ship it as an on-device binary.**
   *Recommended — and **done end to end** as of 2026-08-25 (see P1):
   compiler, installing one-shot, the `reader-direct` wiring that
   instantiates both, and the per-boot sysfs rebind that answers **D7**
   (the one-shot cannot run before the initrd's probe, so it re-triggers
   the probe instead).  D1 itself passed on glass 2026-08-25 — by hand,
   because the deployed image predated the wiring (`doc/status.md`).*
   There is a near-precedent: `pinenote-install-waveform` is a
   generated script run by a one-shot shepherd service
   (`pinenote/services/ebc.scm`) — though note it is **not** "before the
   EBC module loads", which is D7's whole subject — and `pinenote-ebc-dump` in
   `pinenote/packages/firmware.scm` is an on-device C tool we already
   cross-build. Adding a sibling is the smallest change to a shape we
   already have. It keeps Python off the device, preserves never-bundle
   (compile from the device's own waveform at boot), and — crucially —
   **a C implementation differential-tested against `wbf_to_custom.py`
   is the "CLUT-compiler differential" §4.2 names as the natural first
   joint artifact with hrdl.** The work pays twice.
2. **Compile on the host at install time, stage to p7.** Simpler to
   build, but moves a mandatory boot artifact into a manual step, and a
   skipped step is a `-EINVAL` probe failure — i.e. no display at all.
   Viable as a *bridge* while (1) is written; poor as the end state.
3. **Put Python in the reader image.** Rejected: a large closure on a
   device whose whole design is minimal, to run one compile once.

### D2. A2 disappears from the vocabulary

hrdl's CLUT compiles six sequences — DU, DU4, GL16, GC16, INIT, WAITING.
**A2 is dropped**, folded into DU plus early cancellation. Bit depth *is*
the waveform choice: Y1→DU, Y2→DU4, Y4→GL16, set per-rect by hints.

`doc/refresh-policy.md` and KOReader's `device.lua` intent mapping are
written in A2/DU/GL16/GC16 terms. Both need rewriting against hints. This
is not hard, but it is not mechanical either — the policy decisions
encoded there were bought with hardware sessions and must be re-derived,
not transliterated.

### D3. Rotation via fbdev is untested upstream

> Nobody rotates via fbdev on his stack (sway does transforms).

Four orientations with autorotation is a **shipped, hardware-validated**
feature of ours (`final4`, 2026-07-19). His stack has never exercised
that path. This is the single most likely place for a nasty surprise,
and it must be an explicit bring-up gate rather than an assumption.

### D4. `-EINVAL` on missing firmware is a worse first-boot failure

Today a missing waveform fails visibly but the system boots. Under
direct mode the EBC probe fails outright: no display. For an operator
installing on their own device (`doc/install.md`) that is
indistinguishable from a brick. Needs either a fallback path, or a
loud pre-flight check, or both — decide deliberately.

### D5. Kernel base — **SIZED 2026-08-25, and it is small**

His tree is `v6.19_ebc_custom`; ours builds 7.1.8. **Port his driver onto
our kernel — do not adopt his kernel.** Our seven-patch stack, ultra
suspend matched pair, and the whole gate apparatus are built around our
base.

The plan called this "the larger of the two rebase surfaces and should be
sized before committing." Sized, from a `--depth 300 --single-branch`
clone at `~/src/reference/hrdl-linux` (2.3 GB; HEAD `819ba1724a6`, which
`git describe` puts at **`v6.19-182-g819ba1724a6`**):

| | |
|---|---|
| commits above `v6.19` | **182** |
| files touched | 12 — **7 of them new** |
| files *modified* | **5**: `drm/Kconfig` (+6), `drm/Makefile` (+8/−2), `rockchip/Kconfig` (+22), `rockchip/Makefile` (+8/−2), `panel-simple.c` (+251, a mode table) |
| total insertions | 5377 |
| his `rockchip_ebc.c` | 2527 (ours is 3481 — his is *smaller*, the pixel work having moved out) |
| new alongside it | `rockchip_ebc_blit_neon.c` 1253, `rockchip_ebc.h` 252, `..._neon.h` 62 |

**Four of the five modified files are build glue.** The textual rebase
surface is therefore close to nothing; the real surface is ~4000 lines of
*new* code compiling against 7.1's DRM.

**Two measurements say that surface is clean.**

1. **`drm_epd_helper.c`: our 7.1-forward-ported copy and his 6.19 copy
   differ by ONE change** — he makes `pvi_wbf_get_mode_index` non-static
   and adds `EXPORT_SYMBOL` so the separate blit module can call it. That
   file needed *zero* API adaptation across 6.19 → 7.1, and our
   forward-port work on it transfers wholesale.
2. **Nine kernel APIs appear in his driver and not in ours** — and ours is
   *proven* to compile on 7.1, so those nine are the entire risk set:
   `drm_client_setup_with_fourcc`, `drm_rect_height`, `drm_rect_width`,
   `drmm_kmalloc`, `drmm_kzalloc`, `kmalloc_array`, `ktime_us_delta`,
   `msleep_interruptible`, `pm_runtime_resume_and_get`.
   **All nine exist in 7.1.8**, checked against the extracted source.
   `drm_client_setup_with_fourcc` — the one that looked risky, being
   recent fbdev-client API — is at `include/drm/clients/drm_client_setup.h`
   in *both* 6.19 and 7.1.8, and he already includes it from that path.
   His tip commit switches to **`scoped_ksimd()`**, which sounds new and
   is: it is in 7.1.8's `arch/arm64/include/asm/simd.h`. He is tracking
   *toward* what 7.1 has.

**What this does NOT establish.** It is a static name-existence check, not
a compile. A name can survive while its signature, its struct layout or
its semantics change, and none of that is covered — nor are macros. The
honest reading is that **no obvious blocker exists**, which is a much
weaker claim than "it will build". The real test is P2, and it is cheap:
graft his files into our 7.1 tree and run `make kernel`.

### D6. Keep 3WIN as a bail-out? — **the premise was wrong**

3WIN survives upstream behind `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE`, and
this plan said "keeping it buildable costs little."

**It is not buildable.** Compiling his tree against 7.1.8 with
`CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE=y` fails in
`rockchip_ebc_blit_neon.c`, and not on anything to do with 7.1:

```c
#ifdef CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE
        if (!direct_mode) {
            vst1q_u8(phases_line, vshrq_n_u8(q8_inner_new, 6);   /* 2 opens, 1 close */
        } else
#endif
```

An unbalanced paren, plus `direct_mode` undeclared in that translation
unit — both wholly inside the `#ifdef`. A missing parenthesis cannot ever
have compiled, so **that configuration has never been built**, which fits
a tree whose default is direct mode.

So the retreat 3WIN was supposed to provide costs a repair, not nothing.
**The real bail-out is our own driver**, which we keep and which is the
shipping one — a strictly better retreat than a config of his we would
have to fix first. Reported upstream rather than patched.

### D7. Probe happens in the INITRD, so nothing in userspace is "before the module loads" — **found 2026-08-25; resolved on glass the same night, by a fourth option**

This is the blocker P0's item 1 (below, under **The plan**) talked itself
out of. Measured in the tree, not assumed:

- **`pinenote-ebc-modprobe-service-type` loads nothing.** It extends
  `etc-service-type` and writes `/etc/modprobe.d/rockchip_ebc.conf`. That
  is its whole body. Nothing in `pinenote/services/` or
  `pinenote/systems/` ever runs `modprobe rockchip_ebc`.
- **The initrd raw-loads it.** `rockchip_ebc` is in
  `%pinenote-display-initrd-modules`, and `pinenote-initrd*`'s
  `#:pre-mount` hook calls `load-linux-modules-from-directory` on that
  list — straight after copying the waveform partition into the
  *initramfs's own* `/lib/firmware/rockchip/ebc.wbf`.
  `pinenote/images/pinenote-initramfs.scm` says so in its own words at the
  bottom of the file ("the initrd raw-loads `rockchip_ebc` … which passes
  no parameters at all"), hardware-confirmed 2026-07-05 by an image whose
  cmdline `refresh_waveform=6` was simply ignored.

So probe — and with it `request_firmware("rockchip/custom_wf.bin")` and
hrdl's `-EINVAL` — happens **inside the initramfs**, before the root
filesystem a shepherd one-shot writes to has been mounted. A one-shot
cannot be ordered before that, which is exactly why hrdl's unit runs
`mkinitcpio -P` and then `modprobe -r rockchip_ebc; modprobe
rockchip_ebc`. On our stack the same load happens **every boot**, not only
the first: the initramfs is discarded, so its firmware directory never
carries anything forward.

Three ways out, none of them written, none tried:

| | cost | risk |
|---|---|---|
| (a) compile the CLUT in the initrd, beside the waveform copy | `wbf-clut` and its closure inside the initramfs, and a `system*` in the pre-mount gexp | biggest initrd change; a failure there is pre-console |
| (b) drop `rockchip_ebc` from the *direct flavor's* initrd module list and modprobe it from a one-shot after the CLUT service | a second initrd variant, a load one-shot, and a working module database at `/run/booted-system/kernel` (the `modprobe -d` shape `usb-gadget.scm` already uses) | display arrives later in boot; the reader flavor drops `console=tty0` anyway, so the U-Boot logo simply stays |
| (c) install, then reload — `modprobe -r rockchip_ebc; modprobe rockchip_ebc` — as hrdl does | smallest; no initrd work | a reload while something holds the DRM/fb device fails, and every boot pays a failed probe first |

**Decided on glass, 2026-08-25 — and it is none of the three.** The
session proved a fourth mechanism with a smaller blast radius than any
of them: leave the initrd raw-load (and its now-*expected* per-boot
`-EINVAL`) alone, and after the CLUT lands write the device back into
the driver's sysfs `bind` file —

```
echo fdec0000.ebc > /sys/bus/platform/drivers/rockchip-ebc/bind
```

— which re-runs the probe, and it passes (`doc/status.md` D2). No initrd
change, no module reload, no modprobe.d exposure (the module is already
loaded; parameters never re-enter the picture). The CLUT one-shot now
performs that rebind itself as its final stage, on every boot including
is-current ones: unbind if bound, bind, then judge the END STATE — device
bound and a DRM `card*` minor present — and fail the service loudly
otherwise (`pinenote/services/ebc-clut-install.sh`, driven through the
new branches by `make ebc-clut-check`). The service-driven rebind has
not itself run on glass; the session ran the same steps by hand. One
prediction above stands: the CLUT installer was needed under every
option, which is why it was built first.
### D8. The EBC node needs a third clock — **RESOLVED 2026-08-25, and it is two lines**

(Numbered D7 until 2026-08-25, when the initrd-probe finding took a
section of its own; every bare "D7" cross-reference in the tree means
the initrd section above.)

P2 left this open: his `v6.19_ebc_custom` branch touches no DTS at all, so
the EBC node his driver binds to had to live somewhere we had not found.

**The branch is `v6.19_pn_dts_v2`** (tip `27d6a52da`). `ls-remote --heads`
on `git.sr.ht/~hrdl/linux` returns **69 branches**, not the four
`doc/reference-register.md` listed — the tree is one branch per topic, and
the device tree is its own topic. The register has been given the row, so
the next person does not repeat this.

**Neither commit `doc/hrdl-evaluation.md` cites leads to a device tree** —
both are driver commits on `v6.19_ebc_custom`. Worth stating plainly,
because it is what sent this task looking in the wrong place:

| cited | what it actually changes |
|---|---|
| `9444147d35a2` — *"rk3566-pinenote.dtsi: set CPLL_333M to 33.33 MHZ…"* | **`rockchip_ebc.c` only**, +7/−3. The evaluation called this a *DTS commit*; the `dtsi` in its subject is a leftover, and that citation is now corrected in place. |
| `70cbadbce9ab` — *"add another panel mode"* | `panel-simple.c`. The evaluation labelled this one correctly — it just is not DTS either. |

`9444147d35a2` is half of a commit split across two branches: its twin
`417dc79cdf8f` carries the DTS half on `v6.19_pn_dts_v2` under the *same
subject and the same author timestamp* (2025-01-09 01:55:29 +0100), and
neither half mentions the other. The evaluation's **substance was right**
— there is a third clock and it is 33.33 MHz — and its **attribution was
wrong**. The finding that `v6.19_ebc_custom` changes nothing under
`arch/` really does hold; that half stands.

The commit that actually adds the clock is a third one, `37ae838a4db8`,
*"rockchip_ebc: adjust cpll_333m and enhance clock management"* — two
lines in `rk356x-base.dtsi`.

#### What the probe requires — the authoritative list

His DTS is evidence; `rockchip_ebc_probe` is the requirement. Read at
`819ba1724a6`, this is every device-tree-backed thing it asks for:

| probe call | DT it needs | ours |
|---|---|---|
| `devm_platform_ioremap_resource(pdev, 0)` | `reg` | ✓ |
| `devm_clk_get(dev, "hclk")` | `clock-names` | ✓ |
| `devm_clk_get(dev, "dclk")` | `clock-names` | ✓ |
| **`devm_clk_get(dev, "cpll_333m")`** | `clock-names` | **✗ — the gap** |
| `devm_iio_channel_get(dev, NULL)` | `io-channels` | ✓ `<&ebc_pmic 0>` |
| `devm_regulator_bulk_get` × 3 | `panel-` / `vcom-` / `vdrive-supply` | ✓ |
| `platform_get_irq(pdev, 0)` | `interrupts` | ✓ |
| `devm_drm_of_get_bridge(…, 0, 0)` | `port`/`endpoint` → panel | ✓ |
| `of_device_id` | `compatible = "rockchip,rk3568-ebc"` | ✓ |

**One gap, and it is fatal.** The `cpll_333m` get is **unconditional** —
it is not behind `if (direct_mode)` — and fails through `dev_err_probe`.
A missing clock is therefore a probe failure and no display: D4's failure
mode arriving from a second direction, and one a `custom_wf.bin` fallback
would not catch.

Two negative results the same read settles:

- **His driver never touches resets.** No `devm_reset_control_*` anywhere
  in the file. Our node declares `resets`/`reset-names`; under his driver
  they are dead properties, which is harmless.
- **`vposneg` vs `vdrive` is a label difference, not a delta.** His
  overlay has `vdrive-supply = <&vdrive>`, ours `<&vposneg>`; the *supply
  name* the driver asks for is `"vdrive"` in both. Nothing to do.

#### The delta

Two lines, and they go in the **direct-mode patch**, not the forward-port:

```dts
&ebc {
+	clocks = <&cru HCLK_EBC>, <&cru DCLK_EBC>, <&cru CPLL_333M>;
+	clock-names = "hclk", "dclk", "cpll_333m";
 	io-channels = <&ebc_pmic 0>;
 	panel-supply = <&v3p3>;
```

hrdl edits the shared `rk356x-base.dtsi` node in place. We should not:
**our forward-port patch is what creates that node in the first place**
(mainline has no EBC node at all), so editing it there means editing the
most rebase-fragile artifact in the repo for a study variant. Re-assigning
the two properties in the board-level `&ebc` overlay — which our
forward-port already adds to `rk3566-pinenote.dtsi` — overrides the base
node's list, keeps the change inside
`linux-pinenote-7.1-hrdl-direct-mode.patch`, and leaves the shipping
kernel's DTBs byte-identical. `CPLL_333M` is in scope there: the include
chain reaches `rk356x-base.dtsi`, which includes
`<dt-bindings/clock/rk3568-cru.h>`, textually before the overlay.

**This delta is written down, not applied.** Nothing in this commit
changes a patch, a package or an image.

#### The 250 MHz / 33.33 MHz contradiction is not one

Issue #23 measured `cpll_333m` at **250 MHz** on our device
(`doc/artifacts/pinenote-dclk-reclock-20260824/`); direct mode wants
**33.33 MHz**. Both are true of the same clock, because `cpll_333m` is not
fixed — it is a plain 5-bit divider off `cpll`, and #23's own dump gives
the numerator:

```
pll_cpll   1000000000
  cpll_333m  250000000     <- the CRU divider sits at /4
```

1000/4 = 250 MHz is the divider our device is *observed* to boot with —
left by the bootloader, since nothing in our DTS mentions `CPLL_333M` —
and it is what `dclk_select=1` exploits. 1000/30 = 33.333 MHz is what direct mode programs. hrdl's
`37ae838a4db8` message says both in one breath: *"diff mode works best
with dclk 33.33 MHz using cpll_333m 33.33 MHz… Alternatively cpll_333m can
be used at 250 MHz, resulting in a noticable speedup."* That second
sentence **is** issue #23, arrived at independently.

Why the driver needs its own handle on the parent, rather than just asking
`dclk` for a rate: `DCLK_EBC` is `COMPOSITE_NODIV` with flags `0` — a pure
mux over {`gpll_400m`, `cpll_333m`, `gpll_200m`} with no divider and no
`CLK_SET_RATE_PARENT`. It can *reparent* to the closest rate at or below
what you ask, and it can never *re-rate* its parent. So reaching 33 MHz
requires setting `cpll_333m` first, which is exactly the order
`rockchip_ebc_set_dclk` uses.

The chain, end to end:

| step | value |
|---|---|
| `clk_set_rate(cpll_333m, 33333334)` → divider 30 | 33,333,333 Hz |
| `clk_set_rate(dclk_ebc, 34000000)` → reparents to `cpll_333m` | 33,333,333 Hz |
| `EBC_DSP_CTRL_DSP_SDCLK_DIV(0)` → sclk = dclk | 33.333 MHz |
| `sdck.htotal = 2208/8 = 276`, `vtotal = 1421` | **85.0 Hz** |

That is the panel's authored rate. For scale against what we ship: LUT
mode at dclk 200 MHz with `SDCLK_DIV=7` gives sclk 25 MHz (63.75 Hz);
#23's `dclk_select=1` gives 31.25 MHz (79.68 Hz); direct mode gives the
remaining 6.7 %.

**A consequence worth pinning: `dclk_select` is dead in our direct-mode
build.** `rockchip_ebc_set_dclk` takes the `if (direct_mode)` branch
before it ever reads `dclk_select`, and `direct_mode` is a
`static bool … = true` whose `module_param` is registered only under
`CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE` — which we correctly build off. So in
`linux-pinenote-hrdl-direct` direct mode is unconditional and #23's
parameter has no effect at all.

#### The 85 Hz panel mode is *not* a second gap

Our direct-mode patch does not carry `panel-simple.c` — it has no `arch/`
hunks and no `ed103tc2` text — so the built variant keeps our
forward-port's mode table (`num_modes = 8`) and does **not** have hrdl's
85 Hz entry from `70cbadbce9ab`.

That turns out not to matter. In direct mode the driver **ignores
`mode->clock`**: `rockchip_ebc_set_dclk` forces 34 MHz whatever the mode
says. All eight of our modes carry identical `htotal`, `vtotal`, `hskew`
and `CLKDIV2` and differ *only* in `.clock`. The panel rate is set by sclk
and those shared timings, so it is 85 Hz whichever mode DRM picks. The
85 Hz entry earns its keep only in **LUT** mode, where dclk *is*
`mode->clock` and `SDCLK_DIV` is 7 — which is why his entry reads
`.clock = 266680`, i.e. 8 × 33.335 MHz.

So `70cbadbce9ab` is optional for us. Derived from source; nothing has run.

#### One driver defect found in this path, and not filed

`rockchip_ebc_crtc_atomic_check` does `mode->clock = rate / 1000` where
`rate = rockchip_ebc_set_dclk(…)`, and that function returns
`clk_set_rate`'s value — **0 on success, not a rate**. So
`adjusted_mode.clock` is zeroed on every successful mode set, in every
mode, not just direct. Ours is correct here and his refactor regressed it:
we call `clk_round_rate`, which does return the rate.

Likely cosmetic on a panel with no meaningful vblank — DRM computes its
timestamping constants from a zero dotclock and complains — but it is a
difference we would inherit. **Deliberately not filed** in
`doc/driver-findings-report.md` or the upstream register: it was read off
source before any panel had run this driver, and this repo's bar for a
finding is higher than that. File it when P3 step 1 either shows the log line or does
not.

#### What we are NOT adopting, and what is still unknown

- **Not adopting his `&cru` block.** His `rk3566-pinenote.dtsi` pins
  `CPLL_333M` to 33333334 at boot alongside `ACLK_TOP_HIGH/LOW`,
  `ACLK_RGA_PRE`, `CPLL_250M`, `HCLK_RGA_PRE`, `HCLK_EBC` and
  `HCLK_JENC`. The driver sets `cpll_333m` on every mode set, so the
  boot-time pin is redundant for correctness; and a board-level `&cru`
  override **replaces mainline's whole `assigned-clocks` list** rather
  than extending it, which is a wider blast radius than a study variant
  needs. If it is ever adopted, mainline's three entries
  (`CLK_RTC_32K`, `PLL_GPLL`, `PLL_PPLL`) must be carried across, as
  hrdl carries them. Directly above a commented-out variant of that block
  that used 333.4 MHz throughout, he notes *"stronger artifacting, I
  suspend [sic] instabilities due to too high clock frequencies"* — so
  these are values tuned against symptoms on his stack that we have never
  reproduced. Copying them would import a fix for an unknown problem.
- **Collateral on `cpll_333m` looks confined, but is checked against the
  wrong tree.** Only two clocks can mux onto it: `DCLK_EBC` and
  `DCLK_VICAP`. Mainline pins `DCLK_VICAP` to 300 MHz, which selects
  `gpll_300m`, so dropping `cpll_333m` to 33 MHz should take nothing with
  it. `HCLK_EBC` is *not* on `cpll_333m` — it is a gate off
  `hclk_rga_pre`. **All of that was read in his 6.19 tree, not verified
  in our 7.1.8 base.**
- **Nothing has run.** No probe, no bind, no frame. Every claim here is
  derived from source. The delta satisfies the probe *as written*; whether
  the clock framework grants 33.333 MHz on this SoC at runtime, and
  whether the panel likes it, are P3 step 1 questions.
- **dtc has not been run on the override.** Property re-assignment through
  a label reference is ordinary DTS, but the gate is `make kernel` on the
  variant, and it has not been done.


## The plan

Cheapest decisive things first, in the ladder's order. **Each phase has a
gate; a red gate stops the phase rather than deferring the problem.**

### P0 — offline de-risking, no kernel code *(mostly done, all rung 1)*

- ✅ **Harness goes aarch64.** Done 2026-08-24, `907efce`.
- ✅ **hrdl's tree is reachable and has not moved.** `v6.19_ebc_custom` tip
  is `819ba1724a6f` — byte-identical to the pin in
  `doc/hrdl-evaluation.md`, so that evaluation is current, not stale.
  `pinenote-dist` cloned to `~/src/reference/` (984 KiB; the register's
  `--depth --single-branch` rule matters — sr.ht silently ignores
  `--filter=blob:none`).
- ✅ **THEIR COMPILER RUNS ON OUR WAVEFORM.** This was the input-format
  risk and it is retired: `wbf_to_custom.py` against this device's own
  2 MiB `ebc.wbf` produces a valid **229,584-byte** `custom_wf.bin`,
  magic `CLUT0002`, **14 temperature bins**, first bin 0–3 °C. We now
  have a reference artifact to differential against.
- **Split cross and native build trees.** Still to do. They share
  `build/` today, and a stale aarch64 `.o` breaks the native link with a
  confusing "file in wrong format" — this bit during the 2026-08-24 probe.
- **Port hrdl's `Sim`** into the harness as a reference model. It is a
  dataclass at `wbf_to_custom.py:29` (`outer`, `inner`, `i`, `phases`,
  `history`) — small.
- ✅ **The CLUT differential is built.** `make clut-check` (2026-08-25):
  byte-identical to `wbf_to_custom.py`, with three mutation controls that
  must differ so identity cannot be accidental. See P1.

**D1 is much cheaper than §D1 estimated.** The compiler is **271 lines**
plus a 334-line `read_file.py` WBF parser — and *we already have the
parser*, in C, tested: `wbf-info --dump-lut` decodes a (waveform,
temperature) LUT to `codes[num_phases][from][to]` and cross-checks itself.
So the C reimplementation is run-length encoding per (from,to) pair plus
`CLUT0002` serialisation **on top of a decoder we already trust**, not
605 lines from scratch. Their Python needs numpy and pandas; ours needs
neither.

**Two things the systemd unit told us that the plan had wrong.**
`pinenote-hrdl-convert-waveform.service` runs the compile, then `mv`, then
**`mkinitcpio -P`**, then `modprobe -r rockchip_ebc; modprobe
rockchip_ebc`.

1. The `mkinitcpio` step is because *their* driver needs the firmware in
   the initramfs. This plan said **"ours may not"**, on the grounds that
   `pinenote-ebc-modprobe-service-type` "loads the module from a shepherd
   one-shot ordered after `pinenote-waveform`". **That is false, and it
   was checked on 2026-08-25 rather than assumed** — see **D7**, which is
   now the blocker this paragraph used to argue away.
2. Their `ExecCondition` is *compile-once-if-absent*, the same shape as
   our waveform installer's "destination exists → exit 0" — which
   `doc/configuration.md`'s neighbour issue #12 §7 already flags as a
   hazard, because a stale artifact then wins forever with no checksum.
   Adding a second derived artifact under the same pattern **compounds an
   existing bug**. Whatever we build should checksum. **Done** — the
   installer keeps a three-line freshness record and rebuilds when any
   line moves (P1, below).

**A safety gap was closed before it could bite** (2026-08-25). The CI
gate grepped `\.wbf$|vcom` and **could not see `custom_wf.bin`** — which
is the same calibration data in another encoding, and falls under the
same never-bundle rule. Extended to match `custom_wf` and to reject any
tracked file carrying the `CLUT0002` magic. Done now, while the count of
such files in existence is still zero.

### P1 — the CLUT compiler (D1) — ✅ **compiler done, gate met, wired into `reader-direct` with the rebind** (2026-08-25)

Write it in C, cross-built like `pinenote-ebc-dump`, run by a one-shot
before the EBC module loads. Differential-test against `wbf_to_custom.py`
on the host at rung 1.

**Gate:** byte-identical `custom_wf.bin` from the C compiler and the
Python one, on a real `ebc.wbf`. Not "equivalent" — identical.

**Met.** `pinenote/tools/wbf/wbf-clut.c` produces a 229,584-byte
`CLUT0002` file byte-identical to `wbf_to_custom.py`'s on this device's
own waveform, on x86-64 and — cross-built as `pinenote-wbf-clut` and run
under `qemu-aarch64` — on aarch64 as well. `make clut-check` is in
`CHECK_HOST_TARGETS`. No Python, no numpy, no pandas: the decode half is
the lineage's own verbatim `drm_epd_helper.c`, exactly as the plan
predicted, and only the run-length + serialisation halves are new.

**The two quirks the plan did not know about.** Byte-identity was not a
formality. `wbf_to_custom.py`'s "remove suffix" step drops the last run
*unconditionally* (an `enumerate`-index/tuple mix-up), and its 32→16 cell
downsample is four-way lossy, order-dependent, and never clears the cell
before writing. Both are reproduced deliberately, both are written up in
`doc/driver-findings-report.md`, and a third finding fell out alongside
them: `drm_epd_helper.c` never applies the `+ 1` to `temp_range_count`,
so the driver cannot select the file's top temperature range. A
clean-room compiler written to what the reference *means* is wrong here,
which is why the gate had to be identity rather than equivalence.

**The installer one-shot exists too, 2026-08-25 — and since the same
date `reader-direct` instantiates it** (it began the day wired into
nothing, which is how the first glass session came to boot an image with
no clut service and do D1 by hand — the release review's top
tag-blocker, now closed). `pinenote/services/ebc-direct.scm` defines
`pinenote-ebc-clut-service-type`: a shepherd one-shot, ordered after
`pinenote-waveform`, that runs `pinenote/services/ebc-clut-install.sh`
with the compiler, the waveform, the destination — and the rebind target
(the driver's sysfs directory and the platform device) as arguments. It
is the analogue of `pinenote-waveform` for the derived file, and it
differs from hrdl's unit in the places that matter:

- **It checksums instead of gating on `test ! -e`.** The stamp beside the
  file records the source waveform's sha256, the compiler's store path,
  and the installed file's own sha256; any of the three moving forces a
  recompile. That closes the stale-derived-artifact hazard issue #12 §7
  names, rather than adding a second instance of it.
- **Its failure paths exit non-zero and say why.** `manuals-stage.sh`
  exits 0 on every failure because a reader without manuals is still a
  reader; a device without a CLUT has no display at all (D4), so this one
  is built to be loud in the boot log.
- **It rebinds the driver after installing** — the D7 answer, added
  after the 2026-08-25 session proved it by hand. Every run that leaves
  a verified CLUT in place ends by re-triggering the probe through the
  driver's sysfs `bind` (unbind first if bound), then checking the end
  state: device bound *and* a DRM minor registered. A rebind that fails
  fails the service; the one legitimate skip — CLUT unchanged, device
  already bound with a minor — is said out loud in the log.

`make ebc-clut-check` runs it — the real file, not a copy — through every
branch against a fake firmware tree and a stub compiler: first run, no-op
when current, recompile on a changed waveform / changed compiler /
corrupted or deleted output, missing waveform, missing compiler, failing
compiler, empty output, unwritable and symlinked destinations, and a host
with no `sha256sum` (which recompiles rather than trusts). The rebind
branches run against a **fake sysfs** — full cycle, said-out-loud skip,
the per-boot bind on a current CLUT, missing driver directory, bound
without a minor, refused unbind, half a rebind target — with the suite
stating exactly what a static fixture cannot re-enact (the bind
transition itself, which glass proved). It carries its own **mutation
control**: a copy of the script with the checksum replaced by upstream's
compile-once-if-absent condition, which the freshness branches must
reject. And it pins the wiring **positively**: exactly the
`reader-direct` flavor instantiates the service — a pin that fires when
the wiring is dropped again, which its negative-form predecessor
("no flavor outside the study…") stayed green through.

**What is still NOT done.** The wired flavor has never booted: the
2026-08-25 session proved the compile-then-rebind sequence by hand on an
image that predated the wiring, and the host suite proves the service
reproduces that sequence — against a stub compiler and a fake sysfs. D4's
first-boot policy for a missing or stale `custom_wf.bin` on a device we
did not set up is still undecided. **No panel has run the
service-driven path.**

### P2 — port the driver onto 7.1.8, behind a flavor

Direct mode only. New flavor (`reader-direct`) alongside the shipping
reader, exactly as `reader-debug` exists today, so the production image
is never the experiment. 3WIN kept buildable (D6).

**Gate:** `make kernel` clean; `make check-host` green with the harness
running aarch64-under-qemu; the drain-gate and ordering negative controls
replaced by whatever the new architecture's equivalents are — **a suite
that goes green because its subject vanished is worse than no suite.**

**Compile gate MET, 2026-08-25.** Grafted his 12 files into a clean
7.1.8 tree and cross-compiled with `aarch64-linux-gnu-`:

- the 366-line patch for the **5 modified files applies clean** — no
  conflicts at all, confirming D5's "the textual surface is nothing";
- **all three objects build in the direct-mode configuration**:
  `drm_epd_helper.o` (25,792 B), `rockchip_ebc.o` (173,296 B),
  `rockchip_ebc_blit_neon.o` (75,528 B, `ELF aarch64 relocatable`), with
  **one** warning (`unused variable 'frame_counter'`).

**What that does and does not prove.** It proves ~4000 lines of his new
code compile against 7.1.8's headers — which is exactly what D5's static
name check could not, since a name can survive while its signature or a
struct layout changes. It does **not** prove the module links, probes,
binds, or works, and the build used arm64 `defconfig` plus minimal
enables rather than our `pinenote_defconfig` alongside our other six
patches. Those are the next steps, not this one.

**Built in OUR kernel package, 2026-08-25.** The compile above used
arm64 `defconfig`; this is the real thing — `pinenote_defconfig`, our
seven patches, his driver, as `linux-pinenote-hrdl-direct` in
`pinenote/packages/kernel.scm` (the `linux-pinenote-debug` shape: inherit,
append one patch).

```
Image                       20,195,840 B
drm_epd_helper.ko               40,368 B
rockchip_ebc.ko                217,152 B
rockchip_ebc_blit_neon.ko       88,184 B
rk3566-pinenote-v1.{1,2}.dtb    63,713 B each
EXIT=0, zero errors, one unused-variable warning
```

**The modules LINK, and modpost resolves the cross-module symbols** —
`rockchip_ebc.ko` imports `rockchip_ebc_schedule_advance_neon` and
`drmm_epd_lut_*` from the other two. That is what an object-only build
cannot show, and it is why his `EXPORT_SYMBOL(pvi_wbf_get_mode_index)`
exists. `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE` lands **off** under
`olddefconfig`, which is necessary given D6.

The swap is `pinenote/patches/linux-pinenote-7.1-hrdl-direct-mode.patch`:
**6194 lines, 11 files**, applying after our seven. One hunk is
hand-merged — his `rockchip/Makefile` context did not match because our
forward-port already adds `rockchip_ebc.o` there. The merge keeps our line
and adds his NEON object with its flags: the blitter needs
`-mgeneral-regs-only` **removed** and `CC_FLAGS_FPU` added, since kernel
code is otherwise built with no FP registers.

**The shipping kernel's derivation is unchanged** — the variant is
referenced only by the `reader-direct` study flavor, and no shipping
flavor's closure contains it.

**One gap found while doing it:** his `v6.19_ebc_custom` branch contains
**no EBC device-tree node** and touches no DTS at all, so it cannot bind
on its own — he must compose branches. It means the third clock the
evaluation cites (`cpll_333m` for direct mode, DTS commit `9444147d35a2`)
is on a branch we have not identified yet.

**That gap is not harmless, corrected 2026-08-25.** The note above said
"for us that is harmless (we have the node)". We have *a* node, and it is
the wrong one: our forward-port's `ebc@fdec0000` declares
`clock-names = "hclk", "dclk"` and nothing else, while his probe does a
hard `devm_clk_get(dev, "cpll_333m")` and `dev_err_probe`s on failure
(`rockchip_ebc.c:2391`). **The module cannot probe on our device tree.**
It is a small DT change, but it is a blocker that has to be named before
P3 step 1, and it is a second reason — alongside `custom_wf.bin` — that
nothing here has been near a panel.

### P2a — module parameters (blocker 1) — **decided 2026-08-25**

A kernel that builds still needs to be *told* something, and our nine
shipped `rockchip_ebc` parameters are aimed at a different driver.

**First, a correction to the premise.** The working assumption was that
our options "would fail the module load". They would not.
`unknown_module_param_cb()` (7.1.8, `kernel/module/main.c:3366`)
`pr_warn`s `unknown parameter '%s' ignored` and **returns 0**. So the
module would load *successfully* with eight of nine intents discarded and
the ninth accepted into dead code. That is strictly worse than a refusal,
and it is the reason this needed a gate rather than a comment.

**The real parameter sets**, derived from `module_param*()` registrations
rather than `modinfo -p` (see below for why that distinction matters):
ours registers **26**, his registers **16** in the configuration we
build. Seven names appear in both (`bw_threshold`, `dclk_select`,
`delay_a`, `hskew_override`, `limit_fb_blits`, `no_off_screen`,
`temp_override`) — but of the **nine we actually ship**, exactly one is
in his set, and it is dead code there.

| our option | fate under his driver |
|---|---|
| `direct_mode=0` | registered only under `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE`, which does not compile (D6) — and inverted in meaning |
| `auto_refresh=0`, `refresh_threshold=60` | gone; he has no threshold-fired auto-global at all |
| `panel_reflection=1` | gone |
| `prepare_prev_before_a2=0` | gone with A2 (D2) |
| `refresh_waveform=6` | gone — his `GLOBAL_REFRESH` is **hard-coded GC16** |
| `defio_delay_ms=250` | gone — no knob; `drm_fbdev_shmem`'s `HZ/20` stands |
| `split_area_limit=0` | **a mirage** — see below |
| `dclk_select=0` | accepted, and never read in direct mode |

**`split_area_limit` is not shared, it only looks it.** `modinfo -p`
prints `parm` modinfo tags, which come from `MODULE_PARM_DESC` — and his
driver carries `MODULE_PARM_DESC(split_area_limit, ...)` on top of
`module_param(limit_fb_blits, ...)`, a description left behind by a
rename. So `modinfo -p` advertises a parameter the module will not accept
and hides the one it will. Transliterating our value into the "renamed"
parameter would be worse than dropping it: `limit_fb_blits=0` means
*allow zero framebuffer blits*, i.e. a panel nothing ever reaches
(`rockchip_ebc.c:1846`). Logged as `doc/upstream-register.md` item 16 and
pinned as `quirk:stale-parm-desc`.

**`dclk_select` is the trap worth reading twice.** It is a real parameter
of his driver, it accepts our value, it appears in sysfs — and
`rockchip_ebc_set_dclk()` returns **before** the `switch (dclk_select)`
whenever `direct_mode` is true, which for us is always. #23's glass
measurement (`dclk_select=1` → `cpll_333m` at 250 MHz → 79.68 Hz) does
not carry over, and the reason is structural rather than a matter of
degree:

| | 3WIN / LUT mode | direct mode |
|---|---|---|
| `SDCLK_DIV` | `pixels_per_sdck - 1` = 7 | **0** |
| `dclk` | 200 MHz (or 250 at `dclk_select=1`) | **34 MHz**, hard-coded |
| panel SDCK | dclk ÷ 8 = 25 MHz (31.25 at 250) | = dclk = **34 MHz** |
| frame rate | 63.7 Hz (79.68 at 250) | **~85 Hz** |

The 33.33 MHz `cpll_333m` in his DTS is not a mistake by a factor of
eight; it is the parent rate for a dclk that has become the source-driver
clock itself. The ~85 Hz the whole swap is for arrives from that line of
`rockchip_ebc_set_dclk()`, with no module parameter involved.

**The decision: the direct-mode options set no parameters at all.** They
carry the `softdep panfrost pre: rockchip_ebc` guard and nothing else.
Every one of his sixteen keeps its driver default, each for a stated
reason recorded in `pinenote/services/ebc-direct.scm`. The two that took
actual argument:

- **`redraw_delay`** — ayakael's `pinenote-dist` ships `redraw_delay=200`
  against a driver default of 0, and that is the *only* one of his four
  shipped options that changes anything (the other three are the
  defaults written out). It schedules a periodic top-up drive of every
  `REDRAW`-hinted pixel, ~2.35 s apart at 85 Hz. We keep 0, because our
  display policy is that **userspace owns every drive** — the same
  2026-07-12 optics finding 10 that makes us ship `auto_refresh=0` —
  and because its power and DDR-fetch cost is unmeasured on the one axis
  with a known silent failure mode.
- **`shrink_virtual_window`** — off, as hrdl ships it. Recorded as the
  *first* thing to try if direct mode shows corruption, since it cuts
  DDR fetch with damage area, but a bring-up default is not where an
  experiment belongs.

**Where it lives, and why not next to the shipping options.** The
service type `pinenote-ebc-modprobe-service-type` gained a real
configuration record with an `options` field, defaulting to the shipping
text — so `base.scm` is unchanged and the reader system derivation is
byte-identical (verified: `f849a8rc…-system.drv` before and after). The
direct-mode value lives in a new `(pinenote services ebc-direct)`, not in
`ebc.scm`, because `make settings-check` requires **exactly one**
`options rockchip_ebc` line in `ebc.scm` — that string has three
build-time copies it holds in agreement, and a second unrelated string
there would break a gate that is right to be strict. Two *service types*
were rejected outright: both would extend `etc-service-type` with the
same `modprobe.d/rockchip_ebc.conf`, so instantiating both collides by
construction. **This is not issue #12 step 3** — no schema, no
validation, no p7 override; it is a Guix-level field where there was a
constructor that ignored its argument.

**Gate:** `make ebc-modprobe-options-check` (in `CHECK_HOST_TARGETS`).
It reconstructs each driver's `rockchip_ebc.c` from its own patch —
verified byte-identical to hrdl's real file, 87,016 bytes — reads the
`module_param*()` registrations with `#ifdef` resolution that **refuses**
rather than guesses at an unknown guard, and checks each options string
against the driver it is for. Since the direct set is deliberately
empty, the load-bearing assertion is the **positive control**: the
*shipping* string, checked against his driver, must be rejected, and it
is — 8 of 9 names unknown. Plus the `quirk:stale-parm-desc` membership
pin, a 3WIN-forced-on control proving the `#ifdef` logic is real, a
sha256 tripwire on the shipping text, and a `guix repl` step that
actually loads the new module (nothing else imports it, so no build
would).

**What this does NOT solve.** Three things, all found while doing it:

1. **On our boot path `/etc/modprobe.d` is nearly inert.** The initrd
   raw-loads `rockchip_ebc`, so parameters land through
   `pinenote-apply-ebc-params` writing sysfs. That one-shot hard-codes
   our nine names and **silently skips** a name whose sysfs file is
   absent, then exits 0. Against his driver it would apply nothing and
   report success. A direct-mode flavor needs its own params one-shot, or
   none — it must not inherit that one unexamined.
2. **`refresh_waveform=6` has no successor.** Global refresh is
   hard-coded `GC16` in his loop. The GL16 wash — no white flash, bought
   with hardware sessions — is a driver change or a CLUT change under
   direct mode, not a parameter. This is D2 becoming concrete.
3. **His fbdev client is forced to `RGB565`.** He calls
   `drm_client_setup_with_fourcc(drm, DRM_FORMAT_RGB565)`; we call
   `drm_client_setup(drm, NULL)`, which takes the plane's preferred
   format — `DRM_FORMAT_XRGB8888`, and KOReader runs
   `framebuffer_linux` on a **32bpp XR24** `/dev/fb0`
   (`doc/koreader-spike.md`). A 16bpp `/dev/fb0` is a different
   framebuffer for every consumer we have. Alongside it, his off-screen
   firmware is `rockchip_ebc_default_screen_x4y4.bin` at one byte per
   pixel where we install a 4bpp `rockchip_ebc_default_screen.bin`, so
   his request misses and he memsets white. Neither is fatal, and
   neither is a parameter.

Nothing here has loaded, probed or bound. It is a configuration derived
from source, gated offline.
**One gap found while doing it, and it is worse than it first read:**
his `v6.19_ebc_custom` branch contains **no EBC device-tree node** and
touches no DTS at all, so it cannot bind on its own — he must compose
branches. This was first recorded as "harmless for us, we have the node".
**That was wrong.** Our node carries two clocks; his probe demands three,
unconditionally, and fails if the third is missing. Chased down and
answered in **D7** — the branch is `v6.19_pn_dts_v2`, the delta is two
lines, and it is not applied.

**The flavor exists, 2026-08-25.** `reader-direct`
(`pinenote/systems/pinenote-reader-direct.scm`, listed in the Makefile's
`FLAVORS`) is the reader image on `linux-pinenote-hrdl-direct`, in
`reader-debug`'s shape: inherit the reader, swap the kernel, rename the
host, add one tool — `wbf-clut`, so the CLUT can at least be compiled by
hand from the console. The shipping reader is untouched and measured to
be: its system derivation is the same store path before and after
(`f849a8rcnwncxpvk4y56p0zlkrjp58ml-system.drv`), and its derivation
closure contains no `hrdl` derivation at all, while `reader-direct`'s
contains `linux-pinenote-hrdl-direct-7.1.8-pinenote.drv`. **It evaluates;
it has not been built, and nothing in it has run.**

**Wiring it turned up an ordering problem P0 got wrong.** P0 guessed our
shepherd ordering "probably accommodates the CLUT compile with no initrd
work", reading `pinenote-ebc-modprobe-service-type` as the thing that
loads the module. It is not — that service only writes
`/etc/modprobe.d`. The module is **raw-loaded by the initrd's pre-mount
hook** (`%pinenote-display-initrd-modules` in
`pinenote/images/pinenote-initramfs.scm`), before the root filesystem is
mounted, and that hook stages `ebc.wbf` and nothing else. So under direct
mode the probe runs, and fails `-EINVAL`, **inside the initrd**, and a
root-filesystem one-shot that writes `custom_wf.bin` afterwards cannot
fix that by itself: something must also reload the module, or the compile
must move into the initrd, or `rockchip_ebc` must come out of the initrd
list for this flavor and be loaded later. Upstream's `mkinitcpio -P` step
followed by `modprobe -r rockchip_ebc; modprobe rockchip_ebc` was not an
Arch quirk — it was this problem, solved twice over. Decide it with D4.

**A smaller correction, to the parameter inventory.** Of the nine options
in `pinenote/services/ebc.scm`, only `dclk_select` is a real parameter of
his module. `split_area_limit` looks shared and is not:
`MODULE_PARM_DESC(split_area_limit, ...)` in his tree is attached to
`module_param(limit_fb_blits, ...)`, so the name reaches `modinfo`'s
`parm:` lines while nothing is registered — there is no
`parameters/split_area_limit` node — and the kernel would **warn and
ignore** it (`unknown_module_param_cb`, 7.1.8
`kernel/module/main.c:3381`), which is worse than a refusal: the
intent is silently dropped. A
`parm:` line is not proof of a parameter.

### P3 — bring-up on glass, one variable at a time

Order matters; each step is a separate session with the 2026-08-07
one-variable protocol:

1. Does it probe and display at all (D4's failure mode is here).
2. Static rendering quality vs the LUT path — optics rig, not a webcam.
3. **Rotation, all four orientations** (D3) — the highest-risk item.
4. Suspend/resume with the ultra matched pair intact.
5. Page-turn latency and quality against today's numbers.

**Gate:** parity with the shipping reader on 1–5 before any ink work.
Ink is the *reason*, but a reader that regresses reading to gain writing
is not a trade this project should make.

### P4 — policy rewrite (D2) — **driven by an on-glass verdict since 2026-08-25**

Re-derive `doc/refresh-policy.md`'s decisions against hints. Rewrite
`device.lua`'s intent mapping. Re-establish the idle washer and
publish-on-call equivalents.

**The P4 driver.** The operator's verdict on the first direct-mode
glass session, watching page turns on video (D4, `doc/status.md`
2026-08-25): **"quality good; more flashing/redrawing per page turn
than a smooth read wants."** That is the pre-registered two-pass +
waveform-class expectation confirmed on glass, and it makes P4 the work
that decides *embrace*: rendering quality is not the problem, drive
policy is. Three separable causes, each with its own fix surface:

1. **Every turn is two passes.** No publish-on-call, and no defio knob:
   his driver has zero references to `defio`
   (`doc/upstream-register.md` item 3), so `drm_fbdev_shmem`'s
   hard-coded `HZ/20` = 50 ms flush window stands, and a page turn's
   damage is split across at least two flushes — two visible drive
   passes per turn, by construction (pre-registered in the deploy
   entry). The shipping driver needed BOTH publish-on-call and
   `defio_delay_ms=250` to reach 8/8 single-pass turns on glass
   (2026-08-01, `doc/refresh-policy.md`); direct mode currently has
   neither. Both mechanisms are ours, small, and port.

2. **The waveform class is untuned, and its per-turn contribution is
   unmeasured.** Under direct mode the waveform class is the per-pixel
   hint bit depth (D2: Y1→DU, Y2→DU4, Y4→GL16), and every pixel no
   `RECT_HINTS` rect covers takes `default_hint` =
   `Y4 | THRESHOLD | REDRAW` (the parameter's driver default). No
   intent mapping exists yet, so nothing reproduces the tuned
   per-intent choices `doc/refresh-policy.md` bought with hardware
   sessions (the wash-promotion threshold, the GL16 global class). The
   shipping record cuts both ways here: shipping's own partials stay
   on the 16-level class *deliberately* (refresh-policy decision 3 —
   DU would corrupt antialiased text) and measured essentially
   flash-free, so the untuned default is a tuning unknown to measure,
   not a proven flashing source.

3. **Washes are hard-coded GC16** — the white-flash class. The shipping
   GL16 wash (no white flash; a policy decision proven on glass) has no
   parameter successor: his `GLOBAL_REFRESH` work item drives
   `ROCKCHIP_EBC_CUSTOM_WF_GC16` unconditionally (P2a gap 2). Under
   direct mode a non-flashing wash is a driver or CLUT change, not
   configuration.

**The tuning surface his driver exposes** — P4 starts from this map,
not from scratch:

| lever | what it moves |
|---|---|
| `default_hint` (module param, mode 0644 → runtime-writable in sysfs) | waveform class + threshold/dither choice + redraw participation for every pixel not covered by a rect |
| `DRM_IOCTL_ROCKCHIP_EBC_RECT_HINTS` | per-rectangle hints, plus `set_default_hint` — the per-region policy instrument, and the successor of our per-refresh waveform choice |
| `DRM_IOCTL_ROCKCHIP_EBC_MODE` | driver mode (NORMAL/FAST/…) and `set_redraw_delay` at runtime — the lever P5 would have KOReader wrap around pen-down/pen-up |
| `redraw_delay` (module param; also via the MODE ioctl) | periodic top-up drive of REDRAW-hinted pixels; ships 0 = off (P2a) |

What has NO knob, and therefore needs code: the defio flush window
(cause 1 — port our `defio_delay_ms` `.fbdev_probe` wrapper and a
publish-on-call equivalent) and the wash class (cause 3 — a driver or
CLUT change, reported upstream per the register either way).

#### File-ready issue text: the two-pass/flashing work item

Written 2026-08-25 so the operator can open it once the session writeup
is reviewed. **Do not open it before then.** Everything between the
rules is the issue body, verbatim; suggested title: *direct mode: page
turns flash and redraw more than the shipping reader (two-pass +
waveform-class policy)*.

---

**Symptom (on glass, 2026-08-25).** First direct-mode session, KOReader
page turns on video: rendering quality is good, but each turn flashes
and redraws more than the shipping reader — the operator's verdict was
"quality good; more flashing/redrawing per page turn than a smooth read
wants" (`doc/status.md`, D4). This was the pre-registered expectation
for an untuned direct-mode image, now confirmed on glass. It is the P4
driver in `doc/direct-mode-adoption.md`, and it gates *embrace*:
reading is the product, and P3's gate is parity with the shipping
reader before any ink work.

**Three separable causes** (source references in
`doc/direct-mode-adoption.md` P4):

1. ~~Two passes per turn~~ **REFUTED on glass 2026-08-26**: ftrace
   shows one flush per repaint — the shim's fsync publishes through
   stock `fb_deferred_io_fsync`, so the port is unnecessary ("or prove
   an equivalent exists": proven). Struck, kept for the record.
2. Untuned waveform class: all damage takes `default_hint`
   (`Y4 | THRESHOLD | REDRAW`) because no intent mapping exists yet —
   nothing reproduces `doc/refresh-policy.md`'s tuned per-intent
   choices. Shipping's own 16-level partials measured flash-free, so
   this cause's per-turn contribution is unmeasured, not established.
3. Washes are hard-coded GC16 (the white-flash class); the shipping
   GL16 wash has no parameter successor — a driver or CLUT change.

**Work items**, in offline-first ladder order:

- [ ] Port the `defio_delay_ms` `.fbdev_probe` wrapper onto the
      direct-mode driver; pin it behind the host suites like the
      original (rung 1).
- [ ] Port publish-on-call (fsync-triggered flush) or prove an
      equivalent exists; keep the flush/EBC-idle semantics honest
      (rung 1, then 4v).
- [ ] Write the intent mapping: KOReader intents →
      `RECT_HINTS`/`default_hint`, re-deriving — not transliterating —
      the `doc/refresh-policy.md` decisions (rung 1; the re-derived
      choices get proven on glass later).
- [ ] Decide the wash: a GL16-class global refresh as a driver change
      vs a CLUT change; either way report upstream per
      `doc/upstream-register.md` rather than quietly forking.
- [ ] Idle-washer equivalent on top of whichever wash lands.
- [ ] One glass session: single-pass turn count (target 8/8, the
      shipping figure), wash behaviour, and the operator's felt verdict
      on video — the 2026-08-25 protocol.

**Acceptance:** page turns on the direct image are single-pass and read
as calm as the shipping reader's to the operator on video, with washes
no flashier than today's GL16 policy — or a recorded decision that a
specific residual is acceptable, and why.

**Non-goals here:** FAST-mode ink (P5), rotation (the D5 chain has its
own item), and anything that changes the shipping reader.

---

### P5 — FAST mode and ink

Only now does the thing we came for get built: `DRIVER_MODE_FAST` for
pen-down rendering, stroke capture on top of it. #20's capture, storage
and vectorization work is **independent of all of the above** and can
proceed in parallel from day one — it needs no panel.

## §7. A question on the record, not a plan: does this need to be in the kernel?

**Status: question. Explicitly not being acted on** (operator, 2026-08-25).
Written down before the first glass session so the session can collect its
one datum (D9), instead of the question being reconstructed afterwards.

Direct mode makes the silicon's LUT and diff engines unused: the
hardware's whole job is to DMA-scan a phase buffer and raise a per-frame
IRQ. Everything else — the waveform state machine, CLUT walk, early
cancellation, dithering, the fb→Y4 blits — is pure computation over
memory, and **in his driver it already runs in a kthread, not interrupt
context**. The seam exists; it is drawn on the kernel side of the
syscall boundary, not forced there.

The irreducible kernel core is small: probe/clocks/regulators and
tps65185 sequencing, IRQ ack + frame-done signalling, DMA-able
phase-buffer allocation + the scanout kick, and a minimal blank/INIT
path so panic output never depends on a daemon. A few hundred lines.
The other ~3,500 could be a userspace RT thread over mmap'd buffers —
double-buffered, needing only to stay one frame ahead; a missed deadline
repeats a phase buffer (a one-frame stall, not corruption).

**Why the cost may be low for us specifically:** we already ship
PREEMPT_RT (the scheduling guarantee this needs, hardware-proven); the
reMarkable 2 runs a userspace software TCON at envied pen latency on a
weaker CPU; NEON in userspace is *easier* (no `scoped_ksimd`, no
`-mgeneral-regs-only`, and it opens Mali/NPU doors kernel code cannot);
`request_firmware` becomes "open a file", dissolving the CLUT-install
and initramfs machinery this plan just built; module parameters become
configuration in #12's system, dissolving the silent-unknown-param
class; and the offline harness stops needing `kernel-shim.h` at all —
userspace waveform code is its own harness. It also continues the
project's actual trajectory: `auto_refresh=0` ("own all washes from
userspace"), publish-on-call, and the idle washer already pulled
*policy* up; this would pull *mechanism* up.

**The honest costs:** the display becomes daemon-critical (watchdog +
kernel blank path required); suspend/resume ordering moves to shepherd
(more of the 2026-07-12-wedge class); loss of fbcon/standard KMS on the
panel without a dumb-framebuffer fallback; and the strategic one — **we
would own the architecture again**, when the point of adopting hrdl's
tree was to stop being a driver-innovation shop. (Mitigation: the
`advance()`/blit code would still be his, relocated; and a thin kernel
driver is arguably *more* upstreamable than either full driver.)

**It reframes embrace-or-reject into a possible third outcome**: adopt
his *computation*, not his *residence*. Nothing in the glass session is
wasted under that outcome — P3 validates his math and scheduling on real
glass, which is exactly the part that would move, unchanged.

**The one datum that decides feasibility** is the measured per-frame
`advance()` cost on the RK3566. His driver already instruments it
(`delta_advance`, `rockchip_ebc.c:1134–1202`). That is glass-plan item
**D9**: harvest it during whatever D4–D8 activity runs. Against an
11.7 ms frame budget at 85 Hz, that number — plus context-switch and
wake-up jitter under PREEMPT_RT, which we can measure offline — is the
whole question.

## What only hardware can answer

Everything in P3, plus: whether FAST mode's 1-bit output and visible
smear are acceptable for ink in practice; whether 85 Hz is stable on this
panel; and whether the 6×-lower DDR fetch actually removes the starvation
margin or merely moves it.

## Bail-out criteria

State these now, while nobody is invested:

- P0's differential does not converge → we do not understand the
  waveform format well enough. Stop.
- P3 step 3 (rotation) cannot be made to work → the shipped
  four-orientation feature regresses. Stop, or descope orientations
  deliberately.
- P3 step 5 shows page-turn quality worse than today with no path back →
  stop; reading is the product.

Direct mode is a means to handwriting, not an end. If it costs the
reader, it is the wrong trade and the plan should die here rather than
be defended.
