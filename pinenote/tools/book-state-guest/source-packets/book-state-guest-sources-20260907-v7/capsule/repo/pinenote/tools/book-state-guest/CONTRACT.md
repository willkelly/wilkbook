# Persistent Book State guest contract

Status: **non-shipping v7 source candidate**. Reader-join v2 and the rebased
15-patch USER_NS kernel source gate are independently accepted prerequisites;
BSG-1 through BSG-5 are closed for the accepted v6 source. Its exact image
`/gnu/store/9yx1xmhf2hnsp6vdwnvvxzqv3i9i9fkz-disk-image` (SHA-256
`53bee9f09d7b3a12ad5e9bf77f1dd91a1e2416be8ba205f06889becfd00de9d4`)
is accepted as an unexecuted artifact by review `02a4d7ad…`. Before QEMU, source
inspection found that successful per-container boundary records remained only
in ephemeral `runsc.stdout`; the console exposed those captures only on failure.
This v7 successor changes the authority and host checks only to validate and
publish each actual finalized record. It is not yet accepted, built, or booted.

## Frozen inputs

- Candidate repository baseline: `399764fa53d4e54bdcfaf84c362d4d1debf35f4c`.
  The immutable accepted-prerequisite attestation still records its earlier
  source base `549dded816e5f73d2c11557ffcd3130a018b82a8`; v7 does not rewrite it.
- Accepted reader-join v2 source root: `6fcbb5b7…`; its exact functional
  Guile/Python files are machine-gated individually from canonical non-build
  paths. The review packet (`87ae3ac2…`) and evidence (`f0128637…`) are recorded
  in the versioned `accepted-prerequisites-v1.txt` attestation.
- Exact kernel derivation/output: `61ls988…drv` / `334ljs8…`; Image
  SHA-256 `5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9`.
- Runtime package: public `gvisor/source`, pinned to
  `release-20260831.0` / `fd2f6b2674208086e324c2f739155eb7e1b48ff2`; accepted
  AArch64 output `/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`.

The system references every required functional file at its canonical
non-build path and verifies the accepted literal hash. It imports the public
execution-spike base directly, not the historical CONTROL/reader systems whose
graph contains `gvisor-local-test-artifacts.scm`. It never imports a mutable
`build/` tree, public runner hash, live review, `/tmp` wrapper, or recursive
source directory. `SOURCE-MANIFEST.sha256` is the executable source roster;
live append-only reviews are informative links only.

`CAPSULE-ROSTER.tsv` is the outer preparation roster. It binds the complete
transitive project-module closure, every relative `local-file` input needed by
system evaluation and lowering (including all 15 kernel patches and the finite
gVisor package-tool/source metadata), and every source-only check. It also binds
`SOURCE-MANIFEST.sha256`, so manifest tampering fails before a capsule is
claimed complete. The manifest deliberately excludes itself; the capsule
roster is the one-way outer binding and is itself frozen by each review packet.

`prepare-source-capsule.py` copies only that positive roster into private
`repo`, `module-view`, and zero-Scheme `package-view` trees. It follows no
symlink, accepts no special or multiply-linked input, re-reads every source
after copying to reject a changing capture, and makes the result read-only.
The module view contains only declared transitive project modules plus their
explicit relative `local-file` assets. Check-only Scheme is not on
`GUILE_LOAD_PATH`; `-L` points only at the separate zero-Scheme package view.

The source-built runtime changes the executable identity from the older
accepted CONTROL demonstration. That historical runtime remains evidence for
its own package only; it does **not** prove this source-built package. The later
QEMU gate must explicitly validate the new gVisor package together with this
guest, the accepted USER_NS kernel, and persistent state image. This source
packet makes no such runtime claim.

## Authority and channels

Guile is the sole authority. The fixed Guile and Python namespaces, access,
text A/B, and language identity are source constants. Each fresh language
instance receives one fresh Book Session endpoint in one fresh owned runsc
container. Its sole application capability is the connected Unix socket at FD
3, donated only through `--pass-fd=3:3`. Books receive no state-volume or
database mount/FD, storage credential, authority namespace, phase, expected
value, replay text, or store handle in argv, environment, or another FD. The
Book State grant is issued only as protocol data over FD 3 after the book says
hello. Python remains isolated with `-I -S` and the accepted 45-path language
profile.

That language closure truthfully contains two SQLite 3.39.3 outputs: the
AArch64 output `cy2qjb…` includes the executable `sqlite3`, and the Python
runtime includes its `sqlite3` package and `_sqlite3` extension. Those tools are
not the persistent-state authority. The trusted Guile backend uses
`guile-sqlite3` 0.1.3 with the separately pinned SQLite 3.53.1 output
`jcrkzfn…`. The security boundary is capability and mount isolation, not the
absence of SQLite code from the book closure.

