# Supervised suspend ladder — 2026-08-02 (os2, fbdev resume-barrier image)

Image `5493d994…` on os2, system
`/gnu/store/xjwyb5isv0awqj3l6wblfh7090xkzj67-system`, kernel 7.0.11.
Two runs this session; **only the second is interpretable** — see
"Instrument failure" below, which is the most important thing here.

## Result

| | outcome |
| --- | --- |
| Rung 1 (freezer `pm_test`) | **PASS** — rc=0, 5 s |
| Rung 2 mechanics | **PASS** — 45 s asleep, rc=0, on-schedule RTC wake, gadget quiesced clean |
| G1 (fbdev un-suspend completes) | **FIXED, hardware-verified** — `fb0.state=0` post-resume |
| Regulator balance | **NO LEAK** — zero drift pre→post |
| TPS65185 registers | **NO DRIFT** — VCOM `03: 8f` intact, `ENABLE 2f` (rails down, not stuck) |
| Rung 2 acceptance | **FAIL** — post-resume damage still paints 0 frames |
| Rung 3 (`deep`) | **NOT RUN** — forbidden by rule until rung 2 passes |

`mem_sleep` was explicitly forced to `s2idle` at the top of the script;
the image boots with `deep` selected, so this is not optional.

## Instrument failure, caught mid-session

The first run reported ACCEPTANCE FAIL using `dd if=/dev/zero
of=/dev/fb0 … conv=fsync` as the damage probe. That verdict was **void**:
a control on a fully healthy device, no suspend involved, showed

```
CONTROL (reader running): irq 778 -> 778 delta 0 ; fb0 md5 f3eb15e1 -> 06b5a22c
```

The framebuffer content changed and **zero frames** were produced. The
`write()` path generates no damage that reaches this panel; only `mmap`
does (38 frames = exactly one pass, with fsync and with the timer alike).
That is a real finding about the driver, and separately it means a
`write()`-based probe cannot distinguish a dead resume from a dead
instrument — which is exactly the trap the first run fell into.

**Standing rule, now encoded in the ladder script: every acceptance run
must gate on a pre-suspend CONTROL probe and abort if it paints 0.** The
second run carries that gate and passed it (38 frames) sixty seconds
before the post-resume probes read 0.

Whether the 2026-08-01 "all four damage probes are dead" result was
measuring the same dead instrument is **unresolved and should be
assumed** — those probes were also `write()`-based. The one result from
that session that survives is the GLOBAL_REFRESH ioctl driving +47
frames, which used a different path.

## The residual is real, and it is not any of the four gates

With a validated instrument, in the same configuration that painted 38
frames a minute earlier:

```
CONTROL PASS: instrument paints (38 frames) before any suspend
RESUMED rc=0 asleep=45s        post-resume: fb0.state=0 crtc_active=0
PROBE A (blanked)              = 0
PROBE B (unblanked, active=1)  = 0
reader restart                 = +192 frames (full recovery, no reboot)
```

Every gate reads **open** at every post-resume stage:

| stage | G1 `fb0.state` | G2 plane fb | G3 master | crtc active | thread |
| --- | --- | --- | --- | --- | --- |
| pre (paints 38) | 0 | 38 `[fbcon]` | none | 1 | I |
| post-resume | 0 | 38 `[fbcon]` | none | 0 | I |
| post-unblank | 0 | 38 `[fbcon]` | none | 1 | I |
| post-probeB | 0 | 38 `[fbcon]` | none | 1 | I |

The post-unblank row is state-identical to the `pre` row that painted,
and it paints nothing. **The four-gate model does not explain this
defect.** G1 was real and is fixed; it was not the cause.

## The surviving lead

`dmesg` across resume:

```
[648.822957] rockchip_ebc_suspend
[693.384975] rockchip_ebc_resume
[693.384993] ebc: rockchip_ebc_plane_reset
[693.385404] ebc: rockchip_ebc_ctx_release
[693.385418] EBC: rockchip_ebc_ctx_free
```

`drm_atomic_helper_resume()` calls `drm_mode_config_reset()` before
committing the duplicated state, which resets every plane — hence
`plane_reset`, and the ctx release/free behind it. The debugfs plane
`fb=` is restored by the subsequent commit, so **the DRM-visible state
looks correct while the driver's own refresh context has been torn down
and rebuilt.** That is the next thing to read offline: the ctx lifecycle
across `plane_reset` → `ctx_release`/`ctx_free` → whatever recreates it,
and whether damage submitted afterwards lands in a context the refresh
thread is actually consuming.

Note the thread reads `I` (idle) at every stage including `pre` — idle is
the healthy at-rest state, not evidence of parking. A parked kthread
would read `P`.

## Files

`ladder.log` (full run), `gates-*.txt` (four-gate reads per stage),
`drm-*.txt` (atomic state snapshots), `gt-pre/post.txt`
(`pm-ground-truth.sh`), `clients-after-reader-stop.txt`.

Device left healthy: reader running, 1162 EBC IRQs, gadget rebound,
regulators balanced, no reboot performed.
