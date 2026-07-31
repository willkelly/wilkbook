# Upstream register — what we owe the community, and when to send it

A standing list of things this project has built or found that would be
useful to someone else, together with **where** they'd go and **what has
to be true before we send them**. It is a tracker, not a plan: nothing
here is scheduled work.

Companion to `doc/driver-findings-report.md` (the written-up findings) and
`doc/hrdl-evaluation.md` (the community-diff evaluation whose §3.3 already
recommends "land the findings report upstream"). This file is the register
that gates that, and everything like it.

## The gate

**Nothing goes out until the baseline is done and the finding is proven in
a system that actually works.**

"Baseline done" means: a minimal PineNote distro that works *very well* as
an ereader and a note-taking device. Not feature-complete — good at those
two things, on hardware, in daily use.

The reason is credibility, and it's specific to our position. We are the
only public 7.0.x PineNote tree (verified 2026-07-31: hrdl tops out at
v6.19 with no 7.0 branch; postmarketOS ships 6.3.10). Everything we report
therefore arrives from a tree nobody else runs. A finding from a working
daily-driver reader is a contribution; the same finding from a tree that
has never been lived on is a code review from a stranger. We only get to
make the first impression once.

Secondary reason: several items below are still moving. A report we have
to retract costs more than one we send late.

## How to use this

When you find something worth giving back, add a row. Don't send it.
When the gate opens, work the list in value order.

Each entry records: what it is, where it lives in our tree, who it's for,
how it would be sent, what has to be true first, and its current status.

Status vocabulary: **ready** (written, verified, gated only on the
baseline) · **needs-verification** (real, but a claim in it is unconfirmed)
· **needs-work** (would have to be written or generalized) · **parked**
(low value, recorded so we stop re-deciding).

---

## Register

### 1. `rockchip_ebc` findings report — **ready**

Seven latent driver issues found by the host tool suites, written up in
`doc/driver-findings-report.md` (draft dated 2026-07-04, already addressed
to the community).

**For:** hrdl (`git.sr.ht/~hrdl/linux`), primarily.
**Why it's the top item:** it's already written, it's machine-verified
against driver source rather than read, and it applies to code hrdl ships
*today* — not just to our fork.

**Applicability confirmed 2026-07-31** for the flagship finding (a
sustained damage source starves the global-refresh path indefinitely and
silently). Fetched `v6.19_ebc` and found the exact structure present:
`do_one_full_refresh` declared at `:180`, read at the top of the refresh
thread at `:1545`; `rockchip_ebc_partial_refresh` at `:1082`;
`list_splice_tail_init` re-splicing the queue inside the frame loop at
`:1128` and `:1257`; the drained-list exit at `:1231`. The report's own
caveat — "equivalent code exists in the hrdl/ayakael 6.19 lineage;
re-check before applying" — is discharged for this finding.

**Not yet re-checked** against `v6.19_ebc` for findings 2–7. Do that
before sending; the same fetch method works.

**Gate:** baseline done. Also re-confirm findings 2–7 still apply.

### 2. `DRM_IOCTL_ROCKCHIP_EBC_REFRESH_BARRIER` — **needs-verification**

A generation-addressed refresh barrier (SUBMIT/WAIT, poison-on-failure)
authored here and hardware-proven 2026-07-30.

**For:** hrdl, as an offer rather than a patch.
**Blocker:** we have no production caller. The barrier is proven by a
separately-invoked root-only diagnostic, not by the reader. Offering UAPI
we don't ourselves depend on is weak. `doc/hrdl-evaluation.md` §3.3 also
notes `v6.19_ebc_custom` is where the community UAPI is actually heading —
check whether that branch has already grown something equivalent before
proposing ours.

**Gate:** a production caller exists, *and* `v6.19_ebc_custom` doesn't
already solve it.

### 3. Deferred-io flush period is tunable — **needs-work** (technique note, not a patch)

`fbdefio.delay` is a plain writable per-helper field
(`drm_fbdev_shmem.c:184`, `HZ/20`), `drm_fbdev_shmem_driver_fbdev_probe()`
is `EXPORT_SYMBOL`'d (`:203`), and `fb_defio.c:297` re-reads the delay on
every fault. So **any** driver can set its own value in a `.fbdev_probe`
wrapper with no upstream change at all.

