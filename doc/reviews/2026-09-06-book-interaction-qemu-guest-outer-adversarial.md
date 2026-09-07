# Book interaction QEMU guest/outer adversarial review — 2026-09-06

## Verdict

**Block the exact guest/outer packet from joined integration on one finite
completion-handshake defect.** The guest can accept `done` followed by EOF and
emit its UI-EOF/final PASS markers even when its queued `finish` command never
left the process. This contradicts the reviewed `finish -> done -> EOF`
contract. A deterministic nonblocking `EAGAIN` reproduction is below.

Apart from that defect, I found no source blocker in the new guest transport,
fixed Guile routing authority, reader QEMU graph, reader-specific outer wrapper,
console checker, system delta, or inherited process/run-root cleanup. In
particular:

- the UI stream is a separately owned nonblocking `FD_CLOEXEC` character
  device and is neither donated at FD 3 nor added to the OCI bundle;
- private control is strict, bounded, directional, lowercase-hex UTF-8 with
  fixed generation 1 and no language, action, request, surface, endpoint, PID,
  or path identity supplied by Lua;
- trusted Guile selects the fixed Guile-then-Python order, creates the action
  envelope, validates every committed presentation identity, and relays only
  the committed value;
- each book's endpoint, runsc group, captures, cgroup, null-netns state, and
  diagnostic stores are cleaned before the next language marker/book;
- the reader graph is the inherited graph plus exactly one Unix-socket
  chardev, one virtio-serial controller, and one named port, retaining no NIC,
  monitor, host filesystem share, or UI logfile; and
- the reader outer reuses the 1,330-line accepted ownership engine rather than
  copying it, joins exact guest-console and coordinator success, and withholds
  its sole success line until the identity-checked run root is absent.

The outer verdict is additionally **conditional on a separately frozen native
coordinator packet**. The active `qemu-coordinator.scm`, native Lua fixture,
native contract/review, and their pending connect fix were explicitly excluded
from this packet and were not read, hashed, or accepted here. The final outer
source must pin exactly the independently accepted five native source hashes;
if that changes anything beyond those literal roster values, re-review the
outer logic. There is no full-gate acceptance before that exact join.

This is source/host-fixture evidence only. I did not run QEMU, ARM64 code,
gVisor/runsc, a system or image build, an image, or hardware. Actual QEMU
virtio-port enumeration, udev symlink creation, connect timing, character-port
I/O, and disconnect-to-EOF remain unproven runtime facts. This review makes no
touch, navigation, cancellation, durable-state, hostile-native-code, UI
security, sandbox-security, or shipping claim.

## Scope and immutable input packet

The review is bound to
`pinenote/tools/book-execution-spike/build/reader-interaction-guest-outer-frozen-inputs-v1.txt`,
SHA-256
`f08701a58a7c0e83e1c8cd57122b34185fa0c4d7deeaf9d9f5d7080b5dd616e4`.
I independently parsed it as 35 entries, found 35 unique repository-relative
paths, rehashed every file, and found zero mismatches. Its exclusions of the
active coordinator, native fixture, contract/review, and old checker manifest
are real: none appears among the entries.

The exact 35 reviewed identities are:

