# Book State guest/system source — adversarial review — 2026-09-06

## Verdict

**Not accepted for image construction or QEMU.** The 39-file source roster is
authentic and the previously accepted reader-join and USER_NS-kernel identities
match, but the new `runsc-fd3-exec.scm` adapter has a descriptor-allocation
bug. When FD 3 is free at the point where the adapter opens `/dev/null`, its
existing operation order leaves the donated Book Session socket on both FD 0
and FD 3 while its final self-check passes. This violates the candidate's
FD-3-only application-capability contract.

This is finding **BSG-1**. It occurs before runsc and does not depend on ARM,
QEMU, gVisor internals, SQLite, the reader UI, or a device. Per the repository's
stop-at-first-failed-gate rule, I did not run the broader supplied host suite,
re-lower the system derivation, build an image, or continue into runtime gates.
The author's reported green checks and cached derivation remain useful candidate
evidence, but they do not waive this earlier source failure.

## Authenticated source boundary

The candidate manifest has exactly 39 entries. `sha256sum --check --strict`
passed all 39 canonical paths, including all new guest files, the system, the
accepted reader-join files, protocol/backend/delegate files, UI files, base
system, channel pin, and public gVisor package definitions. Independently
computed principal identities are:

```text
7eed0358a220f458a9e59fe9918ce2376cf8cc4d13de867de8a0b3224ed2cf9c  pinenote/tools/book-state-guest/SOURCE-MANIFEST.sha256
1d6fc150f4fa9c0bc872cc4846ce8944ad69ff923a8396cbf74f50fcb998c1f1  pinenote/systems/pinenote-book-state-reader.scm
6a9236a4a27180efd9843050ac9476b165f34d18d8d9e8ed70eabd1ec90237e8  pinenote/tools/book-state-guest/book-state-guest-authority.scm
85c6317f652f8a6944511c68935cc25e11af812b063362e97c022b97e483baa7  pinenote/tools/book-state-guest/CONTRACT.md
957b5c1b20fcc37529d066ec79585003e6399d9d87906b61e46aa6d982f81573  pinenote/tools/book-state-guest/derive-system.scm
351e648496aeec9f46d5d192e0a9a9261bd465d86e23a7849eb13eddec218b89  pinenote/tools/book-state-guest/runsc-fd3-exec.scm
```

The prerequisite review documents currently hash to:

```text
15b0e535180540ef852a3f21895c56edbba7e32959cfc104120d4fe285c39aa5  accepted reader-join v2 review
8be8b931322b80a840eeb03c07e1228512af84f2e77c33ae9355fdc7402b03e2  accepted rebased USER_NS-kernel review
```

The retained kernel target remains identified as output `334ljs8…`, target
config SHA-256 `0a885ef8…`, and Image SHA-256 `5435c84e…`. This review did not
reopen those accepted static kernel findings. Likewise, the exact
`djgy782a…-gvisor-source-built-20260831.0` AArch64 package remains statically
accepted as a reusable package but unexecuted; that package acceptance is not
runtime evidence for this guest.

Before executing any reviewer control, I copied all 39 manifest-listed files
plus the manifest into a private read-only source view:

```text
/tmp/opencode/book-state-guest-independent-review-20260906
8058829e55d07e9ab2f5e8e6f08ba0ad25f567198c173bb703f88b87f41f071d  REVIEW-SNAPSHOT.sha256
```

All 40 snapshot records reverified after sealing. The snapshot contains no
live review document and no generated `build/` input.

## BSG-1 — FD 0 can alias the donated Book Session socket

The adapter receives the donation as stdin from Guile `spawn`, then executes:

```scheme
(let ((null-input (open-file "/dev/null" "r")))
  (dup2 0 3)
  (fcntl 3 F_SETFD 0)
  (dup2 (fileno null-input) 0)
  (close-unrelated-fds!)
  ...)
```

If descriptors 0, 1, and 2 are open and FD 3 is free, `open-file` returns FD 3.
The next `dup2(0, 3)` closes that `/dev/null` descriptor and replaces it with a
duplicate of the donated socket. The Scheme port still reports numeric FD 3,
so `dup2(fileno(null-input), 0)` then duplicates the socket back onto stdin.
Both descriptors survive exec.

The final check does not catch this. It requires only the descriptor-number set
`(0 1 2 3)`, FD 3 with `FD_CLOEXEC` clear, and FD 3 of socket type. It neither
requires FD 0 to be `/dev/null` nor requires FD 0 and FD 3 to have different
identities, and it does not forbid FD 0 from being a socket.

### Independent finite reproduction

