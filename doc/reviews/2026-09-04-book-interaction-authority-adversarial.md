# Book Interaction authority/process integration adversarial review — 2026-09-04

## Verdict

**Do not accept the Book Interaction integration gate at this snapshot.** The
ordinary fixture is real: both Guile and Python books communicate over donated
Unix sockets with the accepted Guile Book Session authority, the host receives a
real `<presented-text>` authority result, and pinned KOReader applies that value
through its separate private channel. Endpoint donation, environment narrowing,
normal navigation/close routing, exact-child cleanup, owner-loss cleanup, and
the stated Guile-side bounds held in focused tests.

Two defects remain:

1. **High integration blocker:** the LuaJIT private reader channel does not
   actually set `O_NONBLOCK`. Its variadic `fcntl(F_SETFL, ...)` call passes an
   uncast Lua number; on the reviewed runtime the kernel receives a zero flags
   argument. A never-read peer blocked the second nominally bounded write until
   an external watchdog killed the probe.
2. **Medium regression-integrity defect:** `run-tests.sh` freezes
   `timeout-owner.sh` and `process-identity.sh`, but not the `record-exec.sh`
   program that the timeout owner executes twice to publish the identities on
   which fail-closed owner-loss cleanup depends. A no-op recorder returned green
   with both records absent while every hash currently checked by Book
   Interaction remained unchanged.

The first defect falsifies a central bounded-I/O claim in the runtime under
review. The second does not mean the exact current recorder is broken—it is the
previously accepted implementation and behaved correctly here—but it leaves the
new integration regression gate unable to detect loss of that implementation.

This review does **not** reopen the accepted Book Protocol or Book Session
findings. It also does not reassess KOReader widget correctness already assigned
to the separate reader reviewer. The accepted scope remains trusted-native real
IPC with two known fixture programs. It is not a sandbox, gVisor result,
production security profile, arbitrary-untrusted-exec guarantee, or fallback
runtime.

## Threat and scope boundaries

- Guile remains the sole authority. Python is one fixture book language, not a
  broker or fallback authority.
- The selected Guile/Python book and Lua plugin are reviewed **trusted native**
  fixtures. A hostile same-UID native program is outside this gate: it could
  open new files and sockets, signal processes, inspect accessible `/proc`
  state, modify writable files in the shared temporary tree, fork descendants,
  or attempt other native-process attacks. Descriptor and environment hygiene
  below prevents accidental inheritance; it is not confidentiality or process
  isolation from malicious native code.
- The book controls Book Protocol bytes on its donated session socket. It does
  not receive the private reader-control descriptor. The reader control channel
  is trusted fixture automation, not a peer capability or proposed SDK.
- Host CLI arguments, fixture selection, package evaluation, and calls such as
  `host-action!`, `navigate!`, and `close-session!` are trusted-side operations.
  Their validation was tested for accidental/misconfigured invocation, not as a
  sandbox boundary against a caller already able to choose arbitrary native
  executables.
- Automatic timers do not exist here. The 15-second fixture deadline and
  20-second process owner are whole-test watchdogs, not request expiry. The
  future timer-lease requirement from the Book Session review remains dormant
  until automatic request timers are introduced.
- The process claim is exact cleanup of the two direct children used by these
  known fixtures. There is no cgroup/subreaper and no guarantee for descendants
  spawned by arbitrary native code.
- No sandbox, renderer correctness, display settlement, durability, persistent
  data, networking, device, or production asynchronous scheduler property is
  claimed or inferred.

## Exact reviewed snapshot

Repository baseline was
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The Book Interaction directory was
untracked, so the hashes—not the baseline commit alone—identify the review
object.

### Book Interaction files

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-interaction/integration-host.scm` | `c7571df61a86273a3c88f9bd646f1ebc5a0790ff1913d5e274ccc87b880d84b2` |
| `pinenote/tools/book-interaction/private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `pinenote/tools/book-interaction/test-private-control.scm` | `92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a` |
| `pinenote/tools/book-interaction/fixture-book.scm` | `2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d` |
| `pinenote/tools/book-interaction/fixture_book.py` | `58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua` | `31197623ee29033fc51ca8698a5b1682e4abdad34f50b6b9d0f1a919de4c643a` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/private_channel.lua` | `bb1eedd0ed611760e4a7403ed4a2af3b52ff153c1567ed7429cd7e4f165ea42e` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/_meta.lua` | `89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964` |
| `pinenote/tools/book-interaction/run-tests.sh` | `b17b1fdf8b5b82b65e5183654aa1a696277b03a16b557b14140ecbb04d1c59b9` |
| `pinenote/tools/book-interaction/Makefile` | `7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e` |
| `pinenote/tools/book-interaction/README.md` | `ed9febf76c40b2e0125a549d960a47dce13e8a6bdc336f85f3d1fd9ae9b2c253` |

