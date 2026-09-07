# Book Interaction QEMU log harvester — adversarial review — 2026-09-06

## Disposition

**Blocked before the one actual QEMU demonstration.** The held-FD design is
narrow and several safety properties pass, but the reviewed helper can both:

1. publish `harvest-status=complete` while a live writer still owns and later
   changes an unlinked source log; and
2. wait forever after its direct launcher has exited when a descendant retains
   the launcher's stdout or stderr pipe.

Those are concrete failures of the requested frozen-content and bounded-lifetime
properties. They block acceptance of this helper hash and therefore block use of
this launcher for the separately authorized demonstration. They do not reject
the parent image binding, accepted joined source, coordinator, outer, or reader
implementation, and they do not reopen the closed fixed Book Protocol artifact
gate.

No QEMU, runsc, ARM code, image build, Guix build, mount, deployment, network,
or hardware operation was run. This review used only bounded host Python tests,
private fake launchers rooted below `/tmp/opencode`, static source inspection,
and the launcher's pre-runtime refusal branch. Every reviewer-created temporary
tree and recorded descendant process was removed.

## Reviewed identity and scope

The supplied review packet matched its claimed SHA-256:

```text
pinenote/tools/book-execution-spike/build/reader-interaction-image-runtime-binding-review-packet-v1.txt
2233c6f4f0a69fe2d1c00e590e029cba1ed651709f4466a8f6a61a6c549c7c89
```

The executable inputs relevant to this focused review matched:

```text
harvest_reader_qemu_logs.py
410fc4bbbcc37e257616179c0808c970f0c4a5c2f3062673abf6740d0e5e4dd7

test_harvest_reader_qemu_logs.py
102fa950187aad9ce68ded2da99a35336ca8249d546ebc0ca7f000ad21faa162

reader-interaction-real-qemu-launch-v1.command
dc12833a87a169a3f06c7339a5b6abb40498951f847c1049ddaa5412a76092b9

private runtime RUNTIME-SOURCES.txt
19874cb198e395c37aa9005f750fe2c89489ed19c9de63ae9c2786489f8a3e39
```

The private runtime snapshot's harvester and test copies were byte-identical to
the worktree files at the hashes above. I did not independently accept or reject
the image recipe, initrd choice, raw image, 46-path joined inventory, KOReader,
or fixed QEMU graph; those remain with the parent image-binding reviewer.

This review treats the helper only as a six-file evidence observer. It has no
authority over Book Protocol semantics, the UI protocol, expected book results,
reader lifecycle success, cancellation, timers, persistence, rendering,
durability, arbitrary programs, hostile books, or sandbox qualification.

## Properties that passed

### Narrow data and descriptor boundary

The helper names exactly six files beneath one newly observed private run root:
the outer console and coordinator stdout/stderr, plus `reader.log` and the
reader-QEMU stdout/stderr. It never opens the UI socket and contains no parser
for UI-channel bytes, Book Protocol records, paint records, or expected values.
`reader.log` is the only designated future source for trusted native-UI paint
diagnostics; no raw control-channel log is harvested.

Each source log is opened read-only with `O_NOFOLLOW | O_CLOEXEC` after regular
file, caller-owner, private-mode, single-link, size, and lstat/fstat identity
checks. Run-root and reader directories are opened read-only with
`O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`. The observer has no overlay, mount, UI,
book-channel, or writable source FD. Open read-only FDs survive the accepted
guardian-style unlink without preventing cleanup.

The helper process creates the launcher with `close_fds=True`. Its run-base and
evidence directory FDs therefore do not enter the launcher. Held log FDs are
opened only after launcher creation and cannot enter QEMU, KOReader, or a book
channel through this fork/exec edge.

### Path, type, bounds, and output handling

The existing four host tests independently passed:

```text
Ran 4 tests
OK
```

They cover successful retention after guardian-style unlink, a missing required
log, pathname replacement, and an oversized source. Additional private probes
established:

- a symlink at fixed `reader.log` is rejected as non-regular;
- the real foreign target and its bytes are preserved;
- the resulting evidence directory is caller-owned mode 0700, empty, and has no
  misleading `HARVEST.txt`;
