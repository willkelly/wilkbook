# Third-party audit of the tree at generation 9 (2026-09-03) — and what we verified

A source and PR review received 2026-09-03 evening from an outside
reviewer who had not built or run the tree. Its recommendation: declare
a short stabilization phase, fix the remaining kernel correctness
issues, finish the skipped validation, and only then resume the RT and
semantic-hint work. This record keeps the audit's findings with our
verification of each against the patch text and the device, and the
order we are taking them in. The audit's text is paraphrased; the code
claims are quoted where the exact shape matters.

## Verification table

| # | Audit claim | Verified? | Where | Ours or inherited |
|---|---|---|---|---|
| 1 | The parallel advance runs a band inline when `queue_work()` returns false; that is backwards (false = already queued; the queued invocation owns the completion), so the fallback could run a band twice and complete twice. Unreachable for fresh on-stack work, still wrong. | **Confirmed** | `linux-pinenote-7.1-ebc-parallel-advance.patch`, `rockchip_ebc_blit_neon.c` | ours (2026-09-02) |
| 2 | The probe unwind (`kthread_stop` + `pm_runtime_disable`) is narrower than the acquisitions: vmalloc planes, two phase-buffer DMA maps, the custom LUT, the temperature thread are not released on a failed probe; the custom LUT is not freed on remove either. | **Confirmed, understated**: six vmalloc planes (three hints, three prelim-target), not two; the LUT `vzalloc` has no `vfree` anywhere; `dma_map_single` ×2 unmapped only on remove; only the refresh thread stopped on failure. | `linux-pinenote-7.1-hrdl-direct-mode.patch`, `linux-pinenote-7.1-probe-unwind.patch` | inherited shape, our narrow unwind |
| 3 | `rect_hint_batch` is a root-writable module parameter; zero spins the ioctl loop forever (`kmalloc_array(0)` is non-NULL); the count is unbounded. | **Confirmed** | `rockchip_ebc.c` `rockchip_ebc_apply_rect_hints` | inherited param, our loop |
| 4 | The 32×32 NEON dither loads both 16-byte halves from the same row address; the second should be +16. Present in every pixel-format copy. | **Confirmed**: three copies, all without the +16 | `rockchip_ebc_blit_neon.c` | inherited (hrdl) |
| 5 | OFF_SCREEN returns the positive uncopied byte count; EXTRACT_FBS ORs residuals and errnos. | **Confirmed** | `rockchip_ebc.c` | inherited |
| 6 | Every custom ioctl is `DRM_RENDER_ALLOW`, semantically wrong for display-control commands. | **Confirmed as stated; inert in practice**: the driver does not set `DRIVER_RENDER`, so no render node exists. Live node permissions still to record. | `rockchip_ebc.c` ioctl table | inherited |
| 7 | PRs #49 and #50 are still open and should be closed as superseded by #64. | **Stale**: both were auto-marked merged by GitHub when #64 landed (their heads are ancestors of main). | github | — |
| 8 | The R1–R7 shipping-reader list and the optics check were not run; S3–S5 not started. | **Correct** per `doc/status.md` 2026-09-03 late afternoon. | — | — |
| 9 | PR #67's finding (a trial runs the running device tree) should become policy: DTB changes need a cold boot and a live-FDT check before promotion counts. | **Agreed**; the helper's NOTE and the docs are in #67; the cold-boot rule is written into `doc/update-path.md`. | — | — |
| 10 | PR #66's Wi-Fi fix needs captured repetition (30–50 cycles, both trigger paths, varied sleep lengths) before it is called proven. | **Agreed**, and superseded in part: the same evening root-caused the remaining losses to KOReader's `wifi_was_on` bookkeeping, not the radio (`doc/networking.md` §8, the late-night status entry). Rig v2 is designed. | — | — |
| 11 | PR #51's os1 rescue is untested on os1. | **Correct**. | — | — |

One caution on item 6 the audit did not state: KOReader draws through
fbdev and is not DRM master. Gating global refresh or mode control on
`DRM_MASTER` would break the shipping reader outright. Tightening has
to arrive with a broker-owned display node or the reader becoming
master; it is a design item, not a flag change.

## The audit's remaining points, kept as the standing list

- **Semantic hints are not production-ready**: the per-pixel hint plane
  is mutable independently of framebuffer writes and publication, so a
  render can see a mixture of hint generations. Before KOReader relies
  on fine distinctions (PAGE_TURN, INK, ERASE, SCROLL, SMALL_UI,
  SETTLE), a coherent submission boundary is needed — a submit struct
  binding damage, hint defaults and overrides, intent, framebuffer
  generation and publication, with a generation/fence reporting
  accepted, all phases emitted, driver quiescent.
- **Then the RT work**: instrument first (total advance time, per-band
  compute, dispatch delay, barrier wait, missed scans, active area, CPU
  and DDR frequency, temperature, energy per turn; p50/p95/p99/max),
  then persistent pinned band workers under a FIFO coordinator with
  generation-numbered jobs and deadline accounting; only then decide how
  far the CPU clock can fall. The workload split stays: dense page turn,
  clipped small UI update, sparse per-pixel for stylus and overlays,
  nothing when idle. Byte-addressable NEON state is fine; bit packing is
  not the priority.
- **Tests should execute behaviour, not recognise patch text**: the
  current direct-driver checks pin source shape. The minimum behavioural
  suite: single-band vs four-band equivalence on random input, malformed
  RECT_HINTS (inverted, empty, negative, off-screen, enormous, partial
  copies, zero batch), probe fault injection at each acquisition, repeated
  bind/unbind, scalar-vs-NEON dither, ioctl permissions, concurrent
  hint/render stress, a fresh work item always queueing. Split into
  host/model, applied-tree, on-device non-visual, on-glass optical.

## Order we are taking (the audit's, with our state folded in)

1. **Tiny kernel semantics fix** — items 1, 3, 4, 5 as one narrow patch
   (`linux-pinenote-7.1-direct-correctness.patch`, patch 14). Done the
   same night; kernel build and the direct host checks green; glass
   pending.
2. **Resource-lifetime fix** — item 2: one shared cleanup in reverse
   acquisition order for failed probe and remove; an on-device
   bind/unbind and fault-injection test counting threads, DMA warnings,
   vmalloc, runtime-PM balance, kmemleak where available. The most
   important substantive follow-up.
3. **Direct-driver correctness pass** — the ioctl access audit with the
   live node facts recorded first (item 6, with the fbdev caution).
4. **Validation** — the applied-tree behavioural tests, then the skipped
   R1–R7 and optics run on the current baseline; rewrite any R-test that
   assumes the retired refresh-drain driver.
5. **Recovery and process** — merge #67's policy; prove #51 on os1;
   keep a known-good generation (generation 7 or 9).
6. **Wi-Fi proof** — rig v2 with captured per-cycle facts, both trigger
   paths, varied sleep lengths, after the KOReader bookkeeping fix.
7. **Only then** — transactional submission and fences, pinned RT
   workers, sparse tiles, dense page-turn specialisation.

The audit's closing assessment, which we share: the merge was
aggressive but did not leave the reader broken or unrecoverable;
direct-mode adoption remains the right baseline; the project needs a
correctness-and-lifecycle consolidation before more display cleverness.
