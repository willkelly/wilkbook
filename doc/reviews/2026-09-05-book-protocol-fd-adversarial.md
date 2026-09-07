# Book Protocol FD-donation seam adversarial review — 2026-09-05

## Verdict

**Accept Stage 1 at the exact hashes below as a bounded host-only rehearsal of
the first Book Protocol FD-donation seam.** The fixture establishes the intended
ownership transfer, exact public runsc argument, FD hygiene at the proposed
exec boundary, two independent native protocol exchanges, and bounded owned
child cleanup. Pinned gVisor source supports importing a connected Unix socket
this way without enabling host-filesystem UDS access.

This is not actual runsc execution. It is not a sandbox, ARM64/QEMU evidence,
an OCI-bundle review, output-import acceptance, hostile-book isolation, or a
production lifecycle. No later gate is closed by implication.

There is no Stage 1 blocker. The finite prerequisites for the first actual
guest run are listed below; they are expected missing work, not defects in this
host fixture.

## Scope and threat boundary

Reviewed:

- the new files under
  `pinenote/tools/book-execution-spike/protocol-fixture/`;
- the unchanged accepted Guile Book Session authority and Guile/Python codecs;
- the pinned gVisor `run --pass-fd` path from the public command through Sentry
  FD import;
- the distinction between an explicitly donated connected Unix socket and
  host-filesystem socket access governed by `--host-uds`;
- parent/child endpoint ownership, CLOEXEC transitions, unrelated-FD closure,
  private result transport, process groups, and finite cleanup;
- one happy-path host suite and one temporary deadline/kill failure injection.

Not reviewed or accepted:

- any not-yet-complete actual-guest integration files, image, derivation, or
  realized closure;
- native or AArch64 reusable `gvisor/source` package compilation;
- a new runsc binary, diagnostic Sentry, kernel, QEMU run, or hardware;
- arbitrary books, malicious protocol behavior, production resource ceilings,
  cancellation, per-request timers, durable execution, reader transport,
  general output import, or release acceptance.

The accepted corrected CONTROL functional smoke remains separate and
unchanged. This fixture does not replace or retroactively extend it.

## Exact reviewed snapshot

Repository baseline was
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The reviewed files are untracked,
so the baseline does not identify their contents; the hashes do.

### Stage 1 fixture

| File | SHA-256 |
|---|---|
| `protocol-fixture/protocol-host.scm` | `8efd2469b84853d1477e6a21928e3ca55a97decc409c1c1f92c4c0b81c050a0b` |
| `protocol-fixture/fixture-book.scm` | `f08dda9db6c4b0b5ff7579e17a7ba9d3cde6b538f56a1f28ad000781a7ee80a2` |
| `protocol-fixture/fixture_book.py` | `47f0a60052dd95feee4c3078c6e300d62870e20c9e5ea4b73c2113666143afe3` |
| `protocol-fixture/test_protocol_fixture.py` | `fea596135d838460c2dfb665a6f77752fd2a6d384b558c3320555d6955c2c723` |
| `protocol-fixture/check_pinned_gvisor_fd_seam.py` | `1d79ff9ab661a7ab699e22cd1e2de7c02a95028ac6dbef883a322ae17960b4be` |
| `protocol-fixture/Makefile` | `fd8ffed245d6e527213bb3353d441b37a0edcf50f9640756b545f2be9a454e7c` |
| `protocol-fixture/README.md` | `47ec222af598393bd7fdd75685a6b732923385cc9c8fd72b5cd07a677d08fd6a` |

Paths in the table are relative to
`pinenote/tools/book-execution-spike/`.

### Frozen accepted protocol/session inputs

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-session/book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |
| `pinenote/tools/book-protocol/book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| `pinenote/tools/book-protocol/book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| `pinenote/tools/book-protocol/book_protocol.py` | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |

The Book Session authority remains accepted only for the scoped untimed first
`hello` → `initialize` → `action` → `present` interaction described in its own
review. This fixture did not reopen that protocol design.

### Pinned gVisor source seam

The clean checkout was `/tmp/opencode/gvisor-fd2f6b2674` at exact commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, tag identity
`release-20260831.0`.

| Pinned source file | SHA-256 |
|---|---|
| `runsc/cmd/run.go` | `66832e6f90533d94cee4e162e71d0c40aa103fe7be4de92264676c1deaded58a` |
| `runsc/cmd/sandboxsetup/fdmappings.go` | `e135732811633d0be9e92599d48a5ec4cfc1e5c38ae150ed305cd167e4b79b76` |
| `runsc/container/container.go` | `2cd847cc190722fb16ac35d313ee1cb0c12f9f3050d8e36a9580bff9b690efd4` |
| `runsc/sandbox/sandbox.go` | `5bb26b649bbe2bbfd5c61de1cbbadb4eb537ff5d5e6b610bac2e9dd11979198e` |
| `runsc/donation/donation.go` | `e035efc442790a5ebf74fc8f4ad3dc525a746b6862e25e159f72c8160ba84eae` |
| `runsc/cmd/sentry/sentrycmd/boot.go` | `168bd3c5adf5ad9f0126ee96f58acb758a40df62b128b67f207173b3030d8fff` |
| `runsc/boot/loader.go` | `70508976f5b1d52094da8c002dd805fd9f2b8cb02a07ac3037fe8d3b250d7c15` |
| `pkg/sentry/fdimport/fdimport.go` | `51a60b0499417def4820ff8a83c6d64611b5087ce40942880ecce3c25a9cba3c` |
| `pkg/sentry/fsimpl/host/host.go` | `f107c85e3fec48bf09b07bb499309d8f04f01b4a25d8bedcff8b3209871aa3cc` |
| `runsc/config/config.go` | `ad760a4e98f24d6783dc4da72c6c02bd6794f71b8b4dc72ed48267b414e9cf1c` |
| `runsc/fsgofer/lisafs.go` | `5793f2ecdd0807cfb70e9ea7b21d52c4156c9d5a41f2314a535ac04a729c7b60` |
| `g3doc/user_guide/fuse.md` | `35a02bf4059d9559fd1df80b2a688d5abd58ec9f45b04340b8eb0e1d82b9d5e5` |

## Findings

### 1. The public command is exactly the intended seam

At this pin, `runsc/cmd/run.go` registers `pass-fd` on the public `run`
subcommand. `runsc/cmd/sandboxsetup/fdmappings.go` parses `M:N` into distinct
nonnegative host and guest numbers. Therefore the proposed command shape is:

```text
runsc [global flags] run --pass-fd=3:3 --bundle=BUNDLE CONTAINER_ID
```

There is no public `--preserve-fds` command path at this pin. The fixture does
not borrow an OCI/runc convention or widen the runtime policy.

`run.go` uses `os.NewFile` on the inherited host descriptor; importantly, it
does not reopen a path. The file remains keyed by guest FD 3 in `PassFiles`.
The sandbox donation layer supplies only that selected file to the Sentry boot
process and emits the internal `--pass-fd=INTERNAL_FD:3` mapping. The boot
parser and loader preserve guest number 3. `createFDTable` begins with stdio
0–2, adds the one custom mapping at 3, and `fdimport.Import` installs it there.

The outer runsc process closes its owned wrapper after `container.Run`; the
Sentry/import side owns the transferred descriptor. The caller's parent copy
is independently closed by the fixture immediately after successful spawn.

### 2. A connected socket is supported without weakening `host-uds=none`

The donated object's `fstat` type is `S_IFSOCK`. `fdimport.Import` passes it to
`host.NewFD`, whose socket case creates an external Unix endpoint backed by the
already-connected host FD. This is an explicit host-object import, not an
attempt by the sandbox to resolve, open, bind, or connect a filesystem socket.

`HostUDSNone` is consumed by the filesystem gofer. The guarded operations in
`runsc/fsgofer/lisafs.go` are opening a host-filesystem socket and performing
gofer-mediated `connect`/`bind` operations on such paths. They are separate
from `fdimport` and the host-FD filesystem used for an explicit pass-FD.

Consequently all of these flags remain valid together:

```text
--platform=systrap
--network=none
--host-uds=none
--host-fifo=none
--directfs=false
--pass-fd=3:3
```

No `--host-uds=open`, host path mount, networking mode, DirectFS, ptrace, or
compatibility fallback is needed. This conclusion is pinned-source evidence;
the first real runsc execution must still test the behavior end to end.

### 3. Endpoint ownership is singular and explicit

`open-session-endpoint!` creates each `AF_UNIX/SOCK_STREAM` pair with
`SOCK_CLOEXEC`. It makes only the authority side nonblocking and encapsulates
that side in the opaque endpoint binding. The peer returned for donation is a
separate port object.

Both Guile and Python endpoint pairs exist before either fork. Each child
therefore initially inherits its sibling's pair and both authority sockets,
which makes the FD-hygiene check meaningful rather than vacuous. In the child:

1. stdin, stdout, and stderr are replaced with `/dev/null`;
2. only the selected peer is duplicated to host FD 3;
3. CLOEXEC is explicitly cleared on FD 3 for the one exec into runsc;
4. all descriptors above 3 are closed from `/proc/self/fd`;
5. the child verifies no descriptor above 3 remains and verifies FD 3 exists
   and is inheritable;
6. signal dispositions and a minimal environment are installed before exec.

In the parent, `start-peer!` closes its donation object immediately after the
gated child has inherited it and then sets the record field to `#f`. The parent
retains only the authority endpoint. Thus it does not keep an extra copy of a
book peer that could suppress EOF, and neither child keeps its sibling peer or
an authority-side socket.

The strict fake observed exactly `[0, 1, 2, 3]`, verified that FD 3 was a
socket with CLOEXEC clear, and rejected any argument-vector difference before
executing a fixture book. The real Sentry transfer will create internal runtime
descriptors, but pinned source imports only stdio and the requested custom FD
into the initial application table.

### 4. Protocol results do not use stdout, stderr, or a shared channel

The children cannot contribute accepted console evidence: their stdout and
stderr are `/dev/null`. The books contain no result print. The fake's JSON file
is test instrumentation for argv/FD observations and is never read as a book
result.

Only the Guile authority can emit the host PASS marker. It does so only after
each separate endpoint has committed its own exchange and its owned child has
exited zero with no surviving process group. The Guile book requires action
`guile-action` with input `Ada` and presents `Guile book: ADA`. The Python book
requires `python-action` with input `élan λ` and presents
`Python book: ÉLAN Λ`. Those values differ from the host inputs, the two
languages differ from one another, and each book validates its action before
sending its fixed presentation. Swapping or crossing peers cannot satisfy both
authorities.

The accepted Book Session authority additionally binds each pending request to
the endpoint's private binding identity, opaque request ID, action ID, surface
handle, generation, and sequence. This gives the fixture real protocol IPC and
authority comparison; it is not an echo over a fake stdout marker.

### 5. Lifecycle is finite for this host fixture

Each child is held behind a CLOEXEC pipe until the parent has established a
dedicated process group, read its `/proc/PID/stat` start time, atomically
published a mode-0600 PID/start-time/group record, and released the gate.
Guile and Python use separate roots, bundles, IDs, groups, and records.

The protocol scheduler has one 15-second whole-fixture deadline. It creates no
worker thread and does not call `expire-request!`. On unwind, endpoint shutdown
first breaks protocol I/O, then each owned group receives TERM with a two-second
wait and KILL with another two-second wait if needed; the direct child is
reaped and the record removed. The success path independently requires both
children already exited zero and both groups absent before its marker.

The PID/start-time values make ownership publication auditable, but this small
fixture is not the production process guardian: group signalling is not
authorized by re-reading the leader start time on every signal, and the run
directory receives only basic canonical-directory validation. The first guest
integration must retain the accepted private-root identity checks, cgroup
ownership/teardown, runsc state cleanup, and bounded diagnostics from the
corrected CONTROL harness rather than treating this host fixture as a generic
production launcher. That integration requirement does not invalidate the
scoped host result.

The host fixture writes its semantic marker after both process groups disappear
but before `dynamic-wind` releases the two authority endpoints. The committed
test accepts only the process's final zero exit, exact sole stdout line, empty
stderr, and post-return cleanup—not the marker in isolation. The future guest
checker should use the stronger ordering in the finite gate below: release the
authority endpoints and complete cgroup/state cleanup before its final PASS.

## Executed evidence

The exact documented command completed successfully:

```text
make -C pinenote/tools/book-execution-spike/protocol-fixture check
```

Observed result:

```text
PASS: pinned gVisor run --pass-fd=HOST_FD:GUEST_FD seam
test_fixture_keeps_policy_and_transport_narrow ... ok
test_frozen_protocol_and_session_inputs ... ok
test_two_native_books_through_strict_fake_runsc_boundary ... ok
Ran 3 tests in 0.119s
OK
```

The test environment resolved Guile 3.0.9 and Python 3.12.12 through the pinned
`channels.scm`; the Makefile also requested guile-json 4.7.3 and guile-gcrypt
0.5.0. The successful authority import and random opaque-ID allocation exercise
the trusted host's gcrypt requirement.

A separate temporary negative used the same Guix environment and unchanged
fixture source. Its two temporary fake children ignored TERM and never spoke the
protocol. The 15-second guard fired; both dedicated groups were escalated to
KILL, reaped, and had their identity records removed. The bounded oracle was:

```text
negative-deadline-kill-cleanup=PASS peers=2
```

No `bookexec-protocol-*` temporary directory or protocol-host child remained.
The negative script lived only in a temporary directory and was deleted; it is
not a new fixture input or a committed test claim.

The three committed tests are intentionally small rather than an adversarial
Book Protocol corpus. Within Stage 1 they directly cover the important boundary
facts: frozen authority inputs, full policy argv, exact inherited FD set and
CLOEXEC state, two real native language peers, distinct endpoint semantics,
child exit, and record cleanup. Existing protocol/session suites remain the
authority for malformed framing and state-machine attacks. Actual sandbox FD
visibility and behavior remain a next-stage proof.

## Finite gate for the first actual guest fixture

Before authorizing one actual runsc/QEMU fixture, a separate focused review must
establish all of the following from new files and immutable outputs:

1. **Frozen CONTROL remains frozen.** Do not edit the accepted
   `oci-bundle.scm` (`a3a4c4e6…`), `guest-smoke.scm` (`74491a0f…`), launcher,
   or corrected image. Derive the protocol fixture in new named files.