Reviewer evidence is retained read-only at:

```text
/tmp/opencode/book-state-guest-independent-review-counterexamples-20260906
a172be7b489942d9d00b8962ef6f7ecfaf882a14d8b6d6d4e9b23a9dbd848a06  EVIDENCE.sha256
```

The control starts from the exact frozen adapter and adds only a pre-main
descriptor-table precondition: close FDs 3 through 63. The adapter's donation,
`/dev/null`, remap, validation, and exec operations are otherwise byte-for-byte
the candidate operations. A socketpair supplies stdin, the adapter performs its
required `SIGSTOP`, and a harmless host Python target inspects inherited FD 0
and FD 3 after exec. No runsc or sandbox code is invoked.

For comparison, the unmodified adapter on this host stopped with incidental
Guile descriptors 3 through 9 already occupied. `/dev/null` consequently
opened above FD 3 and the observed result happened to be safe:

```text
normal-host-stopped-fds=[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
fd0=/dev/null  fd0_socket=false  fd3_socket=true  same=false
```

With the clean descriptor table, the adapter still exited status zero and its
self-check still passed, but the exec target observed:

```text
clean-table-control-stopped-fds=[0, 1, 2]
fd0=socket:[…]  fd3=socket:[…]  fd0_socket=true  fd3_socket=true  same=true
RESULT=DEFECT_REPRODUCED_FD0_AND_FD3_ALIAS
```

The normal-host result does not close the defect. The candidate pins Guile but
does not establish incidental occupation of FD 3 as a contractual precondition,
and the adapter explicitly claims to normalize an inherited descriptor table.
Correctness must not depend on an unrelated Guile runtime descriptor happening
to reserve the destination number.

At the runsc boundary this exposes the Book Session capability as stdin in
addition to `--pass-fd=3:3`. The OCI process has ordinary inherited standard
I/O, so absent a separate proven closure this can expose the same connected UDS
to a sandboxed book as FD 0 as well as FD 3. Even before that downstream effect,
the trusted adapter has already violated the source contract that the connected
socket is donated only as FD 3.

## Why the reported green source suite does not close BSG-1

The supplied `run-tests.sh` compiles `runsc-fd3-exec.scm` with warnings enabled
but never executes its descriptor remap. `test_source.py` checks only that the
authority names `spawn-owned-runsc-safely` and the adapter contains `SIGSTOP`.
The Guile backend/bridge/inspector tests do not invoke the adapter, and the
static Guix graph check cannot observe exec-time descriptor identities.
Therefore all reported source tests can pass with BSG-1 present.

For the same reason, a successfully lowered system derivation would prove graph
selection, not this FD invariant. I did not rerun the reported 23-test host
suite or the cached derivation helper after the counterexample went red. No
later graph, package, or build result may retroactively relabel this source gate
green.

## Minimum successor requirement

A successor should:

1. reserve FD 3 from the donation **before** opening `/dev/null`—for example,
   duplicate stdin to FD 3 and clear its close-on-exec flag first, then open and
   duplicate `/dev/null` onto FD 0 and close the temporary null descriptor;
2. assert after cleanup that FD 0 is the intended non-socket null input, FD 3 is
   the connected socket, the two identities differ, and the only retained
   descriptors are 0 through 3;
3. add finite executions with FD 3 initially free and initially occupied, not
   only a source-token assertion;
4. rerun the source manifest, compile/static checks, backend/bridge tests, exact
   OCI-delta check, and static Guix graph check; and
5. because the adapter hash is embedded in `%runtime-source-hashes`, refresh and
   independently review the adapter, system source, source manifest, contract,
   tests, and any changed derivation identity before image construction.

This repair need not alter Book Session, Book State, protocol, backend, bridge,
book, UI, OCI policy, kernel, gVisor package, filesystem architecture, or the
two-boot state machine. Those boundaries should remain hash-identical unless a
separate reason and fresh review are supplied.

## Scope and conduct

Static tracing before the first failure confirmed that the candidate intends a
Guile-owned fixed namespace/grant/backend path, separate private virtio UI
channel, fixed source mounts, Python `-I -S`, and public source-built gVisor
selection. These observations are not an acceptance of the uncompleted
authority/service/lifecycle review. In particular, this verdict makes no claim
about two-boot recovery, shutdown/unmount ordering, whole-run blocking bounds,
ARM64 FFI loading, Systrap execution, gVisor cleanup, UI paint behavior, or
physical durability.

One reviewer setup attempt tried to create counterexample files beneath the
already sealed mode-`0500` snapshot and failed with `EACCES` before adapter code
ran. The control was then created in a separate reviewer-owned directory and
the successful reproduction above was sealed; the failed setup did not alter
candidate or snapshot bytes.