### Accepted/runtime dependencies

| File | SHA-256 |
|---|---|
| Accepted `book-session/book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |
| Accepted Guile `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| Accepted blocking adapter `book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| Accepted Python `book_protocol.py` | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| `book-reader/canonical-koreader-output.scm` | `9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239` |
| `book-reader/timeout-owner.sh` | `e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e` |
| `book-reader/process-identity.sh` | `97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354` |
| `book-reader/record-exec.sh` (used but not pinned by this gate) | `fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c` |
| `book-reader/lint-fixture.sh` | `3051d24090152fd873a197cab6bfcbc88f977dbb4124ddf1ddbf910e62c9b7ff` |
| `pinenote/packages/koreader.scm` | `81c075b539803e1ffb1a67724cfa57c7f38698edbaff2889ebaaea00a5da8567` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |
| Final accepted Book Session review | `223c2f5272071a43e02069b2feb49370f81cc084c0909df9e09faa639009939a` |

The package-pinned baseline resolved
`/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`, derivation
`/gnu/store/amd75p0f3namp1x2kwhkhipd568s9na2-koreader-bin-2026.03.drv`, and
one-line revision `v2026.03`. Relevant immutable files were:

| Bundle file | SHA-256 |
|---|---|
| `lib/koreader/luajit` | `d6fdee87218f50e36b44b4c19f18de944f87b465cd24227dacf5b9cb83774a88` |
| `lib/koreader/reader.lua` | `a189ca83623153f2a1b048c7bc04eba1fca76068bd9705dc71296d26292613cc` |
| `lib/koreader/git-rev` | `846aed94948bfa1c155325770bf4df8673850a14395ec585c3d594c859d5b2d5` |
| `frontend/ui/widget/inputdialog.lua` | `a03bdd3827a3108d313a19407c7e2db6176e20c3066595356f4c86e3a50930b4` |
| `frontend/ui/uimanager.lua` | `f74b56b1885647770da9596e753990dd065032b6f85777260c841c19b1999464` |

The two accepted generic codecs and Book Session authority were not
re-reviewed. Their regression behavior was consumed only through this new host.

## Findings

### BI-1 — High integration blocker — LuaJIT `F_SETFL` silently fails to set nonblocking mode

`private_channel.lua` declares `fcntl` as a C variadic function:

```lua
int fcntl(int fd, int command, ...);
```

Its constructor then supplies the third argument as an ordinary Lua number:

```lua
C.fcntl(options.fd, F_SETFL, bit.bor(flags, O_NONBLOCK))
```

LuaJIT FFI does not infer the C integer type for a variadic argument. On the
reviewed x86-64 runtime, the call returned success but supplied the wrong value
to the kernel. A focused socketpair probe observed:

```text
fcntl(3, F_GETFL)          = 0x2 (O_RDWR)
fcntl(3, F_SETFL, O_RDONLY) = 0
fcntl(3, F_GETFL)          = 0x2 (O_RDWR)
```

Thus the constructor's success assertion passes while `O_NONBLOCK` remains
clear. This affects both `read` and `write`; real KOReader's normal event-loop
read happens after readiness, but `_send()` calls `_pump_output()` directly and
therefore reaches a potentially blocking write from reader/UI callback work.

The independent backpressure reproduction created a socketpair, reduced its
send buffer, instantiated the exact Lua module, and never read the peer:

```text
FIRST_SEND_RETURNED
# second send never returned
external watchdog: rc 124
```

The second nominally 4,096-byte-bounded send blocked in `write(2)` until the
two-second watchdog killed the process. Queue frame/byte checks cannot help
because execution never returns from the blocking syscall to examine or report
backpressure. The whole-fixture deadline can eventually kill the process domain;
that is not equivalent to keeping a KOReader event turn nonblocking.

This is not a book-wire authority escalation. The book has no inherited reader
descriptor, and the private peer is the trusted Guile host. It is nevertheless
a blocker to the integration's advertised bounded nonblocking ownership and to
using this adapter without risking a frozen reader callback.

**Required fix.** Pass an explicitly typed C integer in the variadic position,
for example `ffi.cast("int", bit.bor(flags, O_NONBLOCK))`, then read flags back
and require the `O_NONBLOCK` bit. Add a bounded test that calls `waitEvent()` on
an empty socket and fills a never-read output socket until `EAGAIN`/queue-full,
proving every call returns and retained frames/bytes stay within 8/65,800.

### BI-2 — Medium regression-integrity defect — the identity recorder is an unpinned executable dependency

`run-tests.sh` verifies exact hashes for the accepted session/protocol files,
the canonical KOReader evaluator, `timeout-owner.sh`,
`process-identity.sh`, and `channels.scm`. However, the pinned timeout owner
dynamically executes sibling `book-reader/record-exec.sh` for both the GNU
timeout identity and the command identity. Book Interaction neither hashes that
file nor lists it in its source-trace dependencies.

The current `record-exec.sh` hash is the accepted
`fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c`, and
the current baseline plus focused cleanup probes behaved correctly. The defect
is that the new gate would not notice a later change to that executable.

An isolated copy retained the exact pinned timeout owner and process helper but
replaced only `record-exec.sh` with an interface-compatible program that ignored
the record path and immediately `exec`ed its command. A normal bounded command
produced:

```text
timeout-owner rc = 0
command.pid       absent
timeout.pid       absent
```

Every hash currently required by Book Interaction was unchanged. Normal
completion does not expose the loss because waiting on GNU timeout still works;
if an owner is then lost, the fallback identities that are supposed to prevent
orphans and PID-reuse kills do not exist.

**Required fix.** Freeze `record-exec.sh` alongside the other reused process
helpers and record its hash in the README. Prefer also a supplied negative test
that removes either identity publication and requires the owning layer to fail,
rather than relying only on a source hash.

## Positive authority and integration evidence

### Real authority result, not fixture log markers

The ordinary baseline's Guile and Python runs reached real pinned KOReader and
printed their expected child markers. Those markers are diagnostics, not the
authority oracle. Source and a negative control establish the stronger path:

1. `handle-session-input!` calls the accepted endpoint's
   `endpoint-pump-input!`.
2. Only a `committed` result is inspected.
3. The value must satisfy private Guile predicate `presented-text?`.
4. `handle-presented!` additionally requires phase `update-present`, action ID
   `update`, and exact authority-returned text `Book result: ADA`.
5. Only then does the host queue `present` on the separate reader channel and
   advance to `update-applied`.

An independent fake book printed every expected peer success marker, completed
a real hello/action exchange, then sent the expected text with a forged request
ID. A small private-channel reader drove the host to the update phase. The host
rejected the Book Session input, emitted no host success marker, exited nonzero,
and removed both exact child processes. Therefore fixture peer logs cannot
substitute for an accepted `<presented-text>`.

The actual mutation was host/process-only; it made no KOReader UI claim. The
separate reader review remains the authority for whether the trusted plugin
really displayed and updated `InputDialog`.

### Endpoint donation and environment hygiene

Before either fixture source executes, the child launch gate requires the
parent to publish PID plus Linux start time. The child duplicates only the
selected socket to FD 3, redirects standard streams, closes every inherited FD
above 3 from `/proc/self/fd`, and asserts the resulting set.

A focused spawn used the exact implementation with one session socketpair and a
second unrelated socketpair standing in for the private reader channel. After
real Python exec, while the child was blocked on FD 3, the parent independently
observed exactly FDs `0,1,2,3`; FD 3's `socket:[inode]` matched the selected
session peer and neither private-channel inode. The child repeated the same FD
check itself and exited zero. The parent reaped its exact PID and the identity
record disappeared.

The child environment was an exact six-name test allowlist. Parent sentinels in
`AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`,
`BOOK_INTERACTION_CONTROL_FD`, and `BOOK_INTERACTION_ROOT` were absent. Source
inspection of the real book invocation likewise shows only explicit `PATH`,
locale, scoped home/temp, language load paths, and `BOOK_SESSION_FD=3`; only the
reader receives `BOOK_INTERACTION_CONTROL_FD=3` and the fixture root.

This proves descriptor donation and environment replacement for the reviewed
spawn code. It does **not** make secrets inaccessible to hostile same-UID native
code through all OS facilities, nor prevent such code from modifying the shared
writable fixture tree. The honest trusted-native/no-sandbox label is therefore
load-bearing.

### Argument and scope rejection

Focused direct-host cases established:

- missing arguments print the exact usage and fail before child creation (the
  top-level catch converts the internal `exit 2` into final status 1);
- a peer label outside `guile`/`python` fails before child creation; and
- a canonical book path other than the generated
  `RUN_DIR/fixture-book.txt` fails before child creation.

All executable and directory arguments are canonicalized. In the supported
`run-tests.sh` path, KOReader LuaJIT is selected from the verified bundle and
the two peer labels select fixed source files. Direct trusted invocation can
still nominate an arbitrary interpreter executable; that is consistent with
fixture mode and must not be described as untrusted execution policy.

### Bounds and failure cleanup

The Guile private codec independently round-tripped a 1,024-scalar/4,096-byte
emoji value and rejected one extra scalar, confirming a UTF-8 byte rather than
character bound. Eight maximum-value control messages stayed within the
8-frame/65,800-byte host queue; a ninth failed before queue mutation, and owner
cleanup cleared frames and byte accounting. An actual 9,000-byte unterminated
reader line made the active integration host fail on the 8,224-byte line bound,
close both channels, terminate/reap both children, and leave no matching record.

The exact Lua decoder—apart from BI-1's FD mode—also showed bounded parsing:

- an 8,203-byte command required three at-most-4,096-byte polls and then decoded
  exactly 4,096 bytes of well-formed UTF-8;
- callback reentry returned without recursively polling;
- command/event direction, `01` generation, and uppercase hex were rejected;
  and
- a 9,000-byte unterminated input failed with 9,000 retained bytes, below its
  12,320-byte aggregate input cap.

A child that wrote without bound hit `RLIMIT_FSIZE`, exited nonzero, produced a
log no larger than 128 KiB, was reaped, and lost its identity record. This is a
per-regular-file fixture bound, not a memory, file-count, disk-quota, or hostile
native-process bound.

Book JSON framing and Book Session's 65,536-byte frame, 4,096-byte presentation,
and eight-frame output limits are the already accepted implementations; this
review did not rerun their mutation corpora.

### Navigation, close, and cancellation scope

Both real language runs used one locally captured endpoint. For navigation, the
host creates and queues the action on that endpoint, calls `navigate!` on the
same endpoint, requires generation 2 and zero pending requests, then accepts
only the expected stale-generation rejection from that endpoint. For close, it
waits until the same endpoint's outbound queue drains, calls `close-session!`,
requires `closed` with zero pending, observes the peer's rejected delayed write,
and independently keeps the reader sibling alive on its private channel. The
baseline completed both routes for Guile and Python.

There is **no cancellation interaction** in this directory: no code calls
`cancel-request!`. Cancellation remains tested only in the accepted core Book
Session suite. This is not a contradiction in the current README, whose
concrete interaction claims navigation and close, but this integration must not
be cited as cancellation-route evidence. Add a real IPC cancellation phase if
cancellation is intended to enter the integration gate.

### Exact process ownership and deadlines

The supplied baseline killed the Guile host after both child records were
published and independently terminated both surviving recorded children. Normal
Guile and Python runs required both exact direct children to exit zero and be
reaped.

Focused process tests added:

- A TERM-resistant process paired with a deliberately stale start time was not
  signalled. Replacing the record with its actual start time caused bounded
  TERM-to-KILL escalation, and no matching process remained.
- Two TERM-resistant fake integration children triggered the real internal
  15-second deadline. Sequential exact-child escalation completed with host
  status 1 in 19 seconds, both identity records became non-matching, and neither
  child remained.
- The forged-marker and oversized-control failures also cleaned both recorded
  children on exceptional host exit.

These results support PID-plus-start-time cleanup for the two current direct
children and owner-loss choreography. They do not establish collision-free
identity across a hypothetical same-PID/same-start-tick reuse, descendant-tree
ownership for arbitrary programs, or cgroup-grade process-domain cleanup.

## Baseline and test accounting

One ordinary invocation, bounded by a 120-second external watchdog, passed:

```text
16 Guile SRFI-64 private-control assertions
PASS: exact outer cleanup terminated both children after owner loss
PASS: guile fixture book completed the real IPC/UI interaction
PASS: python fixture book completed the real IPC/UI interaction
PASS: Book interaction vertical fixture
```

It resolved the canonical already-present KOReader output and reported
`bundle-mode: package-pinned` and
`mode: trusted-native-fixture (no sandbox)`. The canonical evaluator's build
handler was not entered; no package or system was built or realised.

Five focused drivers then produced exactly **44 passing adversarial checks**:

| Driver | Passing checks |
|---|---:|
| FD/environment, child-output, Guile queue and UTF-8 boundaries | 14 |
| Host argument/scope, forged-marker, and oversized-control negatives | 16 |
| PID/start-time and TERM-resistant cleanup | 4 |
| Lua parser diagnostics plus expected never-read blocking reproduction | 9 |
| Real internal deadline with two TERM-resistant direct children | 1 |

All blocking and process cases had an external watchdog; resistant processes
were addressed only by recorded PID/start time or by the direct test process
that created them. `run-tests.sh` passed `sh -n`.

Three preliminary reviewer expectations were corrected rather than counted:

1. the usage test initially expected status 2, but the top-level catch visibly
   converted `quit (2)` to status 1;
2. an initial Lua test expected an 8.2 KiB maximum line to decode in one 4 KiB
   poll; it correctly required three; and
3. the revised combined Lua queue probe timed out. A smaller diagnostic plus
   `strace` established that this timeout was BI-1, after which it was rerun as
   an explicit expected-watchdog counterexample.

No repository implementation was edited. All generated helpers and mutations
lived in private mode-0700 directories below `/tmp/opencode` and were removed.
A final exact-prefix process/directory scan found no process or temporary path
owned by this reviewer. A separate concurrently active reader review directory
was observed and deliberately left untouched. No hardware, QEMU, VM, gVisor,
network operation, deployment, package build, or system build was used. The only
repository file created by this review is this report.

## Required recheck

1. Correct and verify LuaJIT's `O_NONBLOCK` setup with an explicitly typed
   `fcntl` variadic argument. Pin empty-read and never-read output tests that
   return within a watchdog and reach bounded backpressure rather than blocking.
2. Freeze `book-reader/record-exec.sh` as a direct runtime dependency and add a
   negative test for missing identity publication.
3. Rerun one ordinary Guile/Python offscreen integration and only the focused
   Lua backpressure and recorder controls; do not reopen accepted Book
   Protocol/Session or the separate UI review.
4. Keep cancellation explicitly outside the accepted interaction unless a real
   cancelled action/reply phase is added.

No hardware session is justified by these findings.

---

## Focused BI-1 / BI-2 recheck — later 2026-09-04 snapshot

### Updated verdict

**BI-1 and BI-2 are closed at the hashes below. The Book Interaction
authority/process integration is accepted for its deliberately narrow
trusted-native, real-IPC fixture scope.** This later disposition supersedes the
earlier “do not accept” verdict above for these two findings only.

The acceptance covers one bounded, supervised
`update → present → navigation → close` interaction using the accepted Guile
Book Session authority, the two known Guile/Python fixture books, and the pinned
offscreen KOReader fixture. It does not add a sandbox, gVisor, production
security profile, arbitrary-untrusted-exec guarantee, request timer, durability,
or UI/display-settlement claim. Cancellation remains explicitly untested by
this integration and is not part of this acceptance. The separate reader/UI
review remains independent.

The repository baseline remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`; the scoped directories remained
untracked, so the following hashes identify the accepted snapshot.

