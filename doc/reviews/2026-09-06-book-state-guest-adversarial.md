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

## V5 continuation — clarified BSG-4 boundary; frozen-capsule mode gate fails

### Verdict

**Do not accept the exact v5 packet for image construction or QEMU.**  The
clarified security requirement is accepted: SQLite software may remain in the
book language closure; the book must instead lack direct capability to the
authority database/state volume and private UI channel.  Thus the historical
v4 BSG-4 finding remains an accurate record of the old SQLite-absence
requirement, but SQLite 3.39.3's acknowledged presence is not itself a v5
blocker and no minimal-Python/profile rebuild is required.

The first independent frozen-capsule gate nevertheless fails.  The
authenticated capsule roster requires nine files in `capsule/module-view` to be
mode `0555`; every one is actually mode `0444`.  The packet's own exact checker
stops at the first such file:

```text
FAIL: module-view source mode/type is wrong: pinenote/tools/gvisor-package/check.sh
```

This is finding **BSG-5**.  It is a frozen-packet/replay failure, not a finding
against the clarified SQLite capability boundary, the two new probe algorithms,
Book Session, the accepted FD adapter, the external deadline result, the
reader-join, the kernel, or gVisor runtime behavior.  Per rung order I did not
run the frozen replay, independently lower/query the v5 derivation, compute the
image derivation, repeat the 34-derivation image dry run, or build anything.
The authenticated author logs for those later gates cannot waive the earlier
failure of the exact packet presented for review.

### Authenticated v5 content and shape

Strict byte verification passed all 19 members of `EVIDENCE.sha256` and all 246
members of `SOURCE-SNAPSHOT.sha256`.  The principal identities match the review
request:

```text
5fd333cf57c00fea80b28a519081ce4ccc8d13b94200d07db73c5481230fcc69  EVIDENCE.sha256
2b99fcca343823eca6f5f665bfb7a5e053fed7eede1ce99501c99a9747d7a7e8  SOURCE-SNAPSHOT.sha256
8a86fa2a1e7b8b388ab2858580d279fae9afc42dcd166f64fce4c1030f52d221  canonical SOURCE-MANIFEST.sha256
9e5f4edc0b2c6babea1a576aa8f7c270136a2ceda6f650d64bde18a0d4308f3d  canonical capsule roster
```

The canonical manifest has 131 unique entries.  The roster has 132 entries:
19 project modules, 91 relative local-file assets, 22 check-only files, and the
manifest binding.  The complete packet has 266 regular files and 57 directories
(counting its root), with no links or special files.  All 266 regular files are
mode `0444`.

That last fact is the contradiction.  The roster explicitly assigns `0555` to
these nine module-view assets:

```text
pinenote/tools/gvisor-package/check.sh
pinenote/tools/gvisor-package/emit_guix_inputs.py
pinenote/tools/gvisor-package/inventory.py
pinenote/tools/gvisor-package/offline-check.sh
pinenote/tools/gvisor-package/test_inventory.py
pinenote/tools/gvisor-package/test_vendor.py
pinenote/tools/gvisor-package/vendor-discover.sh
pinenote/tools/gvisor-package/vendor_inputs.py
pinenote/tools/gvisor-package/vendor_manifest.py
```

An independent complete mode comparison found exactly those nine mismatches and
no repo-view mismatch.  Their bytes still match the roster; for example both
copies of `check.sh` hash to `b146c80e…`.  That does not repair their modes.
`gvisor-source.scm` consumes the tools directory through a recursive
`local-file`, and the capsule design itself says executable modes must survive
for such directory inputs.  More fundamentally, the exact checker is part of
the declared frozen boundary and correctly refuses this capsule.

The supplied hash manifests did not detect the post-capture mode discrepancy
because they authenticate file bytes, while `CAPSULE-ROSTER.tsv` separately
declares the required modes and `check-source-capsule.py` enforces them.  The
authenticated supplied `capsule-check.log` and `frozen-replay.log` report a
different earlier state in which this check passed; they are author evidence,
not a successful replay against the current frozen directory.  For comparison,
the preserved v4 packet still has these module-view files at `0555` and its
repo-view copies at `0444`.

