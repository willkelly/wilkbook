# Book interaction QEMU native seam adversarial review — 2026-09-06

## Disposition

**Do not accept this source snapshot or join it to the guest/outer candidate
yet.** The native UI behavior is independently supported for the exact source
identities below, but the lifetime coordinator does not enforce its claimed
30-second connection bound. A blocking Unix `connect(2)` remained stuck after
32 seconds in a focused reproduction.

There is also a join-time cleanup obligation that this host-only candidate does
not prove: forced QEMU termination leaves the private socket pathname behind.
The design assigns final tree removal to the existing outer run-root guardian,
whose active integration snapshot was deliberately not inspected in this
review. The joined source must demonstrate that identity-checked cleanup before
it can satisfy the design's no-private-socket-tree oracle.

This is a source and host-native verdict only. It is not authorization for an
image build or QEMU run, and it does not reopen the accepted gVisor packaging
boundary.

## Reviewed boundary and identities

The implementation record was fixed at the requested SHA-256:

```text
c83704a1e44a52ff42f65551617da2fd7220a0533cb216a8d5e6d1af486d4bf5  doc/reviews/2026-09-06-book-interaction-qemu-seam-implementation.md
```

The design document reviewed alongside it has SHA-256
`ecd170c79cfd2d99cf03dc251f37ecea9ac04c8c3776038f76a996a9ae34e184`.
The candidate sources were:

| Source | SHA-256 |
|---|---|
| `fixture/bookinteractionprobe.koplugin/main.lua` | `8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125` |
| `fixture/bookinteractionprobe.koplugin/ui_audit.lua` | `cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a` |
| unchanged `fixture/bookinteractionprobe.koplugin/private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| unchanged `private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `qemu-coordinator.scm` | `dc7bb40005ff2e2105cc5e34005851190cc693c5870a12462ef823913147ba7d` |
| `qemu-coordinator-contract.md` | `94bbb0226d9975bd5c5d0066becfe2545d1b717634d6a106e7076e55c142091d` |
| `test-qemu-mode-guest.scm` | `90098c62a7f7559a6907b8fbce2f1dcbf46162761565678f4ca9deaf65d408c1` |
| `run-qemu-mode-tests.sh` | `3b3322adc629a353df0adb6d6d7690004cc66d0e5e9ccf981b95264891b14cab` |
| `Makefile` | `14195c0100c7e1c2ff3ac964359cc4265463bf22f293d6fe8f4029994a8da5a5` |

The complete source-hash record is retained at
`/tmp/opencode/book-interaction-qemu-native-independent-review-20260905/source-hashes.json`,
SHA-256
`c85397edfca31330d2b9a6bc6b19060ce3a8184f034eb3c394c0f06a56ae7b81`.
The pinned native reader was
`/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`.

I reviewed only the reader-owned files named for this review. I did not inspect
or mutate the concurrently changing guest authority, system, or outer
`disposable-qemu.scm` integration.

## Blocking finding: the 30-second bound stops before `connect(2)`

`connect-private-socket!` establishes a deadline at
`qemu-coordinator.scm:672-673`, but that deadline is checked only while the
pathname is absent (`:705-708`). Once a socket pathname exists, the coordinator
creates a blocking `SOCK_STREAM|SOCK_CLOEXEC` socket and calls `connect` at
`:691-699`. It does not use `SOCK_NONBLOCK`, readiness polling, a socket timeout,
or another mechanism that can enforce the existing deadline while that call is
in progress.

This is observable for AF_UNIX streams when a listener's accept backlog is
full. The focused reproduction used:

- a fresh caller-owned mode-0700 run root;
- the candidate coordinator and its exact accepted QEMU argument shape;
- a trusted host fake QEMU that bound the exact `book-ui.sock`, called
  `listen(0)`, filled that one queue slot with its own client, and then stopped
  accepting; and
- the same package-pinned native-reader argument, although the coordinator
  correctly never started KOReader in this case.