2. **Exact runtime remains the accepted CONTROL runtime.** Pin the six-file
   source-built CONTROL artifact and live runsc release. Do not substitute the
   reusable Guix package build, diagnostic Sentry, ptrace, native execution, or
   fallback.
3. **Only the supervisor gets gcrypt.** Add guile-gcrypt 0.5.0 to the trusted
   Guile supervisor profile. Keep the existing sandbox language profile at its
   accepted Guile 3.0.9, guile-json 4.7.3, Python 3.12.12 composition and
   unchanged 45-path closure. Account separately for immutable source outputs.
4. **Bundle exposure is enumerated.** Each root gets only its selected fixed
   entrypoint, required accepted codec files, and the existing language closure,
   all read-only except the already bounded scratch/state surfaces. Do not mount
   the repository, broad `/gnu/store`, sibling book, host socket path, 9p share,
   TCP endpoint, reader-private channel, or console transport.
5. **FD mapping is exact.** Put `BOOK_SESSION_FD=3` in each OCI process and use
   exactly one `run --pass-fd=3:3` per separate container. Preserve Systrap,
   `isolation-userns`, USER_NS, DirectFS false, no network, strict sidecars and
   release enforcement, cgroups, mounts, payload rlimits, and no host-level
   finite `RLIMIT_FSIZE` on runsc or sidecars.
6. **Guest evidence is semantic and private.** Require both distinct protocol
   presentations through their matched authority endpoints. Do not accept
   stdout/stderr, console text from a book, or zero runsc exit as a protocol
   result. Pin initial application FD visibility from source and add a bounded
   guest assertion that FD 3 is the selected socket and no unintended
   application descriptor is exposed.
7. **Cleanup precedes guest PASS.** Close the parent's donated peer after spawn,
   close/release both authority endpoints, reap runsc and all sidecars, delete
   runsc state, and prove both cgroups gone before the final guest marker. Keep
   finite parent-owned stdout/stderr and private debug/panic stores, including
   overflow-fatal behavior and failure evidence before cleanup.
8. **One bounded fixed-fixture comparator.** The first runtime asks only whether
   these two known Guile/Python books complete the scoped untimed exchange under
   the already accepted PineNote test kernel and CONTROL policy. It adds no
   cancellation worker, request timer, durable session, arbitrary book FD,
   persistent framework, reader transport, or production resource-policy gate.

Passing that future run would establish a fixed Book Protocol FD exchange
through actual ARM64 gVisor. It would still not by itself establish hostile-book
security qualification, general output import/persistence, production
resources, cancellation/timer correctness, reader integration, or release
acceptance.

## Review hygiene

This review performed source reads, hashes, the bounded trusted host test suite,
and one bounded trusted-host cleanup negative. It did not edit implementation
or accepted protocol/session source, invoke runsc, build gVisor/Bazel/an image,
run QEMU/ARM code, touch reusable-package caches, or access hardware, SSH,
UART, or a device. Only this review document was added.

## Stage 2 actual-guest source gate — 2026-09-05

### Verdict

**Accept the exact Stage 2 implementation-source snapshot below as the bounded
candidate for the first actual ARM64 gVisor Book Protocol fixture.** No defect
was found in the fixed OCI process objects, FD-3 ownership transfer, private
semantic comparison, or success-after-cleanup ordering.

**Do not invoke the reviewed v1 image-build packet.** Finding S2-1 below is a
concrete integration blocker: the required append to this review changes the
whole-file hash that both the cheap gate and build launcher require to remain at
the Stage 1 value. The implementation snapshot is acceptable; the v1 build
packet is intentionally no longer executable as reviewed. A new, separately
reviewed guard revision must fix that circular review dependency without
changing the accepted implementation hashes. That repair would make this
snapshot eligible for a separately authorized image build; this review grants
no build or runtime authorization.

This remains source, native-host, and non-realizing Guix evidence only. It is
not an image or closure acceptance, actual runsc/Sentry execution, ARM64/QEMU
result, hostile-book qualification, general output import result, production
resource-policy result, reader integration, or release acceptance.

### Exact reviewed snapshot

The repository baseline remains
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The Stage 2 files are untracked,
so their contents are identified by hashes, not by that commit.

The submitted source-review manifest is
`pinenote/tools/book-execution-spike/build/protocol-control-source-review-manifest-v1.txt`,
SHA-256
`65b70b49cb6621e1ce78e30006782209edbe3cda4d8e879cd2628e81dd3d28a8`.
Its `runtime-status` is correctly `not-built-not-run`.

| Stage 2 file | SHA-256 |
|---|---|
| `pinenote/tools/book-execution-spike/oci-book-bundle.scm` | `c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7` |
| `pinenote/tools/book-execution-spike/guest-book-protocol.scm` | `c200b6175bfa571658155ce6556b9e6b57097484a9b249a0c411db1aabbc810f` |
| `pinenote/tools/book-execution-spike/guest-protocol-book.scm` | `9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a` |
| `pinenote/tools/book-execution-spike/guest_protocol_book.py` | `b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0` |
| `pinenote/systems/pinenote-book-execution-protocol-control.scm` | `0191a7936200f465beb9014a1b2a7e7b1796de445a2bc0da68b1fb222fa03ee7` |
| `pinenote/tools/book-execution-spike/check_protocol_guest_inventory.py` | `dd6d1f0612b26805958e5d6189640f2342760f976ced105b09a704a35d5d37f7` |
| `pinenote/tools/book-execution-spike/check-protocol-control-system.scm` | `75e470ebfda31e2e130574dfbcfeaf9ccb08653dfec07a0c3dc62947032a3a5e` |
| `pinenote/tools/book-execution-spike/invoke-oci-book-bundle-test.scm` | `ce37c1fc57392d3daefa9e214d51a10d7918ced5f05884f1cd2ce195cdf9a700` |
| `pinenote/tools/book-execution-spike/invoke-guest-book-protocol-test.scm` | `e7b4baa4da04cd7794f042e22444ba3cf91aa347d016b14c777eaadcfc5651bc` |
| `pinenote/tools/book-execution-spike/test_oci_book_bundle.py` | `244cf3ca0febf78f5bf833c6b08d870f846fed7c3053ee228b0bb5c755103ad4` |
| `pinenote/tools/book-execution-spike/test_guest_book_protocol.py` | `3216ab78dd1570a46982d76ce7fb929f16b5292cd361ed6d0487ce1f61d1588e` |
| `pinenote/tools/book-execution-spike/protocol-console-assertions.scm` | `3c456df71d8630c2c6c992cdf637f796312d34e01b9f4803d63e9513d72e3c68` |
| `pinenote/tools/book-execution-spike/assert-guest-protocol-console.scm` | `2bf46b2825fd3f2ca5ccf9adeed17dc376a69bc16dc54c894f47a41703670ba1` |
| `pinenote/tools/book-execution-spike/test_book_protocol_console.py` | `03b6f43e024fdbccfcafe335296215fc98584b40e41bbccbd04d9c48df6de8c9` |
| `pinenote/tools/book-execution-spike/protocol-guest/Makefile` | `3b663f8e746f6b754902a9d1187cb477a7f9d186bc327bc6e23888a8afb20b95` |
| `pinenote/tools/book-execution-spike/protocol-guest/README.md` | `f666841c8db018e997b52ffa36f4b0efdbea1e61bef422d87bdccdb3e22beb55` |
| `pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v1.command` | `7cfdc65f3e4a9e0c3d27f5d31f470cbe609f8e54a47203b6951bb34d2690fbf1` |

The submitted evidence files were also exact at review time:

| Evidence file | SHA-256 |
|---|---|
| `pinenote/tools/book-execution-spike/build/protocol-control-cheap-gate-v1.log` | `09585ab919f628a4121219a21f99346db8c2b60f3a3aa11e611ef3df1fb6d788` |
| `pinenote/tools/book-execution-spike/build/protocol-control-cheap-gate-v1.exit` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |

The frozen CONTROL, protocol/session, and Stage 1 file hashes in the submitted
manifest were independently rechecked. They remained equal to the accepted
values already recorded above; they are not duplicated into another large
table here.

### S2-1: whole-review hash makes the v1 build packet self-invalidating

`check_protocol_guest_inventory.py` hashes this complete review file and
requires the Stage 1 hash
`ab164146dfe1b769dcb4bfd5dfa8b57c59ab775967d962e565d50b876653cf34`.
The v1 image-build command independently requires the same whole-file hash and
then runs that checker through `make ... check`.

That was a valid pre-review guard: the complete cheap gate passed while this
file still ended at the Stage 1 review. It cannot be a valid post-review image
gate because recording Stage 2 here necessarily changes the file. Merely
updating the launcher's expected hash would not suffice; the inventory checker
would still reject the append.

A direct post-append inventory invocation confirmed the failure mode: every
source, frozen-system, and Stage 1 fixture hash check before it passed, then the
checker exited 1 at exactly `FAIL: accepted Stage-1 review hash`. It did not
reach any Guix, build, or runtime operation.

The finite repair is a new guard revision that pins an immutable Stage 1 review
snapshot or otherwise separates the immutable Stage 1 evidence from this
appendable review record. It must also pin this Stage 2 decision and retain all
existing source, kernel, six-file CONTROL, closure, and authorization guards.
No reviewed implementation hash above needs to change. The repair itself needs
review before an image build. This review does not make or test that repair.

### Fixed OCI and isolation boundary

The two OCI process objects have no arbitrary program, argument, profile, or
runtime selector. The Guile process is fixed to:

```text
/profile/bin/guile --no-auto-compile -L /book/modules /book/entry.scm
```

The Python process is fixed to isolated mode (`python3 -I -B`) and a fixed
`runpy` entry. Both receive only `BOOK_SESSION_FD=3` as protocol authority.
The root is read-only; the payload runs as uid/gid 65534 with no capabilities
and `noNewPrivileges`; payload `RLIMIT_FSIZE` remains 1 MiB. No finite
capture-oriented `RLIMIT_FSIZE` is installed on the trusted supervisor, runsc,
Sentry, gofers, prewarmer, or sidecars.

There are exactly five new per-book source mounts across the fixture: three for
Guile (entry, Guile codec, blocking adapter) and two for Python (entry, Python
codec). Each is a distinct top-level immutable store file mounted read-only,
`nosuid`, `nodev`, and `noexec`. Neither book receives the sibling entrypoint,
the trusted session authority, a repository mount, broad store mount, host 9p,
data partition, socket path, or network transport. The common language closure
is the unchanged accepted 45-path closure.

The generated launch argv is exactly:

```text
runsc [accepted fixed global flags] run --pass-fd=3:3 --bundle=BUNDLE CONTAINER_ID
```

The fixed flags preserve Systrap, `--network=none`, strict sidecar usage and
release enforcement, cgroup enforcement, `--host-uds=none`,
`--host-fifo=none`, emulated-only character devices, exclusive file access,
and `--directfs=false`. No annotation, `--preserve-fds`, ptrace, DirectFS,
native-payload, sidecar, or networking fallback was introduced. Stage 1's
pinned-source trace remains the evidence that this public pass-FD mapping is
accepted by the pinned Sentry FD-import path; Stage 2 does not repeat it with a
runsc invocation.

### FD ownership and private semantic result

Each language gets a fresh connected Unix socket pair from the accepted Book
Session authority. In the forked runsc child, the selected peer is duplicated
to host FD 3, CLOEXEC is cleared only there, and every descriptor above 3 is
closed before exec. The child then verifies the exact `[0,1,2,3]` exec shape
and that FD 3 is a socket. Immediately after spawn, the parent closes its
donation copy, clears that field, verifies that no descriptor with the donated
socket identity remains, and retains only the opaque authority endpoint.

Inside each fixed book, FD 3 must be a connected Unix stream socket with
CLOEXEC clear. The books reject a duplicate of that socket and reject an
unrelated inherited non-CLOEXEC descriptor. They send no self-asserted identity
and have no stdout/stderr result path. `--host-uds=none` remains correct because
the fixture donates an already-connected socket and exposes no filesystem UDS
operation.

The authority generates two fresh strong-random nonce-bearing inputs per
language. The Guile book validates its two fixed action identities and computes
an uppercase result; the Python book validates its different two identities
and computes a reversed result. The authority computes the expected values
independently and accepts only matching `presented-text` objects committed by
the corresponding private endpoint, with exact action ID, surface generation,
sequence, and value. Thus the request value is not itself authority, a fixed
stdout marker cannot satisfy the comparison, and crossing the language
endpoint fails.

### Bounded pump, lifecycle, diagnostics, and PASS ordering

The first fixture has one 360-second whole-fixture deadline shared by the two
sequential books. It adds no cancellation worker, detached thread, per-request
timer, durable session, arbitrary book FD, or persistent framework. The
accepted authority remains an EAGAIN-aware, finite-byte/frame pump; socket I/O
does not occur while its transition locks are held. The fixed blocking book
adapters handle partial frame reads/writes, while all application messages stay
within the accepted protocol bounds.

The corrected Stage 1 ordering caveat is closed in the actual-guest adapter. On
every success or unwind, `dynamic-wind` first releases/closes the authority
endpoint, closes any remaining donation, terminates if necessary and reaps the
exact recorded runsc process group, drains and closes both bounded capture
pipes, and deletes the process identity record. Acceptance then requires runsc
exit zero, no 4 MiB stdout/stderr overflow, no runsc cgroup, an empty runsc state
root followed by its deletion, and no debug/panic tmpfs overflow. The private
debug (4 MiB/10 files) and panic (1 MiB/2 files) stores are observed and their
bounded summaries emitted before verified unmount. Only after the unmount check
may the trusted supervisor emit the language PASS. Both final cgroup checks
precede the sole overall PASS.

Failure handling retains the corrected CONTROL discipline: all owned writers
are stopped before finite stdout/stderr and debug/panic evidence is rendered;
captured bytes are bounded and escaped rather than interpreted as results; any
capture/store overflow is fatal; and cleanup runs before the error is
re-thrown. The console checker requires each marker exactly once and in order,
requires each language's non-overflow store summaries before its PASS, rejects
host-only/frozen-smoke markers and failure/overflow fragments, and has a 16 MiB
input bound. The fixed books therefore cannot forge guest acceptance through a
protocol payload, stdout/stderr, or diagnostic text.

### System/profile and immutable runtime checks