### Focused BSG-4 source inspection before the stop

The v4-to-v5 semantic design is otherwise narrow and consistent with the newly
clarified requirement, but these observations are not an acceptance after
BSG-5:

- The authority differs from accepted hash `688b2a9d…` only by the two declared
  boundary-probe arguments.  The accepted FD adapter remains exactly
  `15f8ec5c…`, and the 45-path language closure remains exactly `48728ed9…`.
- The system now truthfully records both SQLite 3.39.3 book-visible outputs and
  separately pins the trusted `guile-sqlite3`/SQLite 3.53.1 backend.  It creates
  and verifies a root-owned mode-`0600` non-secret sentinel on the mandatory
  state volume before authority startup.
- The fixed Guile argv loads `/book/storage-boundary.scm` immediately before
  `/book/entry.scm`.  The fixed Python `-I -S -B -c` program runs
  `/book/storage_boundary.py` and then `/book/entry.py` in the same interpreter.
  Both probe sources are separately mounted read-only, are included in runtime
  provenance, and are passed through the real authority bundle path; there is
  no native fallback or separate, more-isolated probe process.
- Each probe uses direct `stat`/`open` operations.  It requires denial of the
  state root and sentinel visibility; read and non-truncating write opens of the
  existing sentinel and database; read/write opens of the private UI path;
  literal absence from mountinfo; FD 3 as the sole non-CLOEXEC socket; and no
  higher non-CLOEXEC, socket, character-device, or authority-path descriptor.
  Only explicitly enumerated not-found/permission errnos are accepted; import
  failure, timeout, and unknown exceptions cannot produce its PASS line.
- Trusted UI readiness is established before either sandbox runs, and normal
  guest success still requires the unchanged book's real typed state read and
  boot-appropriate state commit plus UI interactions.  Therefore a future
  runtime result must authenticate each actual child probe completion together
  with those positive events, not accept the child-written marker alone.

The boundary markers are written to the bounded per-child `runsc.stdout`
captures.  This source review does not establish that a future two-boot evidence
owner actually harvests and authenticates them.  That exact binding, including
both `360/5` QEMU lifetimes and the accepted image identity, belongs to the
separate two-boot review; it must pass before QEMU authority exists.

### Reviewer-only probe model and rung-order correction

Before invoking the independent capsule checker, I ran the two exact frozen
probe files in a private unprivileged bubblewrap namespace with private
HOME/XDG/compiled/extension paths and a reviewer-created connected socket at FD
3.  This was a reviewer rung-order error: packet shape had already exposed the
all-`0444` anomaly, so the capsule checker should have run and stopped first.
The result is retained only as a probe-code negative control and cannot waive
BSG-5.

For both Guile and Python, the absent-path model emitted the exact boundary PASS
line.  Three intentional exposures then failed nonzero without a PASS marker:

1. binding a reviewer-owned mode-`0700` state directory, existing sentinel, and
   harmless dummy database at the fixed state path failed at root visibility;
2. binding a harmless reviewer file at the fixed private UI path failed at the
   read open; and
3. retaining another socket at FD 4 failed the extra-capability check.

No real database was opened or modified.  This host model is not runsc, Sentry,
ARM, the accepted book, Book State, the private UI, persistence, QEMU, or
shipping evidence.  In particular, it does not replace the required in-sandbox
ARM denial result.

### Required successor and stop point

A reviewable successor must preserve the nine rostered `0555` module-view modes
(or deliberately change the roster/source semantics and explain that new
derivation), freeze the packet in a transport that retains those modes, and
rerun its own checker against the exact frozen directory.  Because the packet
and evidence state changes, it needs fresh packet/evidence identities and a
fresh focused review.  It does **not** need to remove SQLite from the language
closure.

Only after that early gate passes should review resume with the hostile-cache
frozen replay, exact system lowering/requisite query, image `-d`, and the
no-realization 34-derivation dry run.  Image construction remains unauthorized
by this exact review.  Actual ARM/gVisor denial, typed Book State persistence,
the child marker/positive-event join, both hard-guardian bindings, shutdown,
and two-boot recovery remain later runtime evidence, not source facts.