| SHA-256 | Repository-relative path |
|---|---|
| `ecd170c79cfd2d99cf03dc251f37ecea9ac04c8c3776038f76a996a9ae34e184` | `doc/reviews/2026-09-06-book-interaction-qemu-seam-design.md` |
| `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` | `pinenote/tools/book-session/book-session.scm` |
| `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` | `pinenote/tools/book-protocol/book-protocol.scm` |
| `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` | `pinenote/tools/book-protocol/book-protocol/blocking-io.scm` |
| `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` | `pinenote/tools/book-protocol/book_protocol.py` |
| `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` | `pinenote/tools/book-interaction/private-control.scm` |
| `74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa` | `pinenote/tools/book-execution-spike/guest-smoke.scm` |
| `c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7` | `pinenote/tools/book-execution-spike/oci-book-bundle.scm` |
| `eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d` | `pinenote/tools/book-execution-spike/guest-book-protocol.scm` |
| `9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a` | `pinenote/tools/book-execution-spike/guest-protocol-book.scm` |
| `b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0` | `pinenote/tools/book-execution-spike/guest_protocol_book.py` |
| `81276943c553efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047` | `pinenote/systems/pinenote-book-execution-protocol-control.scm` |
| `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` | `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `8fc1312a3799d75c2aedae3641252c525c2cacf16d708701f1a4f517fe4b6ce3` | `pinenote/tools/book-execution-spike/guest-virtio-book-ui.scm` |
| `c0e21eb976890239e8672fc875003a6ea774e6514223b7272133be2e1d7b8707` | `pinenote/tools/book-execution-spike/guest-book-interaction.scm` |
| `d6db42a7534948746926fef80cd78da51515de7e324fe1aa6b645cf15827d164` | `pinenote/systems/pinenote-book-execution-reader-interaction.scm` |
| `d4de980e35a9385d6cdf1a0634b43f2ae3e84ef5a37cefcdbddd0d962b743927` | `pinenote/tools/book-execution-spike/reader-protocol-console-assertions.scm` |
| `66ab27ed221b34670152c1677676ed45c5dd219b1d553d20b490dfb55131f411` | `pinenote/tools/book-execution-spike/assert-guest-reader-protocol-console.scm` |
| `16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002` | `pinenote/tools/book-execution-spike/reader-qemu-graph.scm` |
| `8344c8bb31a8cf1c6387260fe7eccecd29d425f2aab6838e93da4a22f9011326` | `pinenote/tools/book-execution-spike/disposable-reader-qemu.scm` |
| `fc0f04379d8bc3efe74ff71e76e01f3d9e801940a13372bfdfaef6691a617f25` | `pinenote/tools/book-execution-spike/run-disposable-reader-qemu.scm` |
| `3dd4bc38864acdae99c45f9f10ded33dbbef6f79bc48eb7b2d58c5f88db452a6` | `pinenote/tools/book-execution-spike/test-guest-virtio-book-ui.scm` |
| `2a270117650e6aa0ccff257c5d534d20877bdbc5c597be7deec593c044cbd633` | `pinenote/tools/book-execution-spike/test_book_guest_virtio_ui.py` |
| `d5f6a6c4c2f1a13ba2069fbede808d046ad0457df5d7f47a5803cfab19f04fb9` | `pinenote/tools/book-execution-spike/invoke-guest-book-interaction-test.scm` |
| `f5a4c270fdaad8e393da4a6b743b28997070ae648130377ca46f0afb9847a219` | `pinenote/tools/book-execution-spike/test_book_guest_interaction.py` |
| `d5831a800e04712305fe4eaf845401bcf9d759b889ceac0aab5605e4f37da341` | `pinenote/tools/book-execution-spike/test_book_reader_protocol_console.py` |
| `9eaea3d2579106b5eb3e8c6624f06b752f701586f74e087398b4252267db5249` | `pinenote/tools/book-execution-spike/test-reader-qemu-graph.scm` |
| `74393ee0782d7163c24d52c29a3402d20e8019527d9709883ea41a2e8fe593a8` | `pinenote/tools/book-execution-spike/invoke-disposable-reader-qemu-test.scm` |
| `6130de66cb9dc7d9bec523914863b28be851f516448f869490a9731492715180` | `pinenote/tools/book-execution-spike/test_disposable_reader_qemu.py` |
| `7dbdbfee374925064cd67eb3a202f537736659799d1f597cf24b08af63300859` | `pinenote/tools/book-execution-spike/check-reader-interaction-system.scm` |
| `09fc17349d7bc7e41ea8d4e5be646a66ebde10b49c17f5571ddf2ed18ca078df` | `pinenote/tools/book-execution-spike/check_reader_interaction_prerequisites.py` |
| `46b25361369afc7825c6d7b26d749845b4be170496e7e392a166f6ab9beffb0b` | `pinenote/tools/book-execution-spike/check-reader-interaction-module-view.scm` |
| `8dccc703d89d868ea52389936d8b1002859db359ea499e54fc3296aee021694a` | `pinenote/tools/book-execution-spike/prepare_reader_interaction_module_view.py` |
| `f4f6d9dfea60d6c035d61a6b3651ecf38a68819c4abc67d30bf863348352f91c` | `pinenote/tools/book-execution-spike/test_reader_interaction_module_view.py` |
| `1536a0080a2238d5f3b783652bbd04a17b672cc2e10afb1f68829f0fcbff3708` | `pinenote/tools/book-execution-spike/run-reader-interaction-host-checks.sh` |

The accepted Book Protocol, Book Session, kernel, gVisor package, OCI policy,
fixed books, and predecessor image evidence were not reopened. I inspected only
how the new code uses those accepted boundaries.

## Blocking finding: EOF can erase an unsent `finish`

**Severity: integration-blocking protocol/proof error; not a book-to-host
authority escape.**

`wait-for-ui-completion!` in `guest-book-interaction.scm` does this:

1. queues `finish(1, "")`;
2. calls the generic event waiter for `done(1, "ok")`; and
3. then accepts private-control EOF.

The generic waiter calls `pump-book-ui-output!`, but it does not require the
output queue to drain before reading and accepting an inbound event. On EOF,
`pump-book-ui-input!` calls `invalidate-control!`, which intentionally discards
the bounded output queue. That behavior is correct for loss while work is
pending, but the completion path mistakes the resulting EOF for proof that its
own `finish` was sent.

I reproduced this with the actual production completion function and a real
Unix `socketpair`. The private syscall hook was used only to deterministically model
a legitimate nonblocking `write(2) -> EAGAIN`; no hostile in-process reflection
is part of the threat model:

1. the peer wrote an exact `done|1|6f6b\n`;
2. the peer half-closed only its write direction;
3. every authority write attempt returned `-1, EAGAIN`; and
4. `wait-for-ui-completion!` was called with a one-second deadline.

Observed result:

```text
returned=#t snapshot=((open . #f) (eof . #t) (input-bytes . 0)
                      (queued-frames . 0) (queued-bytes . 0)
                      (read-budget . 4096) (write-budget . 4096)
                      (write-frame-budget . 4))
