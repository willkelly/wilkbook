# Rung 2 with the fill discriminator — 2026-08-02, os2 `190321cd…`

**Result: post-resume damage paints. The "dead-write window" was largely a
probe artifact — every probe ever run wrote black onto a black console
background.**

## The run

```
RUNG 1 PASS (freezer pm_test, rc=0, 5s)
CONTROL PASS: instrument paints (46 frames) before any suspend   [checker]
RESUMED rc=0 asleep=44s   post-resume: fb0.state=0 crtc_active=0
PROBE A-blanked-BLACK      irq 912 -> 912   (delta 0)
PROBE A2-blanked-CHECKER   irq 912 -> 958   (delta 46)
PROBE B-unblanked-BLACK    irq 958 -> 958   (delta 0)
PROBE B2-unblanked-CHECKER irq 958 -> 1004  (delta 46)
VERDICT control=46 | blanked black=0 checker=46 | unblanked black=0 checker=46
ACCEPTANCE: post-resume fb writes DO paint
```

Damage reaches the panel after resume at **both** CRTC states, a full
46-frame pass each time. Gates all open post-resume (G1 `state=0`, G2
plane holds `fb=38 [fbcon]`, G3 no master). **Zero regulator drift, zero
TPS drift**, VCOM intact. dmesg gained only benign lines (boot banners,
the rung-1 `pm_test` wait, the expected gadget-quiesce `dwc3` timeout) —
no poison, no timeout, no BUG.

**Independent confirmation on glass** (operator, watching live): console,
then the checker band, then full-screen white (the off-screen wash at
suspend entry), then console with the checker still visible, then a
second checker band mid-screen, then a third about ⅔ down. Three bands at
rows 100, 560 and 860 of 1404 — 7 %, 40 %, 61 % down the panel — exactly
the predicted geometry. The two black bands at rows 400 and 700 were
invisible.

## Why black produced zero, proven

Immediately after the run, with the reader restarted so the region held
non-black content, the **same black probe at the same row**:

```
mmap-fsync row=400 fill=black: irq 1187 -> 1233 (delta 46)
fb rows 400-519 md5: 62227925ec -> b1c6fbad44  (changed: YES)
```

Black is not intrinsically dropped. It is dropped only when the
underlying content is **already black** — which is the driver's
drop-on-match working exactly as designed
(`rockchip_ebc_plane_atomic_update()` discards areas whose blit reports no
change). Post-resume the panel was showing the black console background
the operator saw, so writing black there was a genuine no-op.

## What this does and does not establish

**Established**: damage submitted after resume reaches the panel; the
reader survives suspend in place; rung-2 acceptance passes.

**Not established**: whether the 2026-08-02 damage-baseline fix was
*necessary*. This session's data (2026-08-02) cannot separate "the fix cured a real stale
baseline" from "black-on-black was always the artifact" — both predict
this exact result, and a distinctive fill was never run on the old image.
The fix stays regardless: `ctx->final_atomic_update` was genuinely
`kmalloc`'d and left uninitialised on the resume path while every other
init branch seeds it, and it *is* the diff baseline. That is a real defect
whether or not it produced the observed symptom.

**Retired**: the "post-resume dead-write window" as previously
characterised does not exist on this image.

## The instrument lesson

A probe reporting "no frames" is **ambiguous** unless it also proves the
framebuffer changed. Writing a value that already matches the underlying
content is a genuine no-op that the driver correctly discards, and it is
indistinguishable from a dead pipeline by frame count alone. Every probe
in this program before today wrote `0x00`.

`pinenote/tools/ebc-damage-probe/mmap-band-probe.lua` now reports
`fb-rows-changed=N/120` and flags `[NO-OP WRITE -- a zero delta here means
nothing]`. Demonstrated live, same fill twice:

```
mmap-fsync row=300 fill=checker: irq 1233 -> 1279 (delta 46) fb-rows-changed=120/120
mmap-fsync row=300 fill=checker: irq 1279 -> 1279 (delta 0)  fb-rows-changed=0/120  [NO-OP WRITE …]
```

Never report a zero delta without that field.