The sealed independent evidence is:

```text
/tmp/opencode/book-state-guest-v5-independent-review-20260906/review-evidence/
220017078323c1cae54c4ee3dd5845d65ddb7cad827138dd40f74b650da0903d  EVIDENCE.sha256
```

It includes strict packet checks, the packet shape, the exact checker failure,
the complete nine-file mode audit, and the explicitly non-authoritative host
probe model.  All listed files are mode `0400`; the evidence directory is mode
`0500`.

Two reviewer setup failures are preserved there.  The first probe-model draft
used a bubblewrap option unavailable on this host.  A separate command
mistakenly named the cached AArch64 Python executable; the x86 host could not
execute it, and shell fallback exited status 2 on binary bytes before any
harness code ran.  No ARM instructions or candidate runtime ran.  The first
mode-audit snippet also had a reviewer-only Python syntax error; its corrected
successor produced the complete mode result above.

No frozen packet, implementation, observer, protocol, UI, system, package,
kernel, patch, image, or two-boot source was edited.  No Guix lowering,
requisite replay, image derivation, image dry run, output realization,
image/system/kernel/gVisor/Bazel build, runsc, QEMU, successful ARM execution,
KOReader, device, SSH, network investigation, privileged mount, staging,
commit, push, fetch, merge, or rebase occurred.  This append is the only
repository-path edit made by the v5 continuation.

## V6 continuation — BSG-5 closed; guest source accepted for image construction

### Verdict

**Accept the exact v6 guest/system source for one exact bounded raw-image
construction.**  V6 changes no capsule byte and no functional source from v5.
It restores only the nine authenticated module-view execute bits whose loss
caused BSG-5, then passes the exact frozen-capsule checker, the required
private-clone negative, the complete private source/native/static replay,
system lowering and graph query, image lowering and graph query, and the
no-realization image dry run.  No new counterexample was found in the completed
v5 source/probe review.

This acceptance permits the parent to run the no-argument `image_guix` build
defined by the reviewed `COMMANDS.txt`: private `env -i` HOME/XDG/load/
compiled/extension paths, `--no-grafts`, `--no-substitutes`,
`--max-jobs=1`, and `--cores=2`, targeting the exact raw image below.  Image
construction need not wait for the separate two-boot owner review because it
does not execute the guest.

It does **not** accept ARM/gVisor runtime isolation, execute either boundary
probe in Sentry, prove persistence, authorize QEMU, or accept a two-boot owner.
Those remain later rungs.  In particular, source-built gVisor remains an
accepted package output but not a currently accepted runtime merely because its
identity is unchanged.

### Frozen v6 identity and mode-only delta

The reviewed packet and its post-freeze sibling evidence are:

```text
pinenote/tools/book-state-guest/source-packets/book-state-guest-sources-20260906-v6/
5b801df014ccae882f410bf9deeefdbf8973c77f6c7932955108a9b2007e360b  PACKET-CONTENTS.sha256

pinenote/tools/book-state-guest/source-packets/book-state-guest-sources-20260906-v6-evidence/
c550804a12701d511f2a66afebe3415d67d8f918697ac04b8db38d42f4f2b91a  EVIDENCE.sha256
```

Strict checking passed all five packet-manifest members, all 246 capsule
snapshot members, and all 36 author-evidence members.  The unchanged inner
identities are:

```text
8a86fa2a1e7b8b388ab2858580d279fae9afc42dcd166f64fce4c1030f52d221  canonical SOURCE-MANIFEST.sha256
9e5f4edc0b2c6babea1a576aa8f7c270136a2ceda6f650d64bde18a0d4308f3d  canonical capsule roster
2b99fcca343823eca6f5f665bfb7a5e053fed7eede1ce99501c99a9747d7a7e8  SOURCE-SNAPSHOT.sha256
e1bc1c871b0502d17ccdc7056564989cd455fae943133300df88e60e11dbdf3c  authority
2585371b7f961b7222a92e34818bde8fff0817c42a36b6f87c8c9839432e33b3  OCI successor
0ff742d707955a6c1db5d1eb93f1cddd277fa7c113eeaacc16f3eb785744079e  Guile boundary probe
2381b92d3192375160909c60124e3dcb6004c20a581df18ac04dac4665137a5c  Python boundary probe
696a19a52244ac3803a62db3f7a7adfd03aec952fcec6ba768a06e1309f846f8  system
15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb  FD-3 adapter
```

