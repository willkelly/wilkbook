# Attended glass sessions, late August 2026: what needs proving

**Status: session plan.** Written 2026-08-25 ahead of attended sessions.
Results go to `doc/status.md` (per-operator, append-only) and
`doc/artifacts/`; this document is the *agenda*, and each item names its
decision. Ordering follows the ladder: cheapest decisive observation
first, one variable at a time.

Two images are in play:

- **`reader`** — the shipping image, proven driver. Items in §2 validate
  work that landed since the last deploy.
- **`reader-direct`** — the direct-mode experiment (scaffolding; see
  `doc/direct-mode-adoption.md`). Items in §1 decide embrace-or-reject.
  It has NEVER run; the realistic first goal is forensics, not reading.

## 1. The direct-mode experiment (os2 ← reader-direct)

In strict order; a hard failure at any step ends the direct session and
falls back to the reader image.

| # | prove | how | decides |
|---|---|---|---|
| D1 | `custom_wf.bin` gets compiled at boot from the device's own `ebc.wbf` | boot log of the CLUT one-shot; file present with plausible size (~229,584 B for this panel), checksum stamp written | the on-device compile path works |
| D2 | the module **probes** | `dmesg`: no `-EINVAL`, no missing-firmware, no unknown-parameter refusal | blockers 1+2 were actually fixed |
| D3 | the panel **lights at all** | any visible frame — even garbage counts as data | clocks + DT are close enough to drive glass |
| D4 | a page turn reaches glass | KOReader up; `GLOBAL_REFRESH` (ABI-identical `0xC0016440`) produces a visible wash | the KOReader path survives the swap |
| D5 | **rotation, all four orientations** | rotate through all four; look for the portrait wedge class | the single highest-risk item — nobody has ever rotated via fbdev on his stack. **2026-08-25: UNRESOLVED, not failed** — do not respend glass on it until the queued rung-4v investigation in §3 finds the real lever |
| D6 | suspend/resume with the ultra pair | one cover-close/open cycle, then one backstop-length sleep | his driver coexists with our rails-off configuration |
| D7 | visual quality vs the shipping driver | the webcam A/B protocol from `doc/artifacts/pinenote-dclk-reclock-20260824/` at minimum; optics rig if available | whether quality regressed enough to matter |
| D8 | **FAST mode reaches pen-class latency** | drive `DRM_IOCTL_ROCKCHIP_EBC_MODE` into FAST; measure nib-to-ink however crudely (240 fps phone camera works) | the entire reason for the experiment |

| D9 | **the per-frame `advance()` cost on real silicon** | his driver already instruments it — `delta_advance` (µs from `time_start_advance` to `time_advance_sync`) and min/max frame delay, reported around `rockchip_ebc.c:1134–1202`. Enable the reporting and harvest from dmesg during whatever D4–D8 activity runs; no extra panel time needed | **nothing in the embrace/reject gate** — it is the one feasibility number for the userspace-TCON question (`doc/direct-mode-adoption.md` §7), free to record while the machine is doing D4–D8 anyway, and expensive to reconstruct later |

**What would constitute *reject***: D3–D5 unrecoverable, or D7 showing
reading-quality regression with no visible path back — per the plan's
bail-out rule, a reader that regresses reading to gain writing is the
wrong trade. **What would constitute *embrace***: D1–D6 pass and D8
lands in the tens of milliseconds. Anything between is "iterate".

Known-broken going in, so nobody debugs them live: the refresh policy
still speaks A2 (absent from the CLUT — expect odd wash behaviour); the
self-heal paths write `refresh_waveform` (a parameter that no longer
exists — expect logged write failures, harmless); `dclk_select` semantics
differ.

## 2. Shipping-reader validation (os2 ← reader, current main)

Everything that landed since the deployed image and needs glass or the
device. Any order; each is independent.

| # | prove | how | closes |
|---|---|---|---|
| R1 | timezone: `/etc/localtime` resolves; KOReader clock reads local | one look at the clock | #6's "needs a new image to verify" |
| R2 | manuals shelf: staging one-shot runs; KOReader opens `Manual pages.epub`; **first-open time** of the 538-doc book is tolerable | open it, read a man page, time the first open | #17's rendering unknowns |
| R3 | SNTP opt-in: with servers configured, one sync happens after association; **RTC alarm re-arm survives it** (readback in the log); no retry-loop with Wi-Fi down | daemon log + `wakealarm` readback | #27 end-to-end |
| R4 | KOReader profile: the record-generated seed lands; fonts present; settings as declared | boot + look | #12 step 2 on-device |
| R5 | the #22 drain gate on glass: sustained damage (scrolling) + a queued wash → wash lands within ~1 area lifetime; and suspend entry under sustained damage is prompt | scroll + wash; scroll + suspend | #22's hardware half |
| R6 | cyttsp5 resume handshake rate on the new kernel | count `Validation of the wakeup response failed` per suspend over the session | updates #24 |
| R7 | overnight ultra sleep with the panel intact (alpha-signoff §2's added check) | leave it; look in the morning | sign-off item |

## 3. Explicitly NOT in these sessions

- **#23's `dclk_select=1` optics qualification** — superseded unless
  direct mode is *rejected*; it only matters to the LUT path.
- **Pen wake (#9)** — needs a DT change through branch-and-review first.
- **Anything destructive to os1.** Per the safety model, always.
- **D5's rotation lever — queued as OFFLINE work first (rung 4v), added
  2026-08-25.** The session left rotation *unresolved, not failed*:
  four remote mechanisms — injected MSC gyro events, the KOReader doc
  sidecar, `copt_rotation_mode`, and the
  `/run/wilkbook-orientation.state` file — all produced portrait boots,
  so the rotated render path never executed and we do not actually
  know what decides orientation (the enumeration is in the
  `doc/status.md` session entry). Spending more glass guessing would
  invert the ladder. The work item: boot the same stack under
  `make qemu-virt-visual ROOTFS=…` and instrument KOReader's
  rotation-decision chain end to end — from each candidate input
  (gyro/accelerometer events, the sidecar's `rotation_mode`, defaults,
  the orientation bridge) through `device.lua`/`screen` to the actual
  framebuffer rotation call — until the mechanism that *does* flip the
  virt framebuffer is identified and the four failures are each
  attributed (never read, read-then-overridden, or read-too-late).
  Exit criterion: one named lever that rotates the qemu boot
  deterministically. Only then one targeted glass pass — or physically
  rotate the device out of the box and watch the chain react.

## 4. Session hygiene

Per `doc/device-access.md`: `enabled=0` in `/data/wilkbook/autosuspend.conf`
before working (the `/var/lib` path does not exist); restore after. Deploys
are os2-only via `write-os2-verified.sh`. Post-mortem harvest before any
forced power-off. `doc/status.md` entry per session, per operator.
