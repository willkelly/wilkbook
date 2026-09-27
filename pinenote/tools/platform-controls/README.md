# PineNote platform-controls tests

This directory contains the offline tests for the production suspend broker,
protocol, Wi-Fi helper, KOReader integration, and Shepherd wiring. The packaged
sources live in `pinenote/packages/platform-controls/`.

Run the suite from the repository root:

```sh
make platform-controls-check
```

`test-banner.lua` executes the production broker's renderer and fallback
transaction with only the OS boundaries replaced. It checks every byte of
RGB565 and XRGB8888 framebuffers, including padded strides, visible offsets,
clipped screens and untouched margins/guards; rejects malformed geometry and
unsupported layouts; and injects open/ioctl/write/sync/close failures. Short
writes and EINTR are retried. A failed banner remains best-effort: it logs the
failure and the normal suspend transaction still runs.

The renderer queries both fbdev info ioctls through the descriptor it writes,
accepts little-endian packed truecolor RGB565/XRGB8888 only, and writes at most
96 visible rows. The 16384-pixel virtual-dimension cap bounds allocations and
geometry arithmetic. Display-mode changes by another process during rendering
are not serialized; the broker does not own modesetting. Hardware still owes a
missed-acknowledgement fallback on the direct driver's RGB565 framebuffer and
the retained banner's appearance and cleanup after wake.

## Broker clock semantics

`test-clocks.lua` executes the production helper definitions, input discovery,
protocol construction, and suspend transaction against separate injected wall,
awake and suspend-inclusive clocks. It steps wall time forward and backward
through startup/wake grace, WAIT_READY and RTC settle; it also advances only
the suspend-inclusive clock by an hour inside the actual power-state write.
The main loop's use of the tested grace helper is pinned by `test-static.sh`.

- `CLOCK_MONOTONIC` (Linux clock 1), fractional seconds: the two-second power
  grace, ten-second acknowledgement deadline, and post-RTC-wake settle window.
  These intervals exclude suspend, ignore wall-clock steps, and share the
  semantics of the existing relative `poll()` waits. MONOTONIC is subject to
  kernel frequency adjustment; this does not mean MONOTONIC_RAW.
- Evdev fds select `CLOCK_MONOTONIC` with `EVIOCSCLOCKID`, so press/release
  duration cannot change with SNTP either. If selection fails the fd is closed
  and that physical trigger is disabled with a log; FIFO requests still work.
- `CLOCK_BOOTTIME` (Linux clock 7), fractional seconds: elapsed time around the
  blocking `/sys/power/state` write, including suspend and entry/exit overhead.
  The existing `elapsed >= backstop - 5` RTC/button classification is retained.
  It remains a duration heuristic: a button near the alarm deadline can still
  be classified as RTC. It is not a hardware wake-source determination.
- RTC alarms continue to use `rtc0/since_epoch + backstop`, an absolute value
  in the RTC's own clock domain. Neither MONOTONIC nor system wall time is
  substituted there. Clock availability is checked before device acquisition;
  errors fail explicitly, never silently fall back to realtime.

Hardware still owes a broker run confirming evdev clock selection, normal
power/cover and acknowledged/fallback suspend, RTC resuspend after its complete
awake settle window, and short button wake versus full-backstop duration
classification. Host tests cannot prove this kernel's BOOTTIME accounting
across the PineNote's ultra suspend or the panel's retained banner.

## Residual RTC alarm concurrency

Source inspection of `pinenote/tools/timesync/timesync.lua:set_rtc` and the
broker's `arm_rtc`/resume cleanup finds no shared lock or ownership protocol.
Timesync reads the old alarm and RTC epoch, runs `hwclock --systohc`, reads the
new epoch, then clears/re-arms the alarm and verifies it. The broker separately
clears, reads the RTC epoch, and arms; after resume it clears again. Kernel
serialization of individual sysfs operations does not make these sequences
atomic. In particular:

- Timesync can snapshot no alarm, then the broker arms against the old RTC
  epoch, then timesync changes that epoch without re-arming the new alarm.
- Timesync can snapshot an old alarm, then overwrite a newly armed backstop
  or resurrect the alarm after the broker clears it on resume.
- Either clear can interleave with the other's arm, losing an alarm or making
  an arm fail. Timesync's readback observes only that instant, not future writes.

These are source-inferred races, not observed hardware failures. Wi-Fi teardown
does not stop an already-running timesync attempt. There is no proven time bound
on the active broker's arm-to-suspend window (it includes `sync`). A later
suspend re-arms from scratch but does not repair a missing wake for the current
cycle. MONOTONIC/BOOTTIME fix interval timing only. A shared coordination design
is still owed; this change adds none. The existing timesync `set-rtc? #f` option
avoids timesync's RTC writes, at the cost of not persisting corrections to RTC.

The retired Phase 1 runtime-overlay record is preserved under
`doc/artifacts/pinenote-platform-controls-v1-20260831/`.