The non-realizing system comparison passed 18 assertions. The protocol system
reuses the exact accepted USER_NS kernel object, operating-system package list,
CONTROL runtime package, filesystems (including cgroup2), kernel arguments, and
initrd. The service count is unchanged: the accepted compatibility smoke is
replaced once by the protocol gate, and only its trusted `/etc` evidence entries
change.

The sandbox language profile remains
`/gnu/store/kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-wilkbook-book-execution-languages`,
with recursive Guix hash
`1lmksjn9k8k5bxpnckh5bdd0wwnz3ab7q7wp4cnk5wmfayp1dwln`. Its closure manifest
remains
`/gnu/store/p05h2hdla9lrg10fynmy4qzwvxjy9zp0-wilkbook-book-execution-language-closure`,
45 paths, SHA-256
`48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc`.
It contains the accepted Guile 3.0.9, guile-json 4.7.3, and Python 3.12.12
profile and does not contain guile-gcrypt.

`guile-gcrypt@0.5.0` is added only to the separate trusted supervisor profile.
The pinned target package resolves to derivation
`/gnu/store/zcrpw642bvjqvd8g14l1s96hz36dwr4h-guile-gcrypt-0.5.0.drv` and the
already-present output
`/gnu/store/jlqv218nq0ylpmhx4f8kjhjkg12p2p2c-guile-gcrypt-0.5.0`, recursive
Guix hash `0az2f385q5j7sk2p3sms9hha32va034m284bi1xfcj8c7h9r41bg`. Its direct
libgcrypt reference is the AArch64 output
`/gnu/store/26mx4fa88p3j56dbqbdfdc5h9ilrs1mk-libgcrypt-1.11.0`. This proves
target resolution and profile separation, not execution of gcrypt on ARM64;
that remains part of the future runtime gate.

The accepted six-file CONTROL directory was independently enumerated and every
file matched the v1 launcher's pinned SHA-256. The accepted kernel `Image`,
`.config`, and PineNote v1.2 DTB likewise matched the three pinned hashes. No
replacement runtime or kernel was built or selected.

### Executed source/host evidence

Before this required append invalidated the whole-review hash guard, the exact
command completed successfully:

```text
make -C pinenote/tools/book-execution-spike/protocol-guest check
```

It rechecked the clean pinned gVisor source seam, all frozen and new source
hashes, then passed 18 native host tests and 18 non-realizing Guix system
assertions. The tests include both real native Guile/Python books through the
strict fake boundary, source/profile rejection, malformed schema, stale
presentation and truncated-frame rejection, crossed endpoints, duplicate
donated socket and unrelated-FD rejection, launch-policy mutation, bounded
capture overflow, TERM-to-KILL deadline cleanup, marker ordering, diagnostic
store bounds, process reaping, identity-record removal, and state-root cleanup.
No host-fake path can emit an actual-guest PASS marker.

The v1 command was syntax-checked and, without its separate authorization
token, refused before any hash check or build with exit 125. It was never run
with the authorization token. No image dry run or image realization was
performed. A target-only `guile-gcrypt@0.5.0` dry-run resolved the derivation
above without realizing or compiling anything.

### Remaining gates

After S2-1 is repaired and separately reviewed, a separately authorized image
build must still produce and inspect a new immutable image, exact system and
image closures, realized supervisor profile, source outputs, OCI process
objects, and QEMU graph. Only after that review may anyone request one bounded
ARM64 QEMU execution. A future runtime PASS must still require the external
console checker, zero outer status, runsc/sidecar reaping, state deletion,
cgroup teardown, and clean power-down.

Even that future fixed-fixture PASS would prove only Book Protocol FD donation
for these two known Guile/Python books through the pinned ARM64 Systrap runtime.
Hostile-book isolation, general output import/persistence, cancellation and
timers, production resources, reader integration, and release acceptance remain
separate open gates.

### Stage 2 review hygiene

This Stage 2 review read and hashed the submitted sources and immutable store
objects, reran the bounded host/static gate, and performed only non-realizing
package inspection. It did not edit any implementation, frozen CONTROL,
protocol/session source, fixture, package source, or build recipe. It did not
invoke runsc, Sentry, QEMU, ARM code, an image build, a kernel build, Bazel,
reusable-package caches, hardware, SSH, UART, mounts, or a device. This append is
the only review edit.

## Stage 2 S2-1 guard repair — 2026-09-05

### Verdict

**S2-1 is closed at the exact hashes below.** The repaired source gate pins the
accepted Stage 1 source roster directly and no longer treats the mutable bytes
of this append-only review as machine authority. A review append remains
allowed; changing a reviewed Stage 1 source remains fatal.

The accepted Stage 2 OCI generator, authority adapter, fixed Guile/Python
books, and protocol-control system are byte-identical to the preceding accepted
snapshot. They were not reopened for implementation review. The v2 launcher is
fit to prepare the separately named protocol-control image with the same
accepted kernel and six-file CONTROL artifact, **but only after a separate
image-build authorization**. This verdict does not authorize runsc, QEMU, ARM
execution, hardware, or any later runtime gate.

### Exact repair snapshot

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-execution-spike/check_protocol_guest_inventory.py` | `4c7af05db1741a760d4a0950a3db7bd31d44f7a792d5eea6b8b5ae80851119fd` |
| `pinenote/tools/book-execution-spike/test_protocol_review_drift_guard.py` | `d75efe5903627d8da5812e099d10865abc26eb942b2c432814764c8108e4eeed` |
| `pinenote/tools/book-execution-spike/protocol-guest/Makefile` | `4ea095d3c52f05198ccf0ab68aa93abb9287e37e7fe0afbaaef2e142164c5e94` |
| `pinenote/tools/book-execution-spike/build/protocol-control-source-review-manifest-v2.txt` | `593a77096fdf8fa2aca1ba326cb46bbf4266fe45d9c4f35b450f96f8131d5da1` |
| `pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v2.command` | `c2e6bd17fecac0314e2514ac504e4d78f8cec639cf8e0f6af5948b937f6d6a10` |

The v2 manifest's 40 path-bearing source, guard, test, documentation, launcher,
and evidence hashes were independently recomputed and all matched. Its
historical Stage 1 review hash is correctly labeled reference-only rather than
an input to the current report or build gate.

The five accepted implementation identities remain exactly:

| Accepted Stage 2 source | SHA-256 |
|---|---|
| `oci-book-bundle.scm` | `c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7` |
| `guest-book-protocol.scm` | `c200b6175bfa571658155ce6556b9e6b57097484a9b249a0c411db1aabbc810f` |
| `guest-protocol-book.scm` | `9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a` |
| `guest_protocol_book.py` | `b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0` |
| `pinenote-book-execution-protocol-control.scm` | `0191a7936200f465beb9014a1b2a7e7b1796de445a2bc0da68b1fb222fa03ee7` |

The blocked v1 records also remain frozen: launcher SHA-256
`7cfdc65f3e4a9e0c3d27f5d31f470cbe609f8e54a47203b6951bb34d2690fbf1`
and manifest SHA-256
`65b70b49cb6621e1ce78e30006782209edbe3cda4d8e879cd2628e81dd3d28a8`.
They remain historical evidence and are not candidates for execution.

### Guard model and mutation checks

The inventory checker now has no review-report path, `STAGE1_REVIEW` binding,
or accepted-review hash. Its executable `main` verifies fixed constants only:

- the exact seven-file accepted Stage 1 fixture roster;
- the six frozen protocol/session and corrected-CONTROL source inputs;
- both frozen base systems;
- the exact ten-source manifest embedded in the accepted Stage 2 system; and
- the already reviewed OCI, authority, FD, isolation, lifecycle, and profile
  invariants.

The roster helper is parameterized only to permit a temporary negative test;
the production path supplies the fixed in-source dictionaries and accepts no
path, hash, program, runtime, profile, or book argument. No new trusted runtime
input or compatibility fallback was introduced.

Two focused regressions passed independently:

1. appending bytes to a temporary copy of this review changes its digest but
   leaves the fixed Stage 1 source-roster verification valid; and
2. appending one mutation to a temporary copy of `protocol-host.scm` while
   retaining its accepted expected digest fails exactly at the Stage 1 roster
   check.

The actual review append was then followed by the complete gate. It passed,
confirming that the real append—not only the synthetic test—no longer
invalidates the source gate. No reviewed source was mutated in place.

### v2 build-launcher boundary

The v1-to-v2 launcher diff removes only the whole-review SHA-256 requirement,
updates its explanatory comment, and changes the future dry-run log suffix from
v1 to v2. It preserves direct hash checks for every frozen protocol/session and
base-system source, all five accepted Stage 2 implementation files, every file
in the accepted six-file CONTROL runtime, the accepted kernel `Image`, config,
and DTB, and the accepted 45-path language-closure manifest. It also preserves
the complete cheap/static gates and the dry-run refusal if Guix would rebuild
the accepted kernel or CONTROL runtime.

The authorization check remains the first effective operation. With the
variable absent, independent syntax/refusal checking exited 125 with the sole
message:

```text
refusing: protocol-control image build is not separately authorized
```

The exact authorization assignment recognized by the reviewed v2 launcher is:

```text
WILKBOOK_PROTOCOL_CONTROL_IMAGE_BUILD_AUTHORIZATION=SOURCE_REVIEW_ACCEPTED_AND_IMAGE_BUILD_SEPARATELY_AUTHORIZED
```

This records the interface for the parent/operator; this review did not set the
variable. No launcher dry-run or command below the authorization guard was
executed.

### Evidence and gate separation

The final v2 cheap-gate evidence is SHA-256
`3bbe42f2a74ac090fd283965bbab19cbf2a4bb121c592fa62ffa53e7fefd6348`
with zero-exit-file SHA-256
`9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa`.
It records the pinned gVisor seam check, the repaired inventory, 2/2 review
drift regressions, 18/18 native host tests, and 18/18 non-realizing Guix system
assertions passing.

The retained first v2 attempt failed before the host and system suites because
`python -m unittest` was given a relative filesystem path as a module name. The
final Makefile invokes the fixed regression script directly; the complete
subsequent gate passed. The retained failure is useful chronology but has no
bearing on the accepted final code or result.

S2-1 repair acceptance remains separate from the next gates. A future image
build must still yield a newly named immutable image and independently reviewed
system/image closures, source outputs, supervisor profile, OCI objects, and
QEMU graph. The reusable source-built gVisor package and its native/AArch64
acceptance remain separate and cannot replace the accepted CONTROL artifact in
this fixture. No runtime authorization follows from image preparation.

### S2-1 review hygiene

This repair review performed source reads, hashes, two bounded mutation tests,
the host/static gate, shell syntax checking, and fail-closed launcher refusal.
It did not alter implementation or guard source, set the image authorization
variable, execute a launcher dry-run, build an image/kernel/runtime, invoke
runsc/Sentry/QEMU/ARM code, access hardware, mount anything, stage, commit, or
push. This review append is the only edit.

## Stage 2 v3 Guix module-discovery repair — 2026-09-05

### Verdict

**Do not authorize an image build with the focused v3 launcher.** The v2
failure is correctly root-caused to broad Guix `-L .` package discovery, and
the v3 split preserves package and `local-file` semantics in a clean caller
environment. Finding V3-1 is a narrow blocker: v3 inherits two other Guix
package-discovery inputs, `GUIX_PACKAGE_PATH` and `GUIX_BUILD_OPTIONS`, either
of which can reintroduce an executable `.scm` tree despite the empty explicit
`-L` view.

The accepted Stage 2 OCI generator, protocol authority, fixed books, system,
kernel, language closure, and six-file CONTROL artifact are unchanged. This
review does not reopen their runtime/session/UI acceptance. It authorizes no
runsc, QEMU, ARM, hardware, or image execution by itself.

### Exact reviewed packet

| File or fixed view | SHA-256 |
|---|---|
| `pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v3.command` | `5f74fbe5da608d5785411232d744e46990aa5fb2c3e9fd657751685d2407fe92` |
| `pinenote/tools/book-execution-spike/build/protocol-control-build-launcher-review-manifest-v3.txt` | `e176f55df6dd74794c6228078321ef8b0c2fbca177af8d43fb7ec0aa07d72940` |
| `pinenote/tools/book-execution-spike/prepare_protocol_control_module_view.py` | `033c21b9641ec255532380cde818ee3c26cfba11f097dc1041bf9262dca6dbdd` |
| `pinenote/tools/book-execution-spike/test_protocol_control_module_view.py` | `7b2a91f7e6be61efad046458a041c4e634577ebacf407842270e1083b196da51` |
| `pinenote/tools/book-execution-spike/check-protocol-control-module-view.scm` | `f23d6da1a8409cc9d63430f2bebf1bc5e4db45973345999e4f36655fd9779dab` |
| `pinenote/tools/book-execution-spike/build/protocol-control-guix-module-view-v1/MODULES.sha256` | `7be619569855efca06393a63f4d93289ef8a40af0987141df8cf22189dd69ee9` |
| `pinenote/tools/book-execution-spike/build/protocol-control-guix-package-view-v1/EMPTY` | `eb6412b8d31a23c092c9fe712f130c3bf72ef0620aec7757b2864c212419a636` |
| `pinenote/tools/book-execution-spike/build/protocol-control-guix-load-path-root-cause-v1.txt` | `572fc7ef5c72231a2f1a0a2b3273ae4d92f8088f5de773d29ecba29ffc56781d` |
| `pinenote/tools/book-execution-spike/build/protocol-control-image-launcher-v2-to-v3-current.diff` | `6f2a0d5ea288dea39b06ba60db860369ecf443cbd65e763caa87f6a1b2134ebd` |

All 37 path-bearing hashes in the v3 manifest were independently recomputed
and matched. The five accepted Stage 2 implementation hashes remain exactly
`c5f73730…`, `c200b617…`, `9d18f28a…`, `b862ec83…`, and `0191a793…` as recorded
in the preceding review. No accepted or historical launcher was modified.

### Root cause in pinned Guix

The failure is a Guix discovery effect, not a Stage 2 runtime defect. In pinned
Guix commit `f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c`, build-command `-L` prepends
its argument to all four of `%package-module-path`, `%patch-path`, `%load-path`,
and `%load-compiled-path`. The exact reviewed source identities are:

| Pinned Guix source | SHA-256 |
|---|---|
| `guix/scripts/build.scm` | `f1e29c338be353c632fea16282bc1cf80f2a4e442b179de3e395a7b4e765c4bf` |
| `guix/discovery.scm` | `9f14b75d448c09d988b1be0a071212eeb2cb82775b82d5f8d45bae886ffdfaed` |
| `gnu/packages.scm` | `6ff0204e66f69469331730bbcb2c64d5a93786bed5b6aaa1d4810362b6923de4` |
| `guix/gexp.scm` | `a0386cc696633abe06a4d7fd19d44bc262d7974323d05fcd74553378a96434fb` |
| `guix/scripts.scm` | `9450f9ee6bd667f5242c022d8c36a8a0499b5e8b48b0dd9ceca11eedafd740a9` |

Adding any `-L` entry makes the package cache non-authoritative. The
`specification->package` lookup for trusted `guile-gcrypt@0.5.0` then reaches
`fold-packages`, whose discovery path recursively enumerates regular and
symlinked `.scm` files and calls `resolve-interface` on each. Therefore v2's
`-L .` legitimately executed generated
`build/diagnostic-realized-profile-bundles/guile/launch.scm` during package
discovery, before any image derivation or realization. The recorded guest-root
preflight failure is the expected side effect of loading that generated
launcher on the host.

Pinned `local-file` is a macro that captures `current-source-directory` where
the form appears. Consequently an indiscriminate copied module tree would alter
relative source authority. That explains the failed first view experiment and
why v3 uses symlinks resolving to the reviewed original module files rather than
copies.

### Split discovery boundary

The module view contains exactly 19 `.scm` symlinks, covering the complete
transitive repository-module set imported by the protocol-control system:

- three `pinenote/images` modules;
- eight `pinenote/packages` modules;
- three `pinenote/services` modules;
- four `pinenote/systems` modules;
- `pinenote/timezone.scm`; and
- no file below `pinenote/tools` or any generated `build` subtree.

The helper pins the SHA-256 of every original module, verifies each expected
`define-module`, verifies that all statically declared local `pinenote` imports
remain inside the 19-file roster, requires every view entry to be a symlink to
the corresponding canonical original, and rejects missing or extra `.scm`
entries. Its CLI is closed to `create`, `create-package-view`, and `check`; no
caller can provide a module, source hash, view path, package, or program.

The separate package-discovery view is a real directory containing only the
fixed regular `EMPTY` marker and zero Scheme files. V3 supplies the 19-module
view only through `GUILE_LOAD_PATH`, explicitly clears caller
`GUILE_LOAD_COMPILED_PATH`, and supplies only the empty view to every Guix
build-command `-L`. Thus the system expression can import the reviewed local
modules, while the explicit `-L` argument cannot recurse through the repository
or module view. That is not yet the complete package-discovery boundary because
the caller environment is inherited, as V3-1 details below. No FHS path,
generated-source substitution, or downloader fallback was added.

The restricted Guix check resolved all **57/57** expected `local-file` objects
to their canonical original paths: ten protocol sources, two inherited fixture
sources, the CONTROL recipe, both six-file CONTROL/diagnostic member sets and
their manifests/locks, fourteen kernel patches, two EBC dump sources, and
twelve WBF sources. This directly checks the semantic risk created by moving
module discovery rather than merely showing that imports succeed.

### Independent counterexample and negatives

An independent temporary sentinel module produced the expected discriminator:

1. a non-realizing `guix ... build --dry-run -L SENTINEL
   guile-gcrypt@0.5.0` executed the sentinel and created its private marker;
2. the actual restricted protocol-control `guix ... system image --dry-run`
   with the sentinel path present only in an unrelated environment variable did
   not execute it; and
3. that restricted dry-run completed with 20 prospective derivations and no
   kernel or gVisor derivation.

The focused helper tests passed 3/3: exact symlink roster, positive empty
package view, and rejection of a temporary mutation to the reviewed
`pinenote/systems/base.scm` source. The helper's own `check` also passed against
the fixed on-disk views. No temporary marker or test directory remained.

This confirms the submitted claim only for a clean caller environment: broad
`-L` really is executable package discovery, while the explicit restricted
path excludes generated code and still fails closed on reviewed source
mutation.

### V3-1: inherited Guix discovery variables bypass the empty view

The v3 command uses `env NAME=value ...`, not `env -i`, so variables it does not
name survive into `guix time-machine` and the selected command. Two pinned Guix
paths are relevant:

- `gnu/packages.scm` reads `GUIX_PACKAGE_PATH`, prepends every entry to
  `%package-module-path`, and also adds those entries to Guile's source and
  compiled load paths; and
- `guix/scripts.scm` parses `GUIX_BUILD_OPTIONS` before explicit command-line
  options. A caller-supplied `-L PATH` performs the same imperative path
  additions as an explicit `-L`. Later explicit options do not remove the
  earlier path because `-L` is cumulative.

Two independent temporary, non-realizing counterexamples used the accepted
module view and explicit empty package view:

1. with `GUIX_PACKAGE_PATH=SENTINEL`, `guix time-machine ... build --dry-run
   -L EMPTY guile-gcrypt@0.5.0` exited zero and wrote
   `AMBIENT-PACKAGE-PATH-EXECUTED`; and
2. with `GUIX_PACKAGE_PATH=` but `GUIX_BUILD_OPTIONS="-L SENTINEL"`, the same
   restricted command exited zero and wrote
   `AMBIENT-BUILD-OPTIONS-EXECUTED`.

Both are host-side source execution before realization. The sentinels and
markers lived in private temporary directories and were removed. This does not
alter or disprove the clean-environment dry-run, 19-module roster, 57
`local-file` results, or accepted Stage 2 runtime source. It does show that the
v3 launcher cannot yet guarantee those inputs when the parent invokes the
recorded authorization interface.

The finite repair is to issue a new launcher revision that explicitly clears
at least `GUIX_PACKAGE_PATH` and `GUIX_BUILD_OPTIONS` for **every** Guix process:
the Guix shell reached through the selected Makefile targets, each direct
`repl`, the mandatory image dry-run, and the eventual image realization. The
focused regression must invoke that exact environment with hostile sentinel
values inherited by the outer caller and prove neither sentinel executes. The
fixed 19-module and empty package views, source hashes, local-file check,
resource flags, kernel/CONTROL refusal, and accepted implementation hashes can
otherwise remain unchanged.

### Static gates and no substantive skip

V2's broad `make ... check` consisted of five Makefile prerequisites. V3 calls
the same unchanged `source-check`, `inventory-check`, `review-drift-check`, and
`host-check` targets, then invokes the exact unchanged
`check-protocol-control-system.scm` separately under the restricted split path
instead of its unsafe broad-`-L` Makefile wrapper. The checker SHA-256 remains
`75e470ebfda31e2e130574dfbcfeaf9ccb08653dfec07a0c3dc62947032a3a5e`.
No assertion is removed.

Submitted evidence records the pinned seam, 54/54 inventory assertions, 2/2
review-drift tests, 18/18 host tests, 18/18 protocol-system assertions, and
17/17 inherited base/source-control assertions passing. The protocol-system
checker was independently rerun through the split path and again passed all
18 assertions. The earlier view-regression failure is retained as useful
history; its copied/symlink source-context problem is fixed in the accepted
original-source symlink design and does not describe the final command.

### Non-realizing image graph and build packet

The submitted restricted dry-run log is SHA-256
`c64501cdc83e4c9987e65ec6253628940b819ebd21296feacfecb747aeb5329b`.
It lists only the 20 expected new protocol source/profile/service/system/image
derivations. It does not list a gVisor or
`linux-pinenote-book-execution-test` derivation, so the accepted kernel and
CONTROL binaries remain inputs rather than rebuilds. The dry-run produced no
image realization. This is valid clean-environment evidence but does not close
V3-1.

The v3 authorization guard remains the first effective operation. Its syntax
check passed, and invocation without authorization exited 125 before module
checks or any dry-run. The exact parent/operator authorization assignment is:

```text
WILKBOOK_PROTOCOL_CONTROL_IMAGE_BUILD_AUTHORIZATION=SOURCE_REVIEW_ACCEPTED_AND_IMAGE_BUILD_SEPARATELY_AUTHORIZED
```

It is recorded for interface audit only and **must not be set for the v3
launcher**. A repaired launcher and focused review are required first.

If that token were set, the reviewed but blocked launcher would perform the
fixed hashes and split-path checks, then execute:

```text
env GUILE_AUTO_COMPILE=0 \
  GUILE_LOAD_PATH=/tmp/opencode/wilkbook-book-computer/pinenote/tools/book-execution-spike/build/protocol-control-guix-module-view-v1 \
  GUILE_LOAD_COMPILED_PATH= \