No implementation, manifest, frozen packet, accepted prerequisite, kernel,
gVisor package, image, or system source was edited. No image/system/kernel/
gVisor build, Guix derivation lowering, runsc, QEMU, ARM code, device, SSH,
mount, network investigation, staging, commit, push, fetch, merge, or rebase was
performed. This new review document is the only repository-path edit.

## V2 successor continuation — BSG-1 closed, BSG-2 blocks acceptance

### Disposition

**The exact v2 source successor is not accepted for image construction or
QEMU.** Its FD adapter closes BSG-1, including the reviewer's original FD-3-free
counterexample. The resumed authority review found a distinct blocker,
**BSG-2**: the source and build manifest claim that the complete guest is
bounded to 360 seconds, but that deadline does not govern blocking child-start
or storage-worker cleanup paths. A live child that does not reach the adapter's
`SIGSTOP`, or a storage worker stranded in a backend call, can prevent the
authority from returning indefinitely. In those paths the error handler,
database close, inspector, final `sync`, and halt are never reached.

This does not reopen BSG-1, the reader-join v2 acceptance, the retained kernel
source gate, or the reusable gVisor package acceptance. It is also not a finding
of a forged commit acknowledgement, false paint, SQLite corruption, or
power-loss durability. It is a guest-owner liveness and claim-boundary defect.

### Frozen v2 boundary and authentication

The reviewed successor is the read-only packet:

```text
pinenote/tools/book-state-guest/source-packets/book-state-guest-sources-20260906-v2/
92ee6b2a115bcfdbdbd2a6decd90992fcef065bfdb16495cbe7019e92b73069b  SOURCE-SNAPSHOT.sha256
3144274f171d93f6a8e55752f86e10b1af7cdcdeb3eb04824a127f4a2d15ec29  EVIDENCE.sha256
```

I verified every listed digest and both exact rosters. The packet has 50
regular files: 41 source-snapshot files, eight evidence-manifest members, and
the evidence manifest itself. It has no symlinks or writable entries and no
unlisted source file or evidence member. The nested canonical manifest has 40
entries; the 41st snapshot file is that canonical manifest itself. All 41
frozen source identities matched the canonical tree at review time.

Principal v2 identities are:

| Input | SHA-256 |
|---|---|
| canonical 40-entry source manifest | `64a3a934bad80047329dcbd7ab521a8d27845211a587e3a86d6ab85660ace3a9` |
| system | `fde9fb3bb62628886a8342a0a78f7ca87ccdc06ce13d63bdec3b0bb1a9876be7` |
| authority | `6a9236a4a27180efd9843050ac9476b165f34d18d8d9e8ed70eabd1ec90237e8` |
| FD-3 adapter | `15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb` |
| native FD test | `fae45fc8ea8c87062a9df580a7da4e134bae0c19af4503d959fddb998226eb54` |
| contract | `313b0348c1baeb9bb59a1a0336666dc3f8be94827b59ca3fdb240049bad1f5aa` |

Relative to the sealed v1 review snapshot, 34 source paths are unchanged. V2
changes only the adapter, contract, source manifest, source-test driver,
test runner, and the adapter hash embedded in the system, and adds the native
FD test. In particular, the authority, OCI generator, accepted books,
reader bridge, backend, delegate, UI transport, public gVisor definitions,
base system, and channel pin are unchanged. The v1 review text and its
counterexample remain preserved above; its pre-append full-document identity
was `f1da89b06ac0bdaceb1e5facd90f7912dca56df8bdb889350a9889ba837e3aef`.

The retained packet logs report:

- all source/provenance checks green;
- the nine-line native adapter matrix green;
- 23 expected Guile module-test passes;
- the static Guix object comparison green;
- system derivation
  `/gnu/store/09a4002jpkh9c3snf55mg0azrfirsiwl-system.drv`;
- unchanged kernel output `334ljs8…` and source-built gVisor output `djgy782…`;
  and
- 2,783 derivation requisites, exactly one `gvisor-source-built` derivation,
  and no recorded old binary/local-test/CONTROL/generated-snapshot/`/tmp`/
  live-review match.

These logs are authenticated author evidence, not an independent rerun. I did
not re-lower the derivation after BSG-2 failed the resumed source gate. Static
graph success cannot waive that failure.

### BSG-1 independent successor recheck

I first reran the frozen packet's complete native FD test directly. All nine
cases passed. I then used a separately written fixture against the exact frozen
adapter and independently checked these cases:

1. FD 3 initially free, reproducing the v1 counterexample precondition;
2. FD 3 initially occupied by an unrelated low-number descriptor;
3. the endpoint aliased across FDs 0 through 4; and
4. the endpoint already on FD 3, stdin closed, and an output FD aliased to it.

Every successful exec had exactly FDs 0, 1, 2, and 3. FD 0 was `/dev/null` and
returned EOF; FDs 0 through 2 were non-sockets with identities distinct from
the endpoint; only FD 3 was the socket; all four close-on-exec flags were clear;
and request/response traffic completed bidirectionally only through FD 3. Live
stdout/stderr identities were preserved where applicable, and endpoint aliases
were replaced or closed.

I also made a one-line reviewer-only corruption that copied FD 3 back onto FD 0
instead of installing the opened null descriptor. The new final identity check
rejected it with status 1, and a target-exec canary remained absent. This shows
that the repaired self-check does not merely repeat v1's descriptor-number-only
false positive.

The independent result is therefore: **BSG-1 closed for adapter
`15f8ec5c…`.** This is source/native-exec evidence only; runsc and sandbox
isolation remain unexecuted in this review.

### BSG-2 — the 360-second whole-guest bound is not enforced

The contract says, “the complete guest is bounded to 360 seconds,” and the
system build manifest records `whole-guest-timeout-seconds=360`. The authority
does create one absolute deadline and checks it in its nonblocking UI/Book
Session polling loops. That is not a complete-process timeout.

The earliest counterexample is before runsc executes:

```scheme
(define (wait-for-stopped-child! pid)
  ...
  (waitpid pid WUNTRACED)
  ...)
```

`run-one-sandbox-book!` receives `whole-deadline`, but
`spawn-owned-runsc-safely` does not. The latter calls this blocking `waitpid`
without `WNOHANG`, an alarm, a timer, or any deadline parameter. If the fixed
Guile child remains alive but never reaches its pre-exec `SIGSTOP`, the owner
never regains control to check 360 seconds or clean up the child.

The independent finite control extracted the exact 15-line
`wait-for-stopped-child!` definition from authority `6a9236a4…`, called it for
a live child that remained running without stopping, and imposed a reviewer
cutoff outside the tested function. At 1.502 seconds the exact function had not
returned; source checks confirmed it has no deadline or `WNOHANG` and its
caller receives no whole deadline. The external cutoff killed the private test
process group. This is a finite demonstration of the blocking branch, not a
claim that 1.5 seconds is the product deadline.

There is a second reachable form after an operation/UI deadline fires. The
delegate explicitly performs a “potentially blocking storage call.” Unwinding
`run-one-sandbox-book!` synchronously calls `release-peer!`, which calls
`release-session-endpoint!`. Local endpoint close first rejects future
completion and clears pending output—preserving fail-closed acknowledgement
semantics—but `finish-book-state-session-delegate-close!` then:

1. revokes the backend binding, which can wait for the store mutex held by the
   in-flight operation; and
2. performs an unbounded `join-thread` on that worker.

The SQLite five-second busy timeout bounds SQLite lock contention, not arbitrary
filesystem/kernel I/O or the Guile worker join. No cancellation/timer owner
bounds this close path. Therefore a three-second operation timeout can detect a
failure yet still strand cleanup forever, and the 360-second deadline cannot
make the guest return. `%guest-entry` reaches its `sync` and `halt` only after
the authority returns, while the Shepherd service declares no independent
timeout or guardian.

The supplied source test does not detect this. Its “operation and whole-guest
time bounds are fixed” assertion only counts the two constant definitions. The
23 Guile assertions never execute `run-guest!`, child-stop waiting, an in-flight
worker timeout, or shutdown. The derivation and graph checks cannot establish
runtime liveness.

### Successor requirement

This finding can be resolved in either of two explicitly different scopes:

1. if the guest itself continues to claim a hard 360-second bound, a trusted
   owner outside every potentially blocking child/storage callback must enforce
   it, with reviewed handling for child reap, worker/SQLite ownership, database
   close, and shutdown; or
2. if the intended evidence remains the already accepted **untimed supervised**
   persistence join, remove the complete-guest timeout claim from the contract
   and build manifest, describe the existing values as polling deadlines only,
   and assign any demonstration cutoff/recovery claim to a separately reviewed
   outer guardian.

An unsafe thread cancellation or forced power loss must not be presented as a
durable SQLite close, clean unmount, or completion-observation proof. Persistence,
timeout/cancellation, outer-QEMU termination, and physical-power-loss durability
remain separate evidence boundaries.