### Focused source hashes

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua` | `31197623ee29033fc51ca8698a5b1682e4abdad34f50b6b9d0f1a919de4c643a` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/_meta.lua` | `89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| `pinenote/tools/book-interaction/fixture_book.py` | `58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363` |
| `pinenote/tools/book-interaction/fixture-book.scm` | `2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d` |
| `pinenote/tools/book-interaction/identity-hold.sh` | `bda607a6cc1ee7a2c75a178c485c8ff5799158dd0a24ecaa99d3fd500ea7bf12` |
| `pinenote/tools/book-interaction/integration-host.scm` | `647b741e1eb1afa29622e8ef86306cbb5538e4b76953e3a943d6ae381f240e48` |
| `pinenote/tools/book-interaction/Makefile` | `7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e` |
| `pinenote/tools/book-interaction/private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `pinenote/tools/book-interaction/README.md` | `2a397e5b83baf9654d78f7954c456ef832b32dd025efe69d35e01eb93598529a` |
| `pinenote/tools/book-interaction/run-tests.sh` | `b837f354f88730a9a36fa90d6c2b9145fd3a0d71ae546a0557d41bfb642d1dd9` |
| `pinenote/tools/book-interaction/test-private-channel.lua` | `e23fb4022c29fa445f8ab5c75898ad1ba508107319e685632348dcc61ddd1a06` |
| `pinenote/tools/book-interaction/test-private-control.scm` | `92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a` |