nice -n 10 guix time-machine -C channels.scm -- system image \
  --no-grafts --no-substitutes --no-offload --cores=2 --max-jobs=1 \
  -t raw-with-offset \
  -L /tmp/opencode/wilkbook-book-computer/pinenote/tools/book-execution-spike/build/protocol-control-guix-package-view-v1 \
  --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-book-execution-protocol-control.scm
```

The absence of `GUIX_PACKAGE_PATH=` and `GUIX_BUILD_OPTIONS=` from this exact
command is the blocker; the same omission exists on the preflight Guix
invocations.

An otherwise identical `--dry-run` is mandatory first, and the launcher refuses
if that log names a gVisor or accepted test-kernel rebuild. The resource bounds,
networkless realization flags, target, image type, channels pin, and accepted
system expression are unchanged from v2.

### Gate separation and review hygiene

After V3-1 is repaired and reviewed, a separately authorized image assembly may
proceed. The new image, realized system/image closures, supervisor profile,
source outputs, OCI process objects, and QEMU graph will still require
independent acceptance before any ARM64 runtime authorization. The reusable
source-built gVisor package remains a separate native/AArch64 workstream and
cannot replace the accepted CONTROL artifact here.

This review performed source/store reads, hashes, helper/unit/static checks,
temporary explicit-`-L`, `GUIX_PACKAGE_PATH`, and `GUIX_BUILD_OPTIONS`
sentinel counterexamples, and restricted non-realizing Guix dry-runs. It did
not modify implementation or old packets, set the image-build token, realize
an image, compile a kernel or gVisor, invoke runsc/QEMU/ARM code, access
hardware, mount, stage, commit, or push. This append is the only edit.

## Stage 2 v4 inherited-Guix-environment closure — 2026-09-05

### Verdict

**Accept v4 at the exact hashes below as the finite repair for V3-1. The v4
launcher is fit for a separately authorized image build.** V3 remains blocked
and must not be used. This acceptance closes only the two inherited discovery
variables identified by the v3 review; it does not reopen the accepted runtime,
protocol, module roster, local-file map, resource policy, or isolation design.

| Reviewed item | SHA-256 |
|---|---|
| `pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v4.command` | `8f90615bc9ce1096c3ef8f18725c45b41c6b921c696b692cc88e7be22f488a1b` |
| `pinenote/tools/book-execution-spike/build/protocol-control-build-launcher-review-manifest-v4.txt` | `a936019b87deedad7599936caf1778672b112008299ffebcb4988ab7c937aef8` |
| `pinenote/tools/book-execution-spike/build/protocol-control-image-launcher-v3-to-v4.diff` | `56d2cbd3c325c87630b8c5a58e156411950417803a5bcc3bbe1dba847018ec3a` |
| `pinenote/tools/book-execution-spike/build/protocol-control-v4-inherited-guix-env-regression-v1.command` | `9bd9c13e6fb0100393b74cac38be3b4f54975f8c5e477cc0f70cf3fadedb8197` |
| `pinenote/tools/book-execution-spike/build/protocol-control-v4-inherited-guix-env-regression-v1.log` | `72c22d68a1b4530a3d3bf51c00cb843a51682b35d6cf189597aeff344c94c529` |

All 39 path-bearing hashes in the v4 manifest were independently recomputed
and matched, including the v3 launcher and manifest, the 19-module roster,
empty package-view marker, unchanged checks, accepted Stage 2 sources, language
closure, submitted regressions, and the pre-v4 review at SHA-256
`d79963e858cb24563895d2e384b1c02f4b29b4bb7e2146e19a7f1c5680549d8e`.

### Exact repair and propagation

Independent comparison of v3 and v4 found exactly two semantic changes:

1. immediately after the authorization guard, v4 adds:

   ```sh
   export GUIX_PACKAGE_PATH= GUIX_BUILD_OPTIONS=
   ```

2. the default non-realizing evidence filename changes from v3 to v4.

The export is line 11, after the guard ends at line 9 and before `cd` or any
other checked operation. It is the only launcher occurrence of either variable.
There is no later assignment, `unset`, command-local override, or Makefile
definition for either name. Shell export therefore carries the empty values to
the nested `make` and its recipe environment as well as every direct child.

The six direct `guix time-machine` invocations occur later at launcher lines
115, 121, 124, 127, 132, and 146. Their command-local `env` assignments set only
the reviewed Guile source/compiled paths, so the two already-exported empty Guix
variables remain present. The `make` invocation at line 118 likewise occurs
after the export; its `host-check` recipe's `guix time-machine ... shell`
inherits both empty variables. The protocol-guest Makefile contains no
assignment that can restore either hostile caller value.

The guard remains the first effective operation. With both hostile variables
set but the authorization variable absent, independent invocation passed shell
syntax checking and exited 125 with only the expected refusal, before the
export or any Guix process.

### Hostile-environment evidence

The submitted finite regression covers the required four cases:

- hostile `GUIX_PACKAGE_PATH` alone;
- hostile `GUIX_BUILD_OPTIONS="-L ..."` alone;
- both values together during actual pinned-Guix protocol image lowering; and
- both values together through `make -> guix time-machine -> shell`, with all
  18 host tests passing.

No package-path or build-options marker exists in the retained evidence. Each
of the three image-lowering logs is byte-identical, with SHA-256
`c64501cdc83e4c9987e65ec6253628940b819ebd21296feacfecb747aeb5329b`.
Each records the same 20 prospective derivations, including the disk image and
excluding both a gVisor derivation and the accepted test-kernel derivation. No
image was realized. The submitted nested-make log is SHA-256
`260409c589661a25837f8098fcf5f9341937d295612aa326e9c2686e7fa0d429`
and records 18/18 tests passing without a sentinel marker.

An independent temporary recheck repeated all three individual/combined image
cases using the export line read from the v4 launcher. Every invocation:

- began with hostile outer values;
- observed both values empty after the v4 export;
- left both sentinel markers absent;
- reproduced the exact `c64501cd…` dry-run hash; and
- listed 20 prospective derivations with no kernel or gVisor rebuild.

The independent combined nested-make case also left both markers absent and
passed 18/18 host tests. Temporary sources and markers were automatically
removed. The positive controls from the v3 review remain the discriminator:
without this clearing, each hostile variable independently executed its
sentinel through pinned Guix discovery.

### Gate separation and authorization handoff

The unchanged recognized assignment is:

```text
WILKBOOK_PROTOCOL_CONTROL_IMAGE_BUILD_AUTHORIZATION=SOURCE_REVIEW_ACCEPTED_AND_IMAGE_BUILD_SEPARATELY_AUTHORIZED
```

This review records that v4 is fit to receive that separate authorization; it
does not itself set the token or execute the launcher. V3 remains prohibited.
After image assembly, the newly named immutable image, system/image closures,
trusted supervisor profile, source outputs, exact OCI objects/mounts, accepted
kernel and CONTROL-artifact reuse, and QEMU graph still require independent
review. No ARM64 runtime, QEMU, runsc, hostile-book, general output-import, or
release acceptance follows from this launcher review.

This narrow recheck performed hashes, launcher/diff inspection, fail-closed
refusal, hostile-environment non-realizing Guix lowering, and the nested host
suite. It did not edit implementation or immutable packets, set the build
authorization, realize an image, compile a kernel or gVisor, invoke
runsc/QEMU/ARM code, access hardware, mount, stage, commit, push, or merge. This
review append is the only edit.

## Stage 2 realized protocol CONTROL image binding — 2026-09-05

### Verdict

**Accept this realized image packet as fit for exactly one separately
authorized, bounded fixed-fixture QEMU run.** The image binds the previously
accepted Stage 2 Guile authority, OCI generator, fixed Guile/Python books,
language closure, USER_NS kernel, and six-file CONTROL artifact. The prepared
launcher selects the protocol semantic checker rather than the historical
language-only smoke checker and preserves the accepted outer-QEMU boundary.

This is a functional Book Protocol FD-donation candidate only. It does not
qualify hostile-book isolation, arbitrary books, general output import or
persistence, cancellation/timers, reader integration, production resource
policy, or release acceptance.

### Exact packet and realized identities

| Item | Identity |
|---|---|
| Image-review manifest | `f10e3d825faf82f6471657c959c6bccee0ea4eca562a952d598cf3d17976593f` |
| Image binding | `d79d0732c2d422a23511f75785a8e8d7a675734617abd38839132e2cdf9b381d` |
| One-run launcher | `c6c7ba0af635f229376bebbb1de1c065d1f9aec84f13c44290c9577b4c4ce16a` |
| System | `/gnu/store/c60jb2p84y40xcag6rhnpzw6hmfa8n6x-system` |
| System recursive Guix hash | `1f6yrlqvvx1ix0yfnhpx9xn26vp8l5sxwm2z1kph6xxps7lw75hd` |
| Image | `/gnu/store/mcqjrwv367vzk3wn0wghvl6n4rfyp5l2-disk-image` |
| Image SHA-256 | `08cfe045cf16f23b09f6bf39dfb46c749917e9506cee1d1e8e3043c78063a012` |
| Image recursive Guix hash | `039gm8c76s38i9jvvw42r1kz0g4f6g1pg8d0qgb4jnp9fli7krsf` |
| Private staged baseline | `31d6e3b6bd174361864e3f3c4a14b5658f2f40bb962f193e86e8ff7ee03df6a7` |
| Kernel Image | `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` |
| Current initrd | `06d641e95e712f1b0c94a660baf66c68f3eebd26743c69837da31f53b7ac3175` |

All 61 path-bearing hashes in
`protocol-control-image-review-manifest-v1.txt` were independently recomputed
before this append and matched. Live Guix queries reproduced the exact sorted
system closure of 341 paths and image closure of 343 paths. The only image-only
requisites are the current extlinux output and disk image. Every requisite is a
`/gnu/store` path.

The v4 log lists 20 prospective derivations and records 19 actual derivation
build announcements. The sole listed derivation without a build announcement
is the already-realized trusted supervisor profile
`/gnu/store/p1jkr08nciklb62gh7n499brnnf3drn3-wilkbook-book-protocol-supervisor.drv`.
No kernel, gVisor, or Bazel derivation was built; the only `Bazel` text in the
log is the accepted CONTROL/diagnostic `MODULE.bazel.lock` source check.

The source image references the selected system. The staged baseline is a
private, regular, single-link copy whose sole transformation is the ext4 label
`Guix_image` to `PNGuixRoot`; kernel, config, DTB, initrd, and generated private
extlinux configuration are separately hash-bound and read-only. The retained
non-mounting inspection passed, and its one `e2fsck -fn` invocation exited zero.
That filesystem check was not repeated during this review.

### Why the initrd identity changed

The current initrd is **not** byte-identical to the corrected functional
CONTROL initrd and is not described as such. The prior accepted object was:

```text
/gnu/store/fvaamiasb4xshvg7sryanz379b87l2dd-raw-initrd/initrd.cpio.gz
sha256=e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c
```

The protocol image uses:

```text
/gnu/store/yr98dpvzs0vidg237042s6hd6rl43d18-raw-initrd/initrd.cpio.gz
sha256=06d641e95e712f1b0c94a660baf66c68f3eebd26743c69837da31f53b7ac3175
```

Their raw-initrd derivations have the same Guile-static-initrd, gzip, Guile,
and module-import inputs. The changed input is the generated `/init` object:
the old derivation used `3spv5301…-init`, while the current one uses
`1v0jyrhk…-init`; the raw-initrd builder identity and output consequently also
change.

An exact comparison of those two generated init scripts found one semantic
difference only: the root filesystem UUID bytevector.

```text
corrected CONTROL: a454a7b0-be49-f492-406f-5fb9a454a7b0
protocol CONTROL:  a454a7b0-be49-f492-ea20-70d9a454a7b0
```

Pinned Guix computes an image root DCE UUID from four little-endian hash words:
filesystem digest, host name, service-type-name list, and filesystem digest.
The words are:

```text
corrected: b0a754a4 92f449be b95f6f40 b0a754a4
protocol:  b0a754a4 92f449be d97020ea b0a754a4
```

Only the service-name word changed. That is the expected consequence of
replacing the corrected CONTROL compatibility-smoke one-shot service with the
fixed `book-execution-protocol-gate`; the host and file-system definitions are
unchanged. During image lowering, Guix replaces the label-based source root
with this deterministic concrete UUID before constructing boot parameters and
the initrd.

Direct read-only ext4 superblock inspection confirmed the same metadata chain:

| Object | Root UUID | Label |
|---|---|---|
| Corrected CONTROL source image | `a454a7b0-be49-f492-406f-5fb9a454a7b0` | `Guix_image` |
| Protocol CONTROL source image | `a454a7b0-be49-f492-ea20-70d9a454a7b0` | `Guix_image` |
| Protocol private baseline | `a454a7b0-be49-f492-ea20-70d9a454a7b0` | `PNGuixRoot` |

The current system `parameters`, source-image extlinux configuration, generated
init script, source ext4 filesystem, and private baseline therefore agree on
the new UUID. The private QEMU extlinux file deliberately selects that same
filesystem by its staged `root=PNGuixRoot` label. The accepted kernel remains
byte-identical; the initrd change is fully accounted for by current reviewed OS
metadata, not an unreviewed boot-code or kernel change.

### Realized Stage 2 runtime binding

The system closure contains all twenty expected protocol/runtime source
outputs, including the exact accepted kernel and CONTROL package, unchanged
45-path sandbox language profile, trusted supervisor profile, trusted module
view, source/build manifests, guest entry point, fixed books/codecs, and source
plus compiled Shepherd gate.

The ten realized Stage 2 source outputs independently matched their accepted
source hashes. The Shepherd configuration loads the compiled protocol gate
exactly once and contains no legacy execution-smoke gate. Its generated source
starts the AArch64 supervisor Guile under `env -i`, with:

- `GUILE_LOAD_PATH` equal to the four-module trusted store view followed by the
  supervisor profile source path;
- `GUILE_LOAD_COMPILED_PATH` equal to the supervisor profile cache;
- the exact immutable profile, 45-path closure, two fixed books, protocol
  codecs, session authority, OCI sources, guest-adapter source and accepted
  adapter hash; and
- expected kernel release `7.1.8`.

The sandbox profile manifest remains exactly Guile 3.0.9, guile-json 4.7.3,
and Python 3.12.12. Its closure remains 45 unique paths with zero gcrypt path.
The trusted supervisor manifest is exactly Guile 3.0.9, guile-json 4.7.3, and
guile-gcrypt 0.5.0. The supervisor's `(gcrypt random)` source and compiled module
both resolve through those declared paths. Its package configuration binds
`%libgcrypt` directly to
`/gnu/store/26mx4fa88p3j56dbqbdfdc5h9ilrs1mk-libgcrypt-1.11.0/lib/libgcrypt`;
that direct library is an AArch64 ELF and is the sole direct reference of the
accepted target guile-gcrypt output. Thus `random-token 12 'strong` is available
to the actual AArch64 authority without exposing gcrypt to either book.