Any successor changes the authority and/or its contract/system/test identities
and requires a new exact source packet and focused tests. At minimum, tests must
cover a child that does not stop and an operation whose worker remains blocked
while the interaction deadline expires; they must prove the claimed owner
returns or accurately narrows the claim without forging completion, UI output,
database-close, `sync`, unmount, or halt evidence.

### Reviewer evidence and conduct

The sealed independent evidence is:

```text
/tmp/opencode/book-state-guest-v2-independent-review-20260906/
49c5435d27a310dd772687c48fdc137f905752aa4932bf2a810a5731e4aec0ae  EVIDENCE.sha256
```

It contains packet authentication, the independent FD harness/result, the
one-line false-self-check mutation and absent-canary result, the exact extracted
wait function, and the bounded external-cutoff harness/result. All nine listed
evidence files reverified before the directory was made read-only.

Four reviewer harness setup attempts failed before producing evidence. The
first independent FD harness made the child a session leader before the exact
adapter's `setpgid`, and its next draft had a faulty `/proc/self/fd` fixture
scan. The first timeout-harness draft had nested-quote syntax damage, and its
next draft used the wrong comment indentation in a source assertion. An ambient
Guile module probe also failed because that bare profile does not contain
`sqlite3`; no guest module was loaded. All were reviewer-only
`/tmp/opencode` setup/probe failures, never candidate inputs. The corrected
successful harnesses and final logs are the files sealed above, and no failed
setup result is represented as a passing test.

No implementation, source manifest, frozen source packet, system, authority,
adapter, accepted prerequisite, kernel, gVisor package, or image was edited. No
image/system/kernel/gVisor build, Guix lowering, runsc, QEMU, ARM execution,
device, SSH, mount, network investigation, staging, commit, push, fetch, merge,
or rebase occurred. This append to the existing review is the only repository
edit made for the v2 continuation.

## V4 continuation — BSG-3 closed; BSG-4 blocks acceptance

### Verdict

**Do not accept the exact v4 guest/system source for image construction or
QEMU.**  V4 does close BSG-3: its authenticated finite capsule is complete for
the project-module and relative-`local-file` graph actually used to check and
lower the system.  The isolated frozen replay, static system check, independent
lowering, and independent requisite query all pass.

A later immutable-store inspection found a distinct blocker, **BSG-4**.  The
exact 45-path language closure mounted into each sandbox contains two SQLite
3.39.3 outputs, including an executable AArch64 `sqlite3`, while the Python
output in that same closure contains its importable `sqlite3` package and
AArch64 `_sqlite3` extension.  This contradicts both the review requirement
that SQLite be absent from book-visible paths and the frozen contract's claim
that “SQLite exists only in the trusted profile.”

This finding does **not** show that a book can reach the persistent state volume
or database.  Those paths remain absent from the OCI mount graph, and Guile
remains the Book Session/backend authority.  It is nevertheless a real closure
and capability-boundary failure, not a documentation typo: the OCI generator
bind-mounts every item in the 45-path list into both book containers and does
not mark those store mounts `noexec`.

BSG-1 remains closed for the accepted adapter.  BSG-2 remains closed only at
the external guardian boundary established by the independent deadline review
at SHA-256
`f0cedbe6a6b44b37a03b663c7168d6880520ae6cd592427665756186fbc95db4`.
Its adjacent statement that SQLite is absent from the sandbox closure is
corrected by BSG-4 here; the deadline result itself is not reopened or rewritten.

No image, QEMU, ARM, runsc, KOReader, device, or hardware result follows from
this review.

### Frozen v4 boundary and predecessor chronology

The reviewed source is only the read-only packet:

```text
pinenote/tools/book-state-guest/source-packets/book-state-guest-sources-20260906-v4/
6c19a6abfbf6758d057fa49b8839183b5e767139687a5b1d9b120df9cd15821a  EVIDENCE.sha256
fbc5903f08046440d4a3b4f2d802f17dd496b6e90d71ba37ae032a54cada6934  SOURCE-SNAPSHOT.sha256
7c71465c498449e96f63d943f392a2201cf6afad9b90e5ef110f9c1a46e77676  canonical SOURCE-MANIFEST.sha256
1426d26f002b28a14b0e9913a8c6f39a088f2ec937d84ced28e43a22ebc3c6b4  capsule roster
```

The packet has 259 regular files and 57 directories, with no links, special
files, or writable entries.  Its regular files are 250 mode `0444` and nine
mode `0555`.  The canonical roster has 130 rows: 19 project modules, 89 local
assets, and 22 check-only files.  The canonical source manifest has 129 unique
entries.  Strict verification passed all 16 packet-evidence entries, all 242
snapshot entries, the complete source manifest, both copies of the capsule
roster, and every module/local-file copy.