```

Zero `finish` bytes were written. The queue reached zero only because EOF
invalidation cleared it.

This does not allow the private UI to invent a committed presentation: all four
book results and both language cleanups have already completed before this
function is entered. In the intended joined gate, the outer also separately
requires the pinned coordinator's native-reader lifecycle success line. It
nevertheless invalidates the guest's own final semantic marker and the exact
sequence required by the design review.

### Finite correction and regression

Before accepting `done`, require the queued `finish` frame to reach the
adapter's drained state. An EOF or deadline while `finish` remains queued must
be failure, not successful completion. The minimal regression is the exact
prequeued-`done`, half-close, forced-`EAGAIN` case above; it must not return
success and must emit no guest PASS marker. This does not require adding
navigation, cancellation, a request timer, a new identity field, or a new
transport.

Re-freeze the guest/outer manifest after the correction and rerun the existing
positive fragmented/partial-write case to ensure ordinary short writes still
complete.

## Guest transport source findings

Subject to the completion fix, the transport itself is fit for this finite
trusted UI seam.

### Open and descriptor ownership

`open-book-ui-control!` requires the exact
`/dev/virtio-ports/org.wilkbook.book-interaction` udev symlink, resolves a
character-device target, opens with `O_RDWR|O_NOCTTY|O_NONBLOCK|O_CLOEXEC`, and
checks link identity, resolved target, and opened device identity around the
open. `adopt-book-ui-control-port!` reasserts and then verifies both effective
flags. Errors before publication close the opened port.

Before each runsc launch, the authority compares the UI FD and donated Book
Protocol socket identities and requires the UI FD to remain `FD_CLOEXEC`. The
inherited launch path then closes all descriptors above 3 and requires the exec
shape to be exactly 0,1,2,3, with only the donated Unix stream socket at FD 3.
The independent positive host run observed exactly `[0,1,2,3]` in each fake
runsc process, `fd3_cloexec=false`, and no surviving recorded child identity.
No UI path is present in the unchanged OCI policy.

### Bounded I/O and schema

One input pump makes at most one 4,096-byte read and returns at most one event.
One output pump writes at most 4,096 bytes and finishes at most four frames.
The retained input is bounded by one 8,224-byte line plus one read; an overlong
line fails closed. Output is bounded to eight frames and 65,800 encoded bytes.
Short transfers preserve offsets, while `EINTR` and `EAGAIN` return finite
statuses without losing data.

The codec accepts exactly three fields, direction-allowlisted kinds, canonical
decimal generations 1..1,000,000, lowercase hex, at most 4,096 decoded value
bytes, and strict UTF-8. The guest additionally requires generation exactly 1
and phase-specific exact values. Independent probes rejected leading-zero,
zero, fractional, and out-of-range generations; uppercase hex; an extra field;
a command kind in the event direction; and a hex-decoded invalid UTF-8 byte.
An exact 4,096-byte value encoded, while 4,097 bytes failed.

With a real nonblocking socket, an empty read returned `would-block`; EOF after
an unterminated partial line failed with protocol kind and invalidated the
control. A coalesced complete `ready` plus trailing partial `submit` returned
only `ready`, then rejected the partial at EOF. The independent SRFI-64 adapter
run passed all 22 assertions, including fragmented/coalesced reads, partial
writes, `EINTR`, `EAGAIN`, malformed data, queue bounds, and byte budget.

Closing an invalidated channel leaves final FD close to the enclosing
`dynamic-wind`; no path publishes or donates the UI descriptor to a book.

## Trusted guest authority findings

The authority, not Lua, creates all semantic identity:

- one host object and one endpoint at a time;
- fixed order `guile` then `python`;
- fixed action IDs and strong nonce-bearing input values;
- `host-action!` only after exact `submit` echo;
- Book Protocol request, session, surface, generation, and sequence from the
  returned authority envelope; and
- exact expected transformed text independently computed in Guile.

The private stream carries only kind, generation, and string value. It cannot
name a language, endpoint, action, request, or surface. `present` is queued only
after the accepted Book Session pump commits exactly one value matching the
current session ID, request ID, action ID, surface handle, generation 1,
sequence, and nonce-dependent expected output. A tick may arrive before or
after the book commit, but both are required before relay. `applied` must echo
the exact relayed value before advancing.

EOF from a book is accepted only after the second committed presentation; the
endpoint snapshot must then be closed with zero pending/outbound frames,
sequence 2, and two retained terminal requests. The loop additionally requires
runsc exit 0 and absence of its process group. On any UI/protocol failure the
surface is revoked if still active, endpoint release runs before exact
TERM/KILL/reap and capture finalization, and runtime/cgroup/store cleanup
precedes any success marker. Python starts only after the Guile function has
completed its post-store check and language marker.

The pinned host fixture ran the two real fixed book programs in this route and
passed four distinct nonce values (Latin and Unicode), four exact computed
presentations, four ticks, one done, exact `[0,1,2,3]` child FD shape, and no
guest evidence markers. Independent negative invocations passed for repeated
submit, repeated tick, wrong generation, malformed control, disconnect, and a
crossed Python endpoint forced to the Guile book. Every case returned nonzero,
emitted no host/evidence PASS, and left no child record or launched runtime
state.

The first attempt to run those two guest tests under the ambient Guile 3.0.11
failed during fixture setup because `(json)` was absent from its load path; no
reviewed function ran. Repeating with the already-present pinned
`guile@3.0.9`, `guile-json@4.7.3`, `guile-gcrypt@0.5.0`, and Python shell passed
both negatives in 2.584 seconds and the positive in 0.493 seconds. This was an
environment correction, not an implementation disposition or build.

## Reader graph and outer supervisor findings

`reader-qemu-graph.scm` captures the accepted QEMU argv constructor before the
reader wrapper installs its process-local hook. It preserves that vector
byte-for-byte and inserts only:

```text
-chardev socket,id=bookui0,path=RUN_ROOT/book-ui.sock,server=on,wait=off
-device virtio-serial-pci,id=book-ui-serial
-device virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction
```

The inherited exact `-nic none`, `-monitor none`, no `-netdev`, no `-virtfs`,
no `-fsdev`, private qcow2 overlay, and console chardev remain. The UI chardev
has no logfile. The coordinator receives exactly the generated QEMU vector
without argv zero after its four fixed named options; there is no semantic book
input.

`disposable-reader-qemu.scm` is a 260-line process-local extension over the
unchanged 1,330-line `disposable-qemu.scm`, not a copied ownership engine. It
requires each of its three reader options exactly once, canonicalizes the
coordinator, pins the exact KOReader v2026.03 output, snapshots a fixed
five-file coordinator/plugin roster into a mode-0700 run-root subtree, removes
write bits, and verifies source stability and destination hash. The final
native roster values remain conditional as stated in the verdict.

The wrapper changes only the inherited QEMU argv constructor and completed-log
validator, restoring both through `dynamic-wind`. The accepted guardian makes
the coordinator its one direct child and the process-group leader; descendants
stay in that PGID, and the guardian is a subreaper. It waits/reaps, escalates
TERM then KILL, and only then allows console/coordinator assessment and root
cleanup. The root guardian independently owns the original `(dev,ino)` and
preserves rather than traverses a replacement.

Success requires all of the following:

1. direct coordinator status zero and no surviving same-PGID descendant;
2. exact guest markers, exact two-language diagnostic-store summaries, no
   forbidden failure/overflow/panic fragments, and clean power-down order;
3. exact payload-free coordinator stdout line and no other byte;
4. inherited exact success disposition;
5. identity-safe absence of the original run-root path; and only then
6. the sole joined outer success line.

Independent host negatives passed for guest-checker failure despite exact
coordinator success, coordinator source drift before any child, outer timeout
with TERM-resistant descendants, normal SIGTERM, owner SIGKILL, and foreign
root replacement. The SIGKILL case verified coordinator, fake QEMU, fake
reader, process guardian, root guardian, and owner by PID/start-time, as well as
one shared coordinator-led PGID; all recorded identities and the private root
were gone. The replacement case preserved both the foreign root and renamed
owned tree and emitted no joined PASS. A separate mutation of
`private_channel.lua` (rather than the coordinator file used by the supplied
test) was rejected before any identity record or run-root residue appeared.

These tests use fixed fake coordinator/QEMU/reader processes. They prove the
host ownership algorithm and join behavior, not the excluded real coordinator
or actual QEMU process topology.

## System and derivation-source evidence

The reader OS inherits the accepted protocol-control OS and replaces exactly
the one-shot protocol service plus its source/build manifests. Static checks
show the same kernel object, package list, CONTROL gVisor artifact, filesystems,
kernel arguments, initrd constructor, service count, 45-path sandbox language
profile, and three-package trusted Guile/JSON/gcrypt supervisor profile. The
new service requires `user-processes` and `udev` and adds only the private
control and two guest adapter sources to its trusted source closure.

Independent direct checks found:

```text
kernel config SHA-256: 0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
required config symbols: 8/8 exact
language closure SHA-256: 48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc
language closure: 45 paths, 45 unique
system roster SHA-256: 99066c31e00ac758f63c8d0f6afab147a0ee42753e8f55479332e117ba011e8f
system roster: 341 paths, 341 unique, one eudev 3.2.14
udev rule SHA-256: d24e847307991e0d48febb57ac95ab2878dd65af9a546d07c4793742b81ba21b
exact named virtio-port rule occurrences: 1
```

The saved derivation prerequisite snapshots are sorted and unique: 2,549 paths
for protocol-control and 2,558 for reader-interaction, with exactly 18 removed
and 27 added. Their 45-line `comm -3` snapshot reconstructs exactly. Both have
the sole identical initrd derivation
`/gnu/store/89mdjnh0l5mkbjyv94lid7p4fjb8aw2j-raw-initrd.drv`. These are build-
closure prerequisites only; neither derivation output nor an image was
realized by this review.

Evidence identities read during review:

| SHA-256 | Evidence |
|---|---|
| `5610a22b0c7b847e946e74100f0fa0110decec631dcf013194a063e83a2ac891` | `reader-interaction-host-source-gate-v3.log` |
| `481be816c6d37ebab068e5c459db6cdc4325a6ce6f747ce7f5c92a5e5e9f3314` | `reader-interaction-host-source-gate-v3.command` |
| `5829c034cac108dbd276b4b38cc3417202fb71c2fc96474d57ff26f587de0241` | `reader-interaction-strict-static-v1.log` |
| `f93b764b991f33da3a0606b3e2ee7810752683c93190cc7201cd67ce86e2b188` | `reader-interaction-strict-static-v1.command` |
| `8f93e62de50f1b6ed59dceb5c625cfc7ac56da77fc88528054d19730ebe0fd60` | `reader-interaction-derivation-requisites-check-v1.log` |
| `c9eaf3657dcf36692e1f50525939a21942f515cb4aeb678753643cafcd353066` | `reader-interaction-derivation-requisites-check-v1.command` |
| `968180398f68fe7e5c2b43974c36bece9c8996e887b70d6b1e816ae2f676231b` | `reader-interaction-system-derivations-v1.log` |
| `e3a9b10ca82935ecf4c3adad974180f27e8cf77398bc0ce5bdf78324c96520f9` | protocol derivation prerequisite snapshot |
| `c8f3d8871a3f3adce587eca3924429583ea5760ca6ea86451f56a84aed3ef230` | reader derivation prerequisite snapshot |
| `db62200ce49e2f76b54ae3c69be6d2eef4358d8c4923107878bd94170781b5e7` | exact prerequisite diff |

The implementer host log is green, including 22 adapter assertions, 14 graph
assertions, the guest routing tests, nine reader-outer tests, inherited guardian
and console gates, and module-view checks. That green suite did not contain the
blocking prequeued-`done`/unsent-`finish` case.

## Integration gates remaining

1. Fix and pin the unsent-`finish`/accepted-EOF reproduction, then issue a new
   exact guest/outer frozen manifest.
2. Join the outer's five-file source roster to the separately reviewed frozen
   coordinator/native packet. Do not infer acceptance from the currently
   active file.
3. Run the actual bounded QEMU gate to prove ARM64 virtio-console enumeration,
   udev naming, host connection, four interactions, cleanup, EOF, and joined
   success. This review does not authorize that run.

No other guest/outer source blocker was found. Do not expand the correction
into navigation, cancellation, per-request timers, durable state, generic book
selection, or a security claim.

## Focused finish-delivery re-review — frozen v2 packet

### Superseding verdict

**The sole guest/outer source blocker above is closed in the exact v2 frozen
packet.** The guest/outer source is accepted at this source/host-fixture rung,
conditional only on the later exact join to the separately frozen and accepted
native coordinator/Lua packet. No new guest transport, authority-routing,
descriptor, lifecycle, graph, outer-supervision, or system blocker was found in
the focused delta.

This supersedes the opening v1 blocker verdict only for the identities below;
the original finding and reproduction remain the historical disposition of
v1. The active native coordinator and Lua fixture were still excluded and were
not read, rebound, hashed, or accepted in this re-review. Its separate EINTR
fix cannot enter this verdict implicitly. A future join is acceptable only if
the reader outer pins the exact separately accepted five-file native roster and
does not otherwise change the guest/outer logic reviewed here.

This remains a finite source verdict. I did not run QEMU, runsc/gVisor, ARM
code, an image or system build, a Guix output realization, hardware, SSH,
UART, or a network operation. In particular, the ticket proves the authority's
complete local `write(2)` of one frame; it does not claim that QEMU transported
the bytes, that Lua consumed them, or that a peer event was generated after a
particular physical instant. The trusted private-control peer's exact `done`
semantics and actual virtio runtime remain separate boundaries.

### Snapshot identity and history

The focused packet is
`pinenote/tools/book-execution-spike/build/reader-interaction-finish-delivery-fix-review-packet-v1.txt`,
SHA-256
`0a1313f4ed4bbd65c0e9f18c98adffd07d91ec2f5105100a13a4ad48fa17bc46`.
The replacement roster is
`pinenote/tools/book-execution-spike/build/reader-interaction-guest-outer-frozen-inputs-v2.txt`,
SHA-256
`1cc9a52da080c2ac13bf1fd1431247dd2a4331e0edd8cd15cd87b1947eec54ba`.
I independently parsed 36 entries and 36 unique repository-relative paths,
rehashed every entry, and found zero mismatches. Relative to v1 it has exactly
seven changed identities, one added focused test, and no removed path:

| Status | SHA-256 | Path |
|---|---|---|
| changed | `3b6e8eb172d7e3575c36a95a42d66635c101f7404d2f8028ca0f541dfba66966` | `pinenote/tools/book-execution-spike/guest-virtio-book-ui.scm` |
| changed | `6dc0dfc9b577b3b5b854690879ce02909fc1f85f4b7a776365d8d9dde46e1129` | `pinenote/tools/book-execution-spike/guest-book-interaction.scm` |
| changed | `eba953b32744304221537e2bc1d990c0ad18ca9d56a35afb92b1137acc88f6e8` | `pinenote/systems/pinenote-book-execution-reader-interaction.scm` |
| changed | `50157656251e0dbcd2a4d08865ba422e40f0872f128555092dd2f49c652983fd` | `pinenote/tools/book-execution-spike/test-guest-virtio-book-ui.scm` |
| changed | `56a071c6753793b36baeda0f4d189ac4dee986de64a23f55d93cbfe5a3fa5207` | `pinenote/tools/book-execution-spike/check-reader-interaction-module-view.scm` |
| changed | `40ed66f45406dbe5a066c7ce875c7adaae2e15c64425ca97edf3fd88d2647f72` | `pinenote/tools/book-execution-spike/prepare_reader_interaction_module_view.py` |
| changed | `ad85613bc77f5e834824910b4990f386f3bcc42c6fac11d907c681efedc47829` | `pinenote/tools/book-execution-spike/run-reader-interaction-host-checks.sh` |
| added | `f32eb8039298494257d39e5f33b6bb1b5e1609940f38c001e5d788627ed541bd` | `pinenote/tools/book-execution-spike/test-guest-book-interaction-completion.scm` |

The 35-path v1 roster remains byte-identical at
`f08701a58a7c0e83e1c8cd57122b34185fa0c4d7deeaf9d9f5d7080b5dd616e4`.
Before this appendix, this review remained byte-identical to the fix packet's
accepted-blocker input at
`1f426b81c01729e70e4ed5003ceb0d2d355aed2a1eb5900c182493d3c1052ef1`.
Thus the v1 evidence was preserved rather than relabelled. The v2 roster again
contains neither `pinenote/tools/book-interaction/qemu-coordinator.scm` nor any
native fixture path.

### Source analysis

The adapter adds monotonically increasing `enqueued-frames` and
`delivered-frames` counters to the control owner. Queue admission assigns the
new FIFO ticket only after the existing frame and byte bounds pass. The output
pump increments `delivered-frames` only in the branch where the reported write
offset reaches the exact head frame's bytevector length. It does not increment
on queueing, a positive prefix write, `EAGAIN`, `EINTR`, close, write failure,
or EOF invalidation. EOF still clears retained input, queued frames, and queued
bytes, but deliberately leaves both monotonic counters intact.

`book-ui-command-delivered?` accepts only a positive exact ticket no greater
than the number actually enqueued and compares it to the delivered prefix.
Because completion retains the ticket returned specifically for `finish`, an
empty mutable queue is not proof, nor is successful delivery of a preceding
`input-update` or `present` frame.

The authority now follows this order:

1. queue `finish` and retain its ticket;
2. interleave the existing bounded output and input pumps under the unchanged
   whole-run deadline;
3. reject any event, EOF, close, malformed input, or deadline while that exact
   ticket remains undelivered;
4. only after the ticket is delivered, require exact `done(1, "ok")`; and
5. only after `done`, require transport EOF as before.

The loop remains bounded per turn and does not add retries, acknowledgements,
new wire fields, a per-request timer, or durable state. FIFO completion of the
final `finish` also establishes local full-write completion of every earlier
queued command. The successor system embeds exactly the two corrected source
hashes; the module-view sources only advance that system/source provenance,
and the host runner adds the focused suite in an isolated scratch directory.

### Independent reproductions

I did not rely only on the supplied markers or focused test. An ephemeral
Guile probe used real Unix `socketpair` endpoints and the adapter's private
syscall hook solely to make legitimate nonblocking write outcomes
deterministic. It exercised these distinct cases:

- the original prequeued exact `done` + half-close + perpetual `EAGAIN`
  counterexample now throws; its snapshot remains `enqueued=1`, `delivered=0`,
  `queued=1`;
- prequeued `done` + half-close after a reported two-byte `finish` prefix and
  then `EAGAIN` throws; the finish ticket remains undelivered;
- EOF without `done` while `finish` is wholly unsent throws; invalidation makes
  `queued=0`, but leaves `enqueued=1`, `delivered=0`, and ticket 1 false;
- after an unrelated `input-update` ticket 1 is fully delivered, a blocked
  `finish` ticket 2 still throws on prequeued `done`/EOF, with
  `enqueued=2`, `delivered=1`, `queued=1`;
- a complete `finish` read by a separate peer process followed by that peer's
  fresh exact `done` and EOF succeeds;
- two temporary `EAGAIN` results followed by complete `finish`, fresh `done`,
  and EOF succeeds; and
- a one-byte positive prefix followed by completion of the same `finish`, fresh
  `done`, and EOF succeeds.

The parent closed its duplicate peer endpoint in each positive process test,
so observed EOF came from the peer's actual half-close/close rather than an
accidentally retained writer. These probes produced 12 explicit PASS checks.
They establish that completion keys off full write completion of the exact
finish frame—not generic queue emptiness, any positive write, or a successful
unrelated frame. I found no alternate form of the v1 counterexample.

I also ran only the two modified frozen Scheme suites, not the historical full
stack: the adapter suite passed 24/24 and the focused completion suite passed
8/8. The supplied complete host log,
`reader-interaction-host-source-gate-v5.log`, hashes to
`0e8c33528c952f2bfc3560ab2762aedfcb6b070f2f6d621f89a150fddae5f69c`.
I independently counted its three Scheme totals as 24, 14, and 8 and its
Python `... ok` lines as 54, totaling the claimed 100 checks; its final line is
the finite no-QEMU/runsc/ARM/image PASS. The log is supporting evidence, not a
runtime authorization.

### Remaining join condition

No guest/outer source correction remains from this review. The parent may join
this exact v2 packet only after the separate coordinator review freezes and
accepts its exact source roster. Any guest/outer source change, any outer logic
change beyond rebinding those exact accepted native hashes, or any claim about
actual virtio execution requires evidence outside this focused closure.

## Joined-source binding review — frozen joined v1 packet

### Verdict

**Block the joined-source packet and do not authorize image assembly from it.**
The two prerequisite reviews are accepted and their individual source hashes
are correctly represented, but the production reader outer has not actually
been rebound to the accepted coordinator. It still pins the superseded
coordinator SHA-256 `dc7bb40005ff2e2105cc5e34005851190cc693c5870a12462ef823913147ba7d`,
while the accepted and inventoried coordinator is
`ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde`.

The focused joined host test hides this production mismatch by loading
`invoke-disposable-reader-qemu-test.scm`, which uses `module-set!` to replace
the production source roster with a test-provided roster. The test therefore
genuinely exercises the accepted coordinator and inherited outer lifecycle
logic, but it does **not** prove that the production entry can stage or launch
that coordinator. A direct production-entry reproduction fails before the
QEMU fixture starts.

Review token:

```text
READER_INTERACTION_JOINED_SOURCE_VERDICT=BLOCKED_PRODUCTION_COORDINATOR_HASH_MISMATCH
```

This is one finite join defect, not a reopening of either accepted source
review. The guest/outer v2 behavior and the native coordinator/Lua behavior
remain accepted at their prior scopes. No actual QEMU, runsc/gVisor, ARM code,
Guix output realization, image build or dry-run, hardware, network, SSH, UART,
deployment, or staging operation was performed.

### Frozen inputs verified

The supplied packet and inventory matched their requested identities:

```text
fd1ffb9df24b8e2f26b5463d875a85f7fe923ef39120d47a882afe11fe255b5e  reader-interaction-joined-source-review-packet-v1.txt
2565637e6af78f2700a70004552320131b3eecebcc8d4e1a9c0026a330f6c49e  reader-interaction-joined-source-inventory-v1.txt
```

Before this appendix, the two prerequisite review files matched the accepted
snapshots embedded in the inventory:

```text
3a4c39c3f5fda18be817607d2a75ac83c21fe16bdfeb34a5ae7905bb8ae64221  guest/outer review
5ea9b027fa7027f822ea7227bfde9e90e3d43cf311c44f17f827dd429e1a6863  native coordinator review
```

The guest/outer v2 roster remains byte-identical at
`1cc9a52da080c2ac13bf1fd1431247dd2a4331e0edd8cd15cd87b1947eec54ba`.
I independently parsed the joined inventory as 46 entries and 46 unique
repository-relative paths, rehashed every entry, and found zero file-identity
mismatches. The supplied inventory checker also returns PASS. The defect is not
an inventory hash failure; it is a missing semantic binding between two
individually hash-correct entries.

The machine gate correctly excludes the mutable append-only review files. The
preserved old checker/extractor packet is not a joined source input and presents
no additional source blocker at this rung. Whether the later realized image
uses the exact accepted runtime checker remains a separate brief image-binding
check, not a reason to expand this source review now.

### Concrete production mismatch

The accepted outer source remains:

```text
8344c8bb31a8cf1c6387260fe7eccecd29d425f2aab6838e93da4a22f9011326  disposable-reader-qemu.scm
```

In that exact source, `coordinator-source-sha256` names five files. Four Lua
hashes match the accepted native roster, but its first entry is:

```scheme
("qemu-coordinator.scm"
 . "dc7bb40005ff2e2105cc5e34005851190cc693c5870a12462ef823913147ba7d")
