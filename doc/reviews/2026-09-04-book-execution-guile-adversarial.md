# Book-execution Guile adversarial review — 2026-09-04

## Verdict

**Do not start the first real disposable-QEMU run with this exact outer
supervisor yet.** The actual Guile OCI implementation is acceptable for the
narrow host/static generation gate, and the package remains acceptable for the
bounded non-shipping spike. The USER_NS and cgroup2 definition gaps identified
by the earlier review are corrected in source.

One new first-run blocker remains: cleanup depends on the Guile QEMU owner
remaining alive. Killing that owner with `SIGKILL` left the fake QEMU, its
TERM-resistant descendant, and the private run tree alive. There is no
parent-death signal, watchdog, or external process scope to perform the promised
group cleanup when Guile cannot run its `dynamic-wind` after-thunk. This is an
operational containment failure, not evidence of a gVisor escape.

The generated cgroup preflight also overstates one check: it proves child
creation but silently ignores failure to remove the probe. Correct that
fail-open cleanup result before relying on the stated create/remove preflight.

After those two bounded corrections and an owner-death regression, the outer
envelope is suitable to proceed to an **attended, narrowly labelled functional
compatibility smoke** using the explicit `isolation-userns` profile. Such a
result would still require guest success/failure assertions; QEMU exit zero is
deliberately reported as `GUEST-ASSERTIONS=NOT-RUN`. Production resource
budgets, bounded book-output import, and inherited Book Protocol FD integration
are not prerequisites for that smoke. They remain isolation/release gates.

No implementation was changed by this review.

## Findings

### 1. High, first-run blocker — owner death leaves the QEMU process group alive

`run-disposable-qemu.scm:8-14` handles `SIGINT`, `SIGTERM`, and `SIGHUP`.
`disposable-qemu.scm:310-362` creates a process group and performs bounded
TERM/KILL cleanup from a `dynamic-wind` after-thunk. Those paths work while the
Guile owner runs: all six committed fake-QEMU methods passed, including timeout,
external TERM, preparation failure, normal QEMU exit with a resistant
descendant, and inherited `SIGCHLD=SIG_IGN`.

They cannot run after uncatchable owner death. The module contains no watchdog,
`PR_SET_PDEATHSIG` arrangement, or external execution scope. An independent
fixture made the test process a Linux child subreaper, started the existing
TERM-resistant fake QEMU, and sent `SIGKILL` to the Guile owner. It observed:

```text
owner gone
fake-QEMU pid 1042333 still present
fake-QEMU descendant pid 1042336 still present
private run-root residue still present
```

The fixture then killed the exact process group, reaped both adopted processes,
and removed only its private temporary tree. No test process was left behind.

Before real QEMU, add an owner-death mechanism that kills the complete owned
group even when Guile is killed or crashes, close the setup race in that
mechanism, and pin the `SIGKILL` case. Merely adding another catchable signal
handler is not sufficient. A first real run may not be called structurally
disposable until this is green.

### 2. Medium — cgroup probe removal failure is ignored

The generated launcher in `oci-bundle.scm:601-615` creates
`/.wilkbook-preflight-PID` under `/sys/fs/cgroup` and checks that its
`cgroup.procs` exists. Its `dynamic-wind` cleanup then catches every `rmdir`
error and returns `#f`; the result is discarded and launch continues.

Consequently the claims in the README and disposition that the launcher proves
it can **create and remove** a child are not true. It proves creation and only
attempts removal. This is not a CPU/memory/PID-limit issue: the OCI object still
intentionally omits `linux.resources`. Make failure to remove a probe created by
this invocation fatal on the normal preflight path, while preserving sensible
error cleanup, and add a focused regression.

### 3. Low, trusted-owner race — the run-base FD protects creation, not all later access

`disposable-qemu.scm:546-567` opens the mode-0700 run base with
`O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` and creates the random directory through
`/proc/self/fd/FD`. That closes the earlier `mkdtemp` redirection bug. Later
copies, QEMU paths, and cleanup use the reconstructed pathname, however.

