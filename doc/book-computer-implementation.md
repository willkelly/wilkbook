# Book computer: offline implementation lane

Status: started 2026-09-04; chronological offline implementation record, not a
shipping feature or hardware validation. Historical “pending,” “no runtime,” and
blocked statements below remain true at their dated checkpoints; use the current
snapshot before interpreting them as present status.

Start here:

- Architecture and product direction:
  [self-hosting book computer](wilkbook-self-hosting-book-computer.md).
- Exact protocol/FSM/capability reference and current evidence matrix:
  [Book computer protocols](book-computer-protocols.md).
- Accepted fixed-book QEMU/KOReader result:
  [Book computer demonstration](book-computer-demo.md).
- Physical-device truth: [`status.md`](status.md).

This is an execution record for that direction, not a replacement specification.
Accepted source, active candidate, blocked gate, historical failure, and future
product claims are intentionally kept separate.

## Current snapshot — 2026-09-08

### Release scope: opt-in developer foundation

The operator clarified the release goal on 2026-09-07: land a mergeable
foundation that we can exercise intentionally and future contributors can
continue. Book Computer does not need to become the default reader experience
for this release.

The delivery work is therefore:

- Keep experimental systems and launch commands explicit and opt-in.
- Complete the sandboxed persistent-note integration, retaining honest results
  from the actual runs as well as component tests.
- Provide a device-appropriate opt-in integration and an attended PineNote test
  record. The QEMU guest automates input and shuts down; it is not that device
  integration.
- Leave reproducible source/build/test entrypoints and a concise handoff naming
  the runtime boundaries, configuration/state ownership, known limits, and next
  implementation seams. A temporary reviewed packet alone is not the reusable
  scaffold.
- Prepare the verified source and documentation for a PR; default activation,
  Workbench self-editing, and everyday-use polish are subsequent work.

#### Where the next contributor starts

| Concern | Source / entrypoint | Current scope |
| --- | --- | --- |
| Public baseline checks | `pinenote/tools/book-source-check/`; README's `export-candidate` and `make check-source` commands | Published native persistent-editor and source validation |
| Storage authority | `pinenote/tools/book-state/` and `pinenote/tools/book-state-protocol/` | Guile-owned SQLite, typed Book Session operations; books receive no direct storage capability |
| Note presentation | `pinenote/tools/book-state-reader/`, `pinenote/tools/book-state-reader-join/`, and `pinenote/tools/book-state-device/` | Real native KOReader widget save/paint/reopen/disconnect tests; human device saves and restart recovery on generation 20 with source overrides |
| Sandboxed ARM guest | `pinenote/tools/book-state-guest/` and `pinenote/systems/pinenote-book-state-reader.scm` | Explicit QEMU-only one-shot system, despite the system filename |
| Two-boot execution | `pinenote/tools/book-state-qemu/two-boot/run-two-boot.sh` and its `CONTRACT.md` | Strict two-fresh-boot QEMU pass on one private 64 MiB state disk: both languages A/version 1, then recovery and B/version 2; opt-in only |
| Device integration | `pinenote/systems/pinenote-book-state-device-reader.scm` and `pinenote/tools/book-state-device/README.md` | Opt-in inherited reader flavor; generation 20 trialled/promoted, then live-debugged successfully; clean fixed-generation boot remains |

The PR #79 follow-up includes guest, two-boot and device sources and retained
review history. The source/build/test entrypoints live alongside each tool;
immutable review packets retain their historical identities. Exact hardware
results and failed attempts are recorded in `doc/status.md`.

### Latest execution checkpoint

**Strict production two-fresh-boot pass:** the clean natural-grace successor
completed both fresh ARM boots through the authenticated production graph. Boot
1 saved Guile and Python A/version 1; boot 2 repainted/recovered both A values
and saved B/version 2. All four operation/version-correlated sandbox boundary
records are present. The boot consoles reached canonical power-down at 38.19 s
and 32.79 s; QEMU, KOReader, runsc, checker, and guardian identities are reaped.
The identity-safe campaign cleanup completed and the run base is empty.

The immutable final evidence is
`/tmp/opencode/book-state-natural-grace-r2-final-evidence-base-v2.IOI2LD/book-state-two-boot-evidence.qPQNl4`;
`EVIDENCE.sha256` is
`b9d08b88295df2feaa49b60ec9ca923e57aa964a54523682326fb8554d6da06b`.
Its single-link mode-0400 state artifact is `ffb49189…`; read-only fsck and an
independent final checker replay pass. The exact terminal result was:

```text
BOOK_STATE_TWO_BOOT: status=pass; evidence=/tmp/opencode/book-state-natural-grace-r2-final-evidence-base-v2.IOI2LD/book-state-two-boot-evidence.qPQNl4; manifest-sha256=b9d08b88295df2feaa49b60ec9ca923e57aa964a54523682326fb8554d6da06b; state-artifact=read-only
```

The reserved build produced `/gnu/store/j6i1p44vabm88dxa79f1dyzljzjgzyzc-disk-image`
(`fd4f2fff…`) in 19 seconds across 15 small builders, reusing the exact cached
kernel and gVisor. Its embedded system is `/gnu/store/b1i3hjgdpqvvy6wbny23gnb9wmr0mj6n-system`;
the production bundle manifest is `bd7151f0…`. This remains an opt-in QEMU
foundation, not a default-reader or hardware result.

The device-appropriate opt-in note UI/authority and experimental reader system
are now implemented and realized as the separate `book-state-device-reader`
flavor. Generation 20 was trialled and promoted on wkelly's PineNote. Attended
debugging fixed injected KOReader dialog ownership, the native saved baseline,
authority control-structure nesting, language-vs-UI-label validation, and local
dirty-status handling. Human saves and recovery after restarting both services
passed with those source overrides. Normal suspend has been restored, but
suspend/wake qualification of this experimental feature is still open. Book
Computer stays opt-in; the independent `/data/fonts` fix applies to all readers.

#### Experimental device reader: generation-20 build record

`pinenote/systems/pinenote-book-state-device-reader.scm` inherits the full
reader—including direct-mode EBC/waveform handling, `/data`, Wi-Fi, platform
controls, suspend, and generation/kexec support—and changes only the USER_NS
kernel, source-built gVisor package, cgroup2 mount, KOReader package, and two
Book State services. With no exact root-owned mode-0600 `enabled` marker, the
authority opens neither SQLite nor its Unix socket and the plugin registers no
menu item. The deployed service fixes the one visible namespace and runner to
the Guile note; Python remains a second compile-fixed runner with no UI selector.

Focused native integration now exercises both fixed runners over donated FD 3,
real SQLite save/close/reopen, authority restart, abrupt KOReader disconnect and
reconnect, fresh session/grant identities, stale endpoint and stale `/run`
refusal, natural child exit/reap, private database closure, active-session TERM,
and idle TERM while blocked in `accept(2)`. It generates both OCI bundles and
checks systrap,
`network=none`, `directfs=false`, `host-uds=none`, and exactly
`--pass-fd=3:3`. The accepted two-fresh-boot QEMU evidence remains unchanged;
no third boot was run.

The required pin gate still resolves exactly kernel
`/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote`
and gVisor
`/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`.
The final derivation-first build, using `--no-grafts --no-substitutes
--max-jobs=1 --cores=2`, produced derivation
`/gnu/store/nr0yc3rizlvbrmfdxxv7biwa8zqpmwkr-system.drv` and system
`/gnu/store/7wyr4smys53jgf2cjrif0mm94n9cg11p-system`, with a 2596.6 MiB
closure. Closure inspection found the exact pins, device KOReader/plugin,
authority/module union, and 46-path language closure, with no QEMU or local-test
authority artifact. This is the original generation-20 build, which required
the later source overrides documented above. It must not be presented as an
immutable build already containing the live-debugged fixes.

Attempt 1 and the first host-finalization exit from attempt 2 are preserved.
They exposed four producer/checker joins only: real same-paint UI audit order,
Shepherd's non-UART status line, and ordered state-identity fields plus textual
`0400`. No third production boot was run; attempt 2's already-complete,
pre-cleanup-checked boots were finalized offline after exact fixes. See the
runtime note for paths and full identities.

**Pre-production direct-image two-boot success:** a bounded natural-exit grace in
`finalize-owned-runsc!` fixed premature SIGTERM of `runsc run` during its
deferred teardown. Both languages saved A/version 1 in a 33-second boot,
then recovered A/version 1 and saved B/version 2 in a fresh 29-second boot
using the same state disk. All four runsc exits were zero (0.210–0.229 seconds
natural exit), cgroups were absent, only the expected `null-netns` remained
before ownership-checked cleanup, and four attributed boundary records were
published. Guest/UI shutdown passed and state fsck returned zero.

These are **modified diagnostic-image results**, not strict production
acceptance. Evidence is at
`/tmp/opencode/book-state-successor-natural-grace-run.RrRdmf` and
`/tmp/opencode/book-state-successor-natural-grace-run.REnDoM`;
the diagnostic image/state and patch are retained under
`/tmp/opencode/book-state-successor-natural-grace-direct-20260907-v1`.
The verified grace change is ported to
`pinenote/tools/book-execution-spike/guest-book-protocol.scm`; focused delayed-
exit and stuck-child regressions pass, with TERM/KILL escalation and stale-state
checks retained. The focused guest-suite log SHA-256 is
`487ff7ab8e0897e0181583ee15cc647400e469c1ee142aef9bccf9f32818cccb`.
The clean build and strict confirmation are recorded above. No PineNote
deployment or test occurred.

#### Earlier checkpoints retained chronologically

**V9 attempt 1:** the corrected Guix filesystem declaration is proven on real
AArch64 QEMU. `WBBookStateV1` passed fsck and mounted as ext4 at 6.7 seconds;
the V8 `ext4: Unknown parameter 'noatime'` failure is gone. The run then reached
the fixed 360-second VM deadline before `book-state-volume-ready` or the Book
State authority emitted any record, so boot 2 never started and the strict
checker did not pass. Journal replay on a private state-image copy followed by
`debugfs` inspection found neither the sentinel nor SQLite database.

The barrier is no longer unknown. A separately named diagnostic image retained
ordered Shepherd syslog showing `udev` and the state filesystem service
complete, followed by immediate `book-state-volume-ready` failure with
`Unbound variable: get-string-all`. The generated service had put `use-modules`
inside its compiled start lambda, where it did not provide lexical bindings to
the compiled g-expression. The minimal canonical source fix declares
`(ice-9 textual-ports)`, `(srfi srfi-1)`, and `(srfi srfi-13)` through the
Shepherd service's `modules` field and removes that inner import. Its generated
parser reaches the expected missing-mount rejection offline rather than an
unbound-variable exception.

Direct troubleshooting then replaced only the generated volume-ready `.scm`
and `.go` in a disposable writable copy of the original V9 root, using
`debugfs`; the immutable V9 image and failed campaigns were not modified. Two
fresh diagnostic boots crossed the repaired gate: the state filesystem mounted,
the sentinel and schema-1 SQLite database were created, source provenance and
all kernel/network/mount checks passed, and the exact source-built gVisor
version check passed. Read-only journal replay after the second run found the
Guile namespace at state version 0 with no commit receipt, which is the expected
point at which the host UI failure interrupted the run.

The remaining blocker is outside the image. Under AArch64 TCG, the guest's
reply to KOReader's `channel-ready` arrives after the three-second BookInfo
startup notice has expired; the inherited UI fixture then rejects the missing
second notice before the first note can become ready. A retry after `open`
cannot recover an already-expired notice. The third and final authorized
diagnostic tried consuming the exact two known notices before emitting
`channel-ready`; it removed them, then failed because it incorrectly required
the underlying ReaderUI to be visible even though `onReaderReady` runs before
that widget enters the visible stack. No guest output was produced in that
third run. All six recorded QEMU/KOReader PID/start-time identities from the
three cycles were checked absent after cleanup.

The UI correction is therefore narrow: consume exactly the two
pinned clean-profile notices before `channel-ready`, require neither a third nor
an already-visible underlying widget, and emit the historical
`startup-overlays-dismissed:2` marker only after the first `dialog-shown` so the
semantic evidence order is unchanged. The canonical and two-boot copies now
carry that byte-identical change. It compiles with KOReader's LuaJIT and passes
all 22 native reader-join lifecycles with exactly one marker per log and the
historical marker order. The three-cycle diagnostic allowance is exhausted; no
fourth diagnostic cycle was used.

The reserved clean successor build then completed in 20 seconds with one job,
two cores, and 17 small derivations; neither kernel nor gVisor was rebuilt.
Image `/gnu/store/cbnpv8rxy7i7h5m58a5vkn929dq4yvvb-disk-image` is
`2839f9fc…`, with embedded system `a4qgl0y3…`. Read-only extraction proved the
installed mount flags and compiled volume-gate imports. The exact 88-field,
eight-role production binding selects payload manifest `0336260c…` and bundle
manifest `22cc91b2…`; the full host gate passes.