The realized OCI evidence contains exactly two fixed process objects. Each has
45 individual read-only language-store mounts; Guile has three separate
read-only source mounts and Python has two. Both retain read-only rootfs,
non-root UID/GID, empty capabilities, no-new-privileges, isolated network
namespace, 1 MiB payload `RLIMIT_FSIZE`, and no broad store, repository, or host
mount. Their exact launch suffixes are:

```text
run --pass-fd=3:3 --bundle=/run/wilkbook-book-protocol-gate/guile wilkbook-guile-book-protocol
run --pass-fd=3:3 --bundle=/run/wilkbook-book-protocol-gate/python wilkbook-python-book-protocol
```

Both retain Systrap, `isolation-userns`, `directfs=false`, `--network=none`,
`--host-uds=none`, strict sidecar usage/release enforcement, cgroups, and the
accepted remaining runtime flags.

The realized guest authority retains the accepted success ordering. Immediately
after each spawn, the parent closes its donation copy and retains only the
opaque authority endpoint. After validating endpoint-delivered nonce-dependent
computed text, it releases or closes that endpoint, reaps the exact runsc
process group, drains bounded captures, removes the PID record, rejects capture
overflow, removes runsc state, checks cgroup absence, accepts bounded diagnostic
stores, and verifies their unmount before emitting the language PASS. After
both books it checks both cgroups absent before emitting cgroup teardown and
overall protocol PASS. Neither book has a stdout/stderr result path.

The relevant realized profile/module/etc trees contain 208 symlinks and zero
targets in the host worktree. The realized sources, guest entry, generated
service, and source/build manifests contain no
`/tmp/opencode/wilkbook-book-computer` reference. This closes the source-closure
host-leakage check for the bound runtime material.

### One-run launcher and checker

The launcher is mode 0400 and refuses with status 125 before any Guix or QEMU
operation unless separately authorized. Before its sole Guix invocation it
clears `GUIX_PACKAGE_PATH`, `GUIX_BUILD_OPTIONS`, `GUILE_LOAD_PATH`, and
`GUILE_LOAD_COMPILED_PATH`; there is no later override. The in-guest service
executes no Guix command, so the v3 discovery issue has no guest runtime seam.

Before QEMU, the launcher rehashes the image binding, private input manifest,
baseline, kernel/config/DTB/initrd/extlinux files, all accepted host and realized
Stage 2 sources, the 45-path closure file, all six CONTROL binaries, accepted
outer runner, protocol checker, checker bridge, entry point, and channels file.
It creates a private three-module checker view and verifies each copied module.

The accepted outer runner remains byte-identical at SHA-256
`0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca`.
The prepared graph has exactly one QEMU invocation, a 600-second deadline,
`tcg,thread=multi`, CPU `max`, `-nic none`, no host share or 9p, and a private
qcow2 overlay over a newly hash-verified private raw baseline snapshot. Kernel,
initrd, extlinux and baseline hashes are passed explicitly to the outer runner,
which snapshots and rehashes them before QEMU.

The isolated bridge exports the legacy module name required by the unchanged
outer runner but delegates to the accepted protocol semantic checker. That
checker requires the ordered protocol provenance, kernel/network/mount/version,
negative-protocol, per-language Systrap, diagnostic-store, cgroup teardown, and
overall protocol markers; it explicitly forbids legacy smoke/payload success
markers. The bridge separately requires clean kernel power-down. Independent
preflight again accepted the complete protocol chain, rejected a missing clean
power-down marker, and loaded the accepted outer runner through this bridge.

The launcher accepts success only when the outer process exits zero and its
private status file contains exactly this one line:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

It then appends exact run/checker statuses to a mode-0400 private evidence log.

### Authorization handoff and review hygiene

The exact one-run authorization assignment for the parent is:

```text
WILKBOOK_PROTOCOL_CONTROL_QEMU_RUN_AUTHORIZATION=PROTOCOL_CONTROL_IMAGE_ACCEPTED_AND_RUN_SEPARATELY_AUTHORIZED
```

This review establishes fitness for one bounded invocation but does not itself
set or consume that token. The run must remain the fixed Guile/Python protocol
fixture against this exact packet; a diagnostic variant, rerun, changed image,
changed launcher, or different payload requires separate review and explicit
authorization.

This review performed hashes, Guix closure/reference queries, derivation and
generated-source inspection, read-only filesystem-metadata reads, OCI/QEMU graph
checks, checker preflight, and fail-closed launcher refusal. It did not mount or
modify the image, repeat `e2fsck`, edit implementation or immutable packets,
build anything, set the runtime token, invoke QEMU/runsc/ARM code, access
hardware, stage, commit, push, or merge. This review append is the only edit.

## Stage 2 first protocol CONTROL runtime failure attribution — 2026-09-05

### Verdict

**The one authorized protocol CONTROL run failed its functional gate. Do not
rerun it.** The authorization was consumed. A future QEMU/runsc/ARM invocation
requires corrected immutable source evidence, a newly reviewed image/runtime
packet, and separate explicit authorization.

The failure is narrow and occurred after the fixed Guile book completed its
two nonce-dependent Book Protocol exchanges, but before the Guile language PASS
marker and before Python was started. The accepted earlier two-language
compatibility smoke remains valid evidence for its own scope; this protocol
gate is nevertheless a failure and does not inherit that PASS.