An independent pre-execution walk found exactly 252 regular packet files: 243
mode `0444` and the nine required module-view assets mode `0555`.  All 56
directories, including the packet root, are mode `0555`; there are no links or
special entries.  The roster remains 19 modules, 91 local-file assets, and 22
check-only files plus its source-manifest binding.

All 246 v6 capsule files are byte-identical to v5.  The only metadata changes
are the nine previously listed `capsule/module-view/pinenote/tools/gvisor-package/*`
files from `0444` to their rostered `0555`; no other mode changed.  The exact
capsule checker now passes.  In a private clone, changing only
`check.sh` back to `0444` returns status 1 with the exact BSG-5 rejection.  This
is a behavioral negative, not merely a comparison of mode strings.

The mode record before and after the complete replay is byte-identical and
hashes to
`443e460e7919d058ccc053505dfb4c75bfaf9dba7dc05c324506f5b3bb7b30d3`.
The v5 packet remains unchanged and read-only.  Its failed final-directory
history and the v5 review at pre-append hash `c9e38c87…` remain preserved; v6
does not retroactively turn that packet green.

### Complete private replay

The exact v6 command ran independently as uid/gid 1000 in fresh user, mount,
PID, and network namespaces.  A tmpfs hid the checkout and all other `/tmp`
content; only the read-only v6 packet, read-only v5 packet, prior review roots,
one fresh evidence directory, `/gnu/store`, and `/var/guix` were exposed.
`/home`, `/proc`, and `/dev` were private, and the process began through
`env -i`.  Every Guix/Guile/Guild entry then used the frozen private launcher or
the image command's explicit private HOME/XDG/load/compiled/extension boundary.

The replay passed:

- all capsule missing-input, manifest-tamper, symlink, special-file,
  changing-input, and unlisted-Scheme controls;
- live malicious default-HOME and explicit-XDG bytecode controls, followed by
  all 19 exact module-origin assertions;
- all nine native FD-adapter cases, including FD 3 free/occupied, endpoint
  aliases, closed standard descriptors, and bidirectional FD-3-only traffic;
- all 18 cooperative/external liveness assertions;
- all 23 real backend/bridge/inspector assertions; and
- the static system object comparison with the exact 45-path language profile.

This reuses BSG-1, BSG-2, and BSG-3 only because their accepted adapter,
external guardian, and complete capsule inputs are hash-identical.  BSG-2 still
means external containment only: 300 seconds is the cooperative in-guest budget;
360 seconds plus a 5-second TERM grace belongs to each outer QEMU lifetime.  No
interruptible SQLite cleanup or standalone image deadline is inferred.

### Completed BSG-4 source/probe review

The clarified BSG-4 rule remains exactly as accepted in the v5 continuation:
SQLite 3.39.3 software may exist in the 45-path book closure.  Persistent Book
State authority remains the trusted Guile backend using `guile-sqlite3` and
SQLite 3.53.1.  The requirement is that each fixed book receive no direct
state-volume/database capability and no private UI channel.

The exact source meets the pre-image contract:

1. The authority inverse check removes exactly the two new probe-wiring lines
   and reproduces accepted authority hash `688b2a9d…`.
2. The Guile OCI argv loads `/book/storage-boundary.scm` immediately before the
   unchanged `/book/entry.scm`.  The Python `-I -S -B` argv runs
   `/book/storage_boundary.py` and then `/book/entry.py` in the same interpreter.
   These are the real fixed runsc/Sentry process vectors, not native fallback or
   separately isolated probe bundles.