After **32.000322 seconds**, the coordinator was still blocked despite its
30-second constant. An external TERM interrupted the call, after which the
coordinator exited 1 and the recorded exact QEMU PID was dead. The exact report
is:

```text
/tmp/opencode/book-interaction-qemu-native-independent-review-20260905/connect-full-backlog-report.json
SHA-256 efb28199f29f58d639897610ff40934f2f958b0a511c672b8acf253812a59fae
```

The one-line post-TERM coordinator diagnostic is retained as
`connect-full-backlog.log`, SHA-256
`df13b5bc76c9931c7e803e779efadde51cf35692643456d81e19e48d4237a31c`.
The external signal was necessary to end the reproduction; it is not evidence
that the internal 30-second deadline worked.

This violates both `qemu-coordinator-contract.md:119-123` and the implementation
record's finite-lifetime claim. The outer 600-second guardian remains valuable,
but it cannot substitute for the coordinator's explicitly specified setup
bound.

### Required correction

Make the single connection attempt itself deadline-aware. A corrected path must
remain nonblocking and finite across `EINTR`, queue pressure, and readiness
completion; verify the completed connection error and the retained pathname
identity; open no readiness-probe connection; and still donate exactly that one
connected peer to KOReader FD 3. Add the full-backlog case as a normal negative
test and require timeout failure, no reader launch, and exact child reap within
the stated bound plus a small scheduler allowance.

## Join-blocking cleanup gap: failure leaves socket pathnames

The coordinator owns and reaps its two direct child identities, but it neither
retains the connected socket's identity for cleanup nor removes the pathname.
That can be correct only if the existing outer run-root guardian performs the
design's final identity-checked tree removal.

The independent host gate retained six socket pathnames after negative cases:

```text
coordinator-signal/book-ui.sock
hardcoded-paint/book-ui.sock
outer-owner-kill/book-ui.sock
reject-malformed-frame/book-ui.sock
reject-wrong-generation/book-ui.sock
reject-wrong-routing/book-ui.sock
```

The blocked-connect reproduction likewise left an exact socket pathname after
TERM/KILL/reap. No recorded child identity remained live in these checks. The
socket inventory is
`retained-failure-sockets.json`, SHA-256
`e4ad04ba131fe891e5d2cfd1fab1667bc779d87f48531ae229c537506ce17cc9`.

The test script's eventual `rm -rf` when evidence retention is disabled is not
the reviewed production root guardian. Before a joined source acceptance, bind
the fixed outer guardian and show that, after all owned writers are gone, it
removes the identity-stable run root and these socket entries on normal,
coordinator-signal, resistant-child, and outer-owner-loss paths. If cleanup is
instead added to the coordinator, it must remove only a retained,
identity-verified exact socket and must reject replacement or type drift. I did
not choose between those designs while the outer implementation was active.

## Independently supported native behavior

Subject to the lifetime findings above, the reader half is well supported for
the exact hashes reviewed:

- `BOOK_INTERACTION_QEMU_MODE=1` rejects the old expected-input/result oracle
  variables. Lua has no Guile/Python routing branch and treats all four values
  alike.
- One factory is installed through `addToHighlightDialog`, fetched from the
  actual `ReaderHighlight` registry, and its returned button callback is invoked
  on `nextTick`. This is registered-action fixture automation, not simulated
  touch or a highlight-menu-layout claim.
- The callback opens one editable packaged `InputDialog`. `ready` is sent only
  while that exact dialog is shown topmost.
- Every request must submit its current exact input and run the delayed topmost
  UI task before `present` is accepted. `applied` is queued only after the
  retained wrapper calls the inherited packaged `paintTo`, that method returns,
  and the wrapper observes the exact result text with the same dialog topmost.
- The hardcoded-authority oracle cannot establish semantic acceptance, and a
  hardcoded Lua display mutation cannot forge `applied` for the authority's
  value.
