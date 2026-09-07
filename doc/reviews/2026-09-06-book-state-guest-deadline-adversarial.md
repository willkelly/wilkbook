# Book State guest v3 deadline successor — adversarial review — 2026-09-06

## Verdict

**BSG-2 is closed at the required external containing boundary.**  The v3
source no longer describes its in-guest clock as a whole-guest hard deadline.
It provides a 300-second cooperative polling budget, makes the previously
blocking pre-exec child wait nonblocking, and requires a distinct host process
guardian to terminate and reap the one exact QEMU process group after 360
seconds with a 5-second TERM grace.  Backend revocation and delegate join are
still honestly allowed to block.  There is no standalone-image hard-deadline
claim.

The source and supplied controls are consistent with that boundary.  My
independent 21-check control reproduced all three relevant stuck classes
(blocking `waitpid`, backend revoke, and delegate join) under the exact accepted
guardian implementation.  Every case timed out, escalated, and reaped its exact
PID/start-time/process group within the host bound; an unrelated live process
was not signalled.  No guest-cleanup, `sync`, halt, or pass marker was
synthesized.

**This is not a full guest/system acceptance.**  Actual binding of
`--timeout-seconds 360 --term-grace-seconds 5` to each QEMU boot remains
explicitly pending, and the original guest reviewer is separately continuing
the public-system review.  I did not inspect mutable two-boot work or duplicate
that review.

There is also a new, separate packet-readiness blocker, **BSG-3**: the frozen
source view cannot replay its own system check or derivation.  Its included
`gvisor-source.scm` imports `(pinenote packages gvisor-dependencies)`, but that
module is absent from the 45-entry canonical source roster and 46-file source
snapshot.  The included execution-spike system likewise imports the absent
`pinenote/packages/kernel.scm` and `pinenote/systems/base.scm`.  The complete
native replay reaches and passes the deadline tests, then fails at
`check-system.scm` with:

```text
no code for module (pinenote packages gvisor-dependencies)
```

Consequently the supplied derivation and 2,784-requisite graph records remain
authenticated candidate evidence, but are not independently reproducible from
the frozen source authority as instructed.  The v3 packet is **not yet
ready-to-build**, independently of BSG-2's closure.

## Scope and authenticated authority

I treated the frozen packet, not the mutable checkout, as source authority:

```text
f6331a3d43f9c5be60aa630acc5eabb0eb99c50bea9f07708e3a9b595f38f0fb  source/pinenote/tools/book-state-guest/SOURCE-MANIFEST.sha256
ee251ccdac685cf38ed85b6772836dddcc58ca099b0b38ce5ddd194320fbdf5e  SOURCE-SNAPSHOT.sha256
c57e7bb67959a43f18930e862c0dbefdef48c7d847bf44187bfe1936b14b70ee  EVIDENCE.sha256
3e1e4abc4e36b418ff166a13fff2172dcce70d7163c6afc15d34f6db1a813199  PACKET.txt
ee43fd585dbc39fc163384bfddb9ae2b3c553b4b6a8e198b3f2734c62d953fc5  pinenote/systems/pinenote-book-state-reader.scm
688b2a9dbe5d9ce983cb3e8ca5604a12f494a6a592f5cf0b6cede4fbbeb3be73  pinenote/tools/book-state-guest/book-state-guest-authority.scm
15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb  pinenote/tools/book-state-guest/runsc-fd3-exec.scm
8e829d706d6737378aa6b01da4cdb64fd3d0dcdc5120542a0c3c7493431296cf  pinenote/tools/book-state-guest/test-liveness-boundary.scm
640c23e2c3095bc23d06cb2d547c25580daf751dda111eb727e7880ee3c3c0ed  pinenote/tools/book-state-guest/test-liveness-fixture.scm
27b747aac8c8909fa4ce224d1030e61b389a3d2fee6a2d1737ac055889fd607d  pinenote/tools/book-state-guest/outer-qemu-handoff-v1.txt
0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca  pinenote/tools/book-execution-spike/disposable-qemu.scm
```

Both strict manifest checks passed.  The packet contains 46 regular source
files, no symlinks, and no writable file or directory.  Its original review was
also exact:

```text
3f1aab70c2c3de8beb712fa7294004f785ba61532b52a96c08b14c75f16069ad  doc/reviews/2026-09-06-book-state-guest-adversarial.md
```

The FD adapter, backend adapter, and state delegate are byte-identical between
the frozen v2 and v3 packets:

```text
15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb  runsc-fd3-exec.scm
349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769  book-state-backend-adapter.scm
eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6  book-state-session-delegate.scm
```