- an existing evidence directory is rejected before process creation, its
  foreign sentinel is preserved, and no fake-launcher marker is created;
- a direct launcher exit status 23 is returned as 23, produces
  `harvest-status=failed` and `launcher-status=23`, and cannot cause status zero;
- a success-looking line written by that failed child is retained only in the
  evidence `launcher.stdout` and is not re-emitted as wrapper stdout; and
- the run base is empty after fake guardian cleanup.

Evidence files use exclusive creation, bounded writes, `fsync`, and final mode
0400. A completed evidence directory becomes mode 0500. Missing, overflow,
identity replacement, output collision, and direct child nonzero paths cannot
manufacture the helper's `complete` result.

### Inert launcher boundary

The launcher is syntactically valid shell. With
`WILKBOOK_READER_INTERACTION_QEMU_AUTHORIZATION` absent, an independent
invocation returned status 125, wrote no stdout, and reproduced refusal stderr
SHA-256 `8804eacdd70de0945f10804a2d2aea71d9594c732e0dce38c587ccb9669c3de0`.
The token check precedes hashes, source checks, evidence creation, and process
creation.

The literal is an authorization gate, not mechanically consumable capability
state. The parent must still ensure that any future authorization is supplied
for exactly one invocation. Nothing in this review authorizes that invocation.

## Blocking findings

### H-1 — `complete` does not prove source writers finished or bytes froze

`read_held_log` performs one `fstat`, seeks, and reads until the current EOF. It
does not perform a post-read `fstat`, compare size/timestamps/metadata around the
read, or establish that no writer still owns the inode. The final `complete`
predicate checks only direct child status zero, accumulated errors, and presence
of all six retained byte strings.

An independent fake launcher demonstrated the consequence:

1. It created all six private regular files under a private run root.
2. It passed an append-only FD for `reader.log` to a detached writer whose
   stdin/stdout/stderr did not retain the launcher's pipes.
3. It waited for the observer to open the files, recursively removed its own run
   root to simulate accepted guardian cleanup, and exited zero.
4. The helper returned zero after about 0.465 seconds with
   `harvest-status=complete`, `launcher-status=0`, and
   `run-root-removed=true` while the writer was still alive.
5. The writer subsequently appended `paint-late` successfully to the unlinked
   source inode. The exported `reader.log` remained only `paint-initial`.

Thus packet claim `held-file-lifetime=until-production-child-and-writers-exit`
is not enforced by helper SHA `410fc4bb…`. A clean direct-launcher exit and an
empty run-base pathname do not establish that all writers have closed the held
inode. The retained bytes can be a prefix while the manifest says `complete`.

This is evidence-retention correctness only; the synthetic strings are not
claims about actual KOReader or guest behavior.

### H-2 — inherited descendant pipes defeat the wrapper deadline

The main loop continues while either the direct process is alive **or** a
selector stream remains registered. Deadline and TERM/KILL actions, however,
are conditional on `process.poll() is None` and signal only the direct process.
The child is not placed in a separately owned process group/session.

An independent fake launcher created and removed a valid run root, spawned a
descendant retaining stdout/stderr, and exited status 7. Two seconds later:

```text
direct-launcher-exited=7
run-root-removed=true
descendant-pipe-holder=alive
helper=still-live
```

Because the direct process had exited, advancing past the configured absolute
deadline would not enter either deadline signal branch. The loop can remain in
its finite 20 ms selector waits indefinitely until an external actor closes the
pipe. The reviewer terminated the exact private process group; the helper then
returned status 7, and all recorded processes and files were removed.

The same direct-process-only signaling in the `finally` block does not terminate
descendants after the direct launcher has exited. This fails bounded lifetime on
runner failure and owner-loss propagation.

## Required correction and finite recheck

Do not spend the one actual QEMU run on helper SHA `410fc4bb…`. A replacement
needs a small focused design, not a new log parser or daemon:

1. Own the launched process tree sufficiently to terminate it as a unit (for
   example, a dedicated session/process group suitable for this trusted
   launcher) and apply the absolute deadline even after the direct child exits
   while pipes remain open.