Relevant unchanged dependencies:

| File | SHA-256 |
|---|---|
| Accepted `book-session/book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |
| Accepted `book-session/test-book-session.scm` | `dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec` |
| Accepted Guile `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| Accepted `book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| Accepted Python `book_protocol.py` | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| `book-reader/record-exec.sh` | `fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c` |
| `book-reader/timeout-owner.sh` | `e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e` |
| `book-reader/process-identity.sh` | `97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |

No accepted core/session defect was rerun or inferred from the integration. The
hashes confirm those inputs remained at the previously accepted snapshot.

### BI-1 closure — effective nonblocking mode and bounded backpressure

The LuaJIT constructor now:

1. reads the original flags with `F_GETFL` and rejects a negative result;
2. passes `ffi.cast("int", bit.bor(flags, O_NONBLOCK))` as the variadic
   `F_SETFL` argument;
3. requires the actual `F_SETFL` return value to equal zero; and
4. reads the effective flags back with `F_GETFL`, rejecting construction unless
   the `O_NONBLOCK` bit is really present.

The Guile private-control owner now also checks both the `F_SETFL` result and an
effective `F_GETFL` readback. This recheck did not broaden into unrelated host
behavior.

The supplied exact-runtime regression uses the pinned KOReader LuaJIT, performs
an empty read, and fills a socket whose peer never reads. It requires observed
read and write `EAGAIN`, no callbacks, no error callback, at most eight pending
frames and 65,800 pending bytes, atomic queue-full retry rejection, and bounded
return from a combined read/write pump. It passed in the baseline below.