This result proves neither hostile-book isolation nor general output import,
persistence, cancellation/timers, production resource policy, reader
integration, or release acceptance.

### Retained run evidence

| Item | Identity/result |
|---|---|
| Runtime evidence | `pinenote/tools/book-execution-spike/build/protocol-control-runtime-evidence-v1.7akVje.log` |
| Runtime evidence SHA-256 | `8f216c5e59512331fad79ecf0532d16134b2722101372c540387770a134f6026` |
| Wrapper log | `/tmp/opencode/wilkbook-qemu-protocol-control-wrapper.rsCItV.log` |
| Wrapper log SHA-256 | `fcaf88c4743d2bdfb6caf61957e26af6121ee0b74f4079b715f6c4e3044fe35c` |
| Exact launcher SHA-256 | `c6c7ba0af635f229376bebbb1de1c065d1f9aec84f13c44290c9577b4c4ce16a` |
| Accepted outer runner SHA-256 | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| Wrapper result | `RUN-STATUS=1 CHECKER-STATUS=1` |

The wrapper first re-accepted the immutable private QEMU inputs and recorded
the evidence path and hash. The guest booted the reviewed system and emitted
the source-provenance, kernel-identity, network-absence, forbidden-mount,
pinned-runsc-version, schema-rejection, stale-rejection, and truncated-close
PASS markers. The fixed Guile runsc process exited zero; its diagnostics report
the cgroup absent and runtime-state root present. The retained gVisor log records
container destruction, sandbox destruction, gofer kill/reap with exit zero,
cgroup deletion, and runsc exit zero. Bounded stdout was empty, diagnostic
stores were within their byte/inode limits, and no capture/store overflow,
panic, `BUG:`, or `Oops:` marker appears.

The authority then emitted exactly:

```text
BOOKEXEC-PROTOCOL-FAIL book-execution-protocol-integration-error ("runtime left state entries for wilkbook-guile-book-protocol")
```

The semantic checker correctly rejected that forbidden failure marker. The
guest still shut down cleanly (`reboot: Power down`), but clean shutdown does
not convert the failed protocol assertion into a PASS.

No Guile, Python, cgroup-teardown, or overall protocol PASS marker was emitted.
The source runs the books sequentially and the Guile exception escapes the
first `run-one-book!`, so Python was not started.

### What the control flow proves before the failure

The frozen realized adapter still has SHA-256
`c200b6175bfa571658155ce6556b9e6b57097484a9b249a0c411db1aabbc810f`.
The observed exception text is emitted only by its
`assert-runtime-state-clean!` at lines 770–782, called at line 924. Reaching
that call proves all preceding checks on this path completed:

1. `run-peer-loop!` returned only after the Guile peer reached `done`, runsc
   exited zero, and its process group ceased to exist.
2. The peer reached `done` only after validating the exact initialize envelope,
   validating both endpoint-delivered `presented-text` values against the
   independently computed strong-nonce actions, and observing EOF after both
   presentations.
3. `assert-closed-session-result!` checked a closed transport, no pending
   requests or outbound frames, sequence 2, and two retained terminal requests.
4. The unwind released/unregistered the authority endpoint, finalized and
   reaped the exact owned runsc group, drained the bounded captures, and removed
   the process-identity record.
5. The post-unwind status and capture checks accepted runsc exit zero and no
   capture overflow before entering the failing runtime-state assertion.

Thus the run is positive, scoped evidence for **Guile ARM64 Systrap FD-3
donation and two fixed Book Protocol presentations**. It is not two-language
protocol success: Python did not run, and cleanup-before-language-PASS failed.
The result path remained the donated private socket; zero-byte runsc stdout is
consistent with that boundary but is not by itself the proof.

### Why the cleanup predicate failed

The frozen predicate is:

```scheme
(unless (and (lstat-or-false state)
             (eq? (stat:type (lstat state)) 'directory)
             (null? (directory-entry-names state)))
  (fail "runtime left state entries for ~a" container-id))
```

Its single message conflates three cases: a missing root, a wrong-type root, or
a non-empty root. The retained failure diagnostic records only
`runtime-state=present`; it does not serialize the root type, entry names,
entry identities, or mount information. The private overlay was correctly
destroyed after the run. Consequently, the exact observed entry cannot now be
measured and must not be presented as a recovered fact.

Pinned gVisor source at commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2` explains the expected lifecycle:

- attached `run` calls `container.Run`, which performs New → Start → Wait and
  defers `Container.Destroy`;
- `StateFile.Destroy` explicitly removes both
  `<container>_sandbox:<sandbox>.state` and `.lock`;
- sandbox destruction explicitly removes `runsc-<sandbox>.sock`;
- the runtime log confirms that destroy path and has no state/control-socket
  deletion warning;
- `--gofer-network-namespace` defaults to `null`, as the retained runtime
  configuration confirms;
- empty `--shared-root` defaults to `--root`; and
- the first gofer creates and bind-mounts an empty network namespace at the
  fixed name `null-netns` under that shared root. Standard `run` container
  destruction does not unmount or remove this shared pin. The dedicated
  `UnmountNullNetNS` helper is used by temporary `runsc do`, tests, and other
  owners that remove an entire shared root, not by ordinary `run` cleanup.

Therefore an inherited `.lock` is **not** the expected survivor. A private
`runsc-state/null-netns` namespace pin is the source-supported explanation for
the non-empty root and is intentionally shared-runtime state rather than live
container metadata. It exactly explains why runsc exited zero and removed its
cgroup while the fixture's stronger empty-directory assertion failed.

This attribution is strong but deliberately bounded: because the retained
diagnostic omitted the roster and the overlay is gone, `null-netns` is the
expected and overwhelmingly likely entry, not a directly observed filename.
The evidence does not justify asserting that no additional entry existed. A
corrected gate must make that distinction observable before cleanup.

### Required narrow correction contract

Do not delete the cleanup gate, accept an arbitrary non-empty directory, or use
recursive deletion. If the corrected fixture retains the pinned `null` gofer
namespace mode, it should:

1. validate and retain the fixture-created `runsc-state` directory's device,
   inode, type, mode, UID, and GID before spawning runsc;
2. pre-create the exact private `null-netns` placeholder, retain its underlying
   identity, and permit no other entry;
3. after endpoint release, exact runsc/process-group reap, bounded-capture
   finalization, and cgroup absence, verify that the same state root contains
   exactly `null-netns`—reject any `.state`, `.lock`, control socket, symlink,
   wrong type, replacement identity, or unknown entry;
4. verify from mount information that this exact private path is the expected
   `nsfs` namespace pin, then detach only that reviewed mount (reject unexpected
   stacking rather than blindly looping over arbitrary mounts);
5. after detach, verify the revealed placeholder is the exact pre-created
   device/inode/type/mode/owner, unlink only that file, prove the directory is
   empty, remove the unchanged directory, and prove the root absent; and
6. retain finite escaped entry/type/mount diagnostics before failure cleanup so
   another failure names what was actually observed.

An alternative explicit `--gofer-network-namespace=new` would avoid shared-pin
state while retaining an empty network namespace per gofer, but it changes the
reviewed OCI/runtime source and still requires fresh source, image, and runtime
review. It must not be smuggled into the consumed launcher or old image.

An independent no-mount/no-gVisor host model exercised the exact-owned
post-unmount portion of the correction. It accepted one mode-0700 state root
containing only the original mode-0444 `null-netns` placeholder, then removed
that exact entry and root. It rejected 6/6 cases—surviving `.state`, surviving
`.lock`, control-socket name, replaced placeholder identity, symlink, and extra
unknown entry—and left every rejected root intact. The temporary test tree was
automatically removed. This models roster and identity enforcement only; it is
not runtime, mount, or gVisor evidence.

### Gate state and review hygiene

The prior image-binding review correctly admitted one run, but the resulting
functional gate is now red. There is no authorization remaining for a rerun,
diagnostic variant, changed launcher, different image, or different payload.
Future runtime review must independently verify the corrected source, explicit
state-pin ownership and cleanup tests, newly realized image/closure, exact
runtime recipe, and preservation of every isolation/resource/diagnostic
boundary before requesting one new bounded authorization.

This attribution review recomputed retained hashes, read the frozen realized
adapter and pinned gVisor source, inspected the existing finite logs, and ran
one temporary bounded host-only state-layout model. It did not edit protocol,
OCI, system, launcher, checker, packaging, or gVisor source; build or realize
anything; mount or inspect the destroyed overlay; invoke QEMU/runsc/ARM code;
access hardware; stage; commit; push; or merge. This review append is the only
repository edit.

## Proposed exact null-netns cleanup successor — pending independent review

This section records an implementation proposal and its author-side tests. It
is **not** independent acceptance, image evidence, or permission to run the
consumed gate again. The preceding attribution snapshot remains identified by
SHA-256 `894f0e03d0c4001e644e59cb1dab91d392c3eba6c3435e4fa4a1ee020bd2bfd0`.
The immutable failure packet separately binds that snapshot, the mode-0400
runtime evidence and wrapper, the accepted image/launcher, the realized
historical adapter, and the pinned source files:

```text
768dc48020fde6ba0e1272ad0449790dfa24daa49b345b8d5469abd9b9dcd730  pinenote/tools/book-execution-spike/build/protocol-control-runtime-failure-analysis-v1.txt
```

### Proposed correction boundary

Only `guest-book-protocol.scm` changes among the runtime adapter/OCI/books and
accepted protocol/session cores. Before spawning runsc in actual-guest mode, it
now requires the fixture-created `runsc-state` object to be the same root-owned
mode-0700 empty directory and not a mountpoint. It creates exactly
`runsc-state/null-netns` using `O_EXCL`, forces mode 0444 despite the supervisor
umask, and retains the root, placeholder, and authority network-namespace
device/inode identities.

After the existing endpoint unregister/close, exact runsc-group reap, finite
capture drain, and runsc-zero/capture checks, the proposed gate serializes a
bounded non-following roster before attempting state cleanup: at most four
names and at most two mountinfo records for each name. Names and mount records
are escaped through the frozen diagnostic writer; entry contents are never
opened, read, traversed, or removed. Cleanup first requires cgroup absence
before validating or altering the state mount.

Cleanup accepts exactly one entry named `null-netns` and exactly one mountinfo
record at that exact private path. It requires filesystem and source `nsfs`, a
`net:[decimal-inode]` root matching the mounted object's inode, a mountinfo
device matching `stat.st_dev`, read-write mount and superblock options, a
regular mounted object distinct from both the retained underlying placeholder
and the trusted authority's network namespace, and an unchanged private state
root. It then invokes the frozen fixed `umount -n` utility on that path—no
`MNT_DETACH`, `-l`, mount loop, or caller-selected target. After unmount it
requires no mount record, the same unchanged root, and the exact pre-created
placeholder device/inode/type/mode/UID/GID/link count. It unlinks only that
file, proves the root empty, removes that root, and proves it absent.

The already-unmounted-placeholder case is deliberately strict: it fails before
any unlink and preserves the known placeholder and root. So do unknown files,
other-container `.state`/`.lock`, a control socket, directory, symlink, replaced
placeholder, replaced root, user-namespace mount, authority-network-namespace
mount, stacked mount, or failed unmount. There is no recursive deletion, retry,
delay, expected-lock exception, gofer-network-namespace flag change, network or
host-UDS relaxation, additional broker, or process-wide file-size limit.

The complete accepted-to-proposed adapter diff is finite and reviewable:

```text
939da7cc8c91520f4ec76f7a9c55b34d855f5d5786701585d3cd7455b6649dba  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-guest-adapter-v2.diff
```

Current source identities are:

```text
2d5fd259be66632f4595f475805e33b30e5a0664e1b0b8de1f9a653b1e9dfe1b  pinenote/tools/book-execution-spike/guest-book-protocol.scm
f6dd176943fbfc9059967e9142c91ac21ae629d0c2a0644a65d584e28c0c5884  pinenote/tools/book-execution-spike/test_guest_book_protocol.py
7b9886e4379a49573ad7f3a3a4c9fe2665e9312c5df7407dbcde146d15b7bdbf  pinenote/tools/book-execution-spike/check_pinned_gvisor_null_netns.py
f172795177f39c022f8d376dfe4963d286293b35ef50ba516150468e3f1f741d  pinenote/tools/book-execution-spike/check_protocol_guest_inventory.py
c7c9c59caa628bebb4d1b699d9686316f6ebaef63b28b4a2134f8b7fdc77b0ef  pinenote/tools/book-execution-spike/protocol-guest/Makefile
f09e21d8cfd08398a2dee3b6ea2d7405010744abc4178fdfe848d860a3092360  pinenote/tools/book-execution-spike/check-protocol-control-system.scm
00fcb3deb29649f802c0d71438a8fe1328d01af584fab4677261d9876a4b966a  pinenote/systems/pinenote-book-execution-protocol-control.scm
```

The frozen files retain the required identities: `guest-smoke.scm`
`74491a0f…`, `oci-bundle.scm` `a3a4c4e6…`, Book Session `f5823fa7…`, Guile
protocol `91f121ad…`, blocking adapter `54357076…`, Python codec `4e2423e0…`,
OCI generator `c5f73730…`, Guile book `9d18f28a…`, Python book `b862ec83…`,
base system `b56fafc9…`, and source-control system `341ca902…`. The complete
six-file unpatched CONTROL release, embedded `release-20260831.0`, exact
`run --pass-fd=3:3`, and accepted 45-path closure remain unchanged.

### Host/static evidence

The author-side aggregate passed the pinned FD seam and new pinned null-netns
source-lifecycle check, immutable inventory, 2 review-drift tests, 26 host
tests, and 18 non-realizing protocol-system checks:

```text
4f555132c856b7e1acc28b46f7be42d5a6a39601947b105226c833a5e39b49c2  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-cheap-gate-v4.log
9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3ab86aa  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-cheap-gate-v4.exit
```

The positive lifecycle uses `unshare --user --map-root-user --mount --net` and
has a child in a second network namespace bind-mount its own
`/proc/self/ns/net` at the pre-created placeholder. The supervisor verifies and
non-lazily unmounts it. Negative mounts and preserved residue live only in that
throwaway private mount namespace; hosts without unprivileged namespace support
skip these tests rather than mutating the parent namespace. On this host every
case ran and passed. A failed first aggregate remains preserved as v1 (one stale
diagnostic-header assertion); v2 and v3 passed before final identity repinning;
v4 is the current aggregate.

### Discovery boundary and unauthorized launcher

The current source requires a new 19-module view because the protocol system
identity changed. V3 preserves the independently reviewed shape: exact
hash-pinned symlinks to original module sources in `GUILE_LOAD_PATH`, a separate
`-L` directory containing zero Scheme files, and empty
`GUILE_LOAD_COMPILED_PATH`. A focused run exposed a correction to the old claim:
with only the last variable empty, Guile still consulted
`/home/wkelly/.cache/guile/ccache` by source filename. That v1 focused log is
preserved. The current command additionally sets `HOME=/nonexistent` and
`XDG_CACHE_HOME=/nonexistent` for every direct Guix call and the nested host
gate. Its v3 log contains no user-cache path and passes all 57 relative
`local-file` checks plus the protocol/base/source-control static checks:

```text
da7f404f7401703aab1f20023244784f6552330ba57a6cdfab3de77184ef74a7  pinenote/tools/book-execution-spike/prepare_protocol_control_module_view_v3.py
aed26a82268f436b08622034f2d0d792e003e4b32dc86eb0e12c77b560be2f3d  pinenote/tools/book-execution-spike/build/protocol-control-guix-module-view-v3/MODULES.sha256
eb6412b8d31a23c092c9fe712f130c3bf72ef0620aec7757b2864c212419a636  pinenote/tools/book-execution-spike/build/protocol-control-guix-package-view-v3/EMPTY
3ebd5cc3a739482d50b2794d7c09837731e7f5c7dc71a2fb7974887885fff1f9  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-module-view-v3.command
08ff1e7c87be629a67ffdbc907edfc765a713e0369da218a1e8da1297014a5f3  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-module-view-v3.log
9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3ab86aa  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-module-view-v3.exit
```

The current image recipe is v7. It retains v4's immediate post-authorization
empty `GUIX_PACKAGE_PATH`/`GUIX_BUILD_OPTIONS`, split module/package discovery,
empty compiled path, and accepted kernel/CONTROL reuse checks, adds the fixed
home/cache boundary and hashes every newly executed review gate, and writes a
new v7 dry-run log under `set -C`. It is not a runtime launcher. V5 and v6 are
preserved superseded proposals. No token was supplied; v7's only execution was
the first-operation refusal, exit 125:

```text
4a1947a39004ecc2ee746d6b2a6c110c38bd377c76ba5193860ca5e790abfec6  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v7.command
276ec6955235d5ad84f14b84f18668199e64c29c8268b1594ea9684754c443db  pinenote/tools/book-execution-spike/build/protocol-control-image-launcher-v4-to-v7.diff
087a1afd8971f7a5b1ada561dcff076f13fcc32c69b9acc16b35feb0a44f96cb  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v7-refusal.log
a5e45837a2959db847f7e67a915d0ecaddd47f943af2af5fa6453be497faabca  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v7-refusal.exit
```

This proposal work performed source edits, hash/static checks, fake-runsc host
tests, temporary unprivileged namespace/mount models, and fail-closed launcher
refusals. It did not invoke the v7 dry-run or image command; build or realize an
image; invoke QEMU, runsc, ARM code, Bazel, a kernel build, or a gVisor build;
access hardware; deploy; stage; commit; push; or merge. Independent focused
review of source, tests, documents, manifests, and launcher remains required
before seeking separate image-build authorization. Any runtime would then need
a newly realized and reviewed image-bound packet and another separate one-run
authorization.

## Independent null-netns successor source review — 2026-09-05

### Verdict

**Reject the proposed adapter at SHA-256 `2d5fd259…` for image assembly.** Its
normal, intended single-pin path is source-compatible with pinned gVisor and
passed an independent real-namespace positive. It also correctly rejects an
authority-network-namespace bind without altering the underlying placeholder.
However, there is one concrete fail-preserve bug: an unexpected bind mount on
the unchanged `runsc-state` directory is not rejected before cleanup. With
that mount present and one otherwise valid isolated `null-netns` pin, the
adapter non-lazily unmounts the pin and deletes the exact owned placeholder,
then fails only when `rmdir(runsc-state)` returns `EBUSY`. The gate remains
fatal, but suspicious state has already been partially destroyed.

This does not authorize v7's dry run or image command. It does not authorize a
QEMU, runsc, ARM, kernel, gVisor, Bazel, or hardware invocation. The historical
protocol CONTROL result remains failed; its exact residual entry remains
unknown. Pinned source still makes `null-netns` the strongly supported
explanation, not a directly observed filename.

### Exact reviewed source and packet

```text
ccfc7de1a84503bad1a9f2f0da20bac8309e6f84b283d7b062154fa1ae3341e1  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-source-review-manifest-v1.txt
768dc48020fde6ba0e1272ad0449790dfa24daa49b345b8d5469abd9b9dcd730  pinenote/tools/book-execution-spike/build/protocol-control-runtime-failure-analysis-v1.txt
2d5fd259be66632f4595f475805e33b30e5a0664e1b0b8de1f9a653b1e9dfe1b  pinenote/tools/book-execution-spike/guest-book-protocol.scm
939da7cc8c91520f4ec76f7a9c55b34d855f5d5786701585d3cd7455b6649dba  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-guest-adapter-v2.diff
00fcb3deb29649f802c0d71438a8fe1328d01af584fab4677261d9876a4b966a  pinenote/systems/pinenote-book-execution-protocol-control.scm
f6dd176943fbfc9059967e9142c91ac21ae629d0c2a0644a65d584e28c0c5884  pinenote/tools/book-execution-spike/test_guest_book_protocol.py
7b9886e4379a49573ad7f3a3a4c9fe2665e9312c5df7407dbcde146d15b7bdbf  pinenote/tools/book-execution-spike/check_pinned_gvisor_null_netns.py
f172795177f39c022f8d376dfe4963d286293b35ef50ba516150468e3f1f741d  pinenote/tools/book-execution-spike/check_protocol_guest_inventory.py
f09e21d8cfd08398a2dee3b6ea2d7405010744abc4178fdfe848d860a3092360  pinenote/tools/book-execution-spike/check-protocol-control-system.scm
c7c9c59caa628bebb4d1b699d9686316f6ebaef63b28b4a2134f8b7fdc77b0ef  pinenote/tools/book-execution-spike/protocol-guest/Makefile
```

The pinned checkout was clean at
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`. The reviewed gVisor hashes show
that default `--gofer-network-namespace=null` still uses `--root` as the shared
root, opens or creates `null-netns`, starts the first gofer in a new empty
network namespace, and bind-mounts that namespace at the pin. Ordinary attached
`run` destruction still removes container state, lock, control socket,
processes, and cgroup but not the shared pin. There is no global network,
host-UDS, DirectFS, ptrace, or gofer-policy relaxation in the successor.