2. On wrapper signal, failure, overflow, or deadline, terminate/escalate the
   owned tree and reap the direct child; do not wait indefinitely for inherited
   pipe EOF.
3. Before declaring `complete`, establish the accepted production writer
   completion condition and then make a bounded read with stable pre/post file
   metadata and exact byte-count checks. A direct status zero plus pathname
   unlink is insufficient by itself.
4. Add the detached-unlinked-writer and exited-parent/inherited-pipe cases as
   negative regressions. Preserve the current success, missing, overflow,
   replacement, symlink/foreign-target, pre-existing-output, and direct-nonzero
   controls.
5. Require fresh focused review because the accepted executable helper and test
   hashes will change. Update the private immutable runtime snapshot, launcher
   hash pin, and parent packet together.

The corrected helper must remain an observer: no UI socket, raw UI-channel log,
semantic checker, host expected-result oracle, recursive run-root cleanup, or
arbitrary path interface is needed.

## Future run interpretation, still unexecuted

If the helper is corrected and the parent independently accepts the image and
launcher, a separate one-use authorization may permit one actual run. Its result
must be assessed from retained artifacts, not from `harvest-status=complete`:

- wrapper/direct production status must be zero without the harvester masking a
  native failure;
- all six logs must be retained from frozen, finished sources;
- the strict reader console checker must pass the retained console;
- `reader.log`, as the designated trusted native-UI diagnostic source, must
  contain exactly four present/painted records and exactly four
  `paintTo`-topmost-exact records;
- the four literal results must be the actual nonce-dependent values generated
  during that run, with the required two Guile then two Python shapes and equal
  ordered runtime suffixes—not host-predicted literals; and
- the accepted shared native UI lifecycle and cleanup cardinalities must be
  checked separately.

Those obligations are not results. No reader paint line, nonce result, guest
semantic PASS, QEMU cleanup, or image runtime claim was generated or accepted in
this host-only review.

## Focused v4 lifetime recheck — H-1/H-2 fixed, publication still blocked

### Disposition

The proposed v4 helper **closes the original H-1 and H-2 defects**, but the
packet is not yet accepted for the actual demonstration. A separate concrete
publication failure can leave `HARVEST.txt` labeled `complete` after the helper
itself fails. The actual QEMU authorization must therefore remain unset.

This disposition preserves the original blocker evidence above as history. It
does not reopen any accepted image, kernel, guest, Lua, Book Session, Book
Protocol, outer, or coordinator source. It also does not decide the parent
reviewer's image-recipe or image-specific-initrd questions. The parent may finish
those questions independently, but this observer remains a condition on running
the demonstration.

### Frozen identities

The focused packet matched:

```text
pinenote/tools/book-execution-spike/build/reader-interaction-harvester-lifetime-review-packet-v2.txt
53f281e3efc00027f0f18debd4ece4631a76c951870d7d62c3cdfe0b4304a4b6
```

The proposed executable bindings matched:

```text
harvest_reader_qemu_logs_v4.py
b9f7936095d8363d25c6cdc5f754f4883e6ef2a0af9f3c9a4358d6670e691457

test_harvest_reader_qemu_logs_v4.py
84e932737708284531826a4724e8450558fc57958f8ed3c8c87437f2b0c97842

private v5 RUNTIME-SOURCES.txt
3a343d9f99dc6cf37f0575d9a5fb1ed7cb7a5a9f1a505eea880480c7a0084f1c

reader-interaction-real-qemu-launch-v4.command
42f90a468ab5447ab9565abcbf7feb8849756784ef94f19c49f59a0c52fcbbdb
```

The helper, test, and launcher deltas matched `e3297adc…`, `c59d50ae…`,
and `3b520f66…`. Reverse-applying each reconstructed the blocked v1 helper,
test, and launcher bytes exactly at `410fc4bb…`, `102fa950…`, and
`dc12833a…`.