The production campaign ran once from frozen source manifest `6e44b908…`. Boot
1 crossed both repaired startup seams, and KOReader emitted the required
`dialog-shown` → `startup-overlays-dismissed:2` → `dialog-ready` order. Guile
read absent/version 0 and committed A/version 1. The authority then rejected
`runtime left stale cgroup: wilkbook-guile-book-state` after runsc exited zero
and was reaped. Python and boot 2 did not start; no checker `PASS` is claimed.
Read-only inspection of a private state-image copy found one valid Guile
version-1 receipt, integrity OK, no foreign-key rows or sidecars. Every recorded
host process is reaped and the campaign lock is released.

The exact teardown error is not in the retained evidence. Static gVisor source
shows that `container.Run` ignores errors from deferred `Destroy`, so zero exit
does not establish cgroup removal, but it does not identify whether this node
was empty or busy. Another QEMU cycle or clean build requires authorization;
the ready next step is bounded exact-path cgroup metadata and guaranteed runsc
debug emission before selecting cleanup semantics. Exact evidence and
continuation details are in
`pinenote/tools/book-state-qemu/two-boot/RUNTIME-NOTE-20260907.md`.

The historical finalized V9 post-run source copy is
`/tmp/opencode/book-state-qemu-two-boot-v9-mount-flags-successor-20260907-v2`
(`SOURCE-MANIFEST.sha256` `a7f3bbbb…`; runtime manifest `c24fd4ea…`). Its only
functional provenance cleanup after attempt 1 renames the source-fixed external
V9 author input from “review evidence” to neutral “binding evidence”; the closed
88-field payload schema and parent review records do not change. The complete
296-line host gate passed in 59 seconds. Sealed author evidence is
`/tmp/opencode/book-state-qemu-two-boot-v9-mount-flags-successor-20260907-v2-author-evidence`
(`EVIDENCE.sha256` `ee5bfe57…`, host log `c8766691…`). This is not independent
review and does not turn the failed runtime into persistence acceptance.

**Preserved V8 parent:** attempt 5 had already proved the corrected bare-label
QEMU root handoff, Guix root mount, Shepherd startup, and KOReader fixture open,
but failed the state mount because generic protections were passed as ext4 data.
Its unchanged evidence remains at
`/tmp/opencode/book-state-v8-attempt5-evidence-base.bMkfXc/book-state-two-boot-evidence.qGkYzd`.

**Latest delivery state:** the joint V8 guest / V6 checker correlation change
is independently accepted. V8's raw image built successfully in 18.88 seconds
with two cores and one job:
`/gnu/store/rj1a6k042gcchcmcsb8pli426b83w34g-disk-image`.
Build records are at `/tmp/opencode/book-state-image-build-v8-hmm4o55_/`.
Joint review SHA-256:
`a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19`.
Independent artifact-delta inspection and payload preparation are complete.
V8 image SHA-256:
`2a492559aece65eb92832bf836b6b90751f5475101db3642a174c058e5ffa366`.
The immutable artifact packet is
`/tmp/opencode/book-state-image-v8-independent-review-20260907/review-packet-v1`;
its `evidence/PAYLOAD.sha256` digest is
`c26dfa9416c438a59a6fe697773d5325cca863a171e2a6537e9fa93bec2491bc`.
Artifact review SHA-256:
`1a014ece021a59c12daebaa811938496754bf4e6e6b14679f89045ed37e51d53`.
The exact V8 production binding is now independently accepted. Final binding
review SHA-256:
`b9e3d2adfe930ae363a730c57cc93b64e1509c3792e51bc3367d8a6ef742622a`.
One invocation of the reviewed two-boot command has been launched from
`/tmp/opencode/book-state-qemu-two-boot-v8-final-binding-20260907-v1`.
The invocation **failed with exit 1 before QEMU launch**. The one-boot stderr
contains `FAIL: APPEND must contain exactly one root=PNGuixRoot`. The prepared
payload config uses `root=LABEL=PNGuixRoot` and `console=ttyAMA0`, whereas the
launcher's `read-fixed-append` requires `root=PNGuixRoot` and the PineNote UART
console before translating it to QEMU. The artifact/preflight checks did not
exercise this downstream boot-config contract. No guest boot or semantic
persistence acceptance occurred, and boot 2 was not attempted.

Preserved attempt roots:

- Campaign: `/tmp/opencode/book-state-v8-campaign-base.s8i2zM/book-state-campaign.xXf4ms`
- Evidence: `/tmp/opencode/book-state-v8-evidence-base.zdqeQY/book-state-two-boot-evidence.kYJBbj`
- Run base: `/tmp/opencode/book-state-v8-run-base.mbHv7r` (empty after the invocation)

The failed boot record reports equal before/after state hashes:
`45be558efd2f3a824972c48f9e34fdcb1f61df32b1cd162d0b97ff859339f5b2`.
No cleanup, repair, or retry was performed after failure. The per-boot VM limit
remains 360 seconds plus 5 seconds TERM grace for any separately accepted
successor. Step 2, the device reader generation, has not started.

### Resumed device delivery after PR #79