Thus the v3 deadline change did not reopen BSG-1 or modify the prior backend or
delegate candidates.

## BSG-2 analysis

### 1. The in-guest clock is now accurately cooperative

`run-guest!` creates one monotonic deadline from
`cooperative-run-budget-seconds = 300.0`.  UI/session pumping and the fixed
scenario waits check it.  The old `whole-run-timeout-seconds` name and implied
hard whole-guest claim are gone.

The pre-exec adapter wait now calls:

```scheme
(waitpid pid (logior WUNTRACED WNOHANG))
```

It polls until `SIGSTOP` or the cooperative deadline.  Its exceptional cleanup
sends `SIGKILL` to that exact owned PID and polls `waitpid ... WNOHANG` for one
second.  This closes the normal non-stopping-adapter case without pretending a
Scheme deadline can reap a process stuck in uninterruptible kernel I/O.  In
that latter case, the external QEMU owner remains the hard boundary.

The supplied real-function control passed all three assertions for this path:
the non-stopping child reached the cooperative deadline, control returned in
under two seconds, and the exact child was reaped.  My separately authored
control reproduced the same result.

### 2. Revoke and join remain honestly blocking

Book Session detaches the delegate under its endpoint owner by performing the
local close first.  That invalidates session state, sets stopping, removes a
not-yet-started task, and detaches the delegate before any storage callback.
Outside the authority mutex, `finish-book-state-session-delegate-close!` calls
backend revocation and then joins the worker.

Either external operation can still block.  V3 does not wrap them in a
fictional in-process timeout.  The supplied and independent fixtures exercised
the actual delegate close functions in two distinct cases:

1. the worker owns storage and backend revoke blocks acquiring it;
2. backend revoke returns, but joining the blocked worker does not.

Both reached local close first.  Neither returned from final close before the
external guardian timed out and killed the process group.

There is deliberately no post-kill assertion that the delegate task slot is
empty.  A forced outer kill is a process/VM crash boundary, not a completed
delegate close.  Any resulting SQLite state must be assessed under the
backend's crash/journal semantics, not described as a clean halt.

### 3. The accepted external guardian supplies the hard bound

The handoff names the accepted guardian source exactly and requires:

```text
required-outer-timeout-option=--timeout-seconds
required-outer-timeout-seconds=360
required-outer-term-grace-option=--term-grace-seconds
required-outer-term-grace-seconds=5
required-owner-unit=one-exact-qemu-process-group-per-boot
required-owner-timeout-action=term-grace-sigkill-bounded-subreaper-reap
required-timeout-result=fail-guest-status-not-assessed
```

The guardian is a separate host process with its own monotonic deadline.  Guest
output, output EOF, or a hang in cooperative guest code cannot postpone that
deadline.  The reviewer control used shorter fixture values (0.75-second
timeout, 0.10-second TERM grace) against the exact source function to keep the
test finite.  For deliberate blocking `waitpid`, revoke, and join it proved:

- exact return `(124 . #t)`;
- TERM followed by SIGKILL where TERM was intentionally ignored;
- bounded return;
- disappearance of the recorded PID/start-time and its process group;
- no `result=pass`, `SYNC-COMPLETE`, or `HALT-REQUESTED` marker; and
- survival of an unrelated process outside the owned group.

This validates the already accepted **host-process model**.  It does not yet
prove that the pending two-boot runner puts each real QEMU invocation under
that owner with the exact 360/5 options.

### 4. Success and forced-failure claims remain disjoint

The actual success path is ordered as follows:

1. each Book Session is released, locally closed, backend-revoked, worker-
   joined, and its runsc process finalized;
2. runsc capture and owned runtime/cgroup cleanup complete;
3. the trusted SQLite runtime closes;
4. the closed database is reopened read-only and checked for mode, sidecars,
   schema, integrity, namespaces, receipts, versions, and text;
5. the private UI receives `finish`, its terminal state is checked, and the UI
   closes;
6. the authority calls `sync`; and only then
7. the sole `result=pass` marker is emitted.

The system wrapper emits its later success markers, syncs again, and requests
halt only after the authority returns.  Conversely, outer termination reports
failure with guest status unassessed.  It does **not** claim a closed database,
unmounted volume, completed sync, or halt.

## Focused preservation checks

The source-only assertions passed 39/39.  A separate frozen-view host run then
passed:

- the eight-case native FD matrix plus its final FD-3-only assertion;
- warning-enabled compilation of the authority, FD adapter, and OCI bundle;
- 18/18 supplied liveness assertions; and
- 23/23 backend/bridge module assertions.