The frozen protocol/OCI/book inputs recomputed to their recorded hashes:
`guest-smoke.scm` `74491a0f…`, `oci-bundle.scm` `a3a4c4e6…`, Book Session
`f5823fa7…`, Guile protocol `91f121ad…`, blocking adapter `54357076…`, Python
codec `4e2423e0…`, protocol OCI `c5f73730…`, Guile book `9d18f28a…`, Python book
`b862ec83…`, base system `b56fafc9…`, and source-control system `341ca902…`.
The accepted kernel Image remains `f3da1a22…`, the language-closure file
remains `48728ed9…`, and all six accepted CONTROL binaries recomputed to the
v7-pinned hashes, including runsc `a5aca591…`.

### Concrete cleanup bug

`prepare-owned-runtime-state!` correctly rejects a pre-existing mount at the
state root. After runsc exits, though, `cleanup-owned-runtime-state!` checks the
root only through device/inode/type/mode/UID/GID. A self-bind of that exact
directory has the same values and therefore passes `private-runtime-state-root?`.
The post-run cleanup does not require `(mountinfo-at root)` to be empty before
altering the pin.

That omission permits this sequence entirely within a private mount namespace:

1. prepare and retain the original mode-0444 placeholder identity;
2. bind-mount `runsc-state` onto itself;
3. bind a second, isolated network namespace at `null-netns`;
4. pass the exact one-entry roster and exact one-`nsfs`-pin checks;
5. emit `action=nonlazy-unmount`, unmount the reviewed pin, and verify the
   original placeholder;
6. unlink that placeholder; then
7. fail `rmdir(runsc-state)` with `EBUSY` because the unexpected root mount is
   still present.

The source therefore satisfies fail-closed but not fail-preserve. Its bounded
diagnostic also reports mounts for selected entries only; it does not serialize
bounded mount information for the state root itself, so this unexpected mount
would not be identified by the pre-cleanup roster.

The narrow successor should require an unchanged state root **and zero mounts
at that root before any pin unmount**, recheck that invariant before unlinking
the revealed placeholder, and include bounded escaped state-root mount records
in the pre-cleanup diagnostic. Add a real private-namespace regression that
self-binds the root and installs an otherwise valid isolated netns pin, then
requires rejection before the cleanup marker or unmount and proves the pin,
placeholder identity, and root mount remain intact. Keep the existing stacked
pin, wrong namespace, replacement, unmounted-placeholder, residue, and failed
unmount negatives.

### Independent namespace evidence

A new inline host harness used the already-realized Guile 3.0.9/json/gcrypt
profile and executed the actual adapter functions under:

```text
unshare --user --map-root-user --mount --net --fork
mount --make-rprivate /
```

No mount operation occurred in the host mount namespace. Three independently
selected cases produced:

```text
positive:        status=0, root absent after exact nonlazy cleanup
authority-netns: rejected, root and original null-netns placeholder preserved
root-self-bind:  rejected only at rmdir; root preserved but null-netns absent
```

For the last case, the adapter emitted the nonlazy-unmount action and reported
one surviving root mount while `pin-visible-after=#f`. After the disposable
namespace exited, the host-visible original root remained empty. This is direct
host evidence for the partial-cleanup defect; it is not runsc, ARM, QEMU, or
functional protocol evidence.

### Launcher review and authorization interface

```text
4a1947a39004ecc2ee746d6b2a6c110c38bd377c76ba5193860ca5e790abfec6  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v7.command
276ec6955235d5ad84f14b84f18668199e64c29c8268b1594ea9684754c443db  pinenote/tools/book-execution-spike/build/protocol-control-image-launcher-v4-to-v7.diff
da7f404f7401703aab1f20023244784f6552330ba57a6cdfab3de77184ef74a7  pinenote/tools/book-execution-spike/prepare_protocol_control_module_view_v3.py
aed26a82268f436b08622034f2d0d792e003e4b32dc86eb0e12c77b560be2f3d  pinenote/tools/book-execution-spike/build/protocol-control-guix-module-view-v3/MODULES.sha256
eb6412b8d31a23c092c9fe712f130c3bf72ef0620aec7757b2864c212419a636  pinenote/tools/book-execution-spike/build/protocol-control-guix-package-view-v3/EMPTY
08ff1e7c87be629a67ffdbc907edfc765a713e0369da218a1e8da1297014a5f3  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-module-view-v3.log
```

Direct v4→v5→v6→v7 comparison found no skipped gate, discovery broadening,
network/cache downloader, substitute, offload, core-count, or job-count change.
V5 adds hashes for every newly executed gate and a versioned split view; v6
adds `HOME=/nonexistent` and `XDG_CACHE_HOME=/nonexistent` to close Guile's user
ccache fallback; v7 repins only the final adapter/system/test identities and its
matching v3 view. The strict v3 log has 19 symlinked modules, zero Scheme files
in the package view, 57 passing `local-file` resolutions, an empty compiled
load path, and no user-home or ccache lookup. The append-only review document is
not a launcher hash input.

The launcher's exact image-build authorization interface remains:

```text
WILKBOOK_PROTOCOL_CONTROL_IMAGE_BUILD_AUTHORIZATION=SOURCE_REVIEW_ACCEPTED_AND_IMAGE_BUILD_SEPARATELY_AUTHORIZED
```

That value was not supplied and **must not be supplied for v7 under this
verdict**. Independent invocation without it again refused as the first
effective operation with exit 125. No dry run or image realization followed.

This review appended only this section. It did not edit implementation, OCI,
system, launcher, checker, tests, packaging, or gVisor source; run an image dry
run or build; invoke runsc, QEMU, ARM, Bazel, a kernel/gVisor build, hardware,
SSH, UART, or device mounts; stage; commit; push; or merge.

## Proposed state-root mount fail-preserve successor — pending focused recheck

This is an author-side correction proposal, not independent acceptance. The
blocking review above remains fixed at SHA-256
`9d3604330edcafe0b9aa54ccbc39705cecd184265b6c4d22f62b218114ef444e`.
Its v7 launcher, v1 source-review packet, `2d5fd259…` adapter diff, and all prior
evidence remain preserved and must not be repurposed.

### Narrow source correction

The cleanup now rejects any mount at the exact unchanged `runsc-state` root
before it inspects or unmounts the accepted `null-netns` pin. After the ordinary
non-lazy pin unmount, it rechecks both root identity and zero root mounts before
the first unlink. The original placeholder, exact one-entry roster, pin
namespace/device/inode/type checks, authority-namespace rejection, stacked-pin
rejection, and fail-preserve residue rules are unchanged.

The pre-cleanup diagnostic now reports the exact root-mount count and emits at
most two root mountinfo records, including mount ID, parent mount ID, device,
filesystem type, root/source byte counts, and the escaped bounded raw record.
Each source record is clipped to 2,048 bytes before escaping. Even if every byte
needs four-byte `\\xNN` encoding, the two new records add under 17 KiB including
their fixed summaries; this remains inside the accepted outer runner's 2 MiB
console framing/boot headroom. Entry diagnostics remain capped at four names and
two mount records per entry.

These are ownership observations for this controlled private fixture. They do
not purport to prevent arbitrary concurrent privileged mount operations on a
host outside that ownership boundary.