I independently reran the original never-read shape against the exact reviewed
module rather than relying on the supplied test. `F_GETFL` returned `2050`
(`O_RDWR | O_NONBLOCK`). Both of the original 4,096-byte sends returned. Further
sends reached fail-closed backpressure with exactly eight retained frames,
57,496 retained bytes, and seven observed write-would-block returns; the
five-second watchdog was not reached.

For a mutation control, I copied only the plugin fixture and replaced the typed
variadic expression with the original untyped
`bit.bor(flags, O_NONBLOCK)`. The supplied exact-runtime regression failed with
status 1 at constructor readback—`private channel O_NONBLOCK verification
failed`—rather than hanging or passing. Therefore the test is sensitive to the
specific BI-1 regression, and the runtime property was also independently
observed.

No focused bypass remains for BI-1.

### BI-2 closure — frozen recorder and two live identities

`run-tests.sh` now freezes the exact current `book-reader/record-exec.sh` hash
`fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c`
alongside `timeout-owner.sh` and `process-identity.sh` before package lookup or
process launch.

Its acceptance gate waits for both the command and deadline records to denote
currently live PID/start-time identities, reads both tuples, rejects equal PIDs,
and revalidates both exact identities. The gate also stops waiting if its own
outer owner identity dies. Normal completion still checks that command,
deadline, reader, and peer records no longer match live processes.