```

`stage-coordinator-sources!` iterates that production list and
`snapshot-one-source!` rejects any source whose SHA-256 differs. The accepted
current `qemu-coordinator.scm` hashes instead to `ca0c552f…`; therefore the
normal `run-disposable-reader-qemu.scm` path deterministically rejects the only
coordinator this joined packet accepts.

The joined test does not use that normal binding. Its command invokes
`test_disposable_reader_qemu_actual_coordinator.py`; that test in turn invokes
`invoke-disposable-reader-qemu-test.scm` and supplies a generated five-entry
roster containing `ca0c552f…`. The invoker validates only roster shape/hash
syntax and then executes:

```scheme
(module-set! (resolve-module '(disposable-reader-qemu))
             'coordinator-source-sha256 roster)
```

That private override is appropriate for the existing fake-coordinator outer
tests. It is not evidence that production imports the accepted coordinator.
The joined inventory checker composes the 36-path v2 roster, the joined test,
and nine native paths, but does not parse or compare the production
`coordinator-source-sha256` value. Consequently its four mutation tests and the
strict static gate can all pass while this exact mismatch remains.

### Independent production-entry reproduction

I reused only the joined test's private host socket fixture and exact pinned
KOReader path, replacing its test invoker with the production
`run-disposable-reader-qemu.scm` entry and removing the test roster argument.
Observed result:

```text
returncode=1
stdout=""
stderr contains "reader coordinator source identity mismatch"
joined success present=false
fake-QEMU evidence created=false
run-root residue=0
```

Thus the source mismatch occurs before the fake QEMU executable is launched;
the accepted coordinator itself is never started. Cleanup still succeeds. This
is a source-binding counterexample, not QEMU or UI runtime evidence.

The supplied joined host log remains useful but narrower than claimed. It
hashes to
`952732ae8cf6067cfa95981d669b9efa5dbb53753fc6f1d986b69b33709a279f`
and records the inventory self-test, nine accepted outer tests, and two tests
using the actual accepted coordinator. Those two establish real host Unix
connection behavior, shared PGID, PID/start-time cleanup, inert-socket outer
removal, exact KOReader pinning, and success/failure joins **under the private
roster override**. They do not establish the production source join.

### Other finite checks

No second blocker was found in the requested launcher/build boundary:

- `reader-coordinator-arguments` supplies exactly four named options followed
  by `--` and the QEMU vector without argv zero. The coordinator independently
  requires that shape and the exact reader graph.
- The coordinator constructs fixed QEMU and KOReader environments. QEMU's exec
  gate permits only stdio; KOReader's permits only stdio plus donated FD 3.
  Both children inherit the coordinator-led outer process group.
- The strict static log hashes to
  `d98b8fdc0ab88e4d45d8fdc98d10d3bfa21bd2747309f55add586c6060fa6e0b`.
  I independently found 20 unique module-view entries, all symlinks resolving
  to the exact hashed original sources, and zero Scheme files in the package
  discovery view. Ambient Guix and Guile discovery variables are cleared and
  cache homes are set to `/nonexistent` by the gate.
- The frozen protocol and reader derivation prerequisite lists are sorted and
  unique at 2,549 and 2,558 paths. Their set delta is exactly 18 removed and 27
  added, and each contains the sole identical
  `/gnu/store/89mdjnh0l5mkbjyv94lid7p4fjb8aw2j-raw-initrd.drv`. The recorded
  reader derivation is
  `/gnu/store/78m4famnsk2abn37996g6533ds28lbwv-system.drv`. The source-only
  minimal-plan checker passed and found no reader-only package, kernel, gVisor,
  compiler, libc, or KOReader build name.
- The guarded recipe hashes to
  `51013e36bb5834968a356b23f18d66a3c4c2f76e3d86e37825896ef29001f9cb`.
  Its authorization check precedes variable mutation, scratch creation, source
  checks, and Guix commands. I independently ran it without authorization: it
  returned exactly 125, emitted only the refusal line, left the dry-run log
  unchanged, and created no scratch root.
- Every possible Guix lowering/build command in that recipe uses
  `--max-jobs=1`, `--cores=2`, `--no-substitutes`, `--no-offload`, the exact
  20-module/zero-package discovery views, and the AArch64 reader system. The
  only realizing command is `guix system image`; there is no Bazel invocation,
  artifact copy, `dd`, deployment, or mutable output staging command. Any image
  result remains a Guix-store output.

These properties make the guarded recipe structurally bounded, but they cannot
authorize it under this packet. Its inventory/static checks share the semantic
join omission, and image assembly does not execute the host production outer,
so a successful image build would not repair or expose the stale coordinator
pin.

### Required finite correction

1. Change only the production `qemu-coordinator.scm` entry in
   `disposable-reader-qemu.scm` from `dc7bb400…` to the accepted
   `ca0c552f…`; retain the four accepted Lua hashes unchanged.
2. Re-freeze the resulting outer identity and joined inventory. The old v2
   roster cannot simultaneously remain the machine identity of a corrected
   outer; use an explicit successor or a narrowly recorded join delta rather
   than rewriting history.
3. Add a source assertion that the production five-entry roster equals the
   accepted native roster. The guarded recipe must invoke a checker containing
   that semantic assertion.
4. Run the two actual-coordinator joined tests through the production entry,
   without `invoke-disposable-reader-qemu-test.scm` or `module-set!`. The
   test-only override may remain for fake-coordinator lifecycle cases.

Because the prior guest/outer acceptance explicitly allowed a later change
limited to rebinding exact accepted native hashes, this needs only a focused
binding recheck. It does not require repeating the native UI fault matrix,
guest routing/cleanup review, or derivation evidence unless another source or
closure identity changes.

## Production-pin correction recheck — joined v2

### Superseding verdict

**The production coordinator-pin blocker is closed.** The exact joined v2
source is accepted as fit for the parent's separately authorized image-assembly
step. The corrected normal production entry binds the already accepted
coordinator and four Lua files without a test roster override; no other core
behavior changed and no new blocker was found in this finite recheck.

Review result:

```text
READER_INTERACTION_JOINED_SOURCE_VERDICT=ACCEPTED_FOR_SEPARATELY_AUTHORIZED_IMAGE_ASSEMBLY
```

This verdict does not itself set the guarded recipe's authorization environment
variable and is not QEMU/runtime authorization. No actual QEMU, runsc/gVisor,
ARM code, image build or dry-run, Guix output realization, hardware, network,
SSH, UART, deployment, or staging operation was performed. The focused host
positive did execute the already accepted packaged KOReader against a Unix-
socket QEMU fixture, as described below.

### Exact corrected snapshot

The packet changed descriptively while this recheck was active. I verified and
record both revisions rather than silently treating them as one:

```text
349e5dedcc2aa945e31a021d28a557bb730921f70bbf4ea2466e5539abb3098b  initially supplied packet v2
5aa21b87da3cac7126f0a7a56ecec56ecbc89ca7c1baec356f7754754819dc37  current packet v2
```

The current revision adds only a 74-line descriptive first-real-QEMU evidence
plan. Removing that inserted section reconstructs the initial packet byte-for-
byte at `349e5ded…`. No source, inventory, test, checker, recipe, or derivation
identity changed with that addition.

The accepted source identities are:

```text
8ae1ec1afd562c1a2f737688b89b0bda396369d2b875b4d0221e7ff83109ccf9  disposable-reader-qemu.scm
b5ff6eabc225a270f017aaa32a74381bfe4f0dac5e51b63e33bc85b274815f33  test_disposable_reader_qemu_actual_coordinator.py
50390fbd40478e5d6fbddfb80f17794fdb715dba6eb57597fc5480771f9c659b  reader-interaction-guest-outer-frozen-inputs-v3.txt
013af480f75b393ebebb077551afdf387b23db9843bbf04bfafec3bed73f3123  reader-interaction-joined-source-inventory-v2.txt
696c3027735b3e04fffbf0bbd093bbcb71be38233f09c0c60b0480c2ed10dfec  check_reader_interaction_joined_inventory_v2.py
3ec15879f008f8e6e34c5f8b293d0a60b8d6afe40805cf79e3ba042112c0f7ed  reader-interaction-next-image-build-v2.command
```

I independently parsed and rehashed all 36 unique v3 roster entries and all 46
unique joined-v2 inventory entries with zero mismatch. Relative to accepted
guest/outer v2, v3 changes exactly one source entry:
`disposable-reader-qemu.scm`, from `8344c8bb…` to `8ae1ec1a…`. The historical
v1, v2, and blocked joined-v1 files remain unchanged at:

```text
f08701a58a7c0e83e1c8cd57122b34185fa0c4d7deeaf9d9f5d7080b5dd616e4  guest/outer v1
1cc9a52da080c2ac13bf1fd1431247dd2a4331e0edd8cd15cd87b1947eec54ba  guest/outer v2
2565637e6af78f2700a70004552320131b3eecebcc8d4e1a9c0026a330f6c49e  joined inventory v1
8eea8caa1f5f8531ca6fc147a9c6dee27bec9fef6c49733491f12e5669f884ae  this review before the present appendix
```

### One-literal source proof and semantic guard

The corrected outer contains accepted coordinator hash
`ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde`
exactly once and contains the superseded `dc7bb400…` hash zero times. Replacing
that one literal in a private byte copy with `dc7bb400…` reconstructs the
blocked outer exactly at SHA-256 `8344c8bb…`. This proves the production source
delta is precisely the authorized one-literal rebind; the other four production
Lua hashes and all behavior are unchanged.

The normal production roster is now exactly, in order:

1. `qemu-coordinator.scm` — `ca0c552f…`;
2. `_meta.lua` — `89a28b0a…`;
3. `main.lua` — `8f58786c…`;
4. `private_channel.lua` — `4d77c191…`; and
5. `ui_audit.lua` — `cfca047a…`.

The flat inventory checker remains a source identity/cardinality gate; it does
not pretend that two separately correct files are semantically joined. The
production-entry test setup and guarded recipe therefore load the normal
`disposable-reader-qemu` module and independently compare its complete ordered
roster to those five accepted values.

I exercised that semantic assertion outside the inventory hash path. The
current production module returned:

```text
status=0  SEMANTIC-PRODUCTION-ROSTER=PASS
```

A private module copy with only the coordinator pin changed back to
`dc7bb400…` returned:

```text
status=1  SEMANTIC-PRODUCTION-ROSTER=REJECT
```

Thus a future stale or unauthorized production pin is detected even if a flat
source inventory were also regenerated to match that changed file.

### Production-entry reproduction

The focused actual-coordinator test now names
`run-disposable-reader-qemu.scm` directly. It contains no `module-set!`, roster
argument, or `invoke-disposable-reader-qemu-test.scm` path. Its setup first
requires the exact production five-source roster above.

I reran only its two focused cases; both passed. I also independently replayed
the exact production-entry shape that exposed the prior mismatch. The corrected
result was:

```text
production entry=run-disposable-reader-qemu.scm
roster override present=false
returncode=0
stdout=exact joined success
stderr empty=true
fake-QEMU evidence created=true
coordinator/QEMU/reader shared PGID=true
run-root residue=0
```

This host-only positive used the accepted `ca0c552f…` coordinator, exact pinned
KOReader v2026.03, and a Unix-socket executable standing in for QEMU. It
completed the four previously accepted real KOReader paint observations. It did
not execute QEMU or guest code.

The paired negative supplied a privately mutated coordinator to the same normal
production entry. Production staging rejected it before the fake-QEMU sentinel
ran, emitted no joined success, and left no tracker or run-root residue. This
closes both sides of the original counterexample: the accepted source now
passes production staging, while a nonaccepted source still fails before child
launch.

The supplied host log hashes to
`c564454619c8a67215a8b5e95c46f2e5feb970d8bf44ec061eb063f6032a4b5e`.
It records the semantic inventory/drift gate, inherited guardian 9/9, and the
same normal-production-entry focused 2/2. I did not rerun the nine already
accepted guardian cases or the broader native UI/codec/namespace matrices.

### Static and guarded-build boundary

The strict-static successor hashes to
`52ce28a1874483cb2aff5dd5616ccab470f60491eed16b1c6c1bb8d9b3135b4a`
and records the joined v2 inventory, unchanged exact 20-module view, zero-Scheme
package-discovery view, local-file provenance, reader system delta, language
closure, kernel prerequisites, and named-port rule as passing. The production
pin is host launcher source outside the guest Guix system, so the accepted
reader system, derivation, 2,549/2,558 prerequisite cardinalities, 18/27 delta,
and shared initrd identities legitimately remain unchanged.

The v2 image recipe's semantic roster assertion occurs before its first Guix
derivation or image operation and offers no test override. Its authorization
check remains first. I independently invoked the exact recipe without the
authorization variable: it returned 125, emitted only the fixed refusal line,
left its dry-run path unchanged, and created no scratch root. The previously
reviewed one-job/two-core, no-substitute, raw-image-only bounds are unchanged.

This source verdict therefore makes the exact joined v2 packet fit for a
separate parent-authorized image assembly. It does not authorize QEMU and makes
no claim about a realized image until the later image-binding check.

### Current descriptive real-run plan

The packet's current-only addition is a plan, not executable source or evidence.
Within that limited status it is consistent with the reviewed boundaries:

- a mode-0700 evidence directory is outside `RUN_BASE`;
- the keeper opens only existing regular log files read-only and holds their FDs
  until the production child and its owned descendants have exited; open read-
  only regular-file FDs do not prevent identity-safe unlink of the run tree;
- the keeper copies evidence only after the production verdict and cannot emit
  or upgrade that verdict;
- the four reported values come from the runtime `reader.log`, must match four
  paired topmost-paint observations in order, and are not host-preselected
  expected-result values;
- raw private-channel bytes are not captured, and the accepted KOReader
  environment still contains no host result oracle; and
- no PNG is promised or manufactured because the accepted fixture has no
  screenshot output and uses the existing packaged `InputDialog` paint path.

No keeper/harvester implementation was supplied or accepted here. Any such
future source, its exact open/identity/bounds behavior, and its binding to the
real image/runtime command require the planned narrow image/runtime review.
The descriptive addition therefore neither expands nor blocks this source
acceptance.