3. Both probes are immutable separately declared source mounts and appear in
   both the 2,786-node system graph and 4,855-node image graph.  The OCI policy
   remains strict Systrap, no network/host UDS/directfs, nonroot UID/GID, empty
   capabilities, `noNewPrivileges`, read-only root, and exactly
   `--pass-fd=3:3`; neither authority storage nor private UI is mounted.
4. Before either book, the trusted volume service has created and verified the
   non-secret sentinel, the authority has established real private-UI
   readiness, and the state runtime has opened the sole database authority.
   Private-UI denial therefore cannot pass merely because trusted UI was never
   functional.
5. Each probe performs direct OS `stat`/`open` checks for the root, existing
   sentinel, existing database, and UI path; scans mountinfo; and audits live
   descriptors.  Writeability probes use `O_WRONLY` without `O_CREAT` or
   `O_TRUNC`, so unexpected access closes the descriptor and fails without
   writing or truncating the database/sentinel.  Only explicit
   `ENOENT`/`EACCES`/`EPERM` denial is accepted.  An import failure, timeout,
   unknown exception, visible path, forbidden mount, or extra capability FD
   exits before the unchanged book and cannot emit the probe PASS marker.
6. FD 3 is checked as the sole inherited non-CLOEXEC socket; any interpreter
   FD above 3 must be CLOEXEC, non-socket, non-character-device, and unrelated
   to the authority paths.  The accepted pre-exec adapter separately proves
   exact `(0 1 2 3)` ownership.  The unchanged book then has to complete its
   real hello/initialize, typed `state-read`, and boot-required typed
   `state-commit` through FD 3.  That positive path proves the same process
   continued beyond its probe.

The exact per-language `BOOK_STATE_SANDBOX_BOUNDARY` text occurs only in the
two authenticated probes, not in either unchanged book.  It is written to the
owned bounded child capture before book startup.  Runtime acceptance must
authenticate that actual child marker together with the real book hello/read/
commit evidence; a self-asserted marker alone is never proof.  This is a fixed
trusted-fixture conclusion, not qualification of arbitrary hostile books.

The reviewer-only v5 intentional-exposure model remains useful only as a native
negative control because v6 changed no probe byte: absent paths passed, while
state, UI, and extra-socket exposures failed.  It was run out of order in the v5
review and is not transferred to ARM.  Real denial under the exact source-built
gVisor/Sentry process must still be demonstrated after the image exists.

### Derivation and bounded image-build boundary

Pinned derivation-only lowering independently reproduced:

```text
/gnu/store/kjiz9wzqbdr9p1y3w0ni6qh8hzhqrkp0-system.drv
/gnu/store/p6iwha5axl4s5yi2qb9l76x00cw9vqzg-disk-image.drv
```

The sorted system graph contains 2,786 unique paths and hashes to
`997d072610a9bfe6ee120b8e4ca1bba57c2c327abd8605eeb364bcf0111093cb`.
The sorted image graph contains 4,855 unique paths and hashes to
`51441e314d451c7dcbadb023bd871576c84033822c28a802dd4de503ada73608`.
It includes internal system derivation `bci0wwk…`, both probe store files, the
accepted USER_NS kernel derivation, and exactly the source-built gVisor
derivation.  The kernel Image still hashes to `5435c84e…`; the cached outputs
remain `334ljs8…` and `djgy782…`.

The exact no-substitute image dry run reports 34 derivations, including the
image root, and does not list the already-cached kernel or gVisor derivations.
Neither system output `l1f4jxp…` nor expected image output
`/gnu/store/9yx1xmhf2hnsp6vdwnvvxzqv3i9i9fkz-disk-image` exists.  Therefore
this review lowered derivations but realized no target output.  The permission
granted here is narrowly to construct that exact expected image with the
reviewed command; any source, mode, protocol, package, graph, derivation, or
output identity change requires fresh review.

An image produced under this acceptance still has no execution authority.
Before either boot, the separate outer review must bind that exact image to two
sequential QEMU lifetimes, each with the accepted `360/5` guardian.  QEMU must
then separately prove the actual ARM/Sentry denial probes, positive Book State
events, persistence A→B, cleanup, and its own termination result.  None of
those are inferred from image construction.