An independent same-UID fixture renamed the private run base during the first
copy and replaced its pathname with another mode-0700 directory. The operation
failed before `qemu-img` or QEMU, but cleanup could not find the descriptor-
created run root at the reconstructed path and left it under the moved original
base. The fixture removed that tree and launched no process.

Only the trusted owner can perform this race because the directory is mode
0700. It is therefore not a guest or other-account authority escape and does not
block one attended functional smoke with quiescent trusted inputs. Retaining a
run-root FD and using descriptor-relative creation/cleanup would be the stronger
release design. At minimum, keep the current private-owner/non-concurrent-input
assumption explicit.

## Direct Guile policy review

The conclusions below come from `oci-bundle.scm` and independently parsed output
from that module, not from assuming the retained Python generator is accepted.

- Profile selection is mandatory. `functional-directfs` emits
  `--directfs=true` and the functional-only claim;
  `isolation-userns` emits `--directfs=false` and the candidate-only claim.
  Both record exactly `CONFIG_USER_NS=y`; there is no automatic profile or
  retry fallback.
- The common runtime vector contains the 17 intended fixed flags, including
  Systrap, no network, strict sidecars, always-on release matching, cgroups
  enabled, no host UDS/FIFO, emulated-only character devices, no SUID/flag
  override/rootfs-tar annotation, no root overlay, rootful operation, exclusive
  file access, and disabled raw/packet-socket writes.
- `runsc` is the absolute
  `/run/current-system/profile/bin/runsc`. The generated wrapper starts the
  separate supervisor-profile Guile under absolute `env -i`; the generated
  launcher constructs the environment again before direct `execl`. An inherited
  `GVISOR_ENFORCE_RELEASE=SKIP`, credentials, Guile load paths, and caller
  `PATH` do not reach `runsc`.
- Every descriptor above stderr is marked `FD_CLOEXEC`; the child signal set is
  reset before exec. Missing private Book Protocol FD behavior remains future
  integration work, as requested.
- The payload environment is an exact six-entry vector and Python uses `-I`.
  The payload is numeric uid/gid 65534, has empty capabilities,
  `noNewPrivileges`, fixed rlimits, a read-only root, and fixed working
  directory.
- Requisites resolve to unique, canonical, top-level store objects, include the
  selected profile, and contain the resolved Python target. Generation emits
  one read-only bind per requisite and never a whole-store bind. The selected
  book is one canonical regular file from a separate store item. The generator
  deliberately trusts the selected profile; the real caller must use the exact
  retained language profile rather than an arbitrary `*-profile`.
- The only declared writable container filesystems are the bounded `/dev` and
  16 MiB `/scratch` tmpfs mounts. `root.readonly=true`, closure mounts are
  `ro,nosuid,nodev`, the book additionally has `noexec`, and
  `--overlay2=none` disables the runtime root overlay.

The pinned-runtime flag meanings and immutable-root behavior remain consistent
with the exact gVisor source files and hashes recorded by
`2026-09-04-book-execution-adversarial.md`. This review independently checked
that the current Guile emits those exact names and values; it did not execute
the ARM64 runtime or refetch upstream source.

## System and package disposition

`pinenote/systems/pinenote-book-execution-spike.scm:22-34` defines a local,
non-shipping kernel variant whose post-configure phase enables `USER_NS`, runs
`olddefconfig`, and requires `CONFIG_USER_NS=y`. Lines 97-100 append Guix's
standard `%control-groups`, which declares cgroup2 at `/sys/fs/cgroup`. The
system retains separate language and trusted-supervisor profiles and is not
referenced by another system/flavor module. This is static definition evidence;
the kernel has not been built or booted by this review.

The package source hash is unchanged from the accepted package review. Its three
mutation methods passed, and the already-realized output
`/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0` again passed
exact-layout and six-static-AArch64-ELF inspection without executing an ELF.
Unsigned release provenance and source-build reproducibility remain release
questions, not blockers for this non-shipping package gate.

The QEMU disk mechanism does not use the literal QEMU `-snapshot` option. It
uses the stronger explicit graph described by the source: SHA-verified private
copies of kernel, initrd, extlinux configuration, and raw baseline; a private
qcow2 overlay with explicit raw backing format; and only that overlay attached
to QEMU. An independent replacement of `Image` during copying failed on source
identity change before hashing or QEMU. Six ambiguous extlinux fixtures
(duplicate APPEND, root, `gnu.system`, `gnu.load`, hardware console, and an
already-present QEMU console) all failed before preparation or QEMU.