The adapter still handles source-equals-target FD 3, initially closed stdin,
initially occupied FD 3, duplicate socket aliases, and closed stdout/stderr.
Immediately before `exec`, its exact roster is FD 0–3, FD 3 is the donated
socket, and FD 0–2 are non-sockets.  The reviewer control introduced no new
file descriptor.

The OCI source mounts only proc, bounded tmpfs `/dev` and `/scratch`, the fixed
45-path language closure, and fixed read-only book/protocol sources.  It does
not mount the Book State root or database.  Its rootfs is read-only, the book
runs as UID/GID 65534 with no capabilities and `noNewPrivileges`, and runsc
receives only `--pass-fd=3:3`.  SQLite and `guile-sqlite3@0.1.3` remain in the
trusted supervisor profile, not the sandbox book closure.

These checks cover the deadline delta and its adjacent close/order/profile
invariants.  They are not a substitute for the original reviewer's remaining
guest/system review.

## BSG-3 — frozen source view is not a replayable system authority

The packet's `COMMANDS.txt` says to run the source/native/static gate from its
own `source/` tree and to lower the system there with `guix ... repl -L .`.
That tree includes `pinenote/packages/gvisor-source.scm`, whose line 18 imports
`(pinenote packages gvisor-dependencies)`, but does not include
`pinenote/packages/gvisor-dependencies.scm`.

This is not merely an unrealized local-file input.  Module resolution fails
while evaluating `check-system.scm`, before the operating-system object can be
compared or lowered.  At least two further imported project modules are also
outside the frozen view:

```text
pinenote/packages/kernel.scm
pinenote/systems/base.scm
```

The complete replay through `sh run-tests.sh` passed all preceding source and
native gates, then exited 1 at this module failure.  The narrower exact
`check-system.scm` invocation reproduced the same result.  (`run-tests.sh` is
0444 as part of the packet's unchanged immutable-file convention, so invoking
it through `sh` was necessary; this does not affect the module failure.)

The authenticated supplied records say:

```text
SYSTEM-DERIVATION /gnu/store/nfd0492jbf77bxyp9il9hfv9ck74icgd-system.drv
requisites=2784
kernel-output=/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote
gvisor-source-output=/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0
```

I did not relower these claims from another checkout, because that would replace
the frozen source boundary with mutable, unauthenticated dependencies.  BSG-3
can be closed by a successor source authority that includes and hashes the
complete project-module/local-file dependency boundary (or by an equally exact
authenticated base-plus-overlay composition), followed by a successful static
system check and derivation-only replay from that authority.

## Remaining obligations

1. Close BSG-3 and independently reproduce the static system object and
   derivation from the corrected frozen authority.
2. Let the original guest reviewer finish the remaining source/system review;
   this report accepts only the BSG-2 delta and adjacent finite invariants.
3. Independently verify that the actual two-boot runner applies
   `--timeout-seconds 360 --term-grace-seconds 5` to the exact QEMU process
   group on **each** fresh boot.
4. Only then run two fresh real guests: boot 1 saves and shuts down cleanly;
   boot 2 reopens the retained state and paints it.
5. Keep forced-timeout crash recovery, clean two-boot semantic persistence,
   current-kernel validation, and hardware validation as separate claims.

## Independent evidence

The read-only independent evidence packet is:

```text
/tmp/opencode/book-state-guest-v3-deadline-independent-evidence.1djfi1
9b320f7b46f6adf35b2cf169ee3ea02500b3fd5fb0675e999383b11cf15c31a2  MANIFEST.sha256
```

Principal evidence identities are:

```text
0bcef7c33b4c7621a9b1c51376943e8b2c119c9d50ac5e9fcdac55ef8242a4da  independent-deadline-control.scm
301b07ccff3ba4e034c4ad9ed3b5dfe5f87054efea76c8e4364051739ed081bf  independent-deadline-control.log
10820a41fbce5265a1dfbecd30990a7cf663dc670efeffb2ebc666bc5648f198  focused-host.log
890de6b18d803ac762338292f1e9919c3f05de4d897f87397d0e2f341eccb5ae  full-frozen-replay.log
4d2f6353071712ba9d112da2f1491834ea8835822696da5be8a1a097bf89c462  frozen-check-system.log
bf6f72c0957f792c5d503b43284bd9d6d2a6f735933ecfb1d6ffb2daa68bb2a8  authentication.log
```

No QEMU, runsc, ARM execution, OS image build, kernel build, gVisor build,
device access, SSH, host mount, deployment, staging, commit, push, or merge was
performed.  No implementation or frozen packet file was edited.  This new
review document is the only repository file I changed.