- Normal cleanup closes the dialog, removes and stops the exact source, closes
  FD 3, suppresses a stale callback, and removes the exact public action before
  reader success. The pre-existing close/remove/stop mutations and the new
  action-removal mutation all expose their retained state before quit.
- The private codec and Lua channel are byte-for-byte unchanged. Their existing
  finite framing, nonblocking pump, never-read-peer backpressure, EOF, and
  malformed-input checks remain separate from this four-presentation fixture.

The independent `run-qemu-mode-tests.sh` invocation passed against real pinned
KOReader with four distinct nonce-bearing Latin/Unicode presentations, frame
generation/routing/EOF mutations, hardcoded-result controls, graph/path checks,
normal child reap, signal teardown, and modeled outer group teardown. Its log
is `qemu-mode-check-short-root.log`, SHA-256
`c062919c38798f85fb77e0c861540a0d59218ae2129d3766d662cb07d07cad02`.
The positive coordinator/QEMU logs reproduce the implementer's hashes; the
independent reader log differs only in run root and timestamps and is recorded
in `independent-positive-hashes.json`, SHA-256
`f6d16f7e356da82e084be11f15e0e513a7643bbcbc4407c18cd5c92052d07ff9`.

The unchanged native `run-tests.sh` matrix also passed Guile/Python ×
Latin/Unicode update/present/navigation/close behavior. That transcript is
`native-regression-guix-shell.log`, SHA-256
`ff1a688abfe1c2fc3fa9707aef7b64577a67018879017441a3a409356570b5dd`.
The Guix shell dry run completed first with `--no-substitutes`; no package was
compiled.

## Coordinator constraints that did hold

Static review and live checks support these narrower statements:

- parsing admits exactly four named options, once each, then one `--`;
- the accepted argument list is an exact no-defaults, TCG, no-NIC, no-monitor
  graph with one console, one private socket chardev, one virtio-serial
  controller/port, one kernel/initrd, and the fixed two-node overlay shape;
- the outer remains authoritative for the exact append line, image identities,
  QEMU package identity, and final graph check;
- the run root is canonical, caller-owned, mode 0700, and identity-checked
  before connection; the socket must have the exact in-root name, Unix-socket
  type, length, and stable identity;
- QEMU receives only stdio at exec. KOReader receives only stdio and its
  connected peer at FD 3, not the socket pathname, QEMU path, Book endpoint, or
  expected input/result variables. The coordinator closes its copy after
  donation;
- child environments replace rather than extend the ambient environment. The
  sole delegated value is the caller's already-sanitized `PATH`; that outer
  precondition must be checked in the immutable joined snapshot because the
  standalone host transcript intentionally used the reviewer's broad PATH;
- QEMU stdout and stderr use separate parent-drained 4 MiB pipes and QEMU gets
  no capture-oriented `RLIMIT_FSIZE`; KOReader's combined regular-file log has a
  128 KiB file-size limit; and
- direct child PID/start-time records are published before release, the exact
  candidate contains no `setpgid`, and both children inherit the pre-existing
  outer process group. Descendant cleanup is explicitly left to the existing
  outer subreaper/group guardian rather than inferred from a live direct PID.

Focused independent mutations confirmed that a wrong donated FD failed before
success, a reader log stopped exactly at 131072 bytes, a QEMU stream stopped at
4194304 retained bytes and produced the explicit overflow failure, and a
`setpgid` source mutation matched the gate's forbidden-source check. The report
is `focused-mutation-report.json`, SHA-256
`a11f00fd6f4eee5a785b14b185a2626c448876f3a468b36a16a3a4411829a9c5`.

## Acceptance boundary

No QEMU, ARM program, runsc, gVisor runtime, guest image, kernel, Bazel build,
network, mount, SSH, UART, device, or hardware action was used. The host “QEMU”
was only the fixed local Guile Unix-socket test double; Python was only the
independent reviewer oracle. No implementation file was edited, and nothing was
staged, committed, pushed, or submitted.