## Gate disposition

| Gate | Disposition |
|---|---|
| Pinned gVisor package | **Accepted for the bounded non-shipping spike.** Runtime version/helper selection and provenance remain later gates. |
| Guile OCI generation | **Accepted for the narrow host/static gate.** Use only the dedicated retained profile for the real smoke. |
| Static USER_NS/cgroup2 system definition | **Accepted as source/evaluation evidence.** No kernel/system/image build or boot evidence was produced. |
| First real outer-QEMU launch | **Blocked** on finding 1 and the finding 2 fail-closed correction. A guest assertion phase and reviewed dedicated baseline are also required if the result is to be called functional rather than exploratory. |
| Narrow functional Systrap smoke | **Not yet run.** Once the preceding items are green, it does not require production budgets, output import, or inherited-FD protocol integration. Prefer `isolation-userns`; any DirectFS run remains functional-only. |
| Isolation acceptance | **Open.** Sidecar identity/negative fallback, mount and network canaries, support-process identities, whole-domain cgroup membership and nonzero limits, runtime teardown, hostile workloads, and bounded outputs remain unproved. |
| Release of untrusted-book execution | **Open and later.** Includes isolation acceptance, broker/FD lifecycle, output import, provenance policy, recovery, and PineNote qualification. |

The four reviewed Guile entry/module files do not integrate a console assertion
driver. A concurrent `guest-smoke.scm` appeared after the snapshot below; it was
not named in the requested four-file implementation, is not referenced by the
reviewed runner or tests, and is explicitly excluded rather than treated as
completed evidence. Its observed late-arrival hash was
`13f6d47f5284847953a7f373d9345b5d67cd50d5e3aa8aa53a03c1c12a6b7f48`.

## Bounded checks run

- Exact realized Guile 3.0.11 plus `guile-json` 4.7.3: all **5** committed
  actual-Guile OCI methods passed.
- All **6** committed fake-QEMU methods passed.
- All **3** package mutation methods passed; these contain six removal
  subtests, six duplicate-addition subtests, and the sidecar-directory symlink
  case.
- Cached installed-package inspection passed for all six static AArch64 ELFs.
- Pinned ambient Guix
  `f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c` ran the non-lowering system check:
  all **5** assertions passed.
- Independent actual-Guile generation checked both profiles, exact argv,
  closure mounts, environments, USER_NS records, cgroup path, root policy,
  launcher preflight text, and absence of inherited secrets. A duplicate
  requisite failed with no bundle.
- Independent fake-only cases produced the source-race, extlinux, run-parent,
  and owner-death outcomes recorded above. Every fixture process was explicitly
  killed and reaped and every fixture tree removed.
- Guile reader syntax and shell syntax checks passed.

The first attempt to run the Guile aggregate under the ambient `guile` did not
reach implementation code because that environment lacked `(json)`. It is not
counted as five product failures. The same tests passed when rerun with the
already-realized Guile/`guile-json` paths; no Guix realization was requested.

No kernel/system/image build, lowering, real QEMU, `runsc`, ARM64 execution,
hardware access, SSH, UART, deployment, or network access occurred.

## Exact reviewed snapshot

Snapshot time: **2026-09-04T23:35:28Z**. Repository base:
`50572d7796abdb0928969f4db8836fc5e30aeb58`. In-scope work was untracked and
could change concurrently; these hashes, not path names alone, define the
reviewed bytes.