An independent v5 snapshot walk verified 62 unique manifest path records: every
file was regular, single-link, mode 0400, and hash-correct; no symlink was
present. All 46 joined-source files and all seven runtime-module-view files were
byte-identical between v2 and v5. Apart from `RUNTIME-SOURCES.txt`, the snapshot
delta is exactly replacement of the blocked helper/test copies with their v4
counterparts. No production core or image input changed in this correction.

### Original findings independently closed

The 16 focused tests passed from the immutable v5 private snapshot in 4.476
seconds. This includes the original H-1/H-2 shapes, helper TERM and HUP, a short
absolute deadline, ordinary and detached-child overflow, direct statuses 7 and
23, missing/replaced/symlinked logs, foreign-root preservation, stable-read
metadata mutation, pre-existing evidence, and post-evidence exec failure.

I also rebuilt independent versions of the two original counterexamples rather
than relying only on those tests:

- **H-1:** a zero-exiting fake launcher unlinked its complete private run root
  while a detached new-session child retained an append FD for `reader.log`.
  V4 returned 1 in 0.471 seconds, emitted only a failed manifest, reaped the
  child, prevented the delayed `paint-late` write, and left the run base empty.
- **H-2:** a status-7 fake launcher unlinked its run root and exited while a
  detached new-session child retained the launcher pipes. V4 returned the
  direct status 7 in 0.465 seconds, emitted only a failed manifest, reaped the
  pipe holder, and left the run base empty.

The child-subreaper design is suitably ownership-limited for this trusted
launcher. It does not scan global `/proc`, signal a process group, or signal a
PID merely by number. It discovers only current direct children of itself,
brackets each child's parent/start-time identity around `pidfd_open`, signals
through that pidfd only after kernel reparenting, and reaps with exact child
PIDs. An additional control kept an unrelated live sibling process intact while
the helper terminated and reaped its own detached new-session descendant.

The direct launcher is created in a private session with `close_fds=True`.
Read-only held log FDs are still opened only after that fork/exec boundary. The
helper retains the original six fixed paths and limits, never opens the UI
socket, never logs the raw UI channel, and never computes expected or semantic
results.

After direct-child and adopted-child completion, each held source is read with
bounded `pread`: exact pre-read size, one-byte-past-EOF growth detection, stable
device/inode/mode/owner/group/size/mtime/ctime before and after, and exact byte
count. `complete` additionally excludes every observed adopted child, forced
pipe close, wrapper signal, deadline, overflow, replacement, missing/unstable
log, cleanup residue, and direct nonzero result. These conditions resolve the
original writer-prefix and inherited-pipe findings within the stated owned-tree
boundary.

### P-1 — post-publication helper failure leaves a false complete manifest

The normal path computes `complete`, writes `HARVEST.txt`, makes the evidence
directory read-only, and only then replays captured launcher stdout. If that
replay raises `BrokenPipeError`, the broad `OSError` handler correctly selects a
nonzero helper result, but its fallback writes a failed manifest only when
`HARVEST.txt` is absent. The already-written mode-0400 complete manifest remains
unchanged.

I reproduced this without modifying the helper:

1. A private fake launcher created all six valid logs, allowed the observer to
   open them, removed its run root after all writers were done, wrote one normal
   success line to its stdout, and exited zero.
2. The helper's own stdout was connected to a pipe whose read end was closed,
   deterministically causing the final replay to raise `BrokenPipeError`.
3. The helper exited nonzero (observed status 120, including Python's final
   broken-pipe handling), and stderr reported `Broken pipe`.
4. The evidence directory nevertheless contained `HARVEST.txt` with
   `harvest-status=complete` and no `harvest-status=failed`.

This does not create an acceptable overall run when the required wrapper status
is checked, but it contradicts the packet's
`post-evidence-internal-failure=minimal-harvest-status-failed-manifest` and
`failure-manifest-rule=...never-partial-prefix-complete` claims. It also creates
an internally false artifact for any later consumer that sees the evidence
directory without its wrapper status. Output-pipe loss is a real owner/observer
lifecycle failure, not guest semantics or a request for a new parser framework.

### Finite correction required

Keep the H-1/H-2 ownership and stable-read design, but make publication
fail-closed:

1. No caught failure after evidence creation may leave the canonical manifest
   saying `complete`. Use a failed/pending state until all failure-prone output
   operations needed for success have completed, or securely replace/remove a
   premature complete manifest on failure.
2. Add the closed-final-stdout case above as a regression requiring nonzero
   status and no canonical `complete` manifest. The existing post-evidence exec
   test occurs before a complete manifest exists and does not cover this window.
3. Preserve direct nonzero status, bounded owned-tree cleanup, exact six-log
   scope, exclusive private evidence root, and default refusal.
4. Refresh the helper/test, immutable snapshot, launcher hash pin, and focused
   packet together, followed by another bounded host-only review.

The v4 launcher itself is correctly inert by default. Its shell syntax passed;
with the authorization variable absent it returned 125 with exact refusal hash
`8804eacd…` before hash checks, evidence creation, or process creation. Its token
literal is
`READER_INTERACTION_HARVESTER_V4_PACKET_ACCEPTED_AND_REAL_QEMU_SEPARATELY_AUTHORIZED`.
The run base remained mode-0700 and empty, and the future v4 harvest directory
remained absent. No authorization was supplied or consumed.

No actual nonce-dependent result, reader paint line, guest semantic result,
QEMU cleanup result, or image-runtime result was produced in this recheck. The
future four-result and trusted-`reader.log` obligations recorded above remain
unchanged and unexecuted.

## Focused v5 final-publication recheck — accepted

### Verdict

**Accept the P-1 correction and close the remaining host-harvester gate for the
exact v5 tuple below.** The prior closed-stdout counterexample now returns 1,
not 120, retains all six bounded logs, and seals a read-only failed manifest
with no canonical `harvest-status=complete`. Normal publication still emits the
exact retained success line, seals `complete`, and returns zero. Direct statuses
7 and 23 remain authoritative and do not re-emit success-looking child stdout.

The original H-1/H-2 findings remain closed by the previously accepted v4
owned-tree and stable-read implementation. The v5 delta does not touch that
code. The P-1 blocker immediately above remains preserved as historical evidence
against v4; v4 and its authorization literal are prohibited for the actual run.

This acceptance is only for host log retention and final publication. It does
not expand the harvester into a semantic checker and does not claim any actual
nonce result, UI paint, guest result, QEMU cleanup, rendering, durability,
cancellation, timer, persistence, arbitrary-book, hostile-book, or general
sandbox behavior.

### Accepted exact tuple

```text
focused packet
pinenote/tools/book-execution-spike/build/reader-interaction-harvester-publication-review-packet-v1.txt
db1800568bfbb95cd06b4320011b26e9216e950c6e9d57ad45afb1fc4a94db94

helper
pinenote/tools/book-execution-spike/harvest_reader_qemu_logs_v5.py
462a20ad7eb8c9ce908645aa10a6da8cd6bdd054f852c90e51294dde73e27e51

tests
pinenote/tools/book-execution-spike/test_harvest_reader_qemu_logs_v5.py
2101be2f51f7846778d44c15c39fa59c8c4367de6adfef8440bc287a3bf61e48

private v6 RUNTIME-SOURCES.txt
506605cfec38f32fe2a1bad426529d4e4816174df8a1a3c3ebf9407c66d389a6

launcher
pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v5.command
f1289ecbb4f5363d56deba3437cf12b22f8d7163997f291f1d86c056691ea151
```

The accepted image-binding review independently remains
`805f1abdb77ea48632f1a983bc78ba8963ac536b5ce97ae3a0c7bd9aa6e79e6c`.
I did not reopen or repeat its image, kernel, initrd, KOReader, guest, outer,
coordinator, or Lua review.

### Delta and immutable binding

The helper, test, and launcher deltas matched:

```text
helper v4-to-v5  fe67e71fce457f312b1132fd91adeef6ecf16c11b511eb751c18be1841a64224
test v4-to-v5    f05af12339aa2e33fc700dcf1fd27219338d7db12dd1452193bf91d315f1a9dd
launcher v4-to-v5 a5a65cef9c841435d7be55f2c9096955991ea55d0deab4d8b729f80cc767dc1b
```