This review does **not** establish guest named-port discovery, actual virtio
disconnect behavior, Guile/Python execution under gVisor, Book Session routing
or cleanup, clean guest power-down, hostile-book qualification, general output
import, navigation/cancel/timer integration, touch, persistent sessions,
production resource policy, reader integration, or release acceptance. The
accepted reusable gVisor native/AArch64 packages remain accepted only at their
previous packaging/static boundary and were not substituted into this runtime.
V7 was not invoked.

After the blocking connection is fixed and the integrated run-root cleanup is
proven against a fixed guest/outer snapshot, repeat this source review. Only
then can the native seam be accepted pending realized-image review and a
separately authorized one-use QEMU execution.

## Finite connect-fix recheck — 2026-09-06

### Disposition

The original full-backlog blocking-`connect(2)` finding above is **resolved** by
the focused patch, but the resulting native coordinator snapshot is **not yet
accepted for the guest/outer join**. A distinct, narrower EINTR error in the new
peer-verification helper is reproducible against the exact coordinator. Do not
freeze the current coordinator hash for the builder until that error is fixed.

The private socket pathname left after failed setup is not a coordinator
cleanup failure under the clarified contract. The coordinator closes its
undonated client and reaps its children; pathname and run-root removal remain an
explicit condition on the identity-checking outer root guardian at final join.
The separately reported outer cleanup tests were not repeated or treated as
part of this native-source verdict.

### Fixed inputs and patch synthesis

The implementer's fix record matched its requested SHA-256:

```text
0f886b2856fda85e24b9805e64a6c7802530e0022ec564d16bc235daf7bf48a7  doc/reviews/2026-09-06-book-interaction-qemu-connect-fix.md
```

The private packet `/tmp/opencode/bic2.5rNNeb` was mode 0700. Its frozen patch
matched SHA-256
`50522d4aa65351943bcbdbc4d456cd5ff69a48c550792132296225cb8d112267`.
I independently applied that patch to the preserved exact blocked coordinator
`dc7bb40005ff2e2105cc5e34005851190cc693c5870a12462ef823913147ba7d`;
it applied without offset or fuzz and produced the byte-identical current
coordinator below.

| Rechecked source | SHA-256 |
|---|---|
| `qemu-coordinator.scm` | `d677d0c0e4d78c68b210789bab18344459e42baaa07b70f85228d6a594dc01d1` |
| `qemu-coordinator-contract.md` | `1dcffa8da3a0dabfffff1694b3159e6748cacb931c807af13e583314e1f1942c` |
| `test-qemu-mode-guest.scm` | `3ef68a844f0517df2ef3a933ae350ffa6f5a10f6482bdafd81a70714f57b427b` |
| `run-qemu-mode-tests.sh` | `d5775b05e50d3be072ce4602188097f1c162c4458a09fd030f36e09a1dd0c14a` |
| `README.md` | `d394e29ceaafea6681426075379988a1ea4573057c9407f0bb6bb6f265b1acde` |

The codec and visible-reader sources retained the hashes recorded earlier:
`private-control.scm` `1304b21d…`, `private_channel.lua` `4d77c191…`,
`main.lua` `8f58786c…`, and `ui_audit.lua` `cfca047a…`.

Patch reconciliation is retained in
`/tmp/opencode/book-interaction-qemu-connect-independent-recheck-20260905/patch-apply-report.txt`,
SHA-256
`64c452688739b209209321ad7e33bf894cfaa4a291a8dbf17eccc5ffcb523173`.

### The original blocked-connect case is corrected

The new client is created once with `SOCK_NONBLOCK|SOCK_CLOEXEC`; those flags
are checked before connection. Publication and every ordinary pending turn
share one monotonic deadline. `EAGAIN`, `EWOULDBLOCK`, `EINPROGRESS`, and
`EALREADY` retry on that same client with a bounded sleep while QEMU captures
and status are serviced. Neither writability nor `SO_ERROR=0` authorizes
donation: an exact AF_UNIX pathname from `getpeername` plus stable socket/root
identities is required.