| SHA-256 | File |
|---|---|
| `2eedf2a37b09d675319b04d4e862abd8a5171a8797d7b557d0fbe24438a7bb1a` | `pinenote/tools/book-execution-spike/README.md` |
| `d294f9391733e4db2274d2ce1e387d21cdb9f847122e4aa4b55e9d56c53d5a94` | `pinenote/tools/book-execution-spike/oci-bundle.scm` |
| `ef3b554ad8aa03126f8134669e8d600835f648271748bd50edf2464f5024d7c4` | `pinenote/tools/book-execution-spike/generate-oci-bundle.scm` |
| `123355ca88de19435a48f9137503ab7fcf3bfbfc69287a1474cc420c100b6362` | `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` |
| `4ee44d2c2d3593778ef9b15fa8cf29002a0ef4513bb4d141f4b144383fb88d9e` | `pinenote/tools/book-execution-spike/invoke-oci-bundle-test.scm` |
| `ef918c5b0465b08d326dd98a404dbc67dc4e6894d82b896c2c9c04530ff44545` | `pinenote/tools/book-execution-spike/test_guile_oci_bundle.py` |
| `36d7d8904f88d414025968de0e07b9dd57ae686235bf30a6188ee968749f2abb` | `pinenote/tools/book-execution-spike/test_disposable_qemu.py` |
| `62fb790d35690320c51b7a2f7ee6f66b3631fb1f0b53624c4eb85f0a7d1796dd` | `pinenote/tools/book-execution-spike/run-guile-tests.sh` |
| `6a25230fd9bc32f6f090b61ae4ec137e2b1b2d2cf7cfa98fa399d4f80d382d1b` | `pinenote/tools/book-execution-spike/run-tests.sh` |
| `c12dcb9d6855347267d063929bcab112951adb108243f715a20234b90b7c45b1` | `pinenote/tools/book-execution-spike/check-execution-system.scm` |
| `0ec06d367cd778449df158db0ff07dbdf4e3a0b9b66c4224125a31786587e2d4` | `pinenote/tools/book-execution-spike/check-gvisor-package.sh` |
| `7072434f9d45c754a6bf2c394c142b9c3862b8fae23fed97b9a5ae8c7534b3f5` | `pinenote/tools/book-execution-spike/test_check_gvisor_package.py` |
| `b79ec88a8291d8fe89dd690040dda0af55cf4db5c08cac442abc7c029dfffc3e` | `pinenote/tools/book-execution-spike/expected-release-members.txt` |
| `8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d` | `pinenote/packages/gvisor.scm` |
| `5a4d2d84cf8fcacd3180b7496ebeceb19cfe87de4719b429a2875f7b28dae71e` | `pinenote/systems/pinenote-book-execution-spike.scm` |
| `5048db994fcb5e4dae7af4e2d3299d6d70ecc53e735efdabc6bacb5119453040` | `doc/book-computer-execution-spike.md` |
| `f57f5ef335b6023ca91f5b0004b16131abb5c0d2aae3c70c4573f39113f52f8c` | `doc/reviews/2026-09-04-book-execution-adversarial-disposition.md` |
| `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` | `channels.scm` |

### Post-snapshot concurrent drift

The final integrity check found that concurrent work had changed three
previously hashed files after the review snapshot:

| Post-snapshot SHA-256 | File |
|---|---|
| `e62f2a6ea7f500b8c90967c4d332721ebe5d48bc2463fe863a13e502e80d30a0` | `pinenote/tools/book-execution-spike/run-guile-tests.sh` |
| `39a61e89870ed7464bd6039666cf0592aa0167d09f2b8188b712f3626747e9e4` | `pinenote/tools/book-execution-spike/run-tests.sh` |
| `c9be1eece0aa376e20eb7fc993edb9af308df5a16ce1b8f54d4ee26c58a63f85` | `pinenote/systems/pinenote-book-execution-spike.scm` |

Those bytes and the late `guest-smoke.scm` are not covered by this verdict or
the test results above. The four trusted Guile OCI/QEMU implementation files
remained at their recorded reviewed hashes. Re-review the late integration as a
new snapshot rather than attributing this report's evidence to it.

## Process-style references

The implementation comments accurately identify style precedents, but those
precedents are not security proof:

- pinned Guix `(guix build utils)` direct argv/fork/wait style, exact installed
  `guix/build/utils.scm` SHA-256
  `9dd66a0bc251881c5551099c78e796e6f4c45dda846ea92d0d97a703f10babf5`;