Each OCI process must run a compile-fixed boundary probe immediately before the
unchanged accepted book. The probe source openly names the authority root,
database, a non-secret sentinel, and the separate private UI device; knowing a
path string is not authority. It uses direct OS `stat`/`open` calls—not a failed
SQLite import—to require that root visibility and read/write opens fail only as
not-found or permission-denied. It also requires neither authority path appears
in sandbox mountinfo and that FD 3 is the sole non-CLOEXEC socket. Interpreters
may have opened their own source files or internal pipes above FD 3 by this
point; each must be CLOEXEC, neither socket nor character device, and name
neither authority path. The accepted stopped adapter separately enforces the exact pre-exec roster
`0,1,2,3`. Probe failure prevents the accepted book from starting; normal guest
success still additionally requires the real book's
typed `state-read` and, on boots one and two, `state-commit` over FD 3. No native
fallback exists. These probes become runtime evidence only when the candidate
actually runs under source-built gVisor on ARM; host syntax/static checks are
not containment evidence.

The probe's stdout line has one closed grammar per fixed language:

```text
BOOK_STATE_SANDBOX_BOUNDARY: language=guile result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3
BOOK_STATE_SANDBOX_BOUNDARY: language=python result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3
```

After the Book Session endpoint is released, the accepted owner has reaped the
entire runsc process group, and both bounded pipes have reached EOF, v7 requires
runsc exit 0 and no stdout/stderr overflow. The authority then opens the exact
owned `runsc.stdout` as a stable, no-follow FD; requires a single-link,
owner-only mode-`0600` regular file whose size equals the bounded capture's
observed byte count; and verifies identity, size, timestamps, and content across
the read. The complete capture may contain fixed-book diagnostics, but it must
contain exactly one occurrence of the reserved
`BOOK_STATE_SANDBOX_BOUNDARY` stem as a complete newline-terminated record equal
to the language's line above. Missing, duplicate, quoted/injected, wrong-
language, failure, malformed, truncated, late-mutated, or overflowed captures
fail even when the child exited 0.

Only after all checks does the authority write this non-pass source record to
`/dev/console`:

```text
BOOK-STATE-GUEST sandbox-boundary-source language=LANG container=CONTAINER source=owned-finalized-runsc.stdout publication=next-line-after-child-drain marker-bytes=N marker-sha256=HEX64 capture-bytes=N capture-sha256=HEX64
```

`LANG` and `CONTAINER` are the compile-fixed matching identity; byte counts and
digests come from that stable capture read. Only after that write succeeds does
the authority copy the exact extracted capture substring—not its expected
comparison string—as the next complete console line. Thus a source-record or
marker publication failure cannot emit a complete trusted marker or permit the
eventual guest `result=pass`; a marker-write failure may retain only the
non-pass source record. `publication=next-line-after-child-drain` states that
serial line order is observation order, not probe execution order: the fixed
prelude executed before the book hello, while its relay appears only after the
same process completed the book interaction. This proves provenance only for
these authenticated fixed fixtures; it is not a general defense against an
arbitrary hostile book that can print chosen stdout.

The native KOReader peer receives only the separate CLOEXEC virtio channel
`org.wilkbook.book-interaction`. Its accepted state-text codec permits 0–4096
UTF-8 bytes while all predecessor constructors retain their prior policy. This
first two-boot gate uses two nonempty multilingual namespaces; empty persistence
remains a later gate.

Only this success order can paint **Saved**:

1. real UI Save callback emits `submit`;
2. trusted `host-action!` creates the exact action;
3. fixed book issues `state-commit` with its restart-safe CSPRNG-surface-derived
   operation ID;
4. accepted adapter/backend returns through the endpoint-owned typed observer;
5. the bridge validates session, surface, grant, request, action, sequence,
   operation, expected version, text, and typed response;
6. authority sends correlated `commit-ok`;
7. fixed book receives a separate `present-saved` action; and
8. UI emits `applied` after paint.

`present` and `applied` are never storage evidence. Recovery is accepted only
from a real fixed-book `state-read` and its typed completion.

## Persistent volume and shutdown