Two independent mutation controls passed:

- In an isolated source layout, appending one comment only to
  `record-exec.sh` made `run-tests.sh` fail with status 1 and name that file as a
  changed frozen input before launching the fixture.
- With the original interface-compatible no-op recorder from BI-2, the real
  timeout owner did start a separately identity-recorded hold command, but the
  exact active `require_live_identity_records` function returned status 1
  because `command.pid` and `timeout.pid` were absent. The owner and hold command
  were then removed by their exact identities. Thus the negative is not a
  vacuous command-never-started pass.

During the accepted real baseline, an independent watcher captured both records
while live for each language:

```text
guile:  command=1283515/76907394  deadline=1283507/76907393
python: command=1284465/76907529  deadline=1284457/76907529
```

Each pair used distinct PIDs and both PID/start-time tuples revalidated against
`/proc` while the corresponding real run was active. The Python processes were
created in the same kernel clock tick, but their PIDs—and therefore their exact
identity tuples—were distinct. Neither language could count as accepted merely
because a wrapper returned zero.

No focused bypass remains for BI-2.

### Bounded baseline and cleanup

One `make check` invocation, enclosed by a 120-second reviewer watchdog and a
private reviewer-owned temporary root, passed:

```text
16 Guile SRFI-64 private-control assertions
PASS: typed fcntl and never-read private channel remain nonblocking
PASS: exact outer cleanup terminated both children after owner loss
PASS: no-op identity recorder is rejected before cleanup acceptance
PASS: guile fixture book completed the real IPC/UI interaction
PASS: python fixture book completed the real IPC/UI interaction
PASS: Book interaction vertical fixture
```