### Independent evidence and conduct

The sealed independent continuation evidence is:

```text
/tmp/opencode/book-state-guest-v6-independent-review-20260906/review-evidence/
f3b15f1289dbe490df32020daa8935644c6b44eb95a28744db4fc4be2c1ecd5d  EVIDENCE.sha256
```

It contains the independent pre-execution mode/byte gate, strict packet and
author-evidence checks, positive and negative capsule checks, complete private
replay, both derivation/requisite graphs, image dry run, and the focused probe
source audit.  Every listed file is mode `0400`; the evidence directory is mode
`0500`.

The author's two namespace setup failures remain authenticated in the sibling
evidence and are not rewritten as zero failures.  This independent continuation
had one harmless checksum-path mistake before candidate execution: it asked for
`EVIDENCE.sha256` inside v6 after hashing `PACKET-CONTENTS.sha256`, although the
evidence is the documented sibling.  Two reviewer-only source-audit drafts then
used an overly literal multiline-string assertion and stopped; the corrected
ordered-argv audit passed.  These setup errors altered no packet and supply no
candidate evidence.  The exact namespace replay itself passed on its first
invocation.

No frozen packet, implementation, observer, UI, protocol, system, package,
kernel, patch, image, or two-boot source was edited.  No output was realized;
no image/system/kernel/gVisor/Bazel build, runsc, QEMU, ARM, KOReader, device,
SSH, network investigation, host mount outside the private unprivileged
namespace, staging, commit, push, fetch, merge, or rebase occurred.  This append
is the only repository-path edit made by the v6 continuation.

## 2026-09-07 continuation: v7 finalized-capture observability delta

### Verdict

**Accepted as the finite v6→v7 source successor, and accepted for one exact
bounded raw-image build.  Not runtime-accepted.**  V7 fixes the observability
gap found before v6's retained image was ever executed: a successful boundary
probe wrote its record to the owned `runsc.stdout`, but the authority discarded
that capture on success.  The new authority validates the actual finalized
capture and publishes its exact record to the trusted console before cleanup and
before eventual guest success.

This continuation does not reopen BSG-1 through BSG-5.  Their accepted adapter,
external guardian, complete capsule, capability-denial probes, and mode boundary
are unchanged.  It also does not re-review the protocol, backend, reader join,
private UI, kernel, gVisor package, or retained v6 image.  The v6 image remains
an accepted unexecuted artifact under review `02a4d7ad…`; it is simply
insufficient for the new runtime denial claim because it cannot expose a
successful probe record.

The accepted v7 identities are:

```text
8d9eb000cdd51754a6983ea69d5d561eedf9f039473d41779725c9d43dfbb206  PACKET-CONTENTS.sha256
cb86ceec72ed59353e4ec75f88c292594b210de26074a98a35293c9ccef5e7ce  SOURCE-MANIFEST.sha256
c26f69012d1069bfbb9f5df8dbd610aa63a288e74fabfd325c9842b3d532de07  CAPSULE-ROSTER.tsv
dc068b4c04a9168c9d6f34f9dc1486ad2b0788f53d4906602de6dc9a99aa8c4e  SOURCE-SNAPSHOT.sha256
473142078efb0ec678edbec8b308ca95a75603d5e905ff50b754b1b49b6dd86f  V6-V7-DELTA.tsv
35d0fdfcae67b80b5a02e673cd930b62e5fff45c98ccd96548f2de05d69dae7d  author EVIDENCE.sha256
d852a183608dacf5758e0424f1494522f93c57646b7b396ba80902ffbb240fdd  book-state-guest-authority.scm
ebcf06a909398a120c3be50f4f4c0040e91a181ad3e6ff665a0185a08e8e33b7  pinenote-book-state-reader.scm
```

The preceding 1,142-line v6 review prefix was authenticated before this append
as `4c1df07a0dd1db655f5668975636bdf7aecc8fee3b755d26823be7b4c89cc4e5`.

### Complete finite delta