The complete independent `run-qemu-mode-tests.sh` rerun passed. Its copied
0.25-second deadline faced the exact Linux condition
`EAGAIN; writable; SO_ERROR=0; peer=ENOTCONN` and returned failure in
**0.310231 seconds**. KOReader did not start, no recorded child remained live,
and `/proc/net/unix` retained no open socket for the pathname. The coordinator
correctly left the inert pathname for the outer root guardian. The same run
then passed the four real package-pinned topmost paints and all previously
reviewed native QEMU-mode negatives. Transcript:

```text
/tmp/opencode/book-interaction-qemu-connect-independent-recheck-20260905/qemu-mode-host-gate.log
SHA-256 546df826db03b8cfdb576493dd279657677d28361a2c229f2884512e1f798cfa
```

I also exercised a positive queue-pressure transition absent from the standard
gate. A backlog-zero listener first established the same EAGAIN misleading
state, held it for one second, then accepted and closed its filler. The exact
production coordinator retried its same client, connected, and completed all
four real KOReader presentations at status zero. During the deliberate reader
hold:

- reader FD 3 was `socket:[48405687]` with effective flags `04002`
  (`O_NONBLOCK` set and `FD_CLOEXEC` clear);
- the coordinator retained no Unix socket descriptor; and
- after completion both exact PID/start-time identities were dead, the pathname
  was absent, and `/proc/net/unix` contained no open entry.

The report is `backlog-drain-positive-report.json`, SHA-256
`45712e9f6bc8ffb74f69bc8ad9b22ac8ae29b3ae2e6bd413dd5bbc7c11b6abea`.
This closes the original finite-connect finding without authorizing actual
QEMU.

### New blocking finding: `getpeername` EINTR changes the return type

The new `connected-unix-peer?` at `qemu-coordinator.scm:702-725` binds `peer` to
a caught `getpeername` result. On EINTR, however, its handler recursively calls
the **whole boolean predicate**:

```scheme
((= EINTR (system-error-errno arguments))
 (connected-unix-peer? client path))
```

If the retry succeeds, the inner call validates the vector and returns `#t`.
The outer call then treats that boolean as the raw peer-address vector and
fails with `connected private QEMU peer has an invalid address`. Thus the source
does not implement the contract's claimed EINTR retry even though the
underlying second `getpeername` succeeds with the exact pathname.

This was reproduced against the exact unmodified coordinator with finite
`strace` syscall fault injection. The trace is decisive:

```text
getpeername(...) = -1 EINTR (Interrupted system call) (INJECTED)
getpeername(... AF_UNIX, "/tmp/opencode/bie.tn4h8adv/book-ui.sock") = 0
```

The coordinator nevertheless exited 1 with the invalid-address diagnostic,
never started KOReader, reaped the exact QEMU PID, and left no open Unix FD.
Evidence:

| Evidence | SHA-256 |
|---|---|
| `getpeername-eintr-strace-report.json` | `8ee2ddab02207f8fedddbedd1a98fff593eebde55bfdb2572f72b5bdaf73dce6` |
| `getpeername-eintr-strace.log` | `86c1c2f1a74c054ca94a49f87977ca09bf2071665cb0a6e67cce25fa93139c96` |
| `getpeername-eintr-coordinator.log` | `dd201302f77798acb6970ef326f865ce0f6b127bcb322a06e240ac096ff87df1` |

For distinction, injecting one EINTR into the initial nonblocking `connect`
worked correctly: the coordinator observed `ENOTCONN`, checked `SO_ERROR=0`,
retried the same client, verified the exact peer, completed all four paints,
reaped both children, and exited zero. That report is
`connect-eintr-strace-report.json`, SHA-256
`c190fee583fea5600d0c5cf273ea1097f84c9f02b46f0eb82c18806911a7ceb2`.
The issue is specifically the peer helper's recursive return type, not the
corrected ordinary connect-EINTR state transition.

