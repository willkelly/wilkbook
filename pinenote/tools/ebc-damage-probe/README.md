# ebc-damage-probe — controlled deferred-io / EBC damage-scheduling probes

Device-side LuaJIT probes that write chosen patterns straight into the mmapped
framebuffer and count EBC interrupts (one DSP_END per hardware frame, so an
interrupt delta *is* a frame count). No KOReader, no rotation, no input — the
only variables are the shape, order and timing of the damage.

They exist because a reported "portrait page turns refresh twice" observation
could not be explained by reading code, and every hypothesis formed from the
KOReader-level trace turned out to be wrong. These isolate the driver and
deferred-io behaviour from the reader entirely.

## Running

Requires the panel to be idle and owned by nobody else:

```sh
herd stop reader-session
echo 0 > /sys/class/vtconsole/vtcon1/bind      # fbcon's cursor is a damage source
LUAJIT=/run/current-system/profile/lib/koreader/luajit   # or the koreader-bin store path
$LUAJIT damage-scheduling.lua
$LUAJIT repaint-duration.lua
$LUAJIT write-cost.lua
# restore
echo 1 > /sys/class/vtconsole/vtcon1/bind
herd start reader-session
```

They leave the panel dirty; restarting the reader repaints it. Nothing else is
touched — no power, suspend, firmware, partition or boot state.

`diff_mode=1` masks pixels whose prev == next, so every pattern must genuinely
change the pixels it touches or the driver correctly does nothing. (That is
itself visible in `damage-scheduling.lua`: two full-screen writes 10 ms apart
coalesce into one damage whose final content equals `prev`, and cost **zero**
frames.)

## What they established (2026-07-30)

`damage-scheduling.lua` — each deferred-io flush costs one whole refresh pass,
and passes do **not** pipeline:

| pattern | frames |
| --- | --- |
| 1 full-screen write | 38 (1 pass) |
| 2 full-screen writes, 250 ms apart | 76 (2 passes) |
| 2 **disjoint** half writes, 250 ms apart | 76 (2 passes) |
| 2 full-screen writes, 10 ms apart | 0 (coalesced, then diff-masked) |
| 3 full-screen writes, 250 ms apart | 76 (saturates; redundant areas dropped) |

Disjoint damages cost exactly as much as overlapping ones, which refuted the
then-current "overlapping areas get serialised" explanation.

`repaint-duration.lua` — with **no transpose at all**, identical contiguous
access order, and duration as the only variable:

| write spread over | frames | passes |
| --- | --- | --- |
| 0 ms | 38 | 1.0 |
| 40 ms | 76 | 2.0 |
| 80 / 150 / 250 / 400 ms | 76 | 2.0 |

So rotation is not the defect; it is merely a way of being slow. What matters
is whether a repaint finishes inside the deferred-io window
(`drm_fbdev_shmem.c:184`, `fbdefio.delay = HZ / 20` = 50 ms).

`write-cost.lua` — full-screen write cost by access order: contiguous ~29 ms,
column-order ~255 ms. **Caveat:** these are LuaJIT per-element loops and are
loop-bound, not memory-bound, so the transpose figures do not represent
KOReader's C blitter. Only the `ffi.fill` (real C memset) numbers are
trustworthy as absolute costs.

`repaint-window.lua` — measures KOReader's page-dirtying window **as
deferred-io sees it**, by sampling `min_flt` on the reader's own process.
Deferred-io write-protects the framebuffer pages after each flush, so every
first touch of a page is a minor fault; the fault burst's wall-clock span is
exactly the window that must fit inside 50 ms. Needs the uinput injector
(`pinenote/tools/optics/optics-inject.lua`) running so page turns can be
driven without a human, and takes the reader pid as `argv[1]`.

**Sampling framebuffer *values* cannot measure this** — most of a text page is
white-on-white, so it is written but unchanged. An earlier attempt that way
reported an 11-20 ms "write window" from 57 of 936 sample points, which was
measuring content change, not writing.

Measured 2026-07-30, portrait, 24 C:

| | window | faults | cost |
| --- | --- | --- | --- |
| file-manager repaint | 37-50 ms | ~2570 | content unchanged |
| **document page turn** | **98-145 ms** | **4827-6361** | **76 frames = 2 passes** |

The framebuffer is 2567 pages, so KOReader rewrites *all* of it; a document
turn faults roughly twice that, which is two flush cycles (deferred-io
re-protects after flushing and the still-running repaint faults them again).
Only the document figure is representative — drive turns with the injector
rather than measuring a file-manager repaint. Note the faults occur even on repaints that produce
zero EBC frames because `diff_mode` masks the unchanged result — which is the
direct explanation for the cost being invariant to page content.

`transbench.c` — how fast is a **bulk** framebuffer transpose in compiled C?
KOReader has no such operation today (rotation is per-access re-addressing,
`ffi/blitbuffer.lua:673-674`), so this measures the shadow-buffer proposal's
central cost. Build static and run with the reader stopped and fbcon unbound:

```sh
GCC=/gnu/store/...-gcc-cross-aarch64-linux-gnu-14.3.0/bin/aarch64-linux-gnu-gcc
ST=$(ls -d /gnu/store/*glibc-cross-aarch64-linux-gnu-*-static | head -1)
$GCC -O2 -static -o tb transbench.c -L$ST/lib
```

**Static matters:** a dynamically linked cross build embeds the *host's*
cross-glibc store path as its ELF interpreter, which does not exist on the
device — it dies before `main`.

Result 2026-07-31: `memcpy` 4.8 ms RAM→RAM and 35.3 ms RAM→fb; best tiled
(64×64) transpose **67.8 ms** into the framebuffer, against the 50 ms period.
RAM→RAM and RAM→fb transposes cost the same, so it is cache-bound rather than
write-bound, and 68 ms is 14× the streaming floor — NEON is untried headroom.

`neonbench.c` — the same question with NEON, and with a correctness check on
every variant (a fast wrong transpose is worse than a slow right one). Build as
for `transbench.c` but with `-O3`. Result 2026-07-31: NEON 4x4 block transpose
reaches **48.1 ms RAM→RAM**, and **44.5-46.0 ms into the framebuffer when the
CPU governor is pinned to `performance`** — inside the 50 ms deferred-io
period. Under the shipped `conservative` governor the same code measures
58-75 ms with ±25 % run-to-run spread, because a repaint is a burst that
catches the governor mid-ramp. Pin the governor when benchmarking, and restore
it afterwards.

`parbench.c` — parallel NEON transpose, with optional core pinning, reporting
best/median/worst plus the CPU frequency seen mid-run. Build as for
`neonbench.c` but add `-pthread` and the cross kernel headers
(`-I .../linux-libre-headers-cross-.../include`), which `_GNU_SOURCE` needs.
Run `pb fb conservative` with the reader stopped and fbcon unbound.

Result 2026-07-31, shipped `conservative` governor, 28 samples per variant:
**three threads unpinned never exceeded 43.1 ms**, against 123.6 ms worst for
single-threaded. ×3 beats ×4 (leave a core free), and pinning *hurts* at low
thread counts because idle cores drag the load average below the governor's
`up_threshold=80`. All four cores share one cpufreq policy, so pinning cannot
raise the clock regardless.

See `doc/refresh-policy.md`, "Portrait page turns cost two refresh passes".