The sole data device is a mandatory 64 MiB ext4 filesystem labeled
`WBBookStateV1`, mounted at `/var/lib/wilkbook-book-state-demo` with
`noatime,nodev,nosuid,noexec`. A one-shot service requires the exact generated
filesystem service, verifies that live mount, and sets/verifies its root as
root-owned mode `0700` before authority startup. It also creates or verifies the
compile-fixed, non-secret mode-`0600` file
`.sandbox-boundary-sentinel-v1`. Its existence outside the sandbox makes a
not-found/permission-denied probe result meaningful. There is no fallback
library.

The accepted backend requires a canonical mode-0700 root, not an empty root.
Therefore ext4's normal `lost+found` is harmless and no subdirectory is added;
the fixed database remains exactly
`/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite` (mode `0600`). The
post-close inspector opens that same path read-only on every boot and checks the
two exact namespaces, receipt/version relation, `quick_check`, foreign keys,
and absence of journal/WAL/SHM sidecars.

Each endpoint release closes/revokes and joins its delegate worker, then the
accepted owner joins runsc and finalizes its bounded captures. V7 validates and
publishes the actual per-language boundary record before removing runtime state,
then verifies cgroup, null-netns, runtime-state, debug, and panic-store cleanup.
Only after both language lifetimes are gone does the
authority close SQLite, inspect, finish/close the UI, and `sync`. The service
then requests shutdown; Shepherd's dependency order stops it and the volume
preparation service before the filesystem service unmounts the state volume.

Because Book State starts a worker thread when an endpoint opens, this successor
does not call `primitive-fork` afterward. It uses Guile's accepted `spawn` path
to start a fixed adapter that stops before runsc, records PID/start-time/process
group, maps selected stdin to sole application FD 3, closes unrelated FDs, and
executes the already validated CONTROL argv.

The BSG-1 successor reserves the connected endpoint on FD 3 before opening
`/dev/null`. Temporary null descriptors are integer-owned, moved above FD 3
with Linux `F_DUPFD_CLOEXEC` when a standard descriptor began closed, and
closed without Scheme-port finalizers. Existing bounded stdout/stderr pipes are
preserved. Before exec, the adapter requires the exact roster `(0 1 2 3)`, exact
endpoint identity only on socket FD 3, `/dev/null` EOF on FD 0, non-socket
stdout/stderr, and cleared close-on-exec flags. Any inherited endpoint alias or
other descriptor is closed.

## Two-boot state machine

No phase or expected value enters from outside:

| Actual typed reads at boot start | Required behavior | Final state |
|---|---|---|
| both absent/version 0 | paint absent, automate real edit/save A | A/version 1 |
| both A/version 1 | paint recovered A before any edit, then save fresh B | B/version 2 |
| both B/version 2 | paint B; do not create another save | B/version 2 |
| mixed or anything else | fail closed; no fallback | diagnostic preservation |

The A→B save uses a fresh session/surface and therefore a new operation ID.
Same-operation retries, when used by the accepted book, retain operation ID,
expected version, and text. The authority applies a three-second cooperative
polling deadline to each state operation and a 300-second cooperative budget to
the whole interaction. Those clocks are checked only when trusted Scheme has
control. They do not preempt a storage callback in SQLite/kernel I/O, backend
revocation, a delegate `join-thread`, database close, `sync`, or halt.

## Liveness and the required outer QEMU owner

This non-shipping one-shot system provides **no standalone hard guest cleanup
deadline**. It is supported only as a QEMU demonstration boot beneath the
separately reviewed disposable-QEMU process guardian identified in
`outer-qemu-handoff-v1.txt`. Every actual boot must pass that owner the explicit
options `--timeout-seconds 360 --term-grace-seconds 5`. The owner must bind one
exact QEMU process group, run as its child subreaper, and on timeout perform
TERM, the bounded grace, SIGKILL if needed, and bounded descendant reap. A
timeout is failure with “guest status was not assessed”; it is never a guest
pass.

The authority now polls a non-stopping pre-exec adapter child with `WNOHANG` and
its cooperative deadline, then best-effort kills and reaps that exact child on
the ordinary failure path. This removes BSG-2's earliest unconditional blocking
`waitpid`. It does not pretend that a Guile clock can interrupt arbitrary
storage FFI or the accepted delegate's revoke/join sequence. If one of those
blocks, the outer owner terminates the VM. The standalone image may otherwise
remain hung and never halt.

The final `result=pass` marker is emitted only after both actual boundary-marker
publications, both Book Session endpoints and runsc ownership trees are
closed/reaped, the backend and SQLite database are closed, the read-only
inspector and UI finish/close complete, and `sync` returns. A missing marker or
blocked cleanup therefore cannot synthesize success, clean database close,
`sync`, unmount, or halt evidence. Outer termination models a process/VM crash
followed by SQLite journal recovery on the next boot; it is not a clean unmount
test or a physical-power-loss durability test.