- GNU Shepherd 1.0.9 `(shepherd service)` child signal reset, constructed
  environment, direct exec, session/process-domain, and primitive-exit patterns,
  exact installed `service.scm` SHA-256
  `4ab8666c958b7c2e5ad49d09ec52383fcc2fd4292555de844832010cf9d0e414`;
- Shepherd `(shepherd system)` close-on-exec implementation, exact installed
  `system.scm` SHA-256
  `810c804ad2c3ae138cec52ceb57b1b8ceb8653098842bd2692fd9a3c90f94261`.

The standalone runner deliberately does not import Shepherd/Fibers. In
particular, Shepherd being a long-lived process monitor does not provide an
owner-death backstop to this separate synchronous Guile process.

## Focused two-finding recheck — 2026-09-05 UTC

### Verdict

**Findings 1 and 2 are closed at the exact hashes below.** No new blocker was
found in the guardian or cgroup-preflight changes. The first real functional
runner is allowed from this two-finding process-safety gate once the separately
reviewed dedicated private baseline and guest assertion phase are ready. A zero
QEMU exit still says only `GUEST-ASSERTIONS=NOT-RUN`; it cannot by itself be
reported as a functional result.

This approval remains narrow: use the explicit `isolation-userns` profile, the
reviewed networkless/private-copy QEMU vector, fixed boot-input hashes, a fresh
mode-0700 run base, and an attended first run. Production cgroup ceilings,
bounded book-output import, inherited Book Protocol FD integration, and
release/isolation acceptance remain later gates. The acknowledged same-UID,
trusted-owner pathname race remains release hardening and produced no new
launch escape in this recheck.

### Finding 1 closure — owner death

At `disposable-qemu.scm` hash
`25812ffd6dbe998c60941d499fe90f4153045f968e3c04a62f791de794346f9e`,
each preparation command and QEMU is parented by a dedicated process guardian.
The guardian:

- enters its own process group and becomes a Linux child subreaper;
- forks the exec child behind ready/release pipes;
- requires both child-side and guardian-side `setpgid(child, child)` to finish
  before reporting the exact owned PGID and releasing the child to exec;
- kills only the exact child PID if setup is not established, and uses the
  negative owned PGID only after that setup gate;
- watches an owner-only liveness pipe, then performs bounded TERM/KILL and reaps
  the direct child plus orphaned descendants when owner EOF appears; and
- reports to the live owner, which has only exact guardian-PID/owned-PGID
  fallbacks rather than a name/PID scan.

The descriptor ownership is correct for the original failure. The owner closes
the guardian's liveness read end, the guardian closes the sole write end before
forking the exec child, and the exec child explicitly closes inherited
setup/report/liveness ports before the general `FD_CLOEXEC` sweep and `exec`.
The process guardian also closes its inherited run-root liveness writer before
forking. Thus QEMU or a QEMU descendant cannot retain a writer and conceal owner
EOF. The fake QEMU independently observed no descriptor above stderr.

A separate run-lifetime guardian holds only its liveness read end and the exact
run-root device/inode identity. Normal cleanup acknowledges it only after the
owner's identity-checked deletion succeeds. Owner EOF without that
acknowledgement causes the guardian to wait past the process-cleanup bound and
remove only the still-matching private tree. The small setup protocols and all
guardian waits are bounded.

The pre-establishment child-death path does not issue a process-group kill: it
uses the unreaped exact child PID and waits for that child. Once the release gate
has opened, the group leader's PID is the recorded PGID; a surviving descendant
keeps that group identity occupied while the subreaper terminates and reaps it.
There remains the usual theoretical numeric PID/PGID reuse interval after an
empty group leader is reaped and before the final existence check. No realistic
fixture reproduced collateral signalling, and eliminating every kernel PID
reuse possibility is not required for this bounded first run. This review also
does not demand survival after simultaneous `SIGKILL` of the owner and all
guardians, an OS crash, or an unkillable task.

#### Independent replay

The original counterexample was repeated outside the committed unittest method:

1. the test parent enabled child-subreaper mode solely so it could reap every
   fixture process itself;
2. it launched the Guile owner with inherited `SIGCHLD=SIG_IGN` and a deliberate
   descriptor 199;