The run used the same package-pinned already-present KOReader 2026.03 output as
the initial review and completed without package or system builds. The first
reviewer baseline-watcher attempt failed before launching the suite because the
reviewer script sourced a relative helper from the wrong working directory; it
is not counted. The corrected run above used absolute paths and is the sole
accepted baseline evidence for this recheck.

All independent probes used private exact-prefix directories below
`/tmp/opencode` and finite watchdogs. Cleanup targeted only PID/start-time
records or direct reviewer children within those directories; no name-wide or
broad cleanup was used. A final scan found no reviewer-owned process or
temporary directory. No implementation file, hardware, QEMU, VM, gVisor,
network, deployment, package, kernel, or system build was touched by this
recheck. The only repository write was this appended authority-review section.

---

## Implementation disposition after the rejected review — 2026-09-04

This section is an **implementer record, not an independent re-review**. It does
not change the NOT-accepted verdict at the top of this report. It identifies the
candidate fixes submitted for the focused recheck requested above. The report
hash immediately before this section was
`6b2aa2dbff0745df48134e35b580badf460196ff4b95cb80890381c2f8c294d9`.

### BI-1 disposition: candidate fix implemented

`private_channel.lua` now casts the sole variadic `F_SETFL` argument with
`ffi.cast("int", ...)`, requires a zero return code, calls `F_GETFL` again, and
requires the effective flags to contain Linux `O_NONBLOCK`. The module asserts
the reviewed Linux platform before using its Linux constants. Its other
`fcntl` calls have only the two fixed prototype arguments. Python performs no
`fcntl` initialization, and Guile uses Guile's typed syscall binding rather than
LuaJIT FFI; the Guile private-channel owner now also checks the `F_SETFL` return
and reads back effective `O_NONBLOCK`. The accepted Book Session source was not
changed.

New `test-private-channel.lua` runs under the resolved bundle's actual LuaJIT.
It creates a real socketpair, checks an empty `waitEvent()` returns through
`EAGAIN`, reduces the send buffer, and never reads the peer. Repeated maximum
events reach real write-side `EAGAIN` and then queue-full while every call
returns under a five-second watchdog. The test requires 1–8 retained frames,
positive retained bytes no greater than 65,800, atomic queue-full retry, and a
second bounded combined input/output pump.

### BI-2 disposition: candidate fix implemented

`run-tests.sh` now freezes the actual runtime `book-reader/record-exec.sh` at
`fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c`.
Each ordinary language run launches the timeout owner asynchronously and cannot
count unless both the command and timeout PID/start-time records exist,
currently match live processes, and name distinct PIDs. This check occurs while
the real integration is running; final success markers cannot replace it.

The same live-record predicate is applied to an isolated copy whose only
mutation is an interface-compatible no-op `record-exec.sh`. A known local hold
program proves the mutated command really started, both owner records remain
absent, and the predicate returns failure. Exact outer and hold identities are
then terminated and checked for residue. The mutation is therefore red before
cleanup acceptance rather than passing because the wrapped command returned
zero.

### Scope retained

The ordinary Guile and Python books remain unchanged. Python is only a fixture
book language and is not a broker or fallback authority. Navigation and close
still run through real IPC and KOReader. No integration call to
`cancel-request!` was added: cancellation remains explicitly outside this gate
and must not be cited as integrated evidence. No timer, gVisor, sandbox,
durability, device, QEMU, package build, or hardware claim was added.

