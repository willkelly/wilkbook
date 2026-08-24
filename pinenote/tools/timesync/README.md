# timesync — opportunistic SNTP for a device that is asleep 98.5 % of the time

`timesync.lua` is a **production daemon**, not a test tool; it lives under
`pinenote/tools/` for the same reason `tools/power/autosuspend.lua` does —
it is a LuaJIT program the system service (`pinenote/services/timesync.scm`)
wraps, and its host suite lives next to it. `test-timesync.lua` is the
rung-1 gate, run by `make timesync-check`.

## What it does

Steps the system clock from a configured SNTP server whenever a network
happens to be there, announces the step loudly, and writes the correction
back to the RTC so it survives a cold boot.

It is **not** an NTP daemon. It does not discipline the clock, keep a
drift file, touch adjtime, or hold a connection. The reasoning is in
`pinenote/services/timesync.scm`'s header (the five shape decisions) and
`doc/networking.md` §7; the short version is that at a measured ~1.5 %
awake duty cycle disciplining a clock is meaningless — the thing being
disciplined is asleep almost always and its oscillator is the RTC's
anyway. What matters is that the clock be *anchored*, because everything
this project reconstructs a session from is a timestamp.

## The three properties worth knowing before you change it

1. **It cannot wake the device.** Every wait is `poll(NULL, 0, ms)`, a
   CLOCK_MONOTONIC timeout: not a wakeup source, and it does not run down
   while the device is suspended. So the poll interval is in *awake*
   seconds — it looks for a network when the device is in use, and costs
   nothing when it is not.
2. **It will not open a socket without a route.** `/proc/net/route` is
   consulted first, and a loopback-only table is "no network". With no
   Wi-Fi — the common case for this device — a poll is two file reads.
3. **It backs off.** An unreachable server costs `poll`, then 2×, …, up
   to the cap. That is the whole of "must not retry-loop itself awake".

## The RTC backstop, which is the sharp edge

`autosuspend.lua` arms its safety wake by reading the RTC's own clock
(`/sys/class/rtc/rtc0/since_epoch`) and writing `since_epoch + N` to
`wakealarm` — an **absolute** value in RTC seconds. Two things follow:

- a wrong *system* clock never misplaces the alarm (the arming arithmetic
  never reads the system clock);
- writing the *RTC* does. Step it forward past a pending alarm and the
  compare never matches, so that wake silently never happens.

So `rearm_alarm_value()` preserves the alarm's remaining **interval**
across the RTC write rather than its instant. The residual — the two
daemons do not lock, so a sync landing inside the ≤10 s window inside
`suspend_once()` can still cost one cycle's alarm — is documented in the
service header and in `doc/power-management.md`.

## Known limits, stated up front

- **IPv4 only.** The socket is `AF_INET`, `getaddrinfo` is asked for
  `AF_INET` answers, and the reachability check reads `/proc/net/route`,
  which is the IPv4 table. A v6-only network reads as "no network" and
  the daemon stays silent — wrong, but silently *inert* rather than
  silently wrong about the time.
- **One answer is trusted, and SNTP is unauthenticated.** There is no
  quorum across servers and no clock filter; the first reply that passes
  validation and lands inside the sanity window wins. Anyone who can
  answer on the path can therefore set this clock to any plausible date.
  That is the protocol, not an oversight — it is part of why the shipped
  default configures no server at all (`doc/networking.md` §7.3).
- **The correction is a step, never a slew.** Anything measuring
  durations across the step sees a discontinuity — which is why the step
  is announced to `/dev/kmsg`, and why `autosuspend.lua` grew
  `idle_elapsed()`.

## Running it by hand

```
luajit timesync.lua --once --dry-run --skip-route-check \
       --server 192.168.1.1 --quiet
```
prints `WOULD-SET <epoch>` and sets nothing. Drop `--dry-run` (as root)
to actually step the clock; drop `--once` for the daemon behaviour.
`--hwclock ""` disables the RTC write-back.

## What `make timesync-check` covers, and what it does not

Covered, on the host, with no root, no network, and no device:

- **verbatim extraction** of the protocol and policy functions from the
  shipped `timesync.lua` — packet construction, reply validation (mode,
  version, LI=3, stratum bounds, nonce echo, truncation), the NTP era-0 /
  era-1 split at 2036, the plausibility window, the backoff schedule, the
  route-table reader, and the alarm re-arm arithmetic;
- **a real loopback round trip**: the suite binds a UDP socket, launches
  the actual daemon at it, answers one request with a time it chose, and
  requires that time back out of `--dry-run`. That is what proves the
  `ffi.cdef` struct layouts — `sockaddr_in`, `pollfd`, and glibc's
  `struct addrinfo` field order (glibc puts `ai_addr` before
  `ai_canonname`; musl the other way, and a wrong guess yields a wrong
  address rather than a crash). The `localhost` round exercises
  `getaddrinfo`, the `127.0.0.1` round `inet_pton`;
- **the service defaults**, cross-checked against the daemon's, and the
  pinned fact that the shipped configuration has **no servers**.

Not covered, and not claimable from a green run:

- `settimeofday()` and `hwclock --systohc` are never executed — the suite
  runs `--dry-run` throughout, because a test that sets the developer's
  clock is not a test anyone will run twice. The RTC path is arithmetic
  here, sysfs on the device.
- Nothing has been booted. **No clock has been set on a PineNote**, no
  image carrying this has run, and the interaction with a real suspend
  cycle is reasoned from `autosuspend.lua`'s source, not observed.
- The daemon's timing behaviour across an actual suspend (that the
  monotonic wait really is frozen and really is not a wakeup source) is a
  property of `poll(2)` and of Linux suspend, argued rather than measured.