Independent whole-tree comparison found exactly the declared 16 changed
capsule records: two added host-check files and 14 byte-only changes covering
the authority/system copies and their test/capsule metadata.  The capsule grew
from 246 to 248 regular files.  There are no inherited mode changes, links,
special files, multi-link regular files, or write bits.  All directories are
mode `0555`; repo/metadata/package-view files are `0444`; and the same nine
rostered gVisor module-view wrappers remain `0555` while every other
module-view file is `0444`.

The probes, OCI generator and process vectors, accepted Guile/Python books,
Book Protocol sources, FD-3 adapter, capture/process-group owner, kernel
definition and patches, and source-built gVisor definition are byte-identical
to accepted v6.  Removing only the relay import, accessor bindings, delimited
relay block, and production call from v7 reproduces the exact v6 authority byte
stream and SHA-256 `e1bc1c871b05…`.  The system's functional change is limited
to the new authority hash and truthful observability provenance.

### Actual finalized-capture path

The production path is connected in the required order:

1. The fixed language Book completes its typed interaction, then endpoint
   release closes/revokes and joins the state delegate.
2. The accepted owner reaps the complete runsc process group, drains both
   bounded pipes to EOF, flushes and closes both capture outputs, and only then
   marks the child finalized.
3. `capture-result` refuses an unfinalized child.  V7 requires both child and
   result status zero and rejects either stdout or stderr overflow.
4. The relay opens that bundle's owned `runsc.stdout` with
   `O_RDONLY|O_CLOEXEC|O_NOFOLLOW`.  It requires a single-link, authority-owned
   mode-`0600` regular file whose size equals the capture owner's observed byte
   count.  Device, inode, mode, link count, UID, GID, size, mtime, and ctime must
   remain identical across path-before, FD-before, FD-after, and path-after
   observations, and the FD read must return exactly the bounded byte count.
5. The whole capture must be valid UTF-8 and contain exactly one occurrence of
   the reserved stem.  It must be a complete line, have the compile-fixed
   matching language, equal the closed pass grammar byte-for-byte, and end in a
   newline.  Missing, wrong-language, duplicate, quoted/injected, failure,
   malformed, truncated, non-UTF-8, changed, or overflowed input fails.
6. The authority hashes the actual stable-FD capture and the substring extracted
   from it.  It first emits a source-attribution line containing fixed
   language/container identity plus actual byte counts and SHA-256 values; that
   line contains neither the reserved stem nor `result=pass`.  It then emits the
   extracted capture substring, not the expected comparison constant.

The attribution record alone is not pass evidence.  Serial order also does not
pretend to be probe execution order: `publication=next-line-after-child-drain`
states that the probe ran before the fixed book but its trusted relay occurs
after the same process and its pipes have finished.  Any source- or marker-write
or flush error propagates out of the helper, produces authority status 1, and
cannot reach the sole final guest `result=pass`.  A boundary-looking line without
that later final success and the rest of the sealed runtime joins must never be
accepted.

The source binds the two marker grammars to compile-fixed Guile/Python profiles,
container IDs, probe hashes, and unchanged book hashes.  The real OCI vectors
still load each probe immediately before its book in one process, FD, and
namespace context.  Neither accepted book nor its Book Protocol source contains
the reserved marker stem, and the OCI mount/FD policy remains unchanged.  This
is sufficient provenance for these fixed authenticated fixtures, not a general
claim about arbitrary hostile books able to print chosen stdout.

### Independent focused execution

Two networkless unprivileged host matrices drove the exact v7 authority helper
through the accepted process-group and bounded-capture owner.  They used a
pre-existing immutable Guile 3.0.9 test profile directly, private HOME/XDG/TMP
and explicit source/compiled/extension/system module paths.  No Guix process or
output realization was needed.  The child was a reviewer-owned fixed Python
writer, not runsc or either real probe, so these runs establish relay mechanics
only—not gVisor/Sentry/ARM containment.