Principal unchanged semantic identities are:

```text
688b2a9dbe5d9ce983cb3e8ca5604a12f494a6a592f5cf0b6cede4fbbeb3be73  book-state-guest-authority.scm
15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb  runsc-fd3-exec.scm
ee43fd585dbc39fc163384bfddb9ae2b3c553b4b6a8e198b3f2734c62d953fc5  pinenote-book-state-reader.scm
6bca96d57de552a9b70f716c637f0d41109f7959a5aa9336741587aa97bd7b46  CONTRACT.md
```

The predecessor evidence also reverified rather than being inferred from v4:

- the 40-file sealed v1 review snapshot manifest is `8058829e…`; its separate
  four-file BSG-1 counterexample manifest is `a172be7b…`;
- the v2 packet evidence manifest is `3144274f…`, its source snapshot is
  `92ee6b2a…`, and all eight evidence plus 41 source entries passed strict
  checking; and
- the v3 packet evidence manifest is `c57e7bb6…`, its source snapshot is
  `ee251ccd…`, and all nine evidence plus 46 source entries passed strict
  checking.

This preserves the actual sequence: v1 failed BSG-1; v2 repaired BSG-1 but
failed the original in-guest hard-deadline claim; the separate deadline review
closed BSG-2 at the outer boundary; v3 was then rejected for BSG-3's incomplete
frozen source view; and v4 closes BSG-3 but now stops at BSG-4.  A later packet
does not erase any earlier failure or rung-order violation.

### Private startup and complete capsule replay

`pinned-guix.sh` validates canonical absolute views and one immutable
Guix-store bootstrap command, creates a fresh absent process root, and executes
`/usr/bin/env -i` before the first Guix/Guile process.  It supplies private
`HOME`, all four declared XDG roots, `TMPDIR`, an empty `PATH`, disabled
auto-compilation, the positive module view as `GUILE_LOAD_PATH`, a fresh empty
compiled path, and an empty extension path.  Its nested `-L` names only the
package view, which contains one non-Scheme marker and zero Scheme files.

The host shell later obtains Guile and Guild from the pinned pure profile, then
again assigns private HOME/XDG paths and explicit source/compiled/extension
paths before either tool starts.  Check-only Scheme is invoked by pathname and
is not admitted to the positive module view.  The origin gate resolves all 19
project modules and requires every `module-filename` to be the exact copy under
`capsule/module-view`; store-provided Guix/Guile modules are allowed, but no
worktree or other ambient project source is.

The cache test first compiled executable malicious versions of the guest system
module to Guile's real default-HOME and explicit-XDG cache keys.  Each negative
control executed and wrote its canary.  It then supplied hostile caller HOME,
XDG, load, compiled-load, extension, Guile-system, and Guix package/build
variables to the pinned launcher.  Neither canary executed, and all 19 canonical
module origins still matched.  The corrected independent replay additionally
began with hostile outer HOME/XDG/project load/compiled/extension values.

One reviewer invocation before that replay exited 134 because I incorrectly
pointed `GUILE_SYSTEM_PATH` and `GUILE_SYSTEM_COMPILED_PATH` at empty attacker
directories.  That prevented the deliberate attacker Guile from initializing
before the candidate cache control ran.  It is preserved as a reviewer setup
failure, not counted as a candidate PASS or FAIL.  The one valid frozen replay
retained the requested hostile caller cache/project paths while leaving the
immutable Guile system libraries available, and exited zero.

That replay independently passed:

- exact capsule path/top-level/roster/mode/hash checks;
- missing-module controls for `gvisor-dependencies.scm`, `kernel.scm`, and
  `base.scm`, plus the missing forward-port-patch local-file control;
- manifest tamper, symlink, special-file, changing-input, and unlisted-Scheme
  controls;
- both executable caller-cache controls and all 19 module-origin assertions;
- the nine-case native FD matrix, including the original FD-3-free
  counterexample, occupied FD 3, closed standard descriptors, and identity
  checks;
- all 18 external-liveness assertions and all 23 backend/bridge assertions; and
- the static system object comparison.

There is no bare project `-L`, original-PWD escape, mutable capture, stored
project-module fallback, or unlisted Scheme path in the successful replay.

### Independent lowering and v3-to-v4 derivation delta

The authorized derivation-only operation ran through that same pinned/private
wrapper.  `derive-system.scm` sets `%graft?` false and configures the store with
two build cores, one build job, and no substitutes.  It independently returned:

```text
SYSTEM-DERIVATION /gnu/store/qb9s3c1p4xwzfy0i6j2qn084rc2g4wf8-system.drv
PIN kernel-output=/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote
PIN gvisor-source-output=/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0
```

No output or dependency was realized.  A pinned/private Guix store-API query of
that already-computed derivation returned 2,784 sorted unique requisites.  The
exact list hashes to
`a8342e6ffe531182779e560ddf9960765809f877565b987decc25f8c274f827d`,
contains the exact `61ls988a…` USER_NS kernel derivation and exactly one
`il8gj1gx…-gvisor-source-built-20260831.0.drv`, and contains no binary/local-v12/
CONTROL/generated-build/`/tmp`/review/source-packet path.

This authenticates the finite source-package derivation graph.  It is
consistent with the separately accepted public-source v4-final review, whose
current document hash is `5b675a89…`.  It does not infer current gVisor runtime
acceptance from the package name, release, ELF shape, or historical CONTROL
evidence.

I also compared the existing v3 and reproduced v4 derivation payloads directly.
Each recursive graph has 1,557 derivations.  Exactly seven old paths are
replaced by seven new paths, paired by output name:

```text
wilkbook-book-state-guest-source-manifest.drv
wilkbook-book-state-reader-build-manifest.drv
etc.drv
activate-service.scm.drv
activate.scm.drv
boot.drv
system.drv
```

For every pair, the multiset of referenced store-object names and the complete
non-store-reference derivation skeleton are equal after normalizing only the
32-character store hashes.  The other 1,550 recursive derivations are
path-identical.  The changed root input is the embedded source manifest,
`f6331a3d…` to `7c71465c…`; the rest is its ordinary hash cascade.  This verifies
the narrow v3-to-v4 delta claim without pretending that the incomplete v3
packet can replay its own lowering.

### Persistence, UI, mount, OCI, and completion semantics inspected before the stop

The unchanged semantic source has the intended source-only ordering:

- Guile owns the SQLite store, namespace/grant factory, Book Session endpoints,
  typed completion observer, UI control, runsc ownership, inspection, and close.
  Python is one fixed sequential book process and has no backend handle or state
  path.
- The operating system adds exactly one mandatory checked ext4 filesystem,
  label `WBBookStateV1`, mounted at
  `/var/lib/wilkbook-book-state-demo` with
  `noatime,nodev,nosuid,noexec`.  The preparation service depends on that exact
  filesystem service, verifies the live mount and options, and makes the root
  root-owned mode `0700`; the guest service depends on preparation.  There is
  no missing-volume fallback or alternate database path.
- Each fixed book must originate its own `state-read` over donated FD 3.  Only a
  typed completion correlated to the current endpoint/grant/surface lifetime is
  converted to the load value.  The authority then tells the UI to paint that
  returned value before any save.  Boot stage is discovered from absent/version
  0, exact A/version 1, or exact B/version 2 backend data; no host phase or
  expected-result argument seeds the database.
- Save ordering is UI edit/submit, a fresh Book Session action and book-derived
  operation ID, typed backend completion, correlated UI `commit-ok`, then a
  separate book `present-saved` action and UI paint.  Presentation cannot stand
  in for commit observation.
- Both language namespaces must begin in the same discovered stage.  The closed
  read-only inspector checks two exact rows, the complete receipt sequence,
  globally distinct operation IDs, integrity, foreign keys, ownership/mode, and
  absence of journal/WAL/SHM sidecars.
- On ordinary success, endpoint release closes input, revokes the grant, joins
  the delegate worker, finalizes runsc/captures, removes runtime state, closes
  SQLite, runs the inspector, completes and closes the UI channel, returns from
  `sync`, and only then emits the guest PASS marker.  A blocked revoke, worker
  join, SQLite close, or `sync` prevents PASS; the 300-second clock is only
  cooperative polling and does not make those calls interruptible.
- OCI remains strict Systrap with user namespaces, `directfs=false`, no network
  or host UDS/FIFO, a read-only rootfs, UID/GID 65534, no capabilities,
  `noNewPrivileges`, bounded tmpfs scratch/dev, and exactly `--pass-fd=3:3`.
  The state root and database are not among its mounts.

These are source and native-fixture observations only.  They are kept separate
from real sandbox containment, UI rendering, QEMU termination, guest powerdown,
clean filesystem unmount, persistence across boots, and power-loss durability.

### BSG-4 — SQLite is present and executable in the book closure

The exact already-realized closure record authenticated by the authority is:

```text
/gnu/store/p05h2hdla9lrg10fynmy4qzwvxjy9zp0-wilkbook-book-execution-language-closure
48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc
```