```text
eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d  pinenote/tools/book-execution-spike/guest-book-protocol.scm
d928ba9a825761739d1748eb45bef1881f47db7b74c5a950ffc1d9e8f24ce151  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-root-mount-guest-adapter-v3.diff
3330cc6ba3b9bc0bde2a30b38c8134eefcfb5824d29c3b17c2e464dec26581eb  pinenote/tools/book-execution-spike/test_guest_book_protocol.py
0f5240f954c8008fc0576d732ea3209054c45c625b9808c897aca46ab96fd64a  pinenote/tools/book-execution-spike/check_protocol_guest_inventory.py
a6cf6950aae12e05a5ca254e43c23ddef0a79266836ff7778c7a3aaf39735312  pinenote/tools/book-execution-spike/check-protocol-control-system.scm
81276943c553efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047  pinenote/systems/pinenote-book-execution-protocol-control.scm
```

### Actual private-namespace regressions

The focused self-bind regression executes the actual adapter under
`unshare --user --map-root-user --mount --net --propagation private --fork`.
It prepares the original placeholder, self-binds the exact state root, installs
an otherwise valid isolated `nsfs` network-namespace pin, emits the bounded
diagnostic, and calls cleanup. It requires the root-specific rejection before
the `action=nonlazy-unmount` marker, then proves that one root mount and one pin
mount remain. Only after that rejection proof does test-owned cleanup unmount
the pin, reveal and verify the exact original placeholder identity, unmount the
root, recheck root/placeholder identity, and remove its own temporary files.

A second deterministic regression wraps only the frozen utility call in the
test process. Immediately after the accepted utility has unmounted the pin, the
wrapper self-binds the root. The new second root observation rejects before
placeholder unlink; the test verifies that the injected root mount and original
revealed placeholder remain, then removes its own mount and files. This proves
the recheck is operative without adding a production hook or claiming closure
against uncontrolled privileged host races. The intended isolated-netns success
and authority-netns rejection continue to pass.

The complete cheap gate passed 2 pinned-source checks, 2 review-drift tests, 28
host tests, and 18 non-realizing Guix system checks:

```text
93c9f11d64ef254aa1c849e85ef0038ef3a499a1753f61b5b9ed756e5af825f9  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-cheap-gate-v5.log
9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-cheap-gate-v5.exit
```

The separately strict v4 discovery view retains 19 hash-pinned modules, zero
Scheme files in the package view, empty `GUILE_LOAD_COMPILED_PATH`, and
`HOME=/nonexistent` plus `XDG_CACHE_HOME=/nonexistent`. Its final log has no
user-home or ccache reference and passes all 57 `local-file` checks plus the
protocol/base/source-control static comparisons:

```text
97546cc27e25902d926829c27f0d1b02855792595fd0c85a98af02835a0202ea  pinenote/tools/book-execution-spike/prepare_protocol_control_module_view_v4.py
406509bd6e75702de8e3d6c891253432b8b918e6f4bb4f4f6b4218af8a82f749  pinenote/tools/book-execution-spike/build/protocol-control-guix-module-view-v4/MODULES.sha256
eb6412b8d31a23c092c9fe712f130c3bf72ef0620aec7757b2864c212419a636  pinenote/tools/book-execution-spike/build/protocol-control-guix-package-view-v4/EMPTY
622f835f04980d772208e1caf5ff1d4ddbd32d01cb27126053e6bdd53595dd8c  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-module-view-v4.command
bc72f91c6b19a1d40dac6f22aefbdc7769ad4ae2dd043ecbc25b73f9d7ded29c  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-module-view-v4-final.log
9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-module-view-v4-final.exit
```

### Unauthorized v8 image proposal

Only after those tests passed was v8 created. Relative to blocked v7 it repins
the adapter, system/hash gates, two-test-expanded host suite, and versioned
19-module view. It retains the complete six-file unpatched CONTROL release and
embedded `release-20260831.0`, accepted USER_NS kernel and 45-path language
closure, Systrap/`isolation-userns`, `--directfs=false`, `--network=none`,
`--host-uds=none`, cgroups and strict sidecars, 1 MiB payload file limit, finite
captures/stores, and exactly `run --pass-fd=3:3`. It preserves v7's first
authorization guard and immediate empty `GUIX_PACKAGE_PATH` /
`GUIX_BUILD_OPTIONS` boundary.

```text
f3741b2bae44a1915927ab4f975577e1fd5e2457ff93777a457403fb34c30564  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v8.command
55163fcf03e6310d47888635a9eac8a8a70c326220956e4068d7acbb65580eee  pinenote/tools/book-execution-spike/build/protocol-control-image-launcher-v7-to-v8.diff
087a1afd8971f7a5b1ada561dcff076f13fcc32c69b9acc16b35feb0a44f96cb  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v8-refusal.log
a5e45837a2959db847f7e67a915d0ecaddd47f943af2af5fa6453be497faabca  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v8-refusal.exit
```

With hostile outer Guix discovery values and no authorization token, v8 refused
as its first effective operation with exit 125 and did not start Guix. No image
dry run, image/system realization, runsc, QEMU, ARM code, Bazel, kernel/gVisor
build, hardware, deployment, staging, commit, push, or merge occurred. V8 and
the successor source packet remain pending the reviewer's finite root-mount
ordering recheck. Any later image assembly and runtime continue to require
separate authorizations and newly reviewed immutable packets.

## Independent state-root mount successor recheck — 2026-09-05

### Verdict

**Accept the source successor at adapter SHA-256 `eb6a1af3…` as fit for a
separately authorized image assembly.** The focused recheck found no remaining
blocker in the state-root/null-netns cleanup boundary. The correction rejects
the previously demonstrated self-bind before pin cleanup, preserves the root
mount, pin mount, and original placeholder, and re-observes zero root mounts
after the reviewed pin unmount but before the first unlink.

This is source acceptance only. It is not an image dry run, realization, image
or closure acceptance, runtime authorization, ARM64 protocol result, hostile-
book qualification, output-import acceptance, production-resource acceptance,
or release acceptance. The historical protocol CONTROL gate remains failed:
Guile's two FD-3 presentations are scoped positive evidence, Python did not
start, and the exact historical residue remains unknown. `null-netns` remains
the pinned-source-supported attribution, not a directly observed old entry.

### Exact accepted source packet

```text
99050e5a55e0cba59df93ca2ae75cfd414a6be53c950237fd324ea481103d635  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-source-review-manifest-v2.txt
eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d  pinenote/tools/book-execution-spike/guest-book-protocol.scm
d928ba9a825761739d1748eb45bef1881f47db7b74c5a950ffc1d9e8f24ce151  pinenote/tools/book-execution-spike/build/protocol-control-null-netns-root-mount-guest-adapter-v3.diff
3330cc6ba3b9bc0bde2a30b38c8134eefcfb5824d29c3b17c2e464dec26581eb  pinenote/tools/book-execution-spike/test_guest_book_protocol.py
0f5240f954c8008fc0576d732ea3209054c45c625b9808c897aca46ab96fd64a  pinenote/tools/book-execution-spike/check_protocol_guest_inventory.py
a6cf6950aae12e05a5ca254e43c23ddef0a79266836ff7778c7a3aaf39735312  pinenote/tools/book-execution-spike/check-protocol-control-system.scm
81276943c553efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047  pinenote/systems/pinenote-book-execution-protocol-control.scm
```

Reverse-applying the reviewed adapter diff to `eb6a1af3…` independently
reconstructed the rejected predecessor exactly as `2d5fd259…`. The diff is
narrow: two root-mount observations, bounded root-mount diagnostics and mount
IDs, and their fixed limit. It does not change protocol exchange, process/FD
ownership, capture, cgroup, diagnostic-store, or PASS ordering.

### Cleanup ordering and fail-preserve result

The first post-run root check occurs after endpoint release, exact owned runsc
group finalization, capture completion, runsc-zero/capture acceptance, cgroup
absence, authority-network-namespace identity, and state-root identity. It now
requires `(mountinfo-at root)` to be empty before checking the one-entry roster,
accepting the exact `nsfs` pin, emitting the cleanup marker, or calling
`umount -n`.

After that exact pin unmount, cleanup requires:

1. no mount remains at the pin;
2. the state root still has its original device/inode/type/mode/UID/GID;
3. a second `(mountinfo-at root)` result is empty; and only then
4. the exact roster and original placeholder identity are accepted for the
   sole `delete-file`.

Unknown entries, `.state`, `.lock`, control sockets, symlinks, wrong types,
replaced roots/placeholders, already-unmounted placeholders, authority or wrong
namespace mounts, stacked pin mounts, root mounts, and failed unmounts therefore
remain fatal. There is no recursive deletion, mount loop, lazy detach, fallback,
or cleanup-gate removal.

The second observation deliberately does not claim to prevent an arbitrary
privileged process from racing in the final instructions between observation
and unlink. The source and packet accurately scope it as a deterministic
ownership observation in this controlled private fixture after every owned
writer is gone. That is the reviewed boundary; hostile host-root race safety is
not being inferred.

### Independent private-namespace evidence

A separate inline harness loaded the actual adapter from the already-realized
native Guile 3.0.9/json/gcrypt profile and ran only under:

```text
unshare --user --map-root-user --mount --net --fork
mount --make-rprivate /
```

No mount operation occurred in the host mount namespace. The completed cases
were:

```text
intended isolated-netns pin:
  PASS; exact nonlazy cleanup removed the placeholder and state root

state-root self-bind plus valid isolated-netns pin:
  rejected before action=nonlazy-unmount
  root mounts=1 and pin mounts=1 before test-owned cleanup
  an FD retained before either mount still identified the original placeholder
  test-only pin unmount revealed the exact original placeholder path identity

root bind injected immediately after valid pin unmount:
  rejected by the second root observation before placeholder unlink
  root mounts=1, pin mounts=0, exact original placeholder still linked
```

The post-unmount case used an external test-only umount helper that first
performed the requested nonlazy unmount and then self-bound the root. It did
not monkeypatch the adapter's observation function. This independently proves
the second check is active while retaining the source's appropriately limited
concurrency claim.

### Diagnostic bound

Root diagnostics expose the total root-mount count but select at most two
records. Each selected raw mountinfo record passes through the frozen
`bounded-escaped-line`, which clips input to 2,048 bytes and escapes control
bytes and backslashes. The added header contains kernel-tokenized mount ID,
parent ID, device, and filesystem type plus byte counts; it does not print an
unescaped raw record. Thus the stated worst-case addition remains below 17,408
bytes, inside the existing 2 MiB outer console allowance. Existing limits of
four entry names and two mount records per entry remain unchanged.

An independent three-deep state-root mount stack produced:

```text
root-mounts=3 root-mounts-emitted=2 root-mount-limit=2
root diagnostic records emitted=2
complete diagnostic bytes=1162
```

The root-mount roster is emitted before cleanup, remains metadata-only and
escaped, and cannot forge a protocol PASS marker. No diagnostic sink or process
file-size policy changed.

### System and policy preservation

The system source names `guest-book-protocol.scm` once as the adapter
`local-file`, records exact hash `eb6a1af3…` in its ten-source manifest, and
passes that same hash to the guest's runtime provenance check. Its other new
manifest text only declares the two root-mount checks and diagnostic limit.
The 18 static checks confirm the exact accepted USER_NS kernel object, package
list, CONTROL runtime selection, filesystems/cgroup2, kernel arguments, initrd,
service shape, accepted 45-path sandbox profile, and supervisor-only
`guile-gcrypt@0.5.0` delta remain unchanged.

The frozen OCI generator remains `c5f73730…`; therefore Systrap,
`isolation-userns`, `--directfs=false`, `--network=none`, `--host-uds=none`,
strict sidecars, cgroups, OCI payload `RLIMIT_FSIZE=1 MiB`, and exactly
`run --pass-fd=3:3` are unchanged. The accepted kernel Image remains
`f3da1a22…`, the 45-path closure file remains `48728ed9…`, and the complete
six-file CONTROL runtime remains fixed, including runsc `a5aca591…`. The
pinned gVisor checkout was clean at
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`.

The author-side evidence hashes were independently matched:

```text
93c9f11d64ef254aa1c849e85ef0038ef3a499a1753f61b5b9ed756e5af825f9  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-cheap-gate-v5.log
bc72f91c6b19a1d40dac6f22aefbdc7769ad4ae2dd043ecbc25b73f9d7ded29c  pinenote/tools/book-execution-spike/build/protocol-control-root-mount-module-view-v4-final.log
```

Those logs record 2 pinned-source checks, 2 drift tests, 28 host tests, 18
static system checks, 57 `local-file` checks, 19 modules, zero package-view
Scheme files, empty compiled load path, and no user-home/ccache reference.

### V8 assembly packet and authorization boundary

```text
4a1947a39004ecc2ee746d6b2a6c110c38bd377c76ba5193860ca5e790abfec6  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v7.command
f3741b2bae44a1915927ab4f975577e1fd5e2457ff93777a457403fb34c30564  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v8.command
55163fcf03e6310d47888635a9eac8a8a70c326220956e4068d7acbb65580eee  pinenote/tools/book-execution-spike/build/protocol-control-image-launcher-v7-to-v8.diff
421e1ba7fe92100342b93a31fcb15f7b4562f45dcdd1331c10d91e6d2b4ddadd  pinenote/tools/book-execution-spike/build/protocol-control-next-image-build-v8-input-check.log
```

The v7 artifact remains byte-for-byte at its blocking-review hash. The exact
v7→v8 diff contains only the new source/system/test/static identities, matching
versioned module/package views, comment, and v8 dry-run filename. It does not
skip a gate or change Guix discovery, substitutes, offload, jobs, cores, target,
kernel/CONTROL rejection, or image command. I independently recomputed all 43
v8 launcher input hashes and rechecked the 19-module/zero-Scheme package view.

The launcher's exact image-build authorization interface is unchanged:

```text
WILKBOOK_PROTOCOL_CONTROL_IMAGE_BUILD_AUTHORIZATION=SOURCE_REVIEW_ACCEPTED_AND_IMAGE_BUILD_SEPARATELY_AUTHORIZED
```

It was not supplied during this review. With hostile inherited Guix discovery
variables and no token, v8 again refused as its first effective operation with
exit 125. This verdict establishes source fitness for the parent to issue a
separate assembly authorization; it does not itself execute or accept that
assembly.

This review appended only this section. It did not edit source, system,
launcher, tests, checker, OCI, packaging, or gVisor; invoke an image dry run or
realization, runsc, QEMU, ARM, Bazel, kernel/gVisor build, hardware, SSH, UART,
or device mount; stage; commit; push; or merge.