PR [#79](https://github.com/willkelly/wilkbook/pull/79) publishes the accepted
native milestone. Work has resumed on branch `book-computer-device` toward the
operator's requested tablet prototype. Step 1 is the actual sandboxed ARM
save/shutdown/fresh-boot/reopen test; step 2 is a device reader generation.
Step 2 has not started, and no Book Computer generation is installed on the
PineNote.

The two-boot runner's v3 source/pre-image gate is independently accepted:
BTQ-1 through BTQ-4 are closed, including the early dynamic-loader injection
gap. Review SHA-256:
`672c6c7d50e99e8d886b7ae93b94d803d2fc5922d702297770b4947924668b83`.
Production still refuses execution without the exact reviewed image binding.
The guest-v6 mode-only packet is now independently accepted for one bounded
raw-image construction; it preserves v5 code and restores the nine required
executable modes. Final guest review SHA-256:
`4c1df07a0dd1db655f5668975636bdf7aecc8fee3b755d26823be7b4c89cc4e5`.
The host build has been launched with two cores, one job, no substitutes and
a 7200-second limit, after checking the frozen packet and reproducing image
derivation `/gnu/store/p6iwha5axl4s5yi2qb9l76x00cw9vqzg-disk-image.drv`.
Expected output:
`/gnu/store/9yx1xmhf2hnsp6vdwnvvxzqv3i9i9fkz-disk-image`.
**Build completed:** exit 0 in 24.94 seconds, producing the exact expected
output above. The command, clean environment, derivation precheck, complete
stdout/stderr and status are retained at
`/tmp/opencode/book-state-image-build-v6-u_0r5j1z/`.
Independent artifact inspection now accepts the exact image as an artifact.
Image SHA-256:
`53bee9f09d7b3a12ad5e9bf77f1dd91a1e2416be8ba205f06889becfd00de9d4`;
actual image initrd SHA-256:
`e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad`.
Its layout is DOS/MBR, not GPT, with one clean ext4 partition. The reviewed
boot payload changes only the root filesystem label from `Guix_image` to
`PNGuixRoot` (97 bytes across superblocks); the original store image is intact.
Review SHA-256:
`02a4d7adecf9dc36dbd696ea488d00500999cd95d8304a6e76472403281ffa4b`.
Two runner-consumer corrections are active: replace obsolete guest-v4 schema
fields with truthful current identities, and permit legitimate deduplicated
hard links for exact immutable Guix-store executables. No bundle was issued
under the invalid schema. A corrected exact image-binding successor and its
preflight precede actual two-boot execution; no QEMU boot or device deployment
has occurred, and no image rebuild is required for these consumer fixes.

**Later observability correction (2026-09-07):** final-checker review found
that absent sandbox-boundary markers could pass. Source inspection established
that successful guest runs retained those records only in ephemeral container
stdout, so a checker-only correction could not prove the boundary. V7 now
validates each finalized, bounded child capture and publishes the actual
language-specific marker before cleanup. Its two 77-assertion relay matrices
pass independently, including quoted-only and missing-newline negatives.
Guest-v7 review SHA-256:
`ee06d8be01eba8e970c9da59a273daae48d16c23cf0f26a75f8436cd54bc4065`.
One successor raw-image build has started with two cores and one job, after
authenticating the frozen packet and reproducing derivation
`/gnu/store/z714ddhf80rndbx4iz3qs1ys3wwryy5i-disk-image.drv`.
Expected output:
`/gnu/store/lsk489hgzszvym56m5pnsbrvf5malhiy-disk-image`.
**V7 build completed:** exit 0 in 18.83 seconds and exact expected output
`lsk489h…`. The complete build record is retained at
`/tmp/opencode/book-state-image-build-v7-acdmt6cy/`. Boot-artifact inspection
is complete and sealed as historical artifact evidence. V7 image SHA-256:
`7f38261ec047d5db9c0917ea73e42bfbe2d8475cfb90f276ceef799882770350`.
It selects the exact V7 authority through the compiled Shepherd chain and has
no preseeded state database or sentinel. The sealed payload manifest is
`ce98c3c0bf70c4f1a2fbdd001648d19f35896eed425d36029eac9578b34a150f`
(`evidence/PAYLOAD.sha256`, distinct from `STATUS.json`). Artifact review:
`e6e8f415d5925e7d6b6a03be783f1d0afdb1dc0b0dc3283264d10d2c22b756bb`.

V7 is not final-campaign bindable: independent checker review found that
complete same-language attribution/marker pairs can be exchanged between
boots while the sealed checker still passes. The producer/checker successor
must bind each capture attribution to that invocation's actual book-owned
operation ID and resulting state version. This joint correction is active;
it does not change the sandbox or storage design. The image and prior evidence
remain preserved. No QEMU or device execution has occurred.

The clarified boundary permits SQLite software inside the book environment;
the book must have no direct access to the authority's state volume/database
or private UI channel. Both fixtures must execute their boundary probes and
state operations inside the actual gVisor sandbox. Native fixture acceptance
does not satisfy this runtime gate.

### Published milestone and earlier checkpoints

**Delivery checkpoint:** publish the accepted native persistent-note editor,
public source/native test lane, reusable gVisor package and reviewed source
graph tooling. Guest persistence and the two-boot runner are follow-up work;
their working directories and new guest system are not part of this publication
roster. References below to those paths record local experiments, not runnable
features included in this checkpoint. The unfinished runner has stopped with
its partial v2 preserved and explicitly not ready for review or execution.

**Latest guest finding:** BSG-3's complete source-view replay is independently
closed, but BSG-4 blocks guest acceptance. The 45-path language closure includes
SQLite 3.39.3 executables/libraries and Python's SQLite module. Earlier claims
that SQLite is absent from book-visible paths are therefore incorrect. This
does not establish access to the authority's persistent Book State database:
the guest review confirms that no state volume, namespace, grant or database
path is donated to the sandbox. The stronger SQLite-absence requirement needs
an explicit decision in follow-up work. See
[`book-state-guest-adversarial.md`](reviews/2026-09-06-book-state-guest-adversarial.md),
BSG-4. No guest fix or further review cycle is required to publish the accepted
native-editor milestone.

- **Accepted, narrow components:** JSON framing; the ordinary untimed Book
  Session; the SQLite backend; seven-message state model; backend adapter; and
  optional state-enabled Book Session successor/delegate. The optional successor
  is not installed over the live ordinary Book Session source.
- **Accepted integration evidence:** fixed Guile and Python books executed under
  ARM64 gVisor/Systrap in QEMU through donated Book Session FDs, and four fresh
  nonce-bearing results reached the real packaged KOReader `InputDialog:paintTo`
  path offscreen. The original demonstration still has
  `launcher-status=1`/`harvest-status=failed`; the accepted host-only correction
  does not relabel those facts.
- **Accepted persistent-note native UI:** the exact
  `pinenote/tools/book-state-reader/` packet is accepted at the offline native-UI
  fixture gate. Its `SHA256SUMS` manifest is
  `a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab`;
  review `doc/reviews/2026-09-06-book-state-reader-adversarial.md` has SHA-256
  `56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301`.
  The provided gate and independent 29-control, 38-stream, 32-UI, and
  14-cleanup checks passed. This is one in-memory Guile authority process, one
  real packaged KOReader process, and five UI generations—not fresh-process
  storage recovery, SQLite integration, QEMU/runsc/ARM, an operator run,
  physical rendering, or a durable end-to-end join.
- **Native state v1 independently reviewed and blocked:** an independently
  assembled source-only execution found no join-logic defect and passed 13
  factory assertions plus six fresh authority phases / twelve fresh
  Guile-or-Python book processes across real SQLite save, process restart,
  reopen, CAS, acknowledged receipt replay, namespace isolation, and a
  4,096-byte NUL reopen/second-commit path. Packet SHA-256:
  `02bd736c7dd6954837ab1053b2d91692d60a723a4ede5fb80499ce2d06bac777`;
  source manifest SHA-256:
  `42053ee2907648aac4334b75bf26cc19c63f11984128705963aeae43bcdd9ffe`;
  host log SHA-256:
  `23392544b6a1339b3548a19247ad1d74eec63fb7fb8c975cc1e0f96b97a2724d`.
  Review SHA-256:
  `16469cd08f246743caa4b0e3524cba3080cd75603fc84512f7f7a678f0998877`.
  NI-1 blocks exact-source executable acceptance because v1 does not seal every
  executed source, including the Python codec and live blocking-I/O source, and
  permits caller-chosen source identities. NI-2 corrects the scenario label:
  books consumed/presented the first receipt, so v1 proves acknowledged replay,
  not drop-before-ack/restart/retry. A separate close/commit race suppressed a
  late acknowledgement but never retried that operation, so it does not close
  NI-2. This does not establish accepted native integration or any KOReader,
  QEMU, runsc, ARM, or hardware result. The backend's separately accepted
  lost-ack process-crash tests remain unchanged.
- **Accepted trusted-native persistence join v2:** the successor closes NI-1
  and NI-2 at its own immutable snapshot. Independent review verifies the exact
  29-file roster and 25-source executable closure; source/shadow mutations are
  rejected without executing their canaries. A real adapter commit followed by
  an undelivered acknowledgement, EOF/process death, and a fresh-process exact
  retry returns the original receipt with unchanged version and receipt count.
  The 13 factory assertions, 12 retained book processes, three lost-ack book
  processes, and 4096-NUL paths pass. Review SHA-256:
  `928885be26b58469c9012848260035428ac2eb1494f47bc9a90f940df4777c51`;
  review packet `264bbfab85e4393322a6bba2051fe29f54be5958be3e50eb0c15e46888997224`;
  snapshot manifest `261b5f018af7c00afe8b3b8db81c42e14bd4efde85ac85a465a459f2ce89013f`.
  V1's blocked disposition and acknowledged-replay scope above remain historical
  facts. V2 is native book/session/SQLite evidence, not KOReader or sandboxed
  persistence. The joined reader is implemented separately under
  `pinenote/tools/book-state-reader-join/`, but its v1 review is blocked:
  restarted sessions reuse `note_s1_q1`, so a second new save after restart
  conflicts with the first receipt; a checked process-identity helper is later
  sourced from its mutable repository path. Independent review also confirms
  that UI clear-and-save is unsupported, despite storage-only present-empty
  recovery working. The supplied 12-lifecycle suite passes, but omits the
   ordinary second-save-after-restart case. The accepted v2 successor below
   corrects operation identity, exact helper loading, and real UI empty saves.
  Review SHA-256:
  `cf31edc06b2c057f3c2c6bfd280940559255301eb76934bf0f603abb06a39d6e`.
- **Accepted native persistent-note editor v2:** the reader-join successor
  closes both v1 findings and proves real UI clear/save. Independent replay
  passes 22 fresh lifecycles (66 unique, reaped process identities), both
  languages' restart/save version progression 1 → 2 → 3, present-empty recovery,
  4096-byte UI save/reopen, and exact retry without another commit. SQLite has
  nine namespaces and 13 receipts, integrity OK, no foreign-key violations.
  Review SHA-256 `15b0e535180540ef852a3f21895c56edbba7e32959cfc104120d4fe285c39aa5`;
  source manifest `6fcbb5b7b8766f5cbc8802ad84c4b28d500c5941b0f2dc6f871d4ec8976c82e0`.
  Runnable command: `make -C pinenote/tools/book-state-reader-join check`.
  Guest integration is now source work under `pinenote/tools/book-state-guest/`;
  the accepted editor remains native SDL-offscreen, not sandboxed or on glass.
- **Accepted durable-reader prerequisite:** the private completion observer under
  `pinenote/tools/book-state-integration/completion-observer/` is independently
  accepted at core source
  `0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f`.
  Independent checks pass 53/53 and replay both 37-assertion observer suites;
  queue exhaustion and callback failures produce no false completion or
  stranded worker. Review SHA-256:
  `e4f1ae002ba07268c825ddc24b02477ba259a16226ca5a1e42344a6fdd0286a5`.
  The frozen v1 native integration still lacks that API; the new reader join
  uses this separately accepted successor. A book `present` cannot substitute
  for a typed storage completion when issuing UI `commit-ok`.
- **Accepted host unit:** the descriptor-bound QEMU state-volume helper's v3
  review closes its pathname, fork, open-file-description identity, and JSON
  grammar findings. The independent focused probe passes 29/29 with descriptor
  counts restored (7→7). Review SHA-256:
  `e8dd85f44e9df080ecb37ad59df969e9e06da56d3178bcc4a59d2eacbeaa2383`.
  The subsequent paused-QEMU integration is now independently accepted too:
  actual post-exec OFD identity, `locking=on` contender rejection, normal/TERM/
  SIGKILL cleanup, foreign-root preservation, and post-reap reopening passed
  source-exact runtime checks. The checker-only successor closes its overly
  broad expected-failure exemption against unchanged runtime evidence. Review
  SHA-256 `0c23c2e61165759586779548b0f39fca217d51627e9f6db9d0c1315f5cbc0b68`;
  accepted checker `2619f166764f416b683268652a486a687227657086097156fea4513bab27f136`.
  Both immutable evidence sets pass 24/24, both 16-case mutation replays pass,
  and six independent checker checks pass. The guest stayed paused with `-S`;
  guest execution and semantic persistence remain integration obligations.
- **Guest/system successor v3 under review:** the new persistent guest selects
  the reusable `gvisor/source` AArch64 output `djgy782…` and the updated test
  kernel `334ljs8…`; the historical CONTROL runtime does not validate this new
  combination. BSG-1's FD-0/FD-3 socket alias is independently closed. BSG-2
  identified blocking cleanup outside the advertised deadline. V3 now declares
  a 300-second cooperative guest budget and requires an outer QEMU guardian
  with `--timeout-seconds 360 --term-grace-seconds 5`. Its 18 host liveness
  controls and 23 backend/bridge tests pass. Independent review closes BSG-2
  at the external guardian boundary, with 21 additional containment checks;
  actual two-boot runner binding remains pending. It also finds BSG-3: the
  frozen source view omits `gvisor-dependencies.scm`, `kernel.scm`, `base.scm`
  and the complete transitive system-input boundary, so its own static system
  check fails before derivation lowering. V4 preparation must include and hash
  those dependencies and replay from that exact view. Deadline/source-view
  review SHA-256:
  `f0cedbe6a6b44b37a03b663c7168d6880520ae6cd592427665756186fbc95db4`.
  V3 source manifest:
  `f6331a3d43f9c5be60aa630acc5eabb0eb99c50bea9f07708e3a9b595f38f0fb`;
  derivation `/gnu/store/nfd0492jbf77bxyp9il9hfv9ck74icgd-system.drv`.
  **V4 BSG-3 successor is now frozen for recheck:** it adds the complete
  19-module positive view and 89 hash-bound local-file assets. Supplied replay
  passes from the frozen packet with the working checkout and ambient `/tmp`
  hidden, including derivation and the 2,784-node requisite graph. Source
  manifest `7c71465c498449e96f63d943f392a2201cf6afad9b90e5ef110f9c1a46e77676`;
  source snapshot `fbc5903f08046440d4a3b4f2d802f17dd496b6e90d71ba37ae032a54cada6934`;
  evidence manifest `6c19a6abfbf6758d057fa49b8839183b5e767139687a5b1d9b120df9cd15821a`.
  The new derivation is
  `/gnu/store/qb9s3c1p4xwzfy0i6j2qn084rc2g4wf8-system.drv`: its embedded
  source manifest changed; system source, authority, FD adapter, kernel and
  gVisor remain unchanged. Independent BSG-3 and remaining guest/system review
  are pending. The original v3 source-view failure remains recorded.
  No persistent guest image or boot has been demonstrated.
- **Public persistence source lane accepted after startup cache correction:** the
  fresh-tree aggregate passes, but independent review executed an unlisted
  `guild.go` from caller `HOME` before private caches were installed. The
  correction must isolate caches before the first Guile tool invocation;
  later project-source authentication cannot close that earlier execution.
  Review SHA-256:
  `7739e982cebdaeea60c3924e4c7f973e4e183069dfda1560d6a2c9b93277e2e8`.
  The v2 startup-isolation correction is now frozen for independent recheck.
  Its supplied exact HOME-cache and XDG-cache regressions leave both canaries
  absent while legitimate Protocol execution succeeds. The sealed fresh-tree
  aggregate passes, including 22 native reader lifecycles; accepted functional
  source identities remain unchanged. Candidate source-map SHA-256:
  `b2b68cfcc0d060a10056dd91b956abbe7bdc0feeb130b183bbd60b2e50ec43a4`;
  evidence manifest:
  `efdc6ab1ecd13fdcc292835ede3359bb04f68c5b2ad5fe2f76de9bdc742d776e`.
  Independent v2 recheck is now accepted: both potent cache poisons were
  reproduced and neither executed through the repaired pipelines. Candidate,
  capsule, aggregate, retained-v1 replay and KOReader provenance verified.
  Final review SHA-256:
  `f43d955e8a866654288049e61e462821074dd412ff875ec3ca6c9ea1a802a1b0`.
  The source-map/capsule machinery otherwise reviewed cleanly. This lane
  resolves the ungrafted KOReader output `p9wkidd…`; it is the base of the
  historical two-graft `s48x0nh…` output, not byte-identical to it.
- **Public legacy-system conversion accepted after BEP-1 correction:** source-control,
  protocol-control and reader-interaction now select `gvisor/source`, with
  `gvisor/source-diagnostic` confined to the diagnostic system. The source-only
  gate lowers all four systems without the machine-local runtime wrapper.
  Its frozen review packet manifest is
  `e7237bc2f6cff3b2c9b20b3748ac7426b6ecbd7727dce8c1b9d6c92d2425649c`.
  These current definitions do not replace the runtime identity of historical
  v12 evidence. Independent review authenticated the source substitutions but
  loaded caller-cached Guile bytecode through direct `guix gc --requisites`
  calls outside the isolated time-machine environment. Fabricated dependency
  lists passed all four graph checks, so the v3 graph acceptance is blocked.
  A successor must isolate every Guix invocation before startup and repeat the
  graph checks against real store queries. Review SHA-256:
  `6dd4cbf21c166e041b39b0d5b23f2ee81e1324eebd391b22a80bdb32230d4a09`.
  The original packet and its failed review remain preserved.
  V4 is now frozen for independent recheck: all Guix entry points use the
  authenticated isolated launcher, and supplied HOME-cache, XDG-cache and
  compiled-load-path regressions leave their markers absent. Real graph pairs
  match for all four systems. The four system sources remain byte-identical to
  v3; the correction changes six source-gate files. V4 packet manifest:
  `2ee45158f8fea25bb52bc0447a3e7d41e5a76c25538c1537ca548602589d2ff3`.
  Independent v4 recheck now closes BEP-1: all four actual graphs reproduce
  byte-for-byte, caller-cache canaries remain absent before the checkers, and
  the original fabricated graphs reject. Acceptance covers source/package
  integration and authenticated derivation graphs, not runtime behavior.
  Final review SHA-256:
  `5b675a8917b5eb6abb7a7cbda244d86c2d55d745d1edf1a63ec1585eda43d357`.
- **Still absent:** a joined sandboxed durable reader, two fresh QEMU boots
  recovering only from the shared state disk, physical-power-loss proof,
  Workbench revision activation/rollback/export, general hostile-book
   qualification, or PineNote Book Computer acceptance.

### Two-boot runner source checkpoint

The source-only campaign under `pinenote/tools/book-state-qemu/two-boot/` is
frozen for independent review. Its supplied gate warning-compiles 23 Scheme
sources, passes 72 assertions, authenticates six accepted parent identities,
reproduces three exact successor patches, and rejects 15 evidence, timeout,
identity and mode mutations. The final source packet includes the corrected
checker-record staging path; no real payload execution has tested it yet.

Packet: `/tmp/opencode/book-state-qemu-two-boot-source-20260906-v1.inqv96up`;
manifest `bd27c96987ae17e0ee6315ea5a75dffd53c70f6b9fdcfcfc516a591faf231bf2`;
source manifest `427c334f7dc0932de73a6131902350815348524febd9d4cdd0f8ce01172b93fa`.
This is host-model evidence. Guest BSG-3, the image build/inspection, independent
runner review and actual two-boot execution remain open.

**Independent v1 disposition: rejected for real-run use.** The per-boot
`360/5` deadline binding, fail-stop sequencing, OFD/writer lifetime and final
checker staging pass the scoped review. Four blockers remain: campaign modules
execute before authentication and checked caller-owned helper paths can change
before use (BTQ-1); caller-supplied authorization hashes and in-bundle review
labels provide no independent artifact anchor (BTQ-2); an extra generic
`FAIL:` console line is accepted (BTQ-3); production wiring uses twelve
`module-set!` mutations/restorations rather than explicit hooks (BTQ-4).
The old guest-v3 identity also needs a reviewed v4 metadata successor (BTQ-5).
Review SHA-256:
`0a825f5ed151c6f03b97c41a227919e9a28891a35056af963d680f3a5b101560`.

A v2 correction is assigned. It must authenticate before module loading,
execute retained verified helper bytes, use an independently pinned artifact
binding, reject failure records and replace mutable module wiring with explicit
authenticated hooks. No real image binding is available yet; production launch
must refuse until the built and reviewed image receives its exact binding.
The original source packet and counterexample evidence remain unchanged.

## 2026-09-06: retain JSON; next slice is durable book state

**Later scope update:** the operator made the real device available on
2026-09-06. Read-only prerequisite inspection is recorded in `doc/status.md`:
os2 is reachable, but its running kernel has `CONFIG_USER_NS` disabled, so the
chosen sandbox cannot run on that kernel. The existing persistence implementation
and reviews continue host-side; deployment and reboot remain attended generation
steps. The earlier offline-only scope below describes the work up to this update.

**Base update completed at the frozen implementation checkpoint:** both fetched
remotes agreed on `549dded816e5f73d2c11557ffcd3130a018b82a8`, and the branch
fast-forwarded there from `50572d7796abdb0928969f4db8836fc5e30aeb58` (53 commits,
no branch-only commits). This brings in the display-driver lifetime and `/data`
kexec-remount fixes. The preflight found no upstream collisions with new lane
files. The changelog keeps our prototype entry alongside upstream's release
notes; `doc/status.md` keeps the read-only check above every intervening upstream
hardware record; `doc/upstream-register.md` merged cleanly. All three preserved
tracked edits were checked against the expected merged content, and all 449
recorded untracked code files remained byte-identical. No commit was created;
the index is empty and the lane changes remain uncommitted. Backup and merge
evidence: `/tmp/opencode/book-computer-base-update-20260906-3tjt1f0l/`, manifest
SHA-256 `ef6345189269cc233001cd9cfcb878977c5f99efc46cbe49dbf87dacf8e9d5f4`.
Frozen reviews continue to identify their original inputs. Existing QEMU kernel
identities remain historical evidence; a successor build inheriting the new
kernel package must establish its own derivation and validation.

**Rebased test kernel built; source gate accepted after v3 recheck.** The existing non-shipping
test package now builds the 15-patch base with `CONFIG_USER_NS=y` as output
`/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote`
(derivation `61ls988abhyi7lzvm19plffyv580nxc1`). Its Image SHA-256 is
`5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9`.
The local build took 830.7 seconds with two cores and one job. The builder's
static checks report an exact one-symbol config delta from the current base,
both PineNote DTBs, and AArch64 EBC, NEON-blit, and WS8100 modules. All 95 warning
lines are retained and classified in
`/tmp/opencode/book-state-rebased-kernel-20260906-CRE501/evidence/REPORT.md`.
A broad source preflight failed its baseline-deep DT assertion on the final
ultra-enabled source. Independent review validates the static artifact
properties but blocks QEMU use: the final-source checker wrongly forbids the
required ultra override, looks for `dt_state_override` in the wrong source
file, and has an activation mutation inconsistent with its required production
config. It also used the base config rather than the exact built test config.
The build continued after that failed gate; successful compilation does not
waive the failed ladder step. The original report's phase count is 24 while
the retained evidence proves 27; its NAR strings use Guix `base32`, not the
reported `nix-base32`. A checker-only correction and successor report are being
prepared, preserving the original records and artifact hashes. Review:
`doc/reviews/2026-09-06-book-state-rebased-kernel-adversarial.md`, SHA-256
`4fb66cbfb327607291b8060faffa5c1f9f2c47a5d80938bd43f70678f094c119`.
**Later v3 recheck:** RKQ-1, RKQ-2 and RKQ-3 are independently closed. The
corrected final-source gate binds the override to the proper suspend node and
requires DT restoration before policy use. Review SHA-256:
`8be8b931322b80a840eeb03c07e1228512af84f2e77c33ae9355fdc7402b03e2`.
All nine kernel artifact identities remain unchanged. This clears the source
gate for a separately scoped local QEMU boot, without a rebuild or PR-merge
prerequisite. The original red-preflight chronology remains preserved.
No new-kernel QEMU boot or device run has occurred.

**PR delivery requested:** the operator asked to open a pull request when this
work is ready. With the upstream base update complete, preserve the reviewed
source packets and historical evidence, finish the executable persistence
demonstration and its independent recheck,
and prepare explicitly staged, logical commits with a PR against GitHub `main`
from a topic branch. This request authorizes that eventual commit/push/PR
delivery; current in-progress work stays unstaged and uncommitted. The PR must
state which results are host, QEMU, or physical-device evidence and identify
remaining limitations. Hardware availability alone is not hardware acceptance.

The operator chose to retain JSON for now. The longer-term direction is an
explicitly modeled protocol: message types, permitted state transitions, and
ownership rules, rather than an increasingly permissive collection of JSON
objects. No wire-format replacement is underway. Display updates remain a
separate acknowledgement boundary; parsing latency has not been measured in
isolation from the rest of the interaction.

At the start of the 2026-09-06 persistence work, the next implementation slice
was defined as a small persistent text book. Its trusted Guile
host owns a per-instance state namespace and transactional save operation;
sandboxed code receives a capability, not a storage pathname. The first
acceptance scenario is edit, save, close, restart the book and supervisor, and
recover the acknowledged text. Interrupted writes and retries must have explicit
outcomes. A storage acknowledgement means the commit completed, independently
of whether KOReader has painted its confirmation.

That plan starts with bounded host-side storage and message/state-machine tests,
followed by the existing sandboxed reader path and a dedicated disposable QEMU
data disk for cross-boot evidence. Workbench revision creation and self-revision
follow this state slice. They are not established by the completed four-result
demonstration. The current status of those increments is summarized above; the
lane remains uncommitted and has made no device write or reboot.

### Accepted host persistence components

The first three persistence components have now passed independent review:

| Component | Accepted source SHA-256 | Evidence boundary |
|---|---|---|
| `pinenote/tools/book-state/book-state.scm` | `7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9` | Real SQLite files, fresh-process reopen, process-crash recovery, CAS, durable receipts, quotas, grant ownership and revocation; 92 Guile assertions plus the Python crash/restart scenario |
| `pinenote/tools/book-state-protocol/book-state-protocol.scm` | `425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257` | Seven fixed JSON message shapes and a single-pending-operation FSM, including the reviewed opaque session/binding identity predicate |
| `pinenote/tools/book-state-protocol/book-state-backend-adapter.scm` | `349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769` | Exact-source join to the accepted backend: 42 real-backend assertions and 19 independent lifecycle checks |

Review records are
`doc/reviews/2026-09-06-book-state-backend-adversarial.md`,
`doc/reviews/2026-09-06-book-state-protocol-adversarial.md`, and
`doc/reviews/2026-09-06-book-state-backend-adapter-adversarial.md`.
Their original blocked dispositions and counterexamples remain in the records;
the successor rechecks close those findings for these exact sources.

Storage uses pinned `guile-sqlite3@0.1.3` and SQLite 3.53.1, with `DELETE`
journaling and `synchronous=FULL`. The trusted endpoint owns its namespace and
opaque grant; books supply neither identities nor paths. Schema 1 stores an
optional UTF-8 text value of at most 4096 bytes. Missing state is version 0;
saving even an empty string produces a present value at version 1. State and
retry receipt commit in one transaction. Exact retries return the original
receipt, including after restart or a later save; changed-payload operation-ID
reuse rejects. Operation IDs use `[A-Za-z0-9_-]{1,128}`. This bounded first schema
retains 64 receipts per namespace without eviction, so it admits at most 64 new
commits per namespace; existing retries remain available at capacity.

The reviews caught and closed read-version regression, impossible conflict
metadata, incomplete SQLite schema validation, and mismatched session/grant
revocation. The backend now checks its complete known schema at open and inside
every write transaction. These are host process-crash and interface proofs,
not physical-power-loss evidence.

The trusted AArch64 SQLite binding prerequisite is also realized:
`/gnu/store/0c81pri4sf9sm16578hjp7di823l5m7y-guile-sqlite3-0.1.3`.
Pinned Guix lowering and realization used `--no-grafts --cores=2 --max-jobs=1`;
the output was already valid in the store, so this step compiled nothing.
Static inspection establishes the AArch64 SQLite FFI target and runtime ELF
dependencies. The 45-path sandbox language profile remains the same. Evidence:
`pinenote/tools/book-state/build/artifacts/aarch64-guile-sqlite3-0.1.3-20260906-v1/`,
manifest SHA-256
`20ec87ad8ae621e9af671667fba868bfb293a23f3863f01ba26643b852565a8e`.
Guest runtime loading is still unproven.

### Integration status

The optional Book Session storage-worker successor is independently accepted
for the real adapter/backend join. BSD-1 was a 5,120-byte response reservation
that could not hold a valid 4,096-byte NUL value's 24,666-byte JSON frame; its
completion exception left an active endpoint with a dead worker. The accepted
successor reserves the proven 24,681-byte worst-case frame bound and makes
completion failure atomically close the endpoint, with revocation and reap
outside the endpoint mutex. Independent replay delivered the original NUL frame
and a second read, verified encoder-failure cleanup and double-close behavior,
and passed 227 existing plus 61 focused assertions. Accepted identities:

- Core: `f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301`.
- Delegate: `eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6`.
- Full patch: `d779ed2c257d9fe0e995011e5a8c83ba9c6945b7eb189648067a29ed7a7d0280`.

The frozen packet is
`pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/`;
the review's successor disposition closes BSD-1 while retaining its failed
predecessor. The live Book Session source has not been replaced by this optional
successor.

The native book/session/backend integration against that pair produced a frozen
v1 packet and passing host log, then received a **blocked exact-source
executable-evidence disposition**. The reviewer independently assembled the
accepted inputs and observed the functional join pass with fresh Guile authority
processes and fresh native Guile/Python fixture books, including real SQLite
save/reopen/CAS, acknowledged receipt replay, namespace isolation, and the
4,096-byte NUL boundary through a fresh reopen and second commit. Deleted-database
recovery failed and swapped namespaces were caught, confirming backend
provenance. But NI-1 showed that the supplied runner does not seal all executed
sources or fixed expected identities; an unlisted Python codec could execute
while the suite stayed green. NI-2 showed that the alleged lost acknowledgement
had already been consumed and presented before replay. The exact hashes and
review identity are in the current snapshot above. A separate close/commit race
did suppress a late acknowledgement after endpoint close, but never retried that
operation. A successor must close NI-1 and execute a continuous
drop-before-ack/restart/retry scenario before native integration can be accepted.
V1 has no KOReader UI and does not make a book's later `<presented-text>` an
authority-observed commit receipt.

That missing trusted receipt observation is now an active, separately scoped
candidate under
`pinenote/tools/book-state-integration/completion-observer/`. The required seam
must expose the exact typed commit operation and committed/conflict/failed
response to trusted code only after the response enters the bounded output
queue, while binding endpoint/delegate/generation identity and clearing on
close/restart. It must not add a book/private-UI wire field or let the outer
authority bypass the book by calling the backend directly.

The NI-1/NI-2 successor work belongs under
`pinenote/tools/book-state-integration/` and is distinct from that completion
observer. Fixing either unit cannot substitute for independently reviewing the
other.

The persistent-note KOReader successor is independently accepted at its exact
offline native-UI fixture boundary. Its five-generation
load/edit/fail/save/reopen sequence uses one in-memory Guile authority process
and one real packaged KOReader process. The accepted tests preserve stale
receipt rejection after new edits and keep `commit-ok`, later `present`, and
inherited topmost `paintTo` as distinct facts. They establish neither
fresh-process SQLite recovery nor the missing trusted typed receipt observer.
The accepted packet-manifest and review hashes, check counts, and explicit
non-claims are in the current snapshot above.

The older 64 MiB ext4 helper snapshot remains blocked by the identity, thread
exclusion, mode, JSON-graph, and cleanup findings in
`doc/reviews/2026-09-06-book-state-qemu-volume-adversarial.md`. Current observed
source addresses those findings with descriptor-bound `/proc/self/fd/N`
handoff, synchronized writer ownership, explicit modes, structural graph
validation, and quarantine cleanup, but its successor re-review is still
pending. The pathname-based proposal in
`doc/reviews/2026-09-06-book-state-qemu-seam-design.md` is historical, not the
current candidate design.

The remaining end-to-end persistence gate is two fresh QEMU boots sharing only
that owned state disk, with real native UI/receipt evidence and no recovered
text supplied through argv, environment, or a fixture oracle. No sandboxed
save/reopen or cross-boot persistence result is claimed yet.

## 2026-09-05: reusable gVisor source packaging is an explicit deliverable

The operator explicitly expanded the scope: maintain a reusable Guix source
package for gVisor, useful beyond the book runtime and able to carry reviewed
patches. This supersedes the earlier decision to defer source packaging as a
separate project. It does not change runtime isolation policy or establish that
the current QEMU-only Systrap failure requires a PineNote compatibility patch.

- Keep `pinenote/packages/gvisor.scm`'s upstream `gvisor-bin` reference intact.
- Develop the source package separately; runtime/network/kernel policy belongs
  to callers, not the reusable package. Native and AArch64 build support must
  have separate evidence, not inferred support declarations.
- The current network-enabled Bazel control/diagnostic build is bootstrap
  discovery, not yet a networkless Guix source package. Turn its dependencies
  into declared content-addressed inputs; a lockfile or warm user cache alone
  does not establish closure completeness.
- Distinguish gVisor built from source using binary bootstrap tools from a
  toolchain built entirely from source. Record bootstrap provenance explicitly.
- Acceptance requires a fresh-cache, network-disabled package build, matching
  helper identities, practical host tests, and independent adversarial review.
  Diagnostic patches stay explicit variants until justified for the base.
- Separate package ownership from the running diagnostic build; do not restart
  that build, mutate its inputs, or duplicate expensive compilation in parallel.

No source package is claimed complete by this decision. No hardware, deployment,
shipping-default, commit, or push authorization is added.

The source-inventory and fixed-input release-target analysis gates are now
independently accepted. The latter passes 13 inventory and 22 vendor tests,
native and AArch64 zero-action replays, and measured network-namespace checks.
Accepted vendor output NAR:
`1sfan3bnkkx7cd6ih9ldkdgr6cprnnzbnfmxs48wck7ik8180ss1`; review:
`doc/reviews/2026-09-05-gvisor-vendor-inputs-adversarial.md`, SHA-256
`6229256c7b96c91febf3911a92c7aa37a54010f582f24d1ac4745dacdd5ea484`.
This is not compilation evidence. The next assigned increment is the dedicated
source-built runtime package, beginning with native x86_64 compilation, with
expensive build scheduling separate from the ARM64 diagnostic lane.

## Corrected CONTROL functional compatibility — 2026-09-05

The reviewed corrected-CONTROL image received one separate execution
authorization and passed the frozen outer checker:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
RUN-STATUS=0 CHECKER-STATUS=0
```

This is the first real ARM64 gVisor/Systrap functional compatibility result for
both fixed Guile and Python payloads. It used the 7.1.8 USER_NS-only test kernel,
QEMU TCG with `-cpu max` and no NIC, `isolation-userns`, Systrap,
`--directfs=false`, `--network=none`, strict sidecar/release enforcement, and
the unpatched source-built CONTROL artifact with `STABLE_VERSION`
`release-20260831.0`. It did not use the diagnostic Sentry or the reusable Guix
`gvisor-source` package. Preserved evidence is under
`pinenote/tools/book-execution-spike/build/corrected-control-runtime-evidence-20260905-v1/`;
the accepted two-line summary has SHA-256
`bff1228fac510ef01209b530446d6190fa352baa15fbc67781aeaa194760a43a`.
The success console was not exported by the runner, so individual payload
sentinels are not claimed as separately retained evidence.

The result confirms the EFBIG attribution and harness correction. The
supervisor no longer imposes a process-wide 4 MiB `RLIMIT_FSIZE`; parent-owned
stdout/stderr captures and separate finite debug/panic stores provide the
bounds instead, while the OCI payload keeps its 1 MiB limit. No gVisor, kernel,
CPU-model, or runtime-policy patch was needed. This is not Book Protocol FD
donation, general-book execution, isolation acceptance, reader integration, or
hardware evidence.

## Next narrow seam: Book Protocol FD donation

Pinned-source inspection resolves the CLI question without guessing. At gVisor
commit `fd2f6b2674208086e324c2f739155eb7e1b48ff2`, the public `run` command uses
`--pass-fd=HOST_FD:GUEST_FD`; the first fixture mapping is exactly
`--pass-fd=3:3`. `runsc/cmd/run.go` keys the caller's file by guest FD, the
internal donation layer passes it to Sentry, and `runsc/boot/loader.go` imports
it into the application FD table. There is no public `--preserve-fds` seam at
this pin.

The host-only implementation is isolated under
`pinenote/tools/book-execution-spike/protocol-fixture/`. One Guile authority
creates two accepted Book Session endpoints and owns two synchronous child
process groups. Each child receives only its own CLOEXEC socket peer, moved to
host FD 3 and explicitly made inheritable for the one runsc exec; all unrelated
descriptors are closed. Each fixed Guile/Python book accepts only
`BOOK_SESSION_FD=3` and completes `hello -> initialize -> action -> present`.
Results cross only that FD; child stdout/stderr are `/dev/null`, not a protocol
or identity channel. Distinct actions/results make endpoint crossing fail. The
host has a whole-fixture deadlock guard but creates no detached thread and does
not call `expire-request!`; request timers remain deferred.

The read-only pinned-source check and three host tests pass. They verify the
exact source commit/hashes and M:N mapping, frozen protocol/session hashes,
complete runtime-policy argv, only FDs 0–3 at the fake runsc boundary, FD 3 as a
non-CLOEXEC socket, both real native language peers, and exact owned-child
cleanup. The fake executable validates the proposed boundary and never invokes
runsc. No QEMU, ARM payload, image/kernel/gVisor build, or hardware operation is
part of this evidence.

The minimum future closure change is also bounded. The existing 45-path sandbox
language closure already supplies Guile 3.0.9, guile-json 4.7.3, and Python
3.12.12. The trusted supervisor profile must add guile-gcrypt 0.5.0 for the
accepted Book Session authority. Separately hash-pinned module/source outputs
must provide the accepted session/protocol code and only the selected fixed book
inside each OCI root; `BOOK_SESSION_FD=3` belongs in each process environment.
This needs a new reviewed generator/launcher, not edits to frozen
`oci-bundle.scm` or `guest-smoke.scm`. It must retain USER_NS, Systrap,
`isolation-userns`, `--directfs=false`, no network, strict sidecars/release,
cgroups, payload limits, bounded diagnostics, and runsc process/state cleanup.
No TCP, host 9p share, console protocol, diagnostic Sentry, or fallback is
introduced. A future reader-private path requires a separately reviewed
virtio-serial design.

Stage 1 is independently accepted. Review SHA-256
`ab164146dfe1b769dcb4bfd5dfa8b57c59ab775967d962e565d50b876653cf34`
identifies the historical report snapshot at acceptance, not the current
append-only `doc/reviews/2026-09-05-book-protocol-fd-adversarial.md`. Machine
gates pin the reviewed Stage-1 source roster instead of the mutable report. The
reviewed host fixture remains frozen. Its one caveat becomes an explicit Stage-2
ordering gate: actual guest PASS must follow endpoint release, owned runsc-group
reap, cgroup/state cleanup, and verified diagnostic-store unmount.

The separate actual-guest **source** implementation is independently accepted
as the bounded Stage-2 candidate; it is not built or runtime-proven. New files
include the fixed
`oci-book-bundle.scm`, `guest-book-protocol.scm`, two silent book entrypoints,
the protocol-control system, and host/static gates documented under
`pinenote/tools/book-execution-spike/protocol-guest/`. The proposed system
inherits the accepted USER_NS kernel and complete unpatched CONTROL package. It
retains the exact 45-path sandbox language closure and adds guile-gcrypt 0.5.0
only to a new trusted supervisor profile. Accepted protocol/session sources and
the two book sources become separately hash-pinned immutable outputs; each OCI
root mounts only its own fixed entrypoint and required codec files read-only.

The Guile authority first re-hashes every trusted/session/codec/book source,
its separately pinned own source, and the exact accepted 45-path closure. It
then runs the two bundles sequentially with exactly `--pass-fd=3:3`. Each book
handles two fresh strong-random nonce-bearing inputs and returns a
language-defined computed value through the accepted session endpoint; no book
stdout/stderr or zero exit is a result oracle. The success path releases
the endpoint, reaps the exact runsc group, checks the cgroup absent, deletes the
empty runsc state root, verifies capture/store bounds, returns through verified
debug/panic unmount, and only then emits the language marker. The final marker
follows both such paths. A 360-second supervisor-owned whole-run deadline is the
only new timer; request expiry remains deferred.

`make -C pinenote/tools/book-execution-spike/protocol-guest check` passes the
pinned-source seam, immutable inventory, two S2-1 review-drift regressions, 18
host tests, and 18 non-realizing Guix system checks. Host tests include real
native Guile/Python peers behind a strict fake runtime, crossed endpoints, an
extra donated-socket descriptor, malformed/stale/truncated-close inputs, 4 MiB
capture overflow, and TERM/KILL deadline cleanup. Fake mode is structurally
unable to emit actual-guest PASS markers. No `runsc`, QEMU, ARM payload,
image/Bazel/kernel build, hardware, staging, or deployment occurred. The frozen
v1 image recipe is retained as the blocked S2-1 record because it hashes the
mutable whole review. The authorized v2 replacement passed every source and
static gate but failed before an image derivation: build-command `-L .` made
pinned Guix recursively discover repository Scheme files as package modules,
including a historical generated guest launcher under `build/`, whose
guest-root preflight executed on the host. No realization followed.

The proposed v3 repair changes no Stage-2 runtime source. It supplies an exact
19-module symlink view through `GUILE_LOAD_PATH` for ordinary module resolution
and gives build-command `-L` a separately verified directory containing zero
Scheme files. This distinction is required because pinned Guix adds `-L` to
both `%load-path` and `%package-module-path`, invalidates the package cache, then
recursively loads every `.scm` found in that package path. A non-realizing image
dry-run with an excluded generated sentinel proved the broad path executes the
sentinel while the split paths do not. The caller's compiled load path was also
set empty; a later focused check below showed that this alone does not suppress
Guile's separate source-name auto-compile cache. The same check
forced all 57 relative `local-file` objects reachable from the module view—the
accepted protocol sources, CONTROL/diagnostic wrapper inputs, firmware tool
sources, and 14 kernel patches—to their original paths; the dry-run listed only
the new protocol/system/image derivations and no kernel or gVisor rebuild. V3
still requires focused review and separate image-build authorization.

## First Book Protocol runtime failed at the teardown gate — 2026-09-05

The historical protocol image was subsequently assembled, independently bound,
and admitted to exactly one reviewed QEMU run. That run is a **full-gate
failure**, not protocol acceptance:

```text
BOOKEXEC-PROTOCOL-FAIL book-execution-protocol-integration-error ("runtime left state entries for wilkbook-guile-book-protocol")
RUN-STATUS=1 CHECKER-STATUS=1
```

It did not produce the required
`OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS` line. The
authorization is consumed and the launcher must not be reused. Retained evidence
is `protocol-control-runtime-evidence-v1.7akVje.log`, SHA-256
`8f216c5e59512331fad79ecf0532d16134b2722101372c540387770a134f6026`;
the mode-0400 wrapper copy records the two status values above.

The failure boundary nevertheless proves one narrower semantic result. In the
frozen adapter, the strict state check is reachable only after the Guile peer
has returned both exact nonce-dependent presentations through its private Book
Session endpoint, reached the exact closed endpoint state, exited zero, had its
endpoint released and runsc group reaped, and passed bounded capture checks.
The retained run reached that state assertion with runsc, application, and gofer
exit zero and the cgroup absent. Therefore the actual ARM64/Systrap Guile book
received FD 3 and completed both presentations. The Guile language PASS marker
was correctly withheld because teardown was incomplete; Python never started.
This distinction does not establish two-language FD donation or full cleanup.

The exact residual entry was not captured: the old diagnostic recorded only
`runtime-state=present`, and the private overlay was destroyed. Pinned source
provides a strong, bounded explanation. `--gofer-network-namespace` defaults to
`null`; an empty shared root defaults to `--root`; and the first gofer bind-mounts
its new empty network namespace at `null-netns`. Ordinary attached `run`
destruction removes `.state`, `.lock`, and the sandbox control socket but not
that shared namespace pin. Thus `null-netns` is the expected and overwhelmingly
likely survivor, **not a measured filename**, and the evidence cannot prove that
no additional entry existed. The immutable evidence/source boundary is recorded
in `protocol-control-runtime-failure-analysis-v1.txt`, SHA-256
`768dc48020fde6ba0e1272ad0449790dfa24daa49b345b8d5469abd9b9dcd730`.

The first null-netns correction (`2d5fd259…`, v7) is preserved but rejected for
image assembly. A private-namespace review reproduced an unexpected self-bind
at the exact `runsc-state` root: because that bind preserves directory identity,
v7 unmounted the valid pin and unlinked the exact placeholder before `rmdir`
failed with `EBUSY`. It failed closed but did not preserve all evidence.

The successor remains narrow: it adds no delay, retry, lock exception,
recursive deletion, runtime flag change, or new broker. Before runsc it verifies
and retains the private state root's identity and creates the exact mode-0444
`null-netns` placeholder with `O_EXCL`. After endpoint/process/capture cleanup,
it emits a bounded non-following roster: at most four entries, two mount records
per entry, and two mount records for the exact root. Every mount line is clipped
to 2,048 source bytes before escaping; the new root roster therefore contributes
less than 17 KiB at worst, within the outer runner's existing 2 MiB console
framing/boot headroom.

Cleanup first requires cgroup absence and zero mounts at the unchanged exact
root, then requires exactly one entry and one internally consistent `nsfs`
`net:[inode]` pin distinct from the authority's network namespace. It invokes
an ordinary non-lazy unmount only on that pin, then rechecks that the root still
has zero mounts immediately before the first unlink. Only then may it verify
and unlink the original placeholder, prove the root empty, remove it, and prove
it absent. An already unmounted placeholder is rejected and preserved rather
than silently accepted. Unknown entries, `.state`, `.lock`, sockets, symlinks,
replaced roots/files, root mounts, wrong namespace types, authority-namespace
pins, stacked mounts, and unmount failure all remain fatal and cannot emit PASS.
The two root observations enforce controlled fixture ownership; they do not
claim to prevent arbitrary concurrent privileged host mount races.

The current cheap gate passes the pinned FD seam and null-netns source lifecycle,
the frozen inventories, 2 review-drift tests, 38 host tests, and 18 static Guix
system checks. Its positive mount test performs the pin lifecycle only inside a
throwaway unprivileged user/mount/network namespace. A real root-self-bind
negative proves rejection before the pin-cleanup marker and verifies the root
mount, pin mount, and underlying placeholder were preserved before test-owned
cleanup. A deterministic second negative inserts a root bind immediately after
the permitted pin unmount and proves the pre-unlink recheck preserves the
revealed placeholder. Negative mounts never alter the parent mount namespace.
The strict v4 discovery check separately verifies
the 19-module `GUILE_LOAD_PATH`, zero-Scheme `-L` package view, all relative
`local-file` identities, and the three inherited system deltas. It also fixes
`HOME` and `XDG_CACHE_HOME` to `/nonexistent`: an earlier preserved check showed
that empty `GUILE_LOAD_COMPILED_PATH` alone still let Guile consult the user's
source-name ccache. No current strict-check log contains that lookup.

V7 remains immutable historical evidence for the rejected adapter. V8 retained
the complete six-file unpatched CONTROL release, `release-20260831.0`, the
45-path guest closure, USER_NS/Systrap/isolation-userns, `--directfs=false`,
`--network=none`, `--host-uds=none`, cgroups, strict sidecars, the 1 MiB OCI file
limit, finite stores and captures, and exactly `run --pass-fd=3:3`. It was later
source-reviewed, assembled, image-bound, and admitted to one separately
authorized successor run, whose outcome is recorded below. V7 and every
consumed historical launcher remain prohibited.

## Successor Book Protocol guest chain observed; host checker fix pending — 2026-09-06

The accepted V8 successor ran once under the reviewed 600-second TCG/QEMU gate.
Its immutable wrapper still reports the original command result accurately:

```text
RUN-STATUS=1 CHECKER-STATUS=1
```

No outer status-zero line exists, and this result is not being relabeled. The
retained full failure frame is
`protocol-control-root-mount-runtime-evidence-v2.OMSobe.log`, SHA-256
`5bfcd98425f0d3e554a343e89775d2ba2f56212ac21753bc15a6542c5818e378`.
An exact single-pass inverse of the accepted outer emitter recovered all 25,120
declared bytes with no elision; the raw console SHA-256 is
`171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3`.
Re-encoding reproduced the retained content region byte for byte. Independent
attribution and image review are recorded in
`doc/reviews/2026-09-06-book-protocol-successor-image-adversarial.md`, SHA-256
`2e60bd2fc0a792dcf03f18ee33b47525b299f885f86955a39c700715429f8e71`.

The recovered console is the first actual ARM64/gVisor evidence for **both**
fixed Book Protocol language exchanges through FD 3. Guile and Python each
reached their language PASS after both nonce-dependent presentations, endpoint
release, zero-exit runsc/group reap, bounded capture drain, cgroup absence,
exact runtime-state cleanup, non-overflowing diagnostic-store summaries, and
verified store unmount. Unlike the historical first run, `null-netns` is now
observed rather than inferred: each language reports one mode-0444 regular
placeholder, one `nsfs` `net:[4026532133]` mount, zero mounts on the state root,
and `action=nonlazy-unmount`. The cgroup teardown and overall protocol markers
then precede clean kernel power-down.

The host failure is narrower. The immutable checker used by the run expected
the shortened store labels `debug` and `panic`, while the frozen FINAL2 emitter
and actual console use `runsc-debug` and `runsc-panic`. Changing exactly those
four checker literals makes the unchanged raw console pass both the semantic
checker and clean-power-down bridge. The correction adds emitter-derived
positive fixtures and missing, reordered, duplicate, overflow, limit, and wrong-
label negatives; a bounded fail-closed extractor regression also checks the
independently derived raw-console hash. Author-side offline replay is green, but
the corrected-checker packet still requires focused independent review before
the host checker gate is closed. The original status remains 1/1 regardless of
that review. No QEMU rerun is authorized or needed for this four-literal host
oracle defect.

This functional result remains limited to the exact trusted Guile/Python books,
authority, image, and cleanup path. It is not hostile-book qualification, a
general transport or output-import implementation, persistence, timer or
cancellation acceptance, reader integration, hardware evidence, or release
acceptance.

## Native-reader interaction seam is source-ready for review — 2026-09-06

The next source-only candidate now joins the accepted Book Protocol guest path
to the separately implemented pinned native KOReader interaction fixture. It
follows
`doc/reviews/2026-09-06-book-interaction-qemu-seam-design.md` without changing
the accepted automatic guest adapter, protocol-control system, or disposable
QEMU runner.

The guest successor inherits the V8 protocol-control system and replaces only
its one-shot authority and source/build manifests. Guest Guile owns the fixed
Guile-then-Python order, fresh nonce actions, Book Session endpoints, commit
validation, exact runsc groups, and cleanup. A bounded nonblocking adapter opens
only the udev-created character path
`/dev/virtio-ports/org.wilkbook.book-interaction`, keeps it `FD_CLOEXEC`, and
never donates it to runsc. Sandboxed books retain only their own Unix socket at
FD 3 through the accepted exact `run --pass-fd=3:3` invocation.

The host successor makes the fixed lifetime-only coordinator the direct child
of the existing process guardian. QEMU and KOReader remain in that process
group. The QEMU delta is exactly one private socket chardev with no logfile,
one virtio-serial controller, and one named port; the no-NIC/no-share graph is
unchanged. Final source-level success requires the coordinator's exact native
lifecycle line, the strict guest nonce/cleanup chain, and clean power-down.

Host-only tests currently pass for the character adapter, actual fixed native
Guile/Python books behind fake runsc, four nonce-derived presentations, routing
and malformed/disconnect cleanup, strict console ordering and labels, the exact
QEMU/coordinator argv, and joined outer cleanup with fake children. The outer
cases create an actual Unix socket node plus `reader-ui` artifacts, retain
PID/start-time identities, and prove normal/failure/TERM/timeout/owner-`SIGKILL`
cleanup of the shared process group before identity-safe root removal. A
replacement-inode negative preserves both the foreign root and the renamed
owned evidence while forcing the joined result nonzero. The production entry
also binds the exact independently reviewed
`s48x…-koreader-bin-2026.03` output. The 20-module Guix view exposes the
accepted 19-module v4 roster plus only the new reader system; package discovery
has zero Scheme files. Strict Guix checks retain all inherited local-file
origins and the three added trusted sources.

No image was realized. Derivation-only evaluation yielded distinct system
derivations—`dj6s…-system.drv` for protocol control and
`mrvx…-system.drv` for reader interaction—but both contain the exact same
`89md…-raw-initrd.drv`. Their derivation build-closure rosters are 2,549 and
2,558 paths, with 18 removed and 27 added; the new-only entries are the expected
source, manifest, Shepherd, boot, activation, and system derivation objects,
not a new package. These are build-closure calculations, not realized runtime
system rosters.

This is a candidate for independent source/static review only. No QEMU, runsc,
ARM code, guest image, kernel build, hardware, deployment, commit, or push was
used. Actual virtio disconnect-to-guest-EOF propagation remains explicitly
unproven, as do the named device's appearance and the joined native/ARM result.
A future QEMU attempt still requires image review and a new one-use
authorization; no consumed launcher may be reused.

## Native-reader QEMU demonstration observed — 2026-09-06

That one-use attempt has now run. In about 31 seconds, the AArch64 guest ran the
two fixed Guile actions and then the two fixed Python actions under gVisor; its
authority relayed all four fresh nonce-bearing results to the pinned native
KOReader v2026.03. The real topmost `InputDialog` inherited `paintTo` path
observed every exact value before `applied`. KOReader then proved its one-action,
one-dialog, source/FD/callback cleanup, the guest proved both language and
cgroup cleanup plus UI EOF, QEMU powered down, and the coordinator reaped both
children. The outer identity-safe run root is empty.

The original run remains truthfully `launcher-status=1` and
`harvest-status=failed`: its host checker required a bare `reboot: Power down`,
while Linux emitted the canonical timestamped
`[   30.381268] reboot: Power down`. A host-only correction now matches either
the exact bare line or one structurally canonical printk timestamp plus the
exact payload; cardinality, final ordering, and every other marker remain
strict. Focused adversarial tests and a full replay over all six immutable logs
pass without rerunning QEMU. Independent review now accepts the functional
demonstration, corrected checker, and fixed-evidence offline gate
(`doc/reviews/2026-09-06-book-interaction-qemu-image-adversarial.md`, SHA-256
`64bb3cb11a1125147b708bc0883b33e924e1d84da80ea08edd0fd6778d120ed2`).
The original exit status is not relabeled.

The concrete result, all four values, evidence hashes, chain, and non-claims are
in `doc/book-computer-demo.md`. This is real offscreen KOReader behavior, not a
PNG or physical-glass result, and it remains the fixed-book fixture rather than
a durable general Workbench.

## Matched diagnostic result — 2026-09-05

The independently accepted source-built control reproduced the v5 line-219
panic, including all 19 normalized gVisor call-chain records. The matched
diagnostic run then exposed the underlying operation:

```text
allocate syscall-thread message length=0x2000:
truncate MemoryFile backing old-size=0x0 new-size=0x40000000:
truncate systrap-memory: file too large
```

Retained transcript: `/tmp/opencode/wilkbook-qemu-diagnostic.Q34tp4.log`,
SHA-256 `9ac39e291ce4b6de468cd2ad46f2c18387e4ea1b29a559419115fa1ad3ab15b9`.
The diagnostic guest smoke launcher imposed a 4 MiB process-wide
`RLIMIT_FSIZE` before executing runsc. Independent source analysis and a
bounded host reproduction established its inheritance into Sentry as the cause
of the failed 1 GiB backing-file extension. The focused correction removes that
host limit, retains parent-drained 4 MiB stdout/stderr caps, and puts direct
debug and panic files on separate pre-mounted finite tmpfs stores (4 MiB/10
files and 1 MiB/2 files respectively). The OCI payload's own 1 MiB file limit
is unchanged. No
fixed-address mapping was reached in this failure, and no payload succeeded in
that diagnostic run. The later corrected CONTROL run passed as recorded above;
the diagnostic result itself justified no kernel, CPU-model, or runtime-policy
change.

Independent attribution is now accepted: the inherited host `RLIMIT_FSIZE`
causes `ftruncate(systrap-memory, 1 GiB)` to return `EFBIG` (27). A bounded host
control reproduced successful truncation without that limit and `EFBIG` at
4 MiB. The initial 8 KiB request rounds to a 1 GiB backing chunk before any
address mapping, so the 52-bit-address, CPU-model, and ptrace hypotheses do not
explain this failure. Current review SHA-256:
`91985cd58f76434805a6ff43f05b7ffa17dc1b06f8c3ad6230c80376230bbf97`.
The required correction bounds stdout/stderr/debug/panic sinks without a finite
file-size limit inherited by runsc or its helpers. Payload limits stay intact.
That requirement was subsequently met by the corrected CONTROL run above using
the existing gVisor and kernel binaries.

## Isolation from release work

- Branch: `book-computer`, forked from
  `50572d7796abdb0928969f4db8836fc5e30aeb58` (`prealpha-candidate`).
- Initial worktree: `/tmp/opencode/wilkbook-book-computer`.
- The architecture draft was untracked in the release checkout; it was copied
  without changing or staging the original.
- No device access: no SSH oracle, UART, deployment, or hardware diagnostics.
- Shipping flavors and reader defaults remain unchanged. Experiments are opt-in.
- VM disks, sockets, logs, and build outputs must be local to this lane. Do not
  reuse another session's writable rootfs or running VM. Bound expensive builds;
  the shared Guix store does not isolate CPU, memory, or disk consumption.
- Bring release fixes into this branch deliberately; record the tested baseline
  again when it changes. Do not rewrite the release session's history.

## Decisions from the implementation discussion

1. Assume gVisor is viable on PineNote; do not make hardware qualification a
   prerequisite for developing the book system. ARM64 QEMU with Systrap is the
   initial integrated execution target. Actual compatibility remains a test.
2. Keep one concrete gVisor supervisor, not a generic runtime framework. It owns
   execution identity, private channel establishment, whole-domain termination,
   and exit/resource observations. Request cancellation is not forced termination.
3. Books use language-appropriate Wilkbook libraries over a shared message
   contract. They never configure the launcher or receive its control channel.
4. Capabilities belong in the first interaction, not a later security retrofit.
   Connection ownership establishes caller identity; requested permission strings
   and self-asserted book identities are not grants.
5. Signed configuration books are a future consumer of the same capabilities.
   Signatures establish provenance/integrity; host policy grants specific
   configuration operations through the existing configuration machinery.
6. Conventional containers are a possible deliberate fallback, not an equivalent
   security claim or an automatic response to gVisor startup failure. Requalify
   the execution profile if that decision is taken.
7. **Trusted runtime language: Guile** (operator decision after the first
   session-reference increment, 2026-09-04). Broker/session capabilities,
   durable-state operations, and gVisor supervision belong in Guile, matching
   Guix/Shepherd integration and its process/scripting facilities. The trusted
   KOReader bridge remains Lua. Python is a sandboxed book language and may
   serve as an independent host-test oracle; it is not the production broker
   or supervisor. The initial Python session/OCI references are being ported,
   with their tests retained rather than treating the prototypes as production
   language commitments. Earlier Python review acceptance applies only to the
   reviewed reference, not automatically to the Guile replacement.
8. Use the pinned Guix and Shepherd sources as concrete Guile style and
   supervision references (`herd` is Shepherd's client). Prefer established
   record/module conventions, explicit argv/environment handling, descriptor
   ownership, and exception-safe cleanup. Cite the relevant source when adopting
   a pattern; do not add a daemon framework solely for resemblance, or treat
   source precedent as proof of our authority/lifetime guarantees.

## First integrated acceptance target

In an ARM64 QEMU system, explicitly activate a sample tool-book. Enter a value
in a generic KOReader panel; a program running under gVisor/Systrap receives the
action through its Wilkbook library, updates the delegated panel, and saves
scoped state. Repeat with Guile and Python without language-specific trusted
host changes. Reopen after worker/reader restart and recover acknowledged state.

Negative cases are part of this target:

- Closing/reflowing the view invalidates old presentation generations.
- An unrelated session cannot use the original session's handles.
- Malformed/oversized input is rejected with bounded host work.
- Cancellation rejects late results, even if the program ignores cancellation.
- Forced termination leaves no live execution descendants.
- Restart does not revive old handles or silently activate book code.

The host knows fields, actions, resources, and surfaces, not exercises or logic.
The first panel is attached interaction, not live insertion into crengine layout.

## Small increments and evidence

### A. Host protocol reference harness

Start with bounded incremental framing and adversarial tests. This is executable
input to the eventual two-language contract, not a final broker-language choice.
Keep the prototype isolated under `pinenote/tools/book-protocol/`.

First host gate (2026-09-04): `make -C pinenote/tools/book-protocol check`
passes 28 tests after review. The reference codec uses a four-byte big-endian
length, at most 64 KiB of UTF-8 JSON per frame, and container depth at most 16.
It rejects duplicate keys, invalid Unicode, non-finite/unsafe numbers, truncated
frames, and further input after a protocol error. Valid JSON surrogate pairs
are accepted, including output from ASCII-escaping language libraries. These
are prototype limits, not a frozen profile. That initial gate exercised no
socket, capability enforcement, Guile codec, renderer, or sandbox.

The next increment adds a Guile/`guile-json` codec and a separate blocking port
adapter. The same `make ... check` command now uses the pinned Guix environment:
31 Python unittest cases (including two real Python/Guile socketpair cases) and
34 Guile SRFI-64 checks pass. Protocol traffic uses an inherited descriptor,
with captured stdout kept separate. A decimal exponent magnitude limit of 1000
is now shared across codecs. This remains host-only conformance scaffolding,
not asynchronous broker integration. Independent adversarial reviews of Python
lifecycle and Guile/cross-language parsing gate acceptance; green supplied tests
do not constitute acceptance of their security claims.

The [first adversarial review](reviews/2026-09-04-book-protocol-adversarial.md)
requested changes before asynchronous message integration: an unstarted Python
feed iterator can permit chunk reordering, silent discard, or premature EOF.
It also found needless large-number conversion work and post-serialization-only
encoder size enforcement. Fixes and regression tests are in progress, to be
rechecked independently. Numeric identity rules are a schema obligation, not
something the generic JSON codec currently enforces: opaque handles/IDs will
be strings; numeric generations/counts require type-strict safe integers,
excluding booleans and inexact aliases. JSON framing is not canonical signing
or revision-identity serialization.

Python recheck outcome: the original reproductions are fixed. A further
copyable-iterator ownership defect was fixed by making both stream owners
non-copyable/non-serializable, then independently checked across copy/deepcopy
and pickle protocols 0–5. The reviewer accepts Python framing for its supported
public API, with 40 Python-only tests passing. This does not accept Guile,
broker schemas, or aggregate transport limits. A small reference session
contract is now implemented under `pinenote/tools/book-session/` to test
connection-owned surface grants, strict integer generations, and cancellation;
16 pinned unittest methods pass, including real socketpair framing and raw
numeric-schema vectors. Independent authority/lifecycle review is underway.
It supplies no sandbox, Guile session-schema, or persistence guarantee.

The subsequent Guile port implements the trusted session authority in
`pinenote/tools/book-session/book-session.scm`, leaving both accepted codecs and
the Python sequential oracle unchanged. Its reported pinned gate passes 125
Guile assertions plus the 16 Python oracle methods. New tests cover private
port-owned bindings, lexical evidence for the four integer fields, mutex-
serialized transitions, allocation failure atomicity, two-socket forgery,
restart and numeric FD reuse. Five bounded reruns passed. Fresh independent
Guile authority review is underway; this is not yet accepted broker integration
or a timer, transport-budget, sandbox, rendering, or persistence result.

Fresh Guile re-review closes the lexical/atomic/serialization obligations, but
blocks endpoint integration: blocking I/O holds transition locks and can stall
restart/global registration; `eq?` port uniqueness does not reject duplicated
socket descriptors or cross-host registration. The next correction separates
bounded nonblocking I/O from atomic transitions and makes fresh socket creation
and authority minting one supervisor-owned operation. No blocking fixture is
accepted as runtime lifetime enforcement. Original authority findings remain
in `doc/reviews/2026-09-04-book-session-adversarial.md`.

Endpoint fix implementation now reports 212 Guile assertions and 16 unchanged
Python oracle tests passing, with five repeated Guile runs. It creates its own
SOCK_CLOEXEC socketpairs, bounds nonblocking pumps to 4096 bytes/four frames per
call and outbound queues to eight frames/524320 bytes, invalidates authority
before shutdown, and keeps socket I/O outside transition locks. The accepted
codecs remain unchanged. Independent endpoint recheck is underway; these are
implementation results, not yet a newly accepted integration gate.

Final session recheck accepts the scoped **untimed** supervised
`hello → action → present` gate. A discovered batched-result loss was fixed by
returning after one committed input transition, with buffered followers still
visible to readiness checks. The final gate passes 227 Guile assertions,
16 unchanged Python oracle methods, and 25 independent focused assertions.
Timer leases are needed only when automatic timers are added. Process donation
and supervisor lifecycle remain separate integration review obligations.
The next host fixture under `pinenote/tools/book-interaction/` connects the
accepted session to actual KOReader IPC and known Guile/Python book peers;
explicit trusted-native fixtures are not a gVisor fallback or sandbox proof.

That fixture now passes a real pinned KOReader InputDialog → private IPC →
Guile session authority → Guile/Python fixture-book → reader result exchange
for both languages, with navigation/close stale-reply rejection. Its local
check passes 16 private-control assertions, an owner-loss cleanup regression,
both end-to-end runs, and compiler/syntax checks. Session and framing source
remain unchanged. The new host/control/process glue and Lua reader IPC are in
fresh focused adversarial review. This is still trusted-native execution of
known fixture books, not gVisor, persistence, or shipping integration.

The fresh reader review rejects the visible-interaction gate: the pending save
callback opens a modal “Saving failed.” message, hiding the dialog; the current
backing-text/IPC assertions do not prove the result was painted. It also found
cleanup omissions and a hardcoded host-result relay that pass. Fixes are assigned
for the correct pending return, real topmost dialog repaint with varied book
results, and independent widget/source/FD teardown oracles. The real IPC flow
remains demonstrated, but displayed feedback is not yet accepted. The variadic
LuaJIT fcntl and fresh-copy initialization bugs were fixed and independently
closed during that review. Details:
`doc/reviews/2026-09-04-book-interaction-reader-adversarial.md`.

The corrected trusted-native desktop/offscreen interaction is now independently
accepted: all BIR findings are closed (final reader-review SHA-256
`8b52370857a38d49d576c0cd7a0270167c8db333e3cb9c0e308f779e417f92ff`).
Both Guile and Python books passed Latin and Unicode runs; independent
instrumentation observed the inherited KOReader paint method returning with the
exact topmost result. Modal, three cleanup-omission, and hardcoded-relay mutations
all fail. The authority-side BI findings are also independently closed for their
reviewed scope. This establishes the host real-IPC/UI fixture, not sandbox
execution, automatic timers/cancellation coverage, persistence, or glass quality.

The [Guile adversarial review](reviews/2026-09-04-book-guile-adversarial.md)
also blocks integration: malformed object separators accepted by the pinned
dependency, invalid C0 control escaping on encode, and quadratic duplicate
checking in our wrapper. Independent recheck closes all five original Guile
findings; a separate 428-case structural mutation corpus found no Python/Guile
acceptance differences. The verified suite count is 46 Python test methods
and 49 Guile assertions (the earlier implementation report undercounted Python
by one): malformed separator vectors, all C0
controls in keys/values, supplementary Unicode, exact post-escaping byte limits,
maximum-width objects, and pre-serialization rejection. Guile deliberately uses
ASCII Unicode escaping; Python can emit direct UTF-8. Wire spelling need not
match. Dependency findings are recorded, not sent, in upstream-register
item 26. Mathematical numeric-value semantics must be distinguished from
preserving signed zero or exact/inexact representation across languages.

Next, once framing is reviewed, add the minimum hello/initialize/action/present
exchange, supervised-connection grants, and generation invalidation. Do not
invent all object operations before exercising this exchange.

### B. Execution and reader feasibility

Initial execution investigation is recorded in
[the execution spike note](book-computer-execution-spike.md). The Guix pin
provides gVisor source packages but not a runnable `runsc`; the new
`pinenote/packages/gvisor.scm` now supplies the complete official ARM64
`release-20260831.0` distribution. A bounded package build passed, producing
`/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0`;
all six installed ELFs are static AArch64 and byte-identical to the verified
archive. Checksums were verified, not a release signature. The dedicated
`pinenote/systems/pinenote-book-execution-spike.scm` system derivation resolves;
no system image or ARM64 runtime execution is proven yet. The inspected reader
artifact has user namespaces disabled, so the initial disposable-VM test uses
a root-launched supervisor and a non-root, capability-free payload. This is
not approval of the eventual shipping privilege model. A new image must have
its own kernel configuration checked rather than inheriting this observation.

The [execution adversarial review](reviews/2026-09-04-book-execution-adversarial.md)
found that payload credentials do not constrain support-process privileges:
the pinned runtime defaults to DirectFS, whereas its `--directfs=false` path
needs user namespaces. **The independent implementation re-review corrected
the initial conclusion that DirectFS would run without them:** with
`--network=none`, `container.New` calls `modifySpecForDirectfs`, which adds a
user namespace before sandbox creation. Both proposed profiles therefore need
`CONFIG_USER_NS=y`. There is no accepted current-kernel workaround. A separately
reviewed test configuration (or a generic ARM64 VM for an explicitly userspace-
only first proof) must supply the prerequisites; shipping kernel configuration
stays untouched. Strict sidecar use/release enforcement must be
explicit, since the pinned runtime still allows embedded fallback by default.
The OCI implementation is incorporating these findings. Before any adversarial
VM run, require a private console/run directory, explicit `-nic none`, and a
throwaway disk layer rather than borrowing the release lane's writable images.

OCI generator implementation now has 10 passing host tests, plus three package
mutation-test methods. The implementation disposition is recorded separately
in `doc/reviews/2026-09-04-book-execution-adversarial-disposition.md`; independent
re-review is pending. The explicit functional/isolation profiles and generated
launch flags are not runtime observations. No ARM64 process has been launched.
A disposable QEMU runner is the next outer-boundary gate; cgroup enforcement,
private-FD integration, helper selection, and actual guest mounts still require
execution evidence.

The package gate is independently accepted. The OCI re-review also confirmed
that `--ignore-cgroups=false` causes runtime-created cgroup membership, not
CPU/memory/PID limits in the absence of resource settings. The test system lacks
a declared cgroup mount. Mount/preflight plumbing is required for the first
functional run with these flags; enforceable whole-domain ceilings remain a
separate isolation gate. Those corrections apply to the Guile execution port
as well as the earlier Python test reference.

The Guile OCI generator and disposable QEMU supervisor are implemented. Reported
host gates pass 10 Python OCI-oracle tests, five Guile OCI comparisons, six
Guile fake-QEMU supervision tests, three package mutation methods, and static
checks. A fresh Guile execution/outer-boundary review is underway; Python
references remain test-only. No real QEMU or ARM64 runtime execution is proven.

First runtime path: **use the PineNote kernel**, per operator correction of the
proposed cached generic-kernel shortcut. That shortcut saved build time but
would have weakened the evidence and required another kernel validation pass.
The test variant inherits `linux-pinenote` source/patches and enables USER_NS
locally; verify the actual post-`olddefconfig` delta rather than assuming it is
one line. A bounded real kernel and dedicated guest-image cross-build (two
cores, one job) is authorized. Actual VM launch waits for runner review. The
shipping configuration stays unchanged; record the exact fork baseline, kernel,
and configuration tested. No host-store sharing or guest networking is added.
An earlier lowering query unexpectedly started that build and timed out without
an output; the implementer verified no remaining build process. Do not repeat
that supposedly cheap query as a derivation-only gate.

Recovery after the harness server restart: the dedicated PineNote kernel
cross-build was confirmed still running with `--cores=2 --max-jobs=1`; it was
not restarted. The fresh Guile execution review accepts the package/OCI host
gates and static USER_NS/cgroup2 definition, but blocks real QEMU on supervisor
SIGKILL leaving its children/run tree behind and swallowed cgroup-probe removal
failure. A focused implementer owns those runner fixes while the existing build
owner continues the kernel/image work. Actual guest execution waits for their
independent recheck. Report:
`doc/reviews/2026-09-04-book-execution-guile-adversarial.md`.

The runner's two findings are independently closed at the reviewed hashes.
The dedicated PineNote kernel and image have now built successfully: kernel
`/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote`,
system `/gnu/store/laq3v5csnh5p8i9njv5vrap0kls5ay5g-system`, raw image
`/gnu/store/vvrp8i9af77sacic7rqnmcjiacpgd74a-disk-image`.
Measured complete configured-symbol delta against the exact base is only
`CONFIG_USER_NS: n → y`. No generic kernel was built or included. Private,
hashed boot inputs are staged under the execution tool's ignored
`build/artifacts/pinenote-book-execution-userns-20260904/`; the frozen source,
kernel/config/patch manifest, image geometry, and guest assertions are now
under independent first-boot review. There has still been no actual guest boot.

First-guest review accepts baseline construction and the exact kernel delta,
but requires three finite smoke-integration corrections: consume/validate the
console log before private-root deletion and propagate failure; check distinct
actual Python/Guile payload output before PASS; and remove the inherited serial
agetty to avoid a second console consumer/writer. The launch recipe must fail
fast. Those fixes are assigned with bounded system/image regeneration; the
accepted kernel output is reused, not rebuilt. Review:
`doc/reviews/2026-09-04-book-guest-smoke-adversarial.md`.

The corrected v2 system/image is built and submitted for focused recheck:
system `/gnu/store/0rlw7zk22cnc4vcrlxz4c91xlphn6489-system`, image
`/gnu/store/klgw7f4nypj4mhfz9l1py3rqmx5l1cm4-disk-image`. The same accepted
kernel output was reused; prior artifacts are retained. The v2 packet is
`build/baseline-review-manifest-v2.txt` under the execution tool, SHA-256
`685855096da1c203431788b655c4d824b284903ee6e8578ff72f5962c12f2fbe`.
It includes parser-before-cleanup propagation, payload-output checks, no serial
agetty, and a fail-fast launch recipe. No actual guest boot has happened yet;
the exact v2 snapshot awaits the finite three-finding recheck.

The focused v2 recheck closes all three findings and accepts the exact first-run
recipe (final guest-review SHA-256
`82696490b3d019baa54c3a726becd5978ccdb329f645f70602ad75beb3d424d1`).
The parent started the real functional QEMU run only after verifying the recipe,
runner, entrypoint, and OCI source hashes. It uses the accepted ten-minute
timeout, no guest network, and a private copy-on-write disk. Outcome pending:
actual guest assertions, not QEMU status alone, decide the gate. This is the
first launch, not yet evidence that ARM64 gVisor or either payload succeeded.

First recipe outcome: **preparation failed before QEMU was started**. The runner
required a store basename matching `HASH-NAME-system`, rejecting the actual
Guix output `HASH-system`. Log:
`/tmp/opencode/wilkbook-first-qemu-v2.eXvWVP.log`. The parent corrected the
optional-name regex and changed fake-QEMU fixtures to the real output shape;
all nine runner tests pass. Focused review of that tiny outer-runner delta is
underway; kernel/image/OCI/recipe inputs are unchanged. This is a harness bug,
not ARM64 runtime or kernel evidence.

The parser correction also tightened total `root=` counting and rejected slash
traversal in named system outputs. Independent focused recheck accepted runner
`15626868e8feee7b42b927eadb8536a41e91ccd7837ab0a6a809bfbf192a17db`.
The authorized retry then launched real QEMU but reached the 600-second outer
timeout, with no completed guest verdict. Log:
`/tmp/opencode/wilkbook-qemu-v2-retry.FdkRuq.log`. Timeout cleanup removed the
private console log without reporting its contents, so no kernel boot stage or
gVisor/payload execution can be inferred. Bounded failure-log reporting and
offline boot/service-path inspection are assigned before another attempt; do
not simply extend the timeout or credit this as a passing runtime gate.

The independently approved bounded diagnostic runner
`e64175dd34ea5bab5e7e15f4b93c83c68875f91a39f78e14d301cf5bdf09b7b5`
ran a 150-second diagnostic-only attempt against unchanged v2 inputs. Log:
`/tmp/opencode/wilkbook-qemu-diagnostic.vJzgOs.log`. This now proves Linux 7.1.8
PREEMPT_RT boot, PNGuixRoot on `/dev/vda1`, Shepherd startup, kernel-identity and
no-network assertions in the guest. It then reports `BOOKEXEC-SMOKE-FAIL` for
the host/share mount check **before runsc**. The check rejects any `/gnu/store`
mount, potentially including Guix's own read-only store bind; source verification
and a precise own-root-vs-share classifier are assigned. A separately proven
Shepherd shutdown/start-future cycle explains the post-failure hang. Both guest
fixes will be combined into v3, reusing the accepted kernel. This is boot/service
evidence, not a successful sandbox or compatibility gate.

The v3 guest correction is built and independently accepted for a full
functional attempt. It permits only the precise own-root read-only Guix store
bind and runs the smoke as a supervised non-respawning child outside the start
future. Image: `/gnu/store/rx9pnklbcbb1mhm0dxr7f4pa46hyayfx-disk-image`;
system: `/gnu/store/k0a2rvacjh05c1zgh723mq51gqhgw7yc-system`. Kernel and
diagnostic runner are unchanged. The parent launched the reviewed 600-second
v3 recipe (`fa4d454d52b4a33b98b4a0867efcb706e17962d0e0cd85f7166f809d4a886dbf`)
after hash verification. Outcome is pending; the mount diagnosis needs its
actual guest canary, not only a source-level explanation.

Actual v3 result (`/tmp/opencode/wilkbook-qemu-v3.58dmsF.log`): kernel identity,
no-network, forbidden-mount and ARM64 `runsc --version` assertions pass. Failure
then occurs **before sandbox launch**, because the OCI validator requires a
`-profile` basename suffix while the retained Guix profile is legally named
`wilkbook-book-execution-languages`. Shutdown completes with `reboot: Power down`
at about 14 guest seconds; the v2 shutdown cycle is no longer observed. Fix the
profile naming assumption and add real-built-profile offline generation using
its actual 45 requisites before v4. No interpreter-under-gVisor success is
claimed by the version query.

V4 fixes profile validation to use canonical store identity, a regular manifest,
and both executable interpreter targets inside the exact retained closure,
not a `-profile` filename suffix. Offline generation against the actual 45-item
ARM profile passes and the focused review independently accepts the change.
System `/gnu/store/7m9iyf4f41grj342ifkw1dlxxmnvjx0a-system`, image
`/gnu/store/qa2lg7szbgfx3fgk9ajkngkyiwg3irc8-disk-image`; kernel and runner
unchanged. The parent started the exact authorized v4 600-second recipe,
SHA-256 `b3fa89d672828202e4b1303e7ae1f9c2e6b0c5f2c639a7814ab97f0ef353d454`.
Outcome pending; no sandbox success is inferred from the host generation gate.

Actual v4 result (`/tmp/opencode/wilkbook-qemu-v4.q521pe.log`): boot, kernel,
network, mount and ARM64 runsc version checks pass. The first `runsc run` now
gets past bundle construction but fails with status 128:
`cannot create sandbox: cannot read client sync file: waiting for sandbox to
start: EOF`. The guest powers down cleanly at roughly 15.4 guest seconds. This
is the first actual sandbox-start attempt, not a successful Sentry or language
execution result. A bounded startup-diagnostic image and independent pinned-
source analysis are assigned without changing the execution profile or kernel.

Record exact package pins, available host tools, guest kernel requirements,
closure preparation, and the private FD path before adding the integrated
launcher. Read current pinned KOReader hooks rather than relying solely on the
architecture draft's earlier source review.

[The reader spike](book-computer-reader-spike.md) records a successful
one-off v2026.03 SDL/offscreen plugin/widget/callback probe. A checked-in replay
is the next gate; this has not exercised actual book messages or persistence.
The existing `insertZMQ` polling seam caps input waits at 50 ms while a source
is registered. Limit registration to active interactions for this prototype;
neither low-latency ink nor idle-power suitability follows from this probe.

The replay is now under `pinenote/tools/book-reader/`, but its first
[adversarial review](reviews/2026-09-04-book-reader-adversarial.md) rejected
the gate. Real event-loop/widget execution was independently confirmed; missing
reentrancy protection, watchdog-loss cleanup, and weak lifecycle/pin oracles
require fixes and independent recheck. Fixture-authored markers are diagnostics,
not proof of registry removal or document closure. The lexical no-write scan
is not write confinement and must not be described as such.

Final reader recheck: **all BR-1–BR-5 findings are closed** and the scoped
desktop/offscreen gate is independently accepted. The original three surviving
mutations now fail on real state oracles; retained dialogs are absent from
UIManager's stack after normal close, callback-error close, and active-document
close. The baseline has 33 expected diagnostic markers, all 15 supplied
mutations fail, and independent checks found no process residue. This accepts
the trusted fixture's KOReader seams/lifecycle, not a shipped plugin, wire
bridge, durable save, or display/power behavior.

Use one persistent asynchronous channel per active execution domain. Bound
outgoing queues and broker work as well as incoming frames. Coalesce only
superseded provisional presentation updates, never acknowledged durable edits.
Keep diagnostics off the protocol stream. Do not synchronously route each pen
sample through an interpreter.

### C. Durable interaction

Choose and test the state transaction and acknowledgement contract before
calling the interaction persistent. Forced-process termination is one failure
boundary; power-loss durability is stronger and requires separate evidence.
Maintain distinct acknowledgements for saved state and submitted presentation;
neither claims optical completion.

### D. Self-revision rehearsal

Add source-resource workspace editing, isolated preview, immutable sealing,
explicit activation, and rollback. Use the UI to change both presentation and
executable behavior in a successor Workbench. Test a deliberately broken
successor and preserve pre-migration data. Rehearsal in QEMU is not the final
on-tablet self-hosting acceptance test.

## Deferred rather than blocked

### Future networked library tools (release timing not assigned)

Operator clarification: deny-by-default sandbox networking is not a permanent
ban on networked books. A library/store/sync workbook should eventually consume
explicit network, credential, and library-import capabilities. Store-specific
logic belongs in tool-books/components, not hardcoded trusted-host integrations.
Brokered networking is the initial direction; explicitly granted network-enabled
execution profiles remain a possible later need. Purchase approval is separate
from permission to access a store. None is implemented by the current spike.

### Well past 1.0: local and remote learning environments

Well past 1.0, a technical book may request an isolated lab environment that a
separate user-facing terminal/SSH service can access: for example, an Apache
exercise inside a book-launched container. A Kubernetes book may instead attach
to a user-approved external kind/full cluster. Preserve the distinction between
permission to request a lab, permission to connect to it, and authority over an
external target. A connection to a lab must not imply a shell on the PineNote or
control of its container runtime. These are future consumers of scoped execution
and endpoint capabilities, not a requirement to build SSH, port exposure, remote
orchestration, nested containers, or Kubernetes into the bootstrap.

Arbitrary environment recipes, warm-template checkpoints, inline structural
editing, multi-lens composition, collection grants, and semantic ink recognition
are not prerequisites. Begin with approved pinned environments and plain restart
from durable state.

QEMU can supply packaging, execution, service, protocol, and recovery evidence.
Desktop/SDL can shorten UI iteration. Neither proves PineNote idle power, suspend
electrical behavior, stylus feel, or optical quality. Record transport and
KOReader-submission measurements separately from panel timings; QEMU timings are
not tablet performance predictions.