Reverse-applying them independently reconstructed the exact v4 helper, test,
and launcher hashes `b9f79360…`, `84e93273…`, and `42f90a46…`. The helper
delta adds only pending-manifest and bounded final-output helpers, moves required
stderr/stdout publication before the complete seal, lets the emergency path
rewrite the still-open canonical manifest FD as failed, and closes that FD in
the existing finalizer. Process discovery, subreaper ownership, pidfd signaling,
deadlines, child reaping, source paths, source bounds, and stable source reads
are byte-unchanged.

The v6 snapshot contained 62 unique hash records. Every recorded file was
hash-correct, regular, mode 0400, and single-link; there were no symlinks. All 46
joined-source files and all seven runtime-module-view files were byte-identical
between v5 and v6. The only source-copy replacement is the v4 helper/test pair
with the v5 pair, plus the corresponding `RUNTIME-SOURCES.txt` metadata update.

The launcher diff changes only the authorization literal, private snapshot,
future evidence path, helper filename, runtime-manifest hash, and helper hash.
The accepted image, baseline, kernel, config, DTB, initrd, KOReader, host tools,
production entry, coordinator, arguments, and single outer invocation are
unchanged.

### Focused independent results

The retained 17-test packet log matched SHA-256
`45ba89eaccfd051bdb2d10acdce7a714ad57fbce263421311d34a84c82c3f367`
and records 17/17 passing. Rather than reopening the inherited matrix, I ran the
four publication-relevant methods from the immutable v6 snapshot:

1. closed final stdout;
2. normal successful publication;
3. direct status 7 with the inherited pipe-holder shape; and
4. direct status 23 with success-looking stdout.

All four passed in 1.848 seconds.

I separately reconstructed the final-publication cases with an independent
private fake launcher:

- **Normal:** status 0; stdout was exactly `EXACT-SUCCESS-LINE`; stderr was
  empty; the canonical manifest said only `harvest-status=complete`; all six
  source logs were retained mode 0400; and the evidence directory was mode 0500.
- **Exact P-1:** the helper stdout pipe had no reader before final replay. The
  helper returned exactly 1, not 120; stderr recorded `Broken pipe`; the
  canonical manifest said only `harvest-status=failed` and recorded the required
  stdout-publication failure; all six logs remained retained mode 0400; the
  manifest was mode 0400; the evidence directory was mode 0500; and the run base
  was empty. No global success line could be delivered to the closed pipe.
- **Direct 7 and 23:** each exact status was preserved, each canonical manifest
  was failed rather than complete, the success-looking child stdout was retained
  in `launcher.stdout`, and none was replayed on helper stdout.

The corrected order is fail-closed: `HARVEST.txt` is exclusively created empty,
made read-only while its sole private writer FD remains open, and cannot contain
`complete` until required stderr and stdout writes and explicit flushes have
succeeded. A caught output error redirects and drains the failed Python stream
to `/dev/null`, avoiding an implicit shutdown flush and status 120, then writes
the failed canonical manifest through the already-open FD. No semantic result
or host expected-value oracle was added.

### Launcher and authorization state

The v5 launcher passed shell syntax checking. Supplying the prohibited old v4
literal returned 125 with the exact refusal output `8804eacd…`, before hash
checks, evidence creation, or process creation. The run base remained private
and empty, and the future v5 evidence directory remained absent.

The only eligible future literal is:

```text
WILKBOOK_READER_INTERACTION_QEMU_AUTHORIZATION=READER_INTERACTION_HARVESTER_V5_PACKET_ACCEPTED_AND_REAL_QEMU_SEPARATELY_AUTHORIZED
```

It was not set, exercised, or consumed in this review. This report closes the
focused harvester precondition; the parent remains responsible for supplying
that exact authorization for at most one invocation under the already accepted
image binding. Any change to the packet, helper, test, v6 manifest, or launcher
hash requires fresh review.

No QEMU, runsc, ARM execution, image or Guix build, mount, deployment, network,
or hardware action occurred during this final host-only review.
