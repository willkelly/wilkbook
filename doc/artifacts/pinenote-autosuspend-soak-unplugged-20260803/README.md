# Unplugged soak, working daemon — 2026-08-03

**First soak of a daemon that can actually suspend.** Every previous soak
measured the silently-failing version (see
`../pinenote-autosuspend-soak-20260803/`, retracted).

Image `7bb55c2f…`, unplugged (`charger=0`), `idle=60 backstop=240`.

## Result: clean

```
suspend_stats: success=2  fail=0
2026-08-03 22:53:19  watching 8 input devices, idle=60s backstop=240s
2026-08-03 22:58:24  resumed after 240s
2026-08-03 23:03:25  resumed after 241s
```

**Sleeps run their full armed duration.** 240 s and 241 s against a 240 s
backstop — so **nothing wakes the device spuriously on battery**. That was
the open question the 8.6-day standby figure depended on, and it is now
answered in the affirmative for this dwell length.

`fail=0` — no dwc3 veto, confirming the `write_file(udc, "\n")` fix holds
in the deployed build.

## Duty-cycle power

| | |
| --- | --- |
| elapsed | 22:53:19 → 23:04:22 = 663 s |
| charge | 3,609,248 → 3,597,380 µAh = 11,868 µAh |
| **average** | **64.4 mA** at ~20 % awake duty cycle |

For comparison, the naive model from the component measurements predicts
`0.2 × 172 + 0.8 × 19.3 = 49.8 mA`. The measured 64.4 mA is ~30 % higher,
and the gap is the per-cycle resume cost that the model ignores: Wi-Fi
re-association, the banner draw and restore, and a full display refresh —
every 5 minutes.

**That gap is the argument for a long idle timeout.** At `idle=300` the
duty cycle drops and the resume overhead amortises across a much longer
sleep; at `idle=60` you pay it twelve times an hour. The shipped default
of 300 s is the right shape, and this soak's 60 s was chosen for test
throughput, not as a recommendation.

## Open: SC7A20

`dmesg` shows one `nobody cared` and a `Call trace` at **108.9 s uptime**,
which is *before* the first suspend (first `PM: suspend entry` was ~145 s).
That differs from the 2026-08-02 signature, which appeared ~28 s *after* a
resume. So this image — which carries the new `st_accel` PM patch — may
have a boot-time storm, may have an unrelated one, or the patch may have
shifted the timing. **Not established either way**; the follow-up needs the
device parked awake (`enabled=0`) so dmesg can be read without racing the
cycle.