`socket-pending-error` also recursively retries EINTR without returning to the
deadline-checking loop. Even after correcting the peer return type, both
auxiliary syscall retries must remain governed by the original total deadline;
they must not form an unbounded EINTR-only sub-loop.

### Required correction and remaining boundary

Retry raw `getpeername` without recursively invoking the boolean validator, so
the outer validator always receives either a peer-address vector or the
intentional not-connected result. Route EINTR in both peer and `SO_ERROR`
queries back through a deadline-aware bounded turn. A focused injected-EINTR
test should require the exact second peer lookup above to produce successful
donation, not invalid-address failure, without adding a runtime option or a
general test-injection framework.

After that small correction, rerun the standard full-backlog gate, the draining
backlog positive, and the two distinguished EINTR injections. If they pass and
the source hashes are frozen, this native coordinator can be accepted for the
final guest/outer join, conditionally on that join binding the already reviewed
outer process/root guardians and their exact socket-tree cleanup.

No guest/outer source, actual QEMU, runsc, ARM program, image, package build,
hardware, mount, network, staging, commit, or push was used for this recheck.
The prior failed 32-second reproduction and its evidence remain preserved; it
is historical failure evidence for the superseded coordinator, not a failure
of the corrected EAGAIN/full-backlog path.

## Final EINTR-only recheck — 2026-09-06

### Disposition

**Accept the frozen native coordinator source for inclusion in the fixed
guest/outer joined-image candidate.** The `getpeername` boolean-as-address bug
and the unbounded auxiliary EINTR retries identified above are corrected in
coordinator SHA-256
`ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde`.
No further native-coordinator blocker was found in the requested finite delta.

This acceptance is source-specific and join-conditional. It does not accept a
realized image or actual runtime. The joined review must bind the already
reviewed outer process/root guardians and exact socket-tree cleanup, and must
separately accept the guest finish-delivery correction now under parallel
review. The coordinator deliberately continues to leave inert failed-listener
pathnames to the outer run-root guardian; that is its fixed ownership contract,
not a request for new cleanup policy.

### Frozen identities

The EINTR fix record matched its requested identity:

```text
d549a1f4e4154f0bfd7ec76bfa9ebd0de557f603e3d038a7c94e0e747380537d  doc/reviews/2026-09-06-book-interaction-qemu-eintr-fix.md
```

The mode-0700 packet `/tmp/opencode/bie2.WLgj7y` reconciled at:

```text
36082469ea505c330889a8d6ce47af42c30839f9a60220a987f07fb4274c80c5  packet-manifest.json
287f80f6086eb25f10bf2440ab2b4cf94c20a0f3b3a69bde4e4c9c351de6c317  qemu-eintr-fix.patch
```

The incremental patch applied cleanly, without offset or fuzz, to the exact
previously reviewed coordinator
`d677d0c0e4d78c68b210789bab18344459e42baaa07b70f85228d6a594dc01d1`
and produced the byte-identical frozen candidate. Independent patch synthesis
is recorded in `patch-apply-report.txt`, SHA-256
`ae0b0bf0ec10c8054c4f36cab198aade0522962b78c5c4c352af3fa86dcd8709`.

The accepted native join inputs are:

| Source | SHA-256 |
|---|---|
| `qemu-coordinator.scm` | `ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde` |
| `qemu-coordinator-contract.md` | `18adc5dabd5561f723eb80e728730b62997ea5d30094662c46c9b143c5ddbac4` |
| `test-qemu-mode-guest.scm` | `5e2918e2ce38f3d32058230f59f19364dbda71f2da77ca52d4008c242bf3ce74` |
| `run-qemu-mode-tests.sh` | `3142afaec5baf01b5c6a1661cf3790085090d13b518134bce8951b40fc5f216f` |
| `README.md` | `ac5ed5c735efa91c7817e9b12d36f5838f21308a3fc3e6ba55a1db87c53d476d` |
| unchanged `private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| unchanged `fixture/.../private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| unchanged `fixture/.../main.lua` | `8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125` |
| unchanged `fixture/.../ui_audit.lua` | `cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a` |