**There is nothing to upstream to mainline.** Recorded here because it's
worth *telling* hrdl: his driver carries 25 `module_param`s and **zero**
references to `defio`/`fbdefio` (verified 2026-07-31 against
`v6.19_ebc`) — the knob is simply unnoticed, and it is directly relevant
to anyone driving this panel through deferred-io.

Do **not** pitch it to mainline as a user-tunable module parameter. The
DRM maintainers' documented position on e-paper driver knobs is hostile to
that framing. (That position was reported to us as a specific 2026-05-05
review quote which we could **not** verify — lore.kernel.org is behind an
anti-bot wall. Treat the specific quote as unconfirmed; the general
principle is well enough established to act on regardless.)

**Gate:** send with item 1 as a footnote. No separate effort.

### 4. Host-harness testing discipline — **needs-work**

The verbatim-source host tools (`pinenote/tools/{wbf,ebc-logic,rastersim}/`)
compile the driver's own source on a workstation and differential-test it.
`doc/hrdl-evaluation.md` §4 argues this is the deeper offer: hrdl's rework
shipped ~130 KB of scheduler with zero regression tests, and a
CLUT-compiler differential (`wbf-info --dump-lut` vs his
`wbf_to_custom.py`) is the natural first joint artifact.

**Gate:** baseline done. Generalizing the harness beyond our tree is real
work — offer the idea first, build only if there's interest.

### 5. Waveform-decode and optics measurement methodology — **needs-work**

`doc/refresh-policy.md` plus `pinenote/tools/optics/`. Per the 2026-07-11
sweep, quantitative display-quality measurement is novel community-wide —
dithering quality, `redraw_delay`'s felt effect, DU-vs-A2 equivalence are
all assertions in the community and numbers here.

**Gate:** the optics program produces results we actually trust and use.

### 6. The 7.0.x forward-port itself — **parked**

Genuinely scarce (we're the only public 7.0.x) but there is **no
consumer**: hrdl hasn't branched past v6.19, postmarketOS ships 6.3.10.
The EBC driver delta from `v6.19_ebc` to ours is only ~231 diff lines, so
the porting value isn't in the driver anyway — it's in DTS, defconfig,
tps65185 and PREEMPT_RT integration.

**Unpark trigger:** someone in the lineage starts a 7.x branch.

---

## Destinations

| who | what they own | channel | verified? |
|---|---|---|---|
| hrdl | `git.sr.ht/~hrdl/linux` — the live upstream, 69 heads, tops at v6.19 | sourcehut; likely `git send-email` to a list | **address not confirmed — look up before sending** |
| m-weigand | `github.com/m-weigand/linux` — the root we forked | GitHub issues/PRs | dormant since ~Feb 2025 |
| postmarketOS | pmaports `device/testing/{device,linux}-pine64-pinenote` | GitLab MR | kernel pinned to m-weigand `616dc3b` at 6.3.10; APKBUILD last touched 2024-07-30 |
| ayakael | Forgejo fork feeding pmOS | — | `ayakael.net/forge/linux-pinenote` **404s** as of 2026-07-31; find current home before relying on it |
| dri-devel | mainline DRM | `git send-email` | only relevant if the driver is ever resubmitted; no EPD infrastructure in mainline and none pending |

## Standing caveats

- **We are ahead of, not aligned with, the lineage.** Line numbers and
  structure in our reports are ours. Always re-fetch the target branch and
  re-verify before sending — the method that worked on 2026-07-31 is
  `https://git.sr.ht/~hrdl/linux/blob/<branch>/<path>`, which returns the
  raw file, plus `git ls-remote --heads` for tips.
- **`doc/hrdl-evaluation.md` §3.3 is the standing strategy**: stay on the
  m-weigand lineage at 7.0.x, track `v6.19_ebc` as our rebase reference
  and `v6.19_ebc_custom` as the UAPI-direction reference.
- **Report, don't patch** (`CLAUDE.md`): driver fixes belong to the
  lineage. This register is how we honor that without dropping findings on
  the floor.