Both matrices passed all 77 connected assertions.  Guile and Python positive
cases emitted the non-pass attribution followed by the exact captured marker,
with independently changed capture lengths/digests.  Negative cases covered
missing, wrong-language/container, duplicate, quoted-extra, failure, malformed,
truncated, invalid-UTF-8, nonzero, stdout/stderr overflow, deleted capture,
post-finalization mutation, and both source- and marker-publication failure.
The second matrix sharpened two cases to a single quoted-only stem occurrence
and a complete exact marker with no closing newline; both failed before any
trusted pass publication.  Thus status zero is not treated as probe success,
and publication exceptions are not caught and converted back into success.

### Exact one-build boundary

The authenticated author replay lowered, but did not realize:

```text
/gnu/store/3s4gz8f6i8dkclwbknp2x4ww786wv19p-system.drv
  -> /gnu/store/i1ws95jfmvmkjcli5731i1h0ql0k1qn7-system
/gnu/store/z714ddhf80rndbx4iz3qs1ys3wwryy5i-disk-image.drv
  -> /gnu/store/lsk489hgzszvym56m5pnsbrvf5malhiy-disk-image
```

The sorted system graph has 2,786 unique records and SHA-256 `8c3a8277…`;
the sorted image graph has 4,855 and SHA-256 `d5336e73…`.  The exact existing
derivations independently expose the expected output names.  Both outputs
remain absent.  The no-substitute dry run lists 15 missing derivations ending
at the exact image root; the accepted cached kernel `334ljs8…` and source-built
gVisor `djgy782…` are not in that build list.

This verdict authorizes **one** realization of that exact v7 raw-with-offset
image using the frozen packet's private command and exactly
`--target=aarch64-linux-gnu --no-grafts --no-substitutes --max-jobs=1
--cores=2`.  The sole expected output is `lsk489hg…-disk-image`.  Any changed
source, mode, channel, option, derivation, graph, dependency choice, or output
identity is outside this acceptance and must stop before execution.

Image construction is not QEMU authority and will not prove the actual probes.
Before a runtime verdict, the realized bytes and boot payload still require
authentication and the separately reviewed outer binding/checker must require,
for **each** fresh boot, both language-specific source-attribution and exact
boundary-marker lines joined to final guest success, real typed reads/commits,
trusted UI evidence, cleanup, QEMU termination, and the sealed two-boot oracle.
The binding must use the payload-manifest identity, not a status-file identity.
Once those finite prerequisites are bound, the next substantive gate is the
actual two-fresh-boot ARM/gVisor run—or a concrete recapture defect found before
it.  No marker, host model, image hash, or self-asserted console text alone is
runtime acceptance.

### Evidence and conduct

The sealed independent evidence is:

```text
/tmp/opencode/book-state-guest-v7-independent-review-20260907/review-evidence/
49bf1e84aeda168c97395a64cd754e796d1fc32eee1199957ee90f7da9af31cc  EVIDENCE.sha256
```

It contains strict packet/snapshot/author-evidence checks, the complete
mode/byte delta audit, both full SRFI-64 relay logs and reviewer writers, the
production-wiring audit, derivation-boundary audit, environment pins, and all
setup-failure records.  Every file is mode `0400`, the directory is `0500`, and
there are no links or special entries.

One procedure violation is retained explicitly: during environment discovery,
before candidate execution, the reviewer ran ambient `guile --version` once
without the required private HOME/XDG boundary.  It loaded no project source
and is excluded from all evidence and conclusions; every subsequent Guile
execution used the private networkless boundary.  Setup also included one
pre-Guile Bubblewrap mountpoint failure and two reviewer-Python audit drafts
that stopped on a quoting error and an overly literal split-string assertion.
The corrected runs passed; none of the three failed attempts is candidate
evidence.

No image, system, kernel, gVisor, Guix, or Bazel output was built or realized.
No runsc, QEMU, ARM, KOReader, device, SSH, networking investigation,
privileged mount, staging, commit, push, fetch, merge, or rebase occurred.  No
frozen packet, guest implementation, protocol, observer, UI, system, kernel,
image, outer checker, or binding source was edited.  This documentation append
is the only repository-path edit made by the v7 review.