Parsing that immutable Scheme datum produces exactly 45 paths.  Contrary to
the contract, two are:

```text
/gnu/store/cy2qjbj9akbc2c3n6cjribi4alkqqzkc-sqlite-3.39.3
/gnu/store/b769xis704c3h67y764hlnq0j3lb6asg-sqlite-3.39.3
```

The first contains mode-`0555`
`bin/sqlite3`, SHA-256 `5f8f07eaa4fc120b66eb916f148a5e16437093214eac0d0313b74088a7e0b04c`,
whose ELF `e_machine` is 183 (AArch64).  The mounted AArch64 Python 3.12.12
output also contains:

```text
lib/python3.12/sqlite3/{__init__.py,__main__.py,dbapi2.py,dump.py}
lib/python3.12/lib-dynload/_sqlite3.cpython-312-aarch64-linux-gnu.so
```

The extension is AArch64, hashes to
`72880673c8f2c22a4e0089b737432ea2c2e4b391479439aa1ed8abc29c333644`,
and names the `cy2qjb…-sqlite-3.39.3/lib` path in its immutable runtime search
path.

`make-protocol-spec` maps every closure item through `bind-mount`; these mounts
default to executable.  `make-rootfs` also points `/profile` at the mounted
language profile.  The same closure is passed to both generated bundles.  Thus
this is not merely a host build dependency found in the 2,784-node derivation
graph: the accepted runtime closure file itself requests the SQLite store paths,
and Python's standard import path exposes the module.

Again, the sandbox receives no state volume, namespace, grant, or database
path.  BSG-4 therefore does not refute the narrower claim that Guile alone owns
*persistent Book State*.  It refutes the stronger required claim that SQLite is
absent from book-visible paths.  Acceptance requires either a new exact language
profile/closure that removes the SQLite executable, libraries, Python module,
and transitive references, or an explicit change to that security requirement.
Either choice changes reviewed package/closure/system/derivation identities and
requires a fresh packet and review.

### Separate two-boot guardian binding

I independently traced the current source under
`pinenote/tools/book-state-qemu/two-boot/`; this is not an acceptance of that
runner.

`run-two-boot.scm` constructs every `one-boot.scm` vector through
`bind-mandatory-outer-timeout-arguments`, which rejects existing copies and
appends exactly `--timeout-seconds 360 --term-grace-seconds 5`.  The pure
`let*` sequential seam invokes that same function for boot 1 and, only after it
returns successfully, boot 2.  `one-boot.scm` requires exactly one value for
each option before calling `disposable-qemu-main`.  The accepted outer parses
those values and passes them unchanged to `run-owned-process` around the
coordinator.  The coordinator starts QEMU in its own inherited process group,
and the outer guardian owns TERM/KILL/reap of that exact group.  Therefore the
narrow source binding reaches both prospective QEMU lifetimes; there is no
whole-campaign 720-second substitute.

No QEMU process was started here, so this is not runtime guardian evidence.
More importantly, frozen two-boot v1 remains rejected for BTQ-1 through BTQ-5
by the independent review whose current hash is `0a825f5e…`: it executes Guile
before authentication, has caller-self-asserted authorization, previously had
an incomplete console failure grammar, wires production through `module-set!`,
and pins the rejected v3 metadata rather than v4.  The narrow timeout binding
does not waive those blockers.  No acceptable image-bound boot authority exists.

### Reviewer evidence, stop point, and non-claims

The independent evidence retained for this continuation is:

```text
/tmp/opencode/book-state-guest-v4-independent-review-20260906/review-evidence/
eeb37930b7bc890dbf4a24daf32378caf9f5aaa97cd5428306af93b69c7640e8  EVIDENCE.sha256
```

It contains the failed reviewer setup log, successful frozen replay, lowering,
raw 2,784-path requisite list and checker output, independent derivation
comparison, exact source-manifest diff, and BSG-4 immutable-store evidence.  All
ten listed files are mode `0400`; the evidence directory is mode `0500`.

Per rung order, review stopped at BSG-4.  No image, system, kernel, gVisor, or
dependency output was built or realized; no Bazel, runsc, QEMU, ARM, KOReader,
privileged mount, device, network, deployment, staging, commit, push, fetch,
merge, or rebase occurred.  The old-kernel reader token was neither supplied
nor used.  No reader harvester or UI socket was touched.  Cancellation,
termination, and power loss are not treated as SQLite close, `sync`, unmount,
halt, completion, persistence, or PASS evidence.

This append is the only repository edit made by the v4 continuation.