3. it waited for a TERM-resistant fake-QEMU descendant, recorded PID/start-time
   identities for the owner, both guardians, QEMU, and the descendant, and
   checked the exact PGIDs;
4. it confirmed fake QEMU inherited no descriptor above stderr; and
5. it sent `SIGKILL` only to the owner.

Unlike the original review result, both guardians, QEMU, and the resistant
descendant disappeared within the bound, and the private run root was removed.
The fixture reaped all adopted processes and retained no orphan or test tree.

### Finding 2 closure — cgroup probe removal

At `oci-bundle.scm` hash
`0cbbdb0da74b20c3420af47fafbaea8af4fa357b04825713d024deeec1c2ca4f`,
generated `launch.scm` factors the probe into
`preflight-cgroup-child`. A normal-path `rmdir` error now throws
`cannot remove the cgroup2 write probe`; the caller converts that exact error to
a failure before the direct `runsc` exec. The outer error path retries removal
best-effort but rethrows the original error, so cleanup failure cannot replace
an earlier missing-`cgroup.procs` or creation error.

The original injected-rmdir counterexample was independently repeated against
newly generated Guile launcher code, without a real cgroup mount. The fake
probe was created once, normal removal threw, error cleanup retried exactly
once, and the observed result was the fatal removal message. Source ordering
also places this call before `(apply execl runsc argv)`. No runtime executable
was invoked.

### Bounded checks

- All **6** current actual-Guile OCI methods passed under the already-realized
  Guile 3.0.11 and `guile-json` 4.7.3 paths.
- All **7** current fake-QEMU methods passed, including inherited
  `SIGCHLD=SIG_IGN`, descriptor closure, resistant descendants, owner
  `SIGKILL`, exact-identity failure cleanup, and run-root removal.
- The two independent counterexample replays above passed.
- No fixture process or Python bytecode cache remained.

No real QEMU, `runsc`, ARM64 executable, network, kernel/system/image build,
Guix lowering, hardware, SSH, UART, or deployment was used. The separate kernel
image build directory was neither read nor polled.

### Exact focused snapshot and exclusions

Snapshot time: **2026-09-05T00:10:14Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The report hash below is its value
immediately before this section was appended.

| SHA-256 | Focused reviewed file |
|---|---|
| `0380a2f2f519d76a8cd0b6ff7b812746a47b59394c33a04ce933b38561bb67bb` | this report before the focused recheck |
| `25812ffd6dbe998c60941d499fe90f4153045f968e3c04a62f791de794346f9e` | `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` |
| `7af5dd0eba52cffc91bf5671d39cb3d2c6f22b9ab78946ec0f8d73346bb0c09f` | `pinenote/tools/book-execution-spike/test_disposable_qemu.py` |
| `0cbbdb0da74b20c3420af47fafbaea8af4fa357b04825713d024deeec1c2ca4f` | `pinenote/tools/book-execution-spike/oci-bundle.scm` |
| `4ee44d2c2d3593778ef9b15fa8cf29002a0ef4513bb4d141f4b144383fb88d9e` | `pinenote/tools/book-execution-spike/invoke-oci-bundle-test.scm` |
| `159ad57af73a203a32f4ec403d508d8c6a54258d2ac759d6e60d9932076698ad` | `pinenote/tools/book-execution-spike/test_guile_oci_bundle.py` |
| `e62f2a6ea7f500b8c90967c4d332721ebe5d48bc2463fe863a13e502e80d30a0` | `pinenote/tools/book-execution-spike/run-guile-tests.sh` |
| `565f8f23df4a5a03a2ae77ab3a575f393204dbbe02fd4022a52de0a9df1b37a0` | `pinenote/tools/book-execution-spike/README.md`, guardian/cgroup disposition only |

Concurrent guest-smoke/system/document integration was explicitly outside this
two-finding recheck. In particular, no conclusion here applies to
`guest-smoke.scm`, `test_guest_smoke.py`,
`pinenote-book-execution-spike.scm`, `check-guest-smoke-system.scm`, the changed
execution-spike note, or any build artifact. The implementer's reported five
guest-smoke methods were not rerun or credited here. Those files need their own
stable-snapshot review before they can satisfy the guest-assertion condition in
the verdict above.