### Candidate snapshot for focused recheck

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-interaction/integration-host.scm` | `647b741e1eb1afa29622e8ef86306cbb5538e4b76953e3a943d6ae381f240e48` |
| `pinenote/tools/book-interaction/private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `pinenote/tools/book-interaction/test-private-control.scm` | `92b05c739b3c7fe8369552c1e34268c4bc57dbf5f451d0f50d04bcf61b68eb7a` |
| `pinenote/tools/book-interaction/test-private-channel.lua` | `e23fb4022c29fa445f8ab5c75898ad1ba508107319e685632348dcc61ddd1a06` |
| `pinenote/tools/book-interaction/identity-hold.sh` | `bda607a6cc1ee7a2c75a178c485c8ff5799158dd0a24ecaa99d3fd500ea7bf12` |
| `pinenote/tools/book-interaction/fixture-book.scm` | `2f4a9a2bf5484629ee14d3da1654afdd524fdf48497714345a0dea990c0ef55d` |
| `pinenote/tools/book-interaction/fixture_book.py` | `58f1bea1e94b3e80de5c450c9172adc03b8534c95480f516a58608945f657363` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua` | `31197623ee29033fc51ca8698a5b1682e4abdad34f50b6b9d0f1a919de4c643a` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/_meta.lua` | `89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964` |
| `pinenote/tools/book-interaction/run-tests.sh` | `b837f354f88730a9a36fa90d6c2b9145fd3a0d71ae546a0557d41bfb642d1dd9` |
| `pinenote/tools/book-interaction/Makefile` | `7ea12e89eeb8cb1461f57c8754932a2512193d7f01d10d7a91e2f4eec85cb39e` |
| `pinenote/tools/book-interaction/README.md` | `2a397e5b83baf9654d78f7954c456ef832b32dd025efe69d35e01eb93598529a` |

The accepted dependency hashes remain exactly those in the rejected review,
including Book Session
`f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668`,
the Guile codec
`91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44`,
the Python codec
`4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735`,
and blocking adapter
`543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd`.

The pinned check passed 16 Guile private-control assertions, the exact-runtime
empty/never-read Lua socket regression, owner-loss cleanup, the no-op recorder
negative, and both actual KOReader offscreen interactions (Guile book first,
Python book second). Guile warning compilation, Lua/Python/shell syntax,
line-length, whitespace, and residue checks also passed. These are implementer
results awaiting the requested focused independent recheck; they do not confer
acceptance.

No hardware session is justified by this disposition.

---

## Implementer snapshot refresh after reader/UI fixes — 2026-09-04

This is not an authority re-review and does not extend the independent verdict
above to changed hashes. The authority-report hash immediately before this note
was `e7e2c1ebca28a4822cc3a1b571cdb7a20f3819f4b75c77e32450dc44cd4bb99f`.

The subsequent BIR-2/BIR-3/BIR-5 implementation left the independently accepted
BI-1 mechanism unchanged:

```text
4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832  private_channel.lua
e23fb4022c29fa445f8ab5c75898ad1ba508107319e685632348dcc61ddd1a06  test-private-channel.lua
```

It also left `record-exec.sh`, `timeout-owner.sh`, `process-identity.sh`, and
`identity-hold.sh` at the hashes accepted in the BI-2 recheck. The current full
suite reran the typed-fcntl socket regression, owner-loss cleanup, no-op recorder
negative, and live identity requirements successfully.

Reader/UI work did change shared `integration-host.scm`, `run-tests.sh`,
`main.lua`, and `README.md`, and added `ui_audit.lua`. Therefore the earlier
whole-directory authority/process acceptance remains evidence for its exact
recorded snapshot, not automatic acceptance of these new shared-file hashes.
Their current values are:

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-interaction/integration-host.scm` | `72e044abd38b33df81a2eeda9e2316f75479f0943b435cb1c72d25a426f22e0d` |
| `pinenote/tools/book-interaction/run-tests.sh` | `be301fcd9468cf952c2bef076290b60a3fd224582d834538126708b486d3e09e` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua` | `eb15a63999f7c4821d8b8c187fc80fb938ba175ff93430c6721c66d090d29daf` |
| `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/ui_audit.lua` | `ebcfcb14c1f5151b4d23bc820fb16b42db74cd1bf3fa1783cd0c29ebc6d4b7a3` |
| `pinenote/tools/book-interaction/README.md` | `7dd33e7f5847dbf3a483241c7f41303088b1b228c297f9ba76be46d1abd43864` |

No accepted Book Session or Book Protocol file changed. A fresh review of the
reader/UI candidate—and of these altered shared files where scopes overlap—is
still required before claiming acceptance for the current complete snapshot.
