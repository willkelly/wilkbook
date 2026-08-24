# hrdl's kernel stack — adoption evaluation and methodology comparison

Status: evaluation complete, 2026-07-12. This is a **standing
reference** (the §3 cherry-pick decisions and the §3.3/§5
corruption-hunt strategy are cited as current by other docs), not an
archive candidate. Method per `doc/worked-examples.md`
case study 1: every load-bearing claim below was verified against fetched
source (shallow git fetch of `git.sr.ht/~hrdl/linux` branches
`v6.19_pinenote` @46028a0e2658, `v6.19_ebc` @7cb827d1730f,
`v6.19_ebc_custom` @819ba1724a6f, `latency_printk` @f7106e64afce; a full
clone of `~hrdl/pinenote-dist` @3e228db; ayakael's pmaports
`device/community/device-pine64-pinenote` pkgver 11 and
`linux-pine64-pinenote` 6.19.3 via the GitLab API), not folklore. Web
sources (pine64.org documentation, monthly updates) are cited where used;
the pine64 forum and Matrix hold essentially no technical hrdl content —
his public record is his git history. Commit SHAs are from his tree.

Companion docs: `doc/eink-research.md` §8 (the 2026-07-11 sweep this
deepens), `doc/kernel-forward-port.md` (the 2026-07-04 cherry-pick
record), `doc/driver-findings-report.md` (our findings; the corruption
investigation), `doc/refresh-policy.md` (decisions this would affect).

## Corrections from the 2026-08-24 re-read (tip 819ba1724a6f, re-verified)

