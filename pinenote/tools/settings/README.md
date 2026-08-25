# settings — the configuration coupling gate

    make settings-check

Rung 1 (`doc/testing.md`): text analysis of the tree, python3 stdlib only.
No Guix evaluation, no build, no store read, no device.

## What it is for

The same knob is declared in several places at once — a Guix
service-configuration record field, a Lua daemon's `opt` table, a `.conf`
key, an argv flag, a build-time module-parameter string, a host tool that
models the shipped stack — and nothing connects the copies. Issue #12's
inventory found 63 operator-reachable knobs across five naming systems.
This gate asserts the copies still agree, so a change to one of them
cannot silently leave the others behind.

Six couplings are checked:

| gate | what must agree |
|---|---|
| record ↔ daemon | every Guix record default equals its Lua `opt` twin (15 pairs across `autosuspend`, `ddr-boost`, `timesync`) |
| shipped EBC parameters | the three build-time copies of the `rockchip_ebc` parameter set — `ebc.scm`'s modprobe options, `firmware.scm`'s `set_parameter` script, `firmware.scm`'s modprobe options — agree key by key |
| waveform literals | every runtime **self-heal** path restores the *shipped* `refresh_waveform`, and the three concurrent writers agree on the GC16 wash transient |
| KOReader seeds | the dead `reader-session.scm` seed is a value-identical subset of the winning `pinenote-reader.scm` seed (the 2026-08-05 class) |
| host model ↔ shipped | `ebc-replay.c`'s `policy_ship()`, which says it models the deployed stack, actually does — including what its usage banner tells an operator the device does |
| runtime `.conf` keys | one boolean grammar; one meaning per key name; every runtime knob has a record field that can express it in a system declaration; and the two persistent (p7) override files share one directory |

## The debt register

`check-settings.py` passes on today's tree **and** records the drift that
is in it, one row per divergence in `DEBT_REGISTER`.

This is a debt register, not an exemption mechanism:

* a divergence **not** in the register is a hard `FAIL` — new drift is a
  bug, and adding a row to silence it is the wrong repair;
* a row that stops matching, because the drift was **paid off**, is also
  a `FAIL` (`stale debt-register entry`) and must be deleted. The
  register can therefore only shrink.  A row owns a SPECIFIC divergence,
  not a site: if the drift at a registered site changes, the gate fails
  with `DIVERGENCE CHANGED` rather than absorbing it as old inventory.
  The first version of this gate matched on the site id alone, so new
  drift at a known-bad site passed silently -- caught in review;
* each row names the issue-#12 step expected to retire it.

Issue #12 step 1 asks for a check that goes red against today's tree. A
permanently-red check is worse than no check — it trains people to ignore
it, and `make check-host` has to stay `EXIT=0` for CI to mean anything —
so the redness is captured as inventory instead. The count in the summary
line is the finding: it should only ever go down.

## Why there is a mutation suite

    python3 pinenote/tools/settings/test-check-settings.py

A gate that reads sources as text fails characteristically: a pattern
stops matching, every comparison silently has nothing to compare, and it
reports a green it did not earn. `pinenote/tools/timesync` records the
same lesson inside its own cross-check ("unescaped, every one of these
matches nothing and the whole cross-check passes vacuously").

So every extractor here treats "site not found" as a `FAIL`, and the
self-test breaks **one coupling at a time** in a scratch copy of the tree
and requires the gate to reject that copy naming that coupling. It also
proves the two properties that keep the register honest: an unlisted
divergence fails, and paying off a listed one fails too.

## Overlap with `timesync-check`

`pinenote/tools/timesync/test-timesync.lua` already cross-checks its own
service record against its daemon. That is deliberate duplication: the
suite belongs with the daemon it tests, and this gate is the single
register that covers the whole tree. If they ever disagree, believe
neither and read the sources.