The incremental patch contains only the coordinator delta. No production fault
injection string, recheck environment variable, timeout option, or CLI option
appears in `qemu-coordinator.scm`; its four-option interface remains exactly
`--run-root`, `--socket`, `--koreader-package`, and `--qemu`. Fault injection
and `BOOK_INTERACTION_QEMU_CONNECT_RECHECK_ONLY` exist only in the host test
runner and copied coordinator sources. The Lua/core hashes above remained
unchanged, and no guest authority, outer runner, or QEMU graph source was part
of the incremental patch.

### Source correction

`fetch-unix-peer` now performs only raw `getpeername` retrieval. It returns the
eventual address vector or the intentional `ENOTCONN` result; the outer
`connected-unix-peer?` validates that result exactly once. Therefore a
successful retry cannot return predicate boolean `#t` to an address-vector
validation frame.

Both raw-peer and `SO_ERROR` EINTR paths invoke `wait-one-turn!` before retry.
That turn runs the original signal, QEMU status, run-root identity, capture, and
monotonic-deadline checks and sleeps for at most 10 ms. Neither helper retains
an EINTR-only recursive path outside the total publication/connection deadline,
and neither busy-spins. The one nonblocking client, exact peer pathname check,
socket/root identity checks, and FD 3 donation boundary are unchanged.

As a control, I independently replayed the exact superseded recursive flow.
One injected EINTR followed by a successful address fetch again made two
`getpeername` calls and failed by treating boolean `#t` as an address. The
preserved replay log is `blocked-boolean-replay.log`, SHA-256
`c49f63946acafad05367bfb03b809b2d2e57e2c26b7e2163591f83e4c789f29b`.
The accepted source has no such whole-predicate recursion.

### Independent focused results

I ran only the requested
`BOOK_INTERACTION_QEMU_CONNECT_RECHECK_ONLY=1` host gate against the
already-present package-pinned KOReader v2026.03; I did not repeat the whole UI
regression. The independent focused transcript passed:

1. the original full-backlog misleading state timed out in **0.313110 s** with
   no false donation or leak;
2. draining that backlog connected the same client and completed four real
   topmost paints;
3. one injected `getpeername` EINTR fetched and validated the real address and
   completed four real topmost paints;
4. repeated `getpeername` EINTR reached the copied total deadline in
   **0.313748 s** without KOReader or a leak;
5. repeated `SO_ERROR` EINTR reached it in **0.313615 s** with the same clean
   result; and
6. a structurally valid wrong AF_UNIX pathname was rejected before KOReader.

The transcript is `focused-connect-recheck.log`, SHA-256
`22413d25e76595988c8baa439c83f84971df76c87d57c31a0d92476d370c6705`.
Independent post-run inspection found all eight exact PID/start-time records
dead, zero open named run sockets in `/proc/net/unix`, and four expected inert
failed-run pathname entries. The audit is `exact-identity-fd-audit.json`,
SHA-256
`73a896a545e72b28f73a94d9214de6a1ce1c56998b41a5eafedbc054d3f5dbbc`.

The independent private evidence root is:

```text
/tmp/opencode/book-interaction-qemu-eintr-independent-recheck-20260905
```

Its manifest SHA-256 is
`e5146fbb065f2e51ead71ec3b9bdebbe1e4f74cbefdb79ade2217a0807f9fda0`.
The packet's separately supplied complete-host-regression transcript remained
hash-authenticated but was not rerun in this EINTR-only review; prior native UI
acceptance and the focused real-paint results above supply the relevant reader
boundary.

No actual QEMU, runsc, ARM execution, image or package build, hardware, mount,
network, guest/outer inspection, implementation edit, staging, commit, or push
was performed. The next valid use of this accepted native source is the fixed
joined-source/image review, not an actual runtime invocation.