Re-read against a fresh shallow clone when interactive refresh became an
active question (issue #20, ink). The branch topology, architecture, UAPI
table, bug-class analysis and the §5 corruption-hunt strategy all still
check out. Four corrections, most consequential first:

1. **§1.2 attributes the 85 Hz to the panel-simple mode. It does not come
   from there.** `70cbadbce9ab` adds an 85 Hz entry, but
   `DRM_MODE_TYPE_PREFERRED` remains on the 40 Hz one and
   `rockchip_ebc_crtc_atomic_check` overwrites `mode->clock` with whatever
   `rockchip_ebc_set_dclk()` achieved. The mode list is decorative -- the
   same conclusion this repo already reached for its own driver. The rate
   actually comes from `SDCLK_DIV` and a `cpll_333m` reclock:

   | | mechanism | sdck | rate |
   |---|---|---|---|
   | ours | dclk 200 MHz, SDCLK_DIV=7 (/8) | 25 MHz | **63.744 Hz** |
   | hrdl LUT/3WIN | cpll_333m->250, dclk->250, /8 | 31.25 MHz | **79.68 Hz** |
   | hrdl direct | cpll_333m->33.33, dclk->34, **/1** | 33.33 MHz | **84.99 Hz** |

   His `9444147d35a2` message states the /1 trick is undocumented in the
   RK3568 TRM, reverse-engineered from the Lenovo Smart Paper, and that
   "LUT mode and 3WIN mode are not compatible with this setting". So
   **85 Hz is structurally direct-mode-only; 79.68 Hz is not.**

2. **The clock work is SEPARABLE, and `doc/refresh-policy.md` writes off
   the lever it enables.** That document's timing correction says
   `dclk_select=1` is a no-op because `DCLK_EBC` is a divider-less mux
   over {400, 333, 200} -- true, and the reason is that nothing reclocks
   the mux parent. `CPLL_333M` is `COMPOSITE_NOMUX` off cpll with its own
   divider, so setting it to 250 MHz first lets the EBC mux select 250
   exactly. Cost: ~2 DT lines + ~10 driver lines. Gain: 1.25x on every
   mode we ship (GL16 596 -> 477 ms, A2 157 -> 126 ms) and 94% of the
   waveform's authored rate instead of 75%. **Gated on DDR** -- EBC fetch
   rises ~335 -> ~419 MB/s on the path the 2026-08-07 A/B proved starves
   silently at 324 MHz. Not to be shipped on arithmetic.

3. **`ROCKCHIP_EBC_DRIVER_MODE_FAST` is named in the UAPI table and
   nowhere else, and it is the interesting one.** It is a separate
   scheduler, not a parameterisation: no hints, no LUT walk, every pixel
   binary from two precomputed constants, and cancellation is
   **unconditional** (`q8_cancel = q8_start & ~q8_idle_finish`, no
   `can_cancel` gate). ~11.7 ms to first motion at the cost of 1-bit
   output and visible smear. §1.2's cancellation paragraph describes only
   the NORMAL-mode variant, which is gated to binary-pixel DU->DU
   transitions -- **a Y4 GL16/GC16 transition cannot be aborted in his
   driver either.**

4. **§3.2's "not separable" list is too broad.** Three items are
   independent of `custom_wf.bin`, the NEON blitters and direct mode: the
   clock reclock (above); the **work-item drain gate** (he stops folding
   new damage in once a work item is pending, so the pipeline drains and
   the global launches -- ~5 lines, and the structural fix for the
   sustained-damage lesson we currently handle by procedure); and
   `shrink_virtual_window` (ships default-off in his tree, so treat as
   experiment, not cherry-pick).

   **The drain gate is ADOPTED (2026-08-24, issue #22.)** Taken as
   described above and adapted to this driver's area list rather than his
   clip list: one `rockchip_ebc_work_item_pending()` helper read per
   frame, gating only the mid-frame `ctx->queue` splice. Two things the
   re-read did not say and that adopting it surfaced. First, the predicate
   has to include `kthread_should_park()`, not just the pending global:
   `rockchip_ebc_quiesce_worker()` blocks in `kthread_park()`, so the same
   starvation stalls a **system suspend**, which is the worse half of the
   bug on a battery-powered device. Second, "stop folding new damage in"
   must NOT be read as gating the `frame == 0` splice — that one is the
   refresh's own starting set, and gating it turns a partial into a
   zero-frame no-op whenever the flag is set at entry. Offline evidence,
   caveats and what remains unproven: `doc/driver-findings-report.md`
   (2026-08-24 update block). The ~5-line estimate held.

**Also worth carrying:** direct mode's phase buffer is 2 bits/pixel, so
it fetches ~56 MB/s against 3WIN's ~335 MB/s -- roughly **6x less** DDR.
Given that our one confirmed EBC failure mode is DDR starvation of the
phase fetch, that reads as an argument *for* direct mode rather than a
hazard, and it changes how §3.1's tradeoff should be weighed.

**Cancellation, FAST, hints, `redraw_delay` and the CLUT remain
inseparable** -- all require the driver to own per-frame phase bytes,
which 3WIN/LUT mode cannot express (one hardware phase counter per
scheduled area; no register says "this pixel is 6 frames into a different
transition"). §3.1's rejection of the full swap therefore still stands on
its strongest ground: the verbatim host harness and `ebc-replay` both
stop compiling on x86.

**Trigger status.** §3.1 said to re-evaluate "when the corruption hunt
closes, when pen latency becomes the active track ... or when a community
rebase forces a structural decision." The first two have now fired.

## 1. What the rewrite actually is (from source)

### 1.1 Branch topology — there are two drivers, and he maintains both

- `v6.19_pinenote` (tip 46028a0e2658, `6.19.r349` in his PKGBUILD) is the
  integration branch: octopus-merges of ~15 topic branches. It merges
  **both** EBC branches; the ship driver is the custom one.
- `v6.19_ebc` is the **m-weigand-lineage legacy driver** rebased to 6.19.
  Verified: it is our driver. A diff against our verbatim extraction is
  159 lines — our two 2026-07-04 ports (fsleep, dma_sync shrink), our
  stubbed `EXTRACT_FBS` (his legacy branch implements it:
  prev/next/final + both phase buffers), `DRM_AUTH` vs `DRM_RENDER_ALLOW`
  on the ioctls, and an area-split error-handling hunk where the legacy
  code still says `// TODO: Error checking!!!!`. The module-parameter
  surface is **identical**, including `globre_convert_before`.
- `v6.19_ebc_custom` is a **76-commit rework stacked on top of the legacy
  branch** (merge-base is `v6.19_ebc` itself). The headline commit is
  de92966ba13a *"rework driver to allow operating at 60–85 Hz"*.

### 1.2 The custom driver's architecture

Four files: `rockchip_ebc.c` (~87 KB), `rockchip_ebc_blit_neon.c`
(~45 KB), `rockchip_ebc.h`, `include/uapi/drm/rockchip_ebc_drm.h`.

- **Per-pixel scheduling.** 3 bytes of state per pixel
  (`packed_inner_outer_nextprev`): an inner counter (2-bit drive phase +
  last-flag + 5-bit repeat count), an outer position into the LUT
  sequence, and packed (next, prev) Y4 nibbles. One NEON `advance`
  function per frame does scheduling, waveform playback, early
  cancellation, and next/prev bookkeeping for every pixel in the ongoing
  clip. There are no damage areas, no area queue, no `split_area_limit`,
  no per-area windows — collisions cannot exist because state is
  per-pixel.
- **Software TCON (direct mode is the default).** `direct_mode=true`
  (3WIN mode survives only behind `CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE`).
  The driver computes 2-bit drive phases in software into double-buffered
  phase buffers (4 px/byte) and the controller scans them out raw; the
  silicon's LUT and diff engines are unused. The EBC node gains a third
  clock (`cpll_333m`, set to 33.33 MHz for direct mode — DTS commit
  9444147d35a2), and an added 85 Hz panel-simple mode (70cbadbce9ab).
- **Offline-compiled waveform (`CLUT0002`).** The kernel no longer walks
  the PVI tables at refresh time. Userspace (`wbf_to_custom.py` in
  pinenote-dist) decodes the device's own `ebc.wbf` and compiles a
  run-length LUT: per temperature bin, 6 sequences × 16×16 (from, to)
  pairs × ≤64 (phase, repeat) entries. The 6 sequences are **DU, DU4,
  GL16, GC16, INIT, WAITING** — **A2 is dropped entirely** (DU + early
  cancellation replaces it; fecc056629a9 implemented cancellation *for*
  A2 first, then A2 was folded into DU). Leading/trailing neutral frames
  are trimmed at compile time. The driver `request_firmware`s
  `rockchip/custom_wf.bin`, validates magic and size, and **probe fails
  with -EINVAL if it is absent**. `ebc.wbf` is *also* still required
  (`drmm_epd_lut_file_init` runs unconditionally). Same
  never-bundle-the-waveform stance as ours, now with a derived second
  artifact.
- **Hints instead of global mode params.** Each pixel carries a hint
  byte: bit depth (Y1/Y2/Y4), THRESHOLD vs DITHER, and REDRAW. Bit depth
  *is* the waveform choice: Y1→DU, Y2→DU4, Y4→GL16 (verified in
  `schedule_advance_neon`: `wf_target = (hints >> 4) & 3`). Hints are set
  per-rect from userspace (`RECT_HINTS` ioctl) or default from the
  `default_hint` param. Dithering (Bayer, blue-noise 16/32 — textures in
  the driver, 4e6f4f4fffea) and thresholding happen in the NEON blitters
  at fb-blit time, producing a packed (prelim, target) pair per pixel.
- **"Fast now, clean later" (`redraw_delay`).** A REDRAW-hinted pixel
  first draws its binarized `prelim` with DU (the comment in the
  scheduler: "Prelim uses waveform DU=0"), then enters the WAITING
  pseudo-waveform — which `rockchip_ebc_change_lut` rebuilds as
  `redraw_delay` hardware frames of neutral — and on WAITING expiry
  reschedules the true Y4 `target` with the quality waveform. The delayed
  quality repaint is literally just another LUT sequence. pinenote-dist
  ships `redraw_delay=200` frames ≈ 2.35 s at 85 Hz; the in-driver
  default is 0, which disables redraws (the hint is masked off).
- **Early cancellation.** An in-flight DU update on a binary pixel whose
  target changes is cancelled by truncating its inner counter, plus
  `early_cancellation_addition` (default 2) extra frames of drive. This
  is the pen/scroll latency win, and it is also why the tree carries the
  temperature clamp (see §2.3).
- **The refresh loop.** One frame loop for everything
  (`rockchip_ebc_partial_refresh`): triple-buffered
  (prelim_target, hints) between `atomic_update` and the thread; new
  damage is folded in mid-frame during the scanout dead time; work items
  (global refresh, LUT change, INIT, suspend, mode changes) are queued
  under `work_item_lock` and **consumed only when `clip_ongoing` is
  empty** — a global refresh structurally cannot launch while frames are
  in flight. A global schedules the whole screen with **forced GC16 +
  REDRAW**; there is no waveform choice for washes. The thread idles
  after `refresh_thread_wait_idle` (2 s) and the device runtime-suspends
  (autosuspend delay 2 s); resume fires a full GC16 wash.
  The per-frame handshake is still a counting `display_end` completion
  with the same 25 ms `EBC_FRAME_TIMEOUT` and the same "Frame %d timed
  out!" log, and there is **no `reinit_completion` anywhere** — a
  straggling DSP_END still credits the next wait one frame early. The
  blast radius is one phase-buffer write racing a scanout, not a
  truncated global; the quirk-F *class* (handshake fragility) is milder
  here but not zero.
- **Temperature.** Still `devm_iio_channel_get` (our tps65185 IIO hunk
  remains load-bearing under any adoption), polled by a dedicated thread
  every 10 s; LUT-bin switches queue a CHANGE_LUT work item that also
  resets all pixels to IDLE (the 7e85b4ff0eac fix we rejected on
  2026-07-04 — correctly: it resets *his* per-pixel state). And the
  clamp: `temperature = max(temperature, 19)` is **still live** in the
  current custom driver, commented "Early cancellation is broken right
  now for lower temperatures". His stack discards every cold temperature
  bin; ours plays the 131-phase 0 °C GC16 correctly (pinned by the
  `wbf cold:` test).
- **fbdev.** `DRM_FBDEV_SHMEM_DRIVER_OPS` (6e15e1e486d3, "to allow fbdev
  emulation") — /dev/fb0 exists; plane formats XRGB8888, RGB565, **R8**
  (native 8-bit gray — interesting for a future KOReader path). Damage
  clips honored; all clips 16-px aligned and merged to one bounding rect
  per buffer generation (cheap, because unchanged pixels schedule
  nothing). `panel_reflection` is gone as a param — the horizontal flip
  is unconditional in `atomic_update` and the blitters.

### 1.3 UAPI: 7 ioctls, and what survives from ours

| ioctl | nr | ours (7.0 port) | his custom driver | compat |
| --- | --- | --- | --- | --- |
| GLOBAL_REFRESH | 0x00 | IOWR, `{bool}` | IOWR, `{bool}` | **byte-identical** — idle-washer, deep clean, KOReader promotion all work unchanged |
| OFF_SCREEN | 0x01 | IOWR, `char *` | IOW, `__u64` ptr, reworked | different cmd word; we don't use it |
| EXTRACT_FBS | 0x02 | stubbed -EOPNOTSUPP | 5 NULL-able buffers: per-pixel scheduler state, hints, prelim/target, both phase buffers | different struct; ours is dead anyway |
| RECT_HINTS | 0x03 | — | per-rect hint bytes + default | new |
| MODE | 0x04 | — | driver mode (NORMAL/FAST), dither mode, redraw_delay | new |
| ZERO_WAVEFORM | 0x05 | — | drive-nothing mode toggle | new |
| PHASE_SEQUENCE | 0x06 | — | play raw phase sequences per region (§4.1) | new |

Module parameters are a clean break: `default_waveform`, `diff_mode`,
`auto_refresh`, `refresh_threshold`, `refresh_waveform`,
`split_area_limit`, `panel_reflection`, `bw_mode`, `fourtone_*`,
`prepare_prev_before_a2`, `globre_convert_before` all **do not exist**;
new surface is `default_hint` (dist ships `0xa0` = Y4|REDRAW),
`redraw_delay`, `early_cancellation_addition`, `dithering_method`,
`shrink_virtual_window`, `refresh_thread_wait_idle`, `y2_dt_thresholds`,
`y2_th_thresholds`, plus carried-over `bw_threshold`, `dclk_select`,
`temp_override`, `hskew_override`, `limit_fb_blits`, `no_off_screen`.

Userspace reference (pinenote-dist): `sway_dbus_integration.py` maps
`app_id`→hint over sway IPC (`mpv`: Y1|DITHER, `kitty`: Y2|REDRAW,
`xournalpp`/`firefox`: Y4|REDRAW, **`KOReader`: plain Y4, no REDRAW** —
the reader manages its own quality); default Y4|REDRAW.
ayakael's postmarketOS packaging (pmaports `device-pine64-pinenote`,
kernel `linux-pine64-pinenote` 6.19.3, built as *vanilla tarball + one
generated patch* from his fork — structurally our approach) compiles
`custom_wf.bin` from the device's own waveform partition on first boot
(`pinenote-init-waveform.initd`: extract → `wbf_to_custom.py` →
mkinitfs → module reload), and carries the workaround we noted in
`doc/eink-research.md` §8, verbatim in the APKBUILD: "rockchip_ebc
sometimes fails to load the initial waveform. This forces a reload
before starting tinydm".

## 2. Does the rewrite eliminate our bug classes?

Grep-proof up front: `auto_refresh|refresh_threshold|area_count|
one_screen_area` — **0 hits** in his custom driver, 17 in ours. There is
no threshold path, no damage accumulator, no auto-global of any kind.
Ghost control is per-pixel REDRAW instead of periodic washes.

| our finding | in his custom driver | in his legacy `v6.19_ebc` |
| --- | --- | --- |
| 1. `blit_pixels` odd-`x2` heap overrun | code replaced (NEON blitters, 16-px aligned clips). Historically **confirmed and fixed by hrdl** — 11c358d1ca7a (2025-01-09) fixes exactly our byte: `*(dst_line + width - 1)` instead of `dst_line + pitch - 1`, *and* the odd-`x1` src/dst confusion (our finding-7 leak) — but only on the custom stack | **still present** |
| 2. `schedule_area` ignores `do_not_start_before_frame` | scheduler deleted; per-pixel state cannot express overlapping windows. Historically **confirmed and fixed by hrdl** — 59b2113e8b9c (2025-01-09) "fix scheduling issues due to overlapping areas": both the begin-together and wait paths now respect `do_not_start_before_frame`, plus off-by-one and `drm_rect_overlap` semantics fixes | **still present** |
| 3. `ctx_free` UAF | no queue in ctx at all — class gone | **still present** (`list_for_each_entry` + kfree) |
| 4. direct-mode LUT transpose | moot differently: his direct mode plays the CLUT per pixel in software; the transposed packed-LUT blit path doesn't exist | still present (latent) |
| 5–7. blit edge quirks | blitters rewritten in NEON; old quirks gone, **new code entirely unpinned** (no test harness exists for it) | still present |
| portrait wedge (2026-07-11) | **unknown.** The machinery plausibly involved on ours (hw diff/3WIN windows, area queue) is absent in direct mode, but this is an inference, not a test. Nobody rotates via fbdev on his stack (sway does transforms) | presumably shared |
| threshold auto-global / quirk F | **structurally absent** — no threshold path, and work items only launch when the pipeline is drained, so no zero-gap global launch exists. Caveat: the counting `display_end` + 25 ms timeout fragility is still there (§1.2), with a one-frame blast radius | identical to ours |
| temp compensation | kept (IIO + bins) but **clamped ≥19 °C** — a regression vs our validated cold-bin behavior | full range, like ours |

Two takeaways. First, the rewrite genuinely eliminates the classes we've
been pinning — not by fixing them but by deleting the code that hosts
them; in exchange you get ~130 KB of new, harness-less NEON code whose
latent bugs nobody has enumerated. Second, hrdl **independently hit and
fixed findings 1, 2 and the finding-7 leak in January 2025**, as
transitional commits on the custom stack, and never backported them to
the legacy branch he still maintains — which is exactly the branch
ayakael's *legacy* users and PNDeb's users run, and byte-for-byte our
driver. This is strong corroboration for our findings report, and it
means authored, field-tested fix diffs already exist for our quirks 1, 2
and 7 (translation targets, with his SHAs as provenance).

## 3. Adoption options

### 3.1 Option (a): full driver swap onto our 7.0.x

What it takes, concretely:

- **Patch surgery**: replace one file with four (driver, NEON unit,
  header, new UAPI header), Makefile/Kconfig hunks (NEON object with
  `CC_FLAGS_FPU`, the 3WIN Kconfig option 3bb1a43638cb), the DTS delta
  (`cpll_333m` third clock on the EBC node + `CPLL_333M` plumbing), the
  85 Hz panel-simple mode. `drm_epd_helper` stays (still loads
  `ebc.wbf`). Our tps65185 IIO hunk stays. Rebase-fragility roughly
  comparable to today — the rework is self-contained — but the patch
  grows ~50%.
- **`scoped_ksimd()`**: present in 7.0.x (his tree converted to it at
  819ba1724a6f). But his defconfig does **not** set PREEMPT_RT — we
  would be the first to run the NEON scheduler under RT, where
  `scoped_ksimd` regions are preemptible mid-frame
  (`doc/eink-research.md` §6 watch item goes live).
- **Waveform pipeline**: the initrd/one-shot flow must additionally
  produce `custom_wf.bin` from the device's own `ebc.wbf`
  (ayakael's first-boot recipe is the reference; `wbf_to_custom.py`
  needs python3+numpy on device, or we re-implement the compiler in C —
  we already have the decode logic in `pinenote/tools/wbf`).
  Never-bundle is preserved: it's a derived per-device artifact. Probe
  fails visibly without it, matching our fail-visibly stance.
- **Host tools — the big one.** `ebc-logic` rung 2/7a and `ebc-replay`
  compile the *verbatim* driver on x86. The custom driver's hot paths
  are aarch64 NEON intrinsics: **the entire offline refresh-machine
  harness and the replay workbench stop compiling on the workstation.**
  Recovery options, none cheap: cross-compile the harness aarch64 and
  run under qemu-user (feasible — we cross-build kernels — but rebuilds
  the harness execution model), or an x86 NEON-emulation header
  (sse2neon-style; large, subtle, and now the harness tests an
  emulation). rastersim's LUT-playback differential loses its subject
  (no hardware LUT in direct mode) but its independent waveform decode
  becomes the natural cross-check for the CLUT compiler. The
  `koreader-input` harness and rung 4/4v are unaffected.

  **[Probe, 2026-08-24 — this objection is much weaker than written.]**
  The recovery was called "none cheap". It was measured instead of
  estimated, on the CURRENT driver, and it costs **one typedef**.

  `guix shell` supplies `cross-gcc`/`cross-libc`/`cross-binutils`/
  `cross-kernel-headers` for `aarch64-linux-gnu` with nothing to build
  but a profile derivation, and `qemu-aarch64` (user mode) ships in
  Guix's `qemu`. With those:

  | | |
  |---|---|
  | `ebc-drain-gate-test` cross-built, run under qemu-user | **31 PASS / 0 FAIL, EXIT=0** — identical to native |
  | `ebc-refresh-test` **with AddressSanitizer** | **148 PASS / 0 FAIL, EXIT=0** |
  | wall time, same test | native 22 ms → qemu **65 ms (~3x)** |

  The only source change needed was `shim/kernel-shim.h`'s `__u64`:
  `uint64_t` is `unsigned long` on aarch64, and glibc's `<signal.h>`
  pulls in the real `asm/sigcontext.h` → `linux/types.h` →
  `asm-generic/int-ll64.h`, which types `__u64` as `unsigned long long`.
  Matching the kernel is strictly more correct and is native-neutral
  (`make check-host` EXIT=0, 3073 PASS, unchanged).

  Two real costs remain, and neither is the harness:

  - **LeakSanitizer does not work under qemu-user** (it needs ptrace-like
    introspection). `ASAN_OPTIONS=detect_leaks=0` is required; ASan's
    *memory-error* detection is unaffected. Exit-time leak checking is
    genuinely lost on this path.
  - **qemu emulates NEON**, so a harness run there tests ASIMD through an
    emulator. That is the same class of objection raised against an
    sse2neon shim — but qemu's ASIMD is vastly more exercised than a
    hand-rolled header, and unlike the shim it needs no code we maintain.

  **What this does and does not prove.** It proves the execution model
  survives cross-compilation and emulation for the *current* driver. It
  does **not** prove hrdl's NEON hot paths run correctly under qemu —
  nobody has compiled them. But the objection was that the harness would
  not exist at all on an x86 workstation, and that is now false: the
  binary runs as aarch64, so NEON intrinsics compile for their real
  target and execute under an emulator that supports them.
- **Policy/UX stack**: `GLOBAL_REFRESH` and the idle-washer survive
  unchanged, but **every wash is GC16** — there is no
  `refresh_waveform`, so Decision 2 (GL16 washes) has no equivalent; the
  GL16/GC16 distinction moves into partial hints (Y4 partials *are*
  GL16) plus REDRAW. Decisions 1/3/4 and the washer's debt model would
  be re-derived around `redraw_delay`/hints. The `pinenote-ebc-params`
  one-shot and the optics harness's param-flip protocol
  (`auto_refresh`, `refresh_threshold`, `default_waveform`,
  `refresh_waveform`, `bw_mode`) are all replaced by MODE/RECT_HINTS
  ioctl calls. KOReader's fbdev target keeps working (fbdev emulation +
  `default_hint`); rung-4v and the trace format keep working.
- **Known regressions imported**: the ≥19 °C clamp (we'd carry a revert
  and re-validate cancellation in cold bins, or accept losing cold
  operation); A2 gone (we ship A2-capable policy surface, currently
  unused); and an unpinned driver (all seven of our quirk tests and the
  rung-7a state-machine assertions describe code that no longer exists).

**Verdict: not now.** The swap deletes bug classes we have already
mitigated in policy (`auto_refresh=0` costs us nothing; the washer owns
cadence) at the price of invalidating the two assets that make this
project workable offline — the verbatim host harness and the replay
workbench — mid-way through an open corruption investigation *on the
current driver*. Re-evaluate when the corruption hunt closes, when pen
latency becomes the active track (the rework's raison d'être — 60–85 Hz,
early cancellation, in-driver dithering — is pen/scroll, where our
lineage is structurally weaker), or when a community rebase forces a
structural decision anyway. The ecosystem signal is real: ayakael ships
the custom driver in postmarketOS community; the legacy lineage's
remaining users are PNDeb/Debian and us.

### 3.2 Option (b): cherry-pick separable mechanisms

Separable and worth taking (in ladder order, harness-first):

1. **Finding-2 fix** (59b2113e8b9c) — translates to our
   `schedule_area`; our deterministic reproducer
   (`test_schedule_quirk_begin_together_conflict`) is the ready-made
   gate: red today documenting the quirk, green after the translation.
   Per the no-silent-driver-fix policy this goes to the lineage as a
   report + proposed patch citing hrdl's SHA, and lands in our tree as a
   pinned carried fix once acked (or sooner if §5's workbench work
   implicates it in the corruption).
   **LANDED 2026-07-12** as the minimal (Option B) translation — dead
   zone honored, monotone waits, end-exclusive windows; the commit's
   containment-drop removal rejected — pins flipped; see
   `doc/kernel-forward-port.md`'s cherry-pick record.
2. **Finding-1/7 fix** (11c358d1ca7a) — same shape, same gates (the
   `quirk:` blit tests).  **LANDED 2026-07-12**, applied verbatim.
3. **EXTRACT_FBS restoration** in the debug kernel only: his *legacy*
   branch implementation (prev/next/final + both phase buffers,
   NULL-able pointers per the custom UAPI's pattern) is a direct
   reference for un-stubbing ours — the
   `doc/kernel-forward-port.md` observability wishlist item, and the
   decisive instrument for the reopened corruption hunt (§5).
   **LANDED 2026-07-12**: `linux-pinenote-debug-extract-fbs.patch` plus
   the ebc-dump grab/decode pair, offline-proven by the ebc-logic dbg
   suite; four defects found in his reference implementation, corrected
   in our port and reported (findings report, EXTRACT_FBS note). The idle
   `--verify` device smoke passed under the live DRM master on 2026-07-13;
   a mid-scribble dump and camera correlation remain.
4. **Blue-noise dither tables** (4e6f4f4fffea) — verbatim constants,
   relevant only if we ever enable `bw_mode` dithering; zero risk to
   carry in the toolbox.
5. **Delayed-quality-redraw as userspace policy** — already on the
   ROADMAP idea list from the §8 sweep; needs no driver change (fire a
   DU-class partial, then re-damage the same rect after settle for a
   quality pass), and `ebc-replay` can cost it offline first.

Not separable: per-pixel scheduling, early cancellation, `redraw_delay`
in-kernel, the CLUT format, the NEON blitters — that package *is* the
rework; taking any of it means option (a).

### 3.3 Option (c): stay and harden — **recommended**

Keep the m-weigand lineage on 7.0.x. Land the findings report upstream
with the new corroboration (§2's fixed-in-January-2025-but-never-
backported evidence strengthens it and gives the lineage ready diffs for
quirks 1, 2, 7). Take option (b)'s items 1–3 through the ladder. Track
`v6.19_ebc` as the rebase reference for our driver copy (it *is* our
driver) and `v6.19_ebc_custom` as the reference for where the community
UAPI is going. Keep `auto_refresh=0` + ioctl-owned washes (finding 10's
policy consequence), which independently matches hrdl's design judgment:
his rewrite deleted driver-initiated washes entirely.

## 4. Methodology: how hrdl validates display work vs how we do

### 4.1 His toolkit (everything found, with evidence)

- **In-driver frame-budget telemetry.** The refresh loop timestamps
  every frame's advance/sync/wait phases and emits per-second
  min/max/rate stats via pr_debug (521a0d725aa7 "provide detailed timing
  stats for partial refreshes", d143fc358d29 "record time for first
  frame separately", ef5c9a658155 "fix frame time measurements and
  switch to us"). This is how "60–85 Hz" is a measured claim inside the
  driver, not a vibe.
- **A dedicated instrumentation branch** (`latency_printk`), kept
  rebased alongside the real branches — his analogue of our
  `linux-pinenote-debug` flavor. It carries: pr_debug markers when
  damage crosses the screen's center column at `atomic_update` and when
  the center pixel first gets non-neutral phase data at blit
  (ae5b2524e56c) — timestamped input→blit→drive latency decomposition;
  a **BPF kfunc `bpf_rockchip_ebc_draw(x, y)`** to inject draw
  coordinates into the driver directly from an input-event BPF program
  (f7106e64afce), bypassing the compositor for floor-latency
  measurements; DRM/EBC/IIO switched built-in for early tracing; and a
  compile-gated blit/frame-number consistency check
  (`check_blit_frame_num`).
- **Driver-state ground truth on demand**: the EXTRACT_FBS ioctl dumps
  the complete per-pixel scheduler state (inner/outer counters,
  next/prev, hints, prelim/target, both phase buffers);
  `rockchip_ebc_dump_buffers.py` snapshots it to files. ayakael packages
  it as a debugging tool.
- **A waveform lab in the driver**: the PHASE_SEQUENCE ioctl
  (6280ecb1f419) plays arbitrary user-supplied phase sequences on up to
  8 regions with per-element frame counts and delays, optional INIT
  bracketing, and **forced temperature** — i.e. hand-driving the panel
  for waveform experiments on glass. The A2-shortening experiment
  (69649f6634bd, "experimental option to shorten a2 waveforms") and the
  CLUT design both fed off this. Sharp edge: raw phase playback is
  exactly the DC-balance hazard `doc/eink-research.md` §1 warns about;
  it's an instrument, not a feature.
- **Parameterized experiments**: `temp_override` (LUT-bin selection),
  `hskew_override` and `dclk_select` (panel-timing search — the
  panel-simple 85 Hz mode commit 70cbadbce9ab has the search trail
  fossilized as comments: hskew 0/10/…/70 tried, "does not work", 64
  shipped), `limit_fb_blits`, a `testing` variable that runs the whole
  scheduler without starting hardware frames (dry-run mode), and
  `zero_waveform` mode (pipeline alive, panel undriven) for isolating
  driver-vs-panel effects.
- **Offline modeling before kernel code**: `wbf_to_custom.py` contains a
  `Sim` class — a Python simulator of the two-level counter scheduler —
  used to design the CLUT format before implementing it in NEON. Same
  instinct as our rastersim, not maintained as a regression suite.
- **Community-era precedent**: the RK3566 EBC reverse-engineering was
  validated by smaeul's C reimplementation of the BSP LUT/pixel path
  with "a test suite to verify its output matches the output from the
  BSP assembly code" (wiki.pine64.org, RK3566 EBC Reverse-Engineering) —
  the community invented verbatim-differential testing before us, then
  let the tradition lapse.
- **Everything else is dogfooding**: demo videos in pine64 monthly
  updates showing application performance, field feedback from the Arch
  image and the postmarketOS port. No optical measurement, no golden
  images, no CI, no pinned regression tests anywhere in the tree, no
  ghosting acceptance criteria beyond eyeballs.

### 4.2 Coverage comparison

What he has that we lack — adopt:

1. **Per-pixel/driver-state dump ioctl** (EXTRACT_FBS): un-stub ours in
   the debug kernel from his legacy-branch implementation. Highest
   priority — see §5.
2. **In-driver frame-budget telemetry**: port the timing-stats idea into
   `linux-pinenote-debug` (counters + rate-limited report). It directly
   serves two hardware-only items on our list: EBC frame timing under
   load, and PREEMPT_RT's actual effect on the refresh thread.
3. **Pen-latency markers + BPF injection**: not needed until the pen
   track opens; note the pattern (center-line markers at each pipeline
   stage) — it composes perfectly with our optics rig, which can
   timestamp the optical response of the same center line and close the
   input→glass loop end to end.
4. **Raw-drive instrument** (PHASE_SEQUENCE-shaped, debug kernel only,
   if ever): would let the rig measure per-phase optical response — the
   academic reflectance-derivative metric — instead of inferring from
   full transitions. Driver work on our lineage, so it's report-first
   per policy, and DC-balance-dangerous; park it as a possibility.

What we have that he lacks — worth offering upstream:

1. **The optics rig and its metric definitions** (flash depth, ghost
   rms, settle, per-event wash attribution, per-frame validity
   auditing). Nobody in the community measures the panel; his stack's
   central quality claims (dithering quality, redraw_delay's felt
   effect, DU-vs-A2 equivalence, the ≥19 °C clamp's real cost) are all
   one capture session away from being numbers. The 2026-07-11 sweep
   already established this is novel community-wide.
2. **The verbatim-source host harness + quirk pinning.** Directly
   relevant to the legacy branch he still maintains and to every
   m-weigand-lineage user; our findings report now ships with the
   corroboration that he independently hit two of the bugs. The deeper
   offer is the *discipline*: his rework shipped ~130 KB of scheduler
   with zero regression tests; a CLUT-compiler differential
   (`wbf-info --dump-lut` vs `wbf_to_custom.py` output) would be a
   natural first joint artifact, and our Sim-vs-NEON differential idea
   transfers to his `advance` function if the harness ever goes
   aarch64.
3. **Trace→replay policy workbench** (`ebc-replay`): his hint/redraw
   parameter space (redraw_delay, hint mixes, cancellation addition) is
   exactly the kind of thing it prices offline in seconds.

### 4.3 Would his methods have caught our finding 10?

No. The session-selective corruption we measured is a divergence between
driver belief and glass state; every instrument in his kit measures the
driver side (state dumps, timing) or the subjective side (dogfooding).
Our own instrumented-kernel run showed the driver side reporting a
perfectly healthy handshake while the campaign's corruption happened —
his telemetry would have shown the same nothing. The one exception cuts
the other way: **EXTRACT_FBS paired with our camera** is precisely the
missing instrument (§5). Conversely, his *design* response to the same
territory is instructive: he deleted driver-initiated washes and moved
quality maintenance to per-pixel redraws — architectural avoidance
rather than detection. Our finding-10 policy (`auto_refresh=0`,
userspace-owned washes) converges on the same judgment from evidence.

## 5. What this says about the reopened corruption hunt (as of 2026-07-12)

*Currency note (2026-08-06):* the hunt has been dormant since
2026-07-12 — everything below is the state and plan as of that date,
not an active track. The quirk-2 overlap fix it names as "authored"
**landed** that same day (§3.2) and has shipped on every kernel since
A.2.8-dbg, so every boot since has been running the promised corruption
A/B — but whether corruption recurred on the fixed kernel is recorded
nowhere. That unrecorded outcome is the open item; `doc/status.md`
owns currency.

The straggler-truncation mechanism is refuted on our silicon
(instrumented run 1, `doc/driver-findings-report.md`), and the hunt is
back at content bookkeeping. hrdl's history is directly useful there:

- **Quirk 2 is now a prime suspect with an authored fix.** hrdl's
  59b2113e8b9c commit message calls the pre-fix behavior "scheduling
  issues", i.e. he observed misbehavior in the field before rewriting
  the engine. The failure mode — two concurrent waveform playbacks over
  the same pixels at different phase offsets — produces exactly the
  wrong-drive-integral family (graying, ghost-level repaints) that
  survived the evidence audit, and our shipped `split_area_limit=0`
  makes overlaps *more* likely. Concrete next steps, all offline first:
  extend the rung-7a fake device to model per-pixel optical integration
  under overlapping windows and check whether an overlap event can
  reproduce the never-a whole-page ghost-paint / armC graying
  signatures; then A/B the translated fix. This is cheaper than the
  camera session and orthogonal to the instrumented kernel.
- **The finding-7 odd-`x1` leak is a prev/next desync primitive** (one
  out-of-clip column of `final` leaks into `next` without being
  scheduled) — small, but it is *bookkeeping* corruption of exactly the
  kind the audit's surviving evidence demands, and hrdl fixed it too
  (11c358d1ca7a). Worth re-examining against the corrupting runs'
  damage-clip geometry (KOReader menu rects with odd x-edges).
- **EXTRACT_FBS + camera is the decisive combination.** Dump
  prev/next/final immediately after an on-camera corruption event and
  diff the driver's belief against the rig's measured panel state: if
  `prev` disagrees with glass, the corruption is bookkeeping (and the
  dump localizes *which pixels*, constraining the mechanism to specific
  blit/schedule paths); if they agree, the corruption is drive-level and
  the hunt moves to waveform/timing territory. This upgrades the next
  hardware session from log-harvest to ground-truth capture, and the
  implementation is a transcription from hrdl's legacy branch into the
  debug patch.
- **The spontaneous autos-off events (soak1) stay unexplained** by
  anything in either tree: his custom driver has no spontaneous global
  sources either, and nothing in his history mentions the phenomenon.
  Still ours to isolate.

## 6. Sources

- `git.sr.ht/~hrdl/linux` — branches and SHAs as cited inline; fetched
  2026-07-12 (`git fetch --depth=500`), driver sources also pulled raw
  per-branch and diffed against our verbatim extraction.
- `git.sr.ht/~hrdl/pinenote-dist` @3e228db — CLUT compiler
  (`bin/wbf_to_custom.py`), UAPI client (`bin/rockchip_ebc_custom_ioctl.py`),
  hint manager (`bin/sway_dbus_integration.py`), shipped config
  (`etc/modprobe.d/rockchip_ebc.conf`), waveform services, README.
- postmarketOS pmaports (gitlab.postmarketos.org):
  `device/community/device-pine64-pinenote` (APKBUILD pkgver 11,
  `pinenote-init-waveform.initd`, the tinydm workaround),
  `device/community/linux-pine64-pinenote` (6.19.3, vanilla tarball +
  generated patch from ayakael.net/forge/linux-pinenote).
- pine64.org: PineNote documentation (driver configs for both kernels),
  August 2025 community update (Arch image, postmarketOS port,
  ten-finger cyttsp5 config fix); wiki.pine64.org RK3566 EBC
  Reverse-Engineering (smaeul's BSP-differential test suite).
- Negative results, recorded so nobody re-searches: pine64 forum threads
  (tid 18911, 18415) contain no hrdl technical content;
  sr.ht web UI 502s (raw/git endpoints work); the postmarketOS wiki is
  bot-gated (Anubis) — use the pmaports git/API instead.