The canonical guardian source exposes the required CLI and lifecycle, and the
host test executes its real process-owner function. Binding those exact options
through the active two-boot runner remains pending independent proof. Source or
image review does not authorize an actual boot until that outer integration is
accepted.

## Source-only check

Run `sh ./run-tests.sh`. Shell scripts are always invoked through `sh`, so a
frozen read-only packet does not rely on executable mode. The launcher
authenticates the source preparer before execution, creates the explicit
read-only capsule, and runs all checks from that private copy. It authenticates
the explicit source roster, proves the
OCI successor preserves the accepted runtime flags and adds only Python `-S`
plus mandatory fixed pre-book probes and their source mounts, compiles with
warnings enabled, syntax-checks both probes without executing them, exercises
actual accepted Guile backend/bridge modules with
an ext4-shaped `lost+found`, executes the post-close inspector through A→B,
tests the real private codec/virtio owner over a mock socket, and compares the
static Guix OS graph. It also runs harmless native child writers through the
accepted owned-process/capture lifecycle and the exact authority relay helper.
Both valid languages prove that model-console bytes come from the finalized
capture and carry its digest/length. Missing, wrong-language/container, duplicate,
quoted-extra, failure, malformed, truncated, invalid-UTF-8, nonzero,
stdout/stderr-overflowed,
deleted, late-mutated, and source/marker-publication-failure cases emit no
trusted pass marker. This is an observability model only,
not execution of either actual probe or evidence about runsc, Sentry, ARM,
containment, QEMU, persistence, networking, hardware, or a device. The suite
also rejects the historical local gVisor wrapper and generated/live-review
inputs; it does not build or boot an image.

Before those broader checks, the suite executes the real Scheme FD adapter and
a harmless native Python exec fixture. Its bounded matrix reproduces BSG-1's
FD-3-free precondition, then covers occupied FD 3, endpoint already on FD 3,
open/closed stdin, duplicate endpoint aliases, closed output descriptors, and
preservation of live stdout/stderr capture identities. The fixture proves FD 0
is EOF and not the Book Session socket while bidirectional traffic succeeds
only through FD 3. It never invokes runsc.

The suite also gives a non-stopping spawned child to the authority's real
`WNOHANG` stop poll and proves finite cooperative return plus exact child reap.
Then, under a short fail-safe wrapper, it calls the accepted outer guardian's
real `run-owned-process` with three TERM-resistant host fixtures: an intentional
blocking `waitpid`, an actual accepted delegate blocked in backend revocation,
and the same delegate blocked in worker `join-thread`. In both delegate cases
the real cooperative deadline expires and local delegate state closes first.
The outer reports timeout, kills and reaps the exact process group, and no
post-cleanup/pass marker appears. This is a host process-containment test, not
QEMU, runsc, ARM, SQLite, unmount, or power-loss evidence.

Before the first Guix, Guile, or guild process, `pinned-guix.sh` replaces caller
HOME/XDG/cache and all Guile/Guix code-path variables with private directories.
It admits only one immutable `/gnu/store/*-guix-command`, gives Guile the
positive module view, and gives both outer and time-machine Guix only the
zero-Scheme package-discovery view. A regression seeds executable malicious
bytecode in both the caller's default HOME cache and explicit XDG cache,
demonstrates that an unsafe Guile invocation executes it, then proves the pinned
entry loads every project module from the canonical private view without firing
either canary.

After that gate is green, prepare a capsule and run the optional
derivation-only check with an absent private process directory:

```sh
BOOTSTRAP_GUIX=$(/usr/bin/readlink -f "$(command -v guix)")
sh CAPSULE/repo/pinenote/tools/book-state-guest/pinned-guix.sh \
  ABSENT-PRIVATE-ROOT CAPSULE/module-view CAPSULE/package-view \
  CAPSULE/repo/channels.scm "$BOOTSTRAP_GUIX" \
  repl -q -- CAPSULE/repo/pinenote/tools/book-state-guest/derive-system.scm
```

It establishes the AArch64 target before resolving `gvisor/source`, disables
grafts and substitutes, sets one job/two cores, asserts the accepted kernel and
source-built gVisor output paths, and prints only the computed system derivation.
It does not realize that derivation. Requisite inspection uses
`query-requisites.scm` through the same launcher's pinned `repl`, private
HOME/XDG boundary, positive module view, and zero-Scheme package view. This
avoids a direct ambient `guix gc` query and gives every nested Guix invocation
the explicit zero-Scheme `-L` package-discovery path.
