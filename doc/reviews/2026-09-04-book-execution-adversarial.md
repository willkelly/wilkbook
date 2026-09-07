# Book-computer execution/package adversarial review — 2026-09-04

## Verdict

The prebuilt package is internally coherent for an **offline, disposable
execution spike**: its fixed-output hash matches GitHub's release API, its
target identity is AArch64-only, its six-file installation matches the standard
non-plugin gVisor helper set, and upstream's resolver will find the adjacent
`gvisor-bin/` directory even when `runsc` is invoked through a Guix profile
symlink. I found no current package-content or target-selection bug.

I do **not** accept the proposed invocation as evidence for the intended
isolation profile. The exact pinned `runsc` defaults to `--directfs=true`. With
rootful launch and no OCI user namespace, that puts the Sentry in the caller's
current user namespace with elevated filesystem privileges. Conversely, the
more isolated `--directfs=false` support-process path creates a user namespace,
while the reviewed PineNote kernel has `CONFIG_USER_NS` disabled. This is a
launcher/kernel-profile mismatch, not a Systrap requirement: Systrap itself
does not require user namespaces.

There is a second default-related bug: the package and spike notes say this
release disallows embedded sidecar fallback by default, but the exact release
source still makes `DEFAULT` permit that fallback. Runtime helper selection
must therefore be made strict and observed, not inferred from package layout.

The first integrated VM acceptance remains blocked. No OCI generator, launcher,
FD transport, cgroup wiring, or execution-specific QEMU harness exists yet;
those are declared future work, not shipping vulnerabilities. The findings
below state the evidence each must produce rather than reviewing nonexistent
code.

## Classification and scope rules

Findings use only the requested classifications:

- **verified bug** — a false present claim or a defect in code that exists now;
- **prerequisite unproven** — necessary evidence is absent, usually because the
  relevant integration is deliberately not implemented yet;
- **deferred production policy** — a trust or release decision that need not
  block a bounded functional spike.

“Host” below means the PineNote/VM Linux instance on which `runsc` executes,
not the x86-64 workstation outside QEMU. Nothing reviewed here is wired into a
shipping flavor. Missing future pieces are not described as exploitable
shipping features.

## Ranked findings

### 1. Blocker — the documented command selects elevated DirectFS, while the hardened alternative needs the disabled user-namespace facility

**Classification: verified bug.** This is a bug in the proposed command and
its implied evidence, not a claim that a container has already shipped.

**Local evidence.**

- `doc/book-computer-execution-spike.md:435-449` says to spell out platform and
  network policy, but the command omits `--directfs`.
- `doc/book-computer-execution-spike.md:163-169` and
  `doc/book-computer-implementation.md:117-120` rely on root launch plus numeric
  non-root payload credentials, empty payload capabilities, and
  `noNewPrivileges` for the functional spike.
- The reviewed kernel configuration has `# CONFIG_USER_NS is not set`
  (`doc/book-computer-execution-spike.md:145-161` and the defconfig hunk at
  `pinenote/patches/linux-pinenote-7.0-forward-port.patch:237-255`).

**Pinned-upstream evidence.** At commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`:

- [`runsc/config/flags.go`][gvisor-flags] registers `directfs` with default
  `true` and describes it as direct Sentry filesystem access with the Sentry
  running at higher privilege.
- [`runsc/config/config.go`][gvisor-config] says DirectFS lets the Sentry
  directly access/mutate container filesystems, runs it with escalated
  privileges, and is unsupported in rootless mode.
- [`createSandboxProcess` in `runsc/sandbox/sandbox.go`][gvisor-sandbox]
  branches on `conf.Network == NetworkHost || conf.DirectFS`. With DirectFS,
  rootful execution, and no user namespace in the OCI spec, it logs that the
  sandbox starts in the current user namespace and applies caller capabilities.
  Without DirectFS it instead creates a new user namespace and maps/runs the
  support process as `nobody`.

The OCI `process.user`, capability sets, and `noNewPrivileges` govern the
payload as implemented by the Sentry. They do not retroactively change the
Linux identity, namespace, or capabilities of the host-side `runsc`, Sentry,
or Gofer processes. Therefore a green run using the documented command would
be useful functional Systrap evidence, but it would not validate the intended
least-privilege support-process profile.

**Required action.**

1. Choose and name the profile before collecting acceptance evidence.
   The recommended isolation candidate is an exact spike kernel with
   `CONFIG_USER_NS=y` plus explicit `--directfs=false`. Re-evaluate the kernel
   security tradeoff; do not silently change the shipping reader kernel.
2. If a preliminary functional run intentionally keeps DirectFS, specify
   `--directfs=true`, label the result **functional/DirectFS only**, and do not
   count it toward isolation acceptance or release.
3. In the selected-profile run, record the effective `runsc` configuration and
   host `/proc` evidence for every support PID: executable, UID/GID, user/mount/
   PID/network namespace links, `CapEff`/`CapBnd`, cgroup, and disappearance on
   teardown. Assert the expected DirectFS value rather than trusting a log
   summary.
4. Pin security-sensitive runtime choices. At minimum the reviewed release
   needs:

   ```text
   --platform=systrap
   --network=none
   --directfs=false                 # for the isolation candidate
   --sidecar-usage-policy=strict
   --sidecar-release-enforcement-policy=always
   --ignore-cgroups=false
   ```

   Also explicitly retain the intended safe values for host UDS/FIFO access,
   host character-device passthrough, SUID handling, OCI flag overrides, and
   root overlay behavior. Launch from a sanitized supervisor environment;
   specifically, do not inherit `GVISOR_ENFORCE_RELEASE=SKIP`, which upstream
   documents as bypassing sidecar release enforcement.

### 2. High — the notes misstate this release's sidecar fallback default

**Classification: verified bug.**

`pinenote/packages/gvisor.scm:16-20` says the candidate changed the default to
disallow the embedded fallback. `doc/book-computer-execution-spike.md:263-266`
makes the same claim. In the exact target commit, however:

- [`RegisterFlags`][gvisor-flags] initializes `--sidecar-usage-policy` to
  `DEFAULT` and says that default will change to strict only after 2026-09;
- [`SidecarUsagePolicy.AllowEmbeddedFallback`][gvisor-config] returns true for
  both `DEFAULT` and `LEGACY_DEPRECATED_SLOW_EMBEDDED_FALLBACK`.

The release changelog is misleading here because consecutive commits changed
and then restored this behavior; the source at the tagged target is decisive.
The package currently installs the right helpers, but a missing or incorrectly
resolved helper can fall back to embedded code and conceal a packaging/runtime
resolution failure.

**Required action.** Correct both local claims. Add
`--sidecar-usage-policy=strict` and
`--sidecar-release-enforcement-policy=always` to the launcher, sanitize the
launcher environment, and make the VM gate observe “sidecar found” paths under
the pinned package output. Add a negative fixture in which a temporary copy of
`runsc` has no adjacent `gvisor-bin/`; strict mode must fail instead of starting
with embedded helpers. `runsc --version` alone does not prove helper selection.

### 3. High — the existing QEMU patterns are not a safe disposable adversarial envelope

**Classification: prerequisite unproven.** The existing scripts are valid
reader boot/service regression tools; this finding applies if they are used as
the pattern for hostile execution tests.

**Evidence.**

- Neither `pinenote/scripts/qemu/run-pinenote-virt.sh:58-64` nor
  `pinenote/scripts/qemu/run-virt-assertions.sh:130-140` specifies a network
  option. QEMU 10.2.1's own [`qemu-options.hx`][qemu-options] says that, absent
  networking options, it activates a default NIC with a `user` host-network
  backend; `-nic none` is the explicit override.
- Both attach the supplied raw disk writable with
  `-drive if=virtio,format=raw,file="$disk"`. A prior guest can therefore leave
  persistent state in a reused image, and a failed test can destroy the clean
  baseline needed to interpret later evidence.
- `run-virt-assertions.sh:99-140` creates a log and filesystem console socket
  without setting `umask 077` or first creating a private run directory. It
  then logs in as root over that socket (`:157-212`). This is intentional for
  the reader harness, but unsafe to expose to other local users during an
  adversarial run.
- `make-virt-disk.sh` does constrain the requested disk beneath
  `/tmp/wilkbook` and recreates it, but the spike document proposes a stable
  filename (`doc/book-computer-execution-spike.md:381-396`). The future harness
  does not yet enforce per-run ownership or non-reuse.

`runsc --network=none` constrains the sandbox network; it does not remove the
VM guest's NIC. A sandbox escape into the VM, a root-console interloper, or a
guest-side test helper would still have the QEMU user network.

**Required action before the first adversarial VM run.**

1. Use a newly created mode-0700 run directory and `umask 077` for the disk,
   console socket, logs, OCI bundles, runtime state, and test canaries. Reject
   symlinks and pre-existing paths where creation is expected to be exclusive.
2. Add `-nic none` (or an equivalently explicit no-network device graph) and
   assert in the guest that no non-loopback interface/default route exists.
3. Make disk disposability structural: use a read-only baseline plus a
   temporary QEMU snapshot/COW layer, or an exclusively created, uniquely named
   disk that is destroyed after the run. Refuse known reader/release disks and
   do not accept a caller-supplied shared writable image.
4. Keep the root console only if the harness needs it, inside the private
   directory. Install traps that kill/wait for QEMU and remove sockets/runtime
   state on every exit path.
5. Pass no host directory, socket, device, or credential into QEMU beyond the
   explicit boot inputs. The workstation's QEMU process remains a separate
   outer boundary; the gVisor denial tests must not be credited as QEMU
   isolation tests.

### 4. High — the narrow OCI filesystem and output-import contract is specified but not proved

**Classification: prerequisite unproven.** This is acknowledged future work at
`doc/book-computer-execution-spike.md:338-341` and is not a defect in an
implemented generator.

The direction at `:416-433` is sound, but “the profile and its transitive
closure” needs a mechanically exact construction. The profile is itself a
Guix store object containing links to package outputs. Mounting only its path
will not make dynamically linked Guile/Python dependencies reachable; mounting
the broad store would violate the architecture. The chosen input and writable
output sources also become host authority exposed through the Gofer or
DirectFS, so host-path validation matters even when the in-sandbox destination
looks narrow.

**Required evidence.**

- Derive the requisites from the retained profile object, canonicalize and
  deduplicate them, and mount exactly those store objects at their original
  `/gnu/store/...` paths plus the profile link. Fail on a missing requisite;
  never recover by mounting `/gnu/store` wholesale.
- Generate `config.json` exclusively from trusted constants. Reject unknown
  fields, annotations, hooks, namespace overrides, mount types/options, and
  book-supplied host paths. Set `root.readonly=true`; make closure/program/input
  mounts read-only with `nosuid,nodev` and `noexec` where execution is not
  required. Pin root-overlay behavior instead of inheriting it.
- Materialize each book input as an immutable, run-owned snapshot. Do not bind
  an arbitrary mutable library subtree that may contain sockets, devices,
  FIFOs, hard links, or symlinks outside the grant.
- Use separate private scratch and output. A cgroup is not a disk quota: bound
  tmpfs/output independently and exercise ENOSPC/oversize behavior.
- Stop the domain before importing output. Walk/import relative to an already
  opened directory, reject non-regular files and links, enforce file/count/
  aggregate limits while copying into a new trusted object, and never consume
  an in-place path selected by the payload.
- Capture the effective mount table and run positive and negative canaries for
  every allowed/forbidden class listed at
  `doc/book-computer-execution-spike.md:489-497`. Include host runtime state and
  control sockets among the forbidden canaries.

### 5. High — whole-domain cgroup enforcement and root-supervisor privilege are not established

**Classification: prerequisite unproven.** The long-term supervisor privilege
choice is additionally a deferred production policy; see the release blockers.

Kernel symbols alone do not establish an available, writable, delegated cgroup
hierarchy. The dedicated system reuses `%pinenote-base-services`; the reviewed
repository service definitions contain no execution-specific cgroup mount or
delegation service. No rootfs has been built, so the relevant `/proc/self/
mountinfo`, controller, and subtree state is unknown.

At the pinned gVisor commit, [`Container.createRoot`][gvisor-container] defaults
an empty OCI `cgroupsPath` to `/<container-id>`, leaves cgroups enabled unless
`--ignore-cgroups=true`, and enters the cgroup while creating the Gofer and
Sentry. That is the right whole-domain mechanism only if the hierarchy exists,
the required controllers are enabled, the limits are actually written, and
every support process remains in the intended subtree. OCI process rlimits do
not substitute for this.

**Required evidence.**

1. Before launch, record cgroup version/mount, writable delegated path,
   available/enabled controllers, and current supervisor cgroup. Choose an
   explicit run-owned `cgroupsPath`; do not rely on `/ID` ownership working by
   accident.
2. Put memory, PIDs, and CPU limits in the trusted OCI resources and fail
   closed if any required controller or write is unavailable. Keep an external
   wall-clock watchdog and separate output/diagnostic limits.
3. During the run, enumerate `runsc`, Sentry, Gofer, prewarmer/metric helper if
   present, and payload state. Prove all charge to the intended domain and that
   memory/PID/CPU exhaustion fixtures terminate predictably without exhausting
   the VM.
4. After `kill --all` and `delete --force`, prove the cgroup is empty/removed,
   all support PIDs and inherited FDs are gone, and a persistent descendant
   cannot emit a late sentinel.
5. Treat the root launcher as a separate privilege domain. For the disposable
   VM it may be an explicitly accepted functional expedient. For release,
   specify the service account, executable/config ownership, runtime-root mode,
   environment, capabilities, namespace setup, cgroup delegation, and which
   narrowly audited step—if any—must begin as root. A non-root OCI payload is
   not evidence for any of those properties.

### 6. Medium — inherited-FD transport has the right direction but no concrete ownership or lifecycle proof

**Classification: prerequisite unproven.**

`doc/book-computer-execution-spike.md:451-456` proposes moving from bounded
stdio to `--pass-fd M:N`, while the architecture correctly keeps diagnostics
separate and derives identity from the supervised connection. No implementation
yet proves descriptor numbering, close-on-exec handling, endpoint ownership,
EOF behavior, backpressure, or cleanup.

**Required evidence.**

- Have the supervisor create a private `AF_UNIX` socketpair—preferably
  `SOCK_SEQPACKET` if the exact runtime path supports it, otherwise
  `SOCK_STREAM` with the existing length framing. No filesystem socket is
  needed.
- Keep the broker endpoint `CLOEXEC`. Clear `CLOEXEC` only on the donated copy
  for the `runsc` exec, map a fixed source FD to a fixed container FD, and close
  every unused duplicate immediately in each process. Do not route this through
  a shell that can silently rearrange descriptors.
- Assert the payload sees exactly the intended FD and no launcher/control/
  credential FDs. Keep stdin closed or separately defined; cap stdout/stderr as
  untrusted diagnostics rather than parsing them as protocol.
- Test fragmentation/coalescing as applicable, oversize/depth rejection,
  bounded send and receive queues, a peer that never reads, half-close/EOF,
  peer death, cancellation with late replies, and forced teardown. Connection
  ownership—not a `hello` field—must select the execution identity and grants.

### 7. Medium — the cheap package checker can report completeness after manifest drift

**Classification: verified bug.** Current package contents are correct; this is
a false-green path in the test harness.

With no options, `check-gvisor-package.sh:73-97` greps selected literals from
the package and verifies only that `expected-release-members.txt` contains six
unique lines. It never compares that manifest with `%gvisor-release-members`.
In particular, the no-option checks do not require `checkpointgofer` or
`runsc-metric-server` in the package's canonical member list. The pass message
“package source pins complete ARM64 release” is therefore stronger than the
mechanized evidence.

An independent static extraction during this review found that the two lists
currently match exactly. Archive/output checks also compare actual files with
the expected manifest, and the package's build phases have their own hardcoded
layout checks, so this is not evidence of a missing installed helper today.

**Required action.** Use one canonical member manifest, or make the no-option
gate parse/evaluate `%gvisor-release-members` and compare exact sorted content
with the external file. Add mutation tests that remove and add each member and
change a directory into a symlink. The gate should separately name what it has
proved: source pin, package manifest, archive, installed output, and executed
runtime resolution.

### 8. Medium — the recorded package realization is internally inconsistent

**Classification: verified bug.** This is stale evidence bookkeeping, not a
binary-content failure.

`doc/book-computer-execution-spike.md:296-304` and `:363-370` record package
output
`/gnu/store/1zwslw4dnc4afb2kh3a8pbhzibqdk1b9-gvisor-bin-20260831.0`.
The current `doc/book-computer-implementation.md:111-116` records instead
`/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0` for the
bounded package build. Both paths exist locally, and their six relative member
SHA-256 sets are identical; this is not a binary-content discrepancy. The
distinct store names nevertheless identify distinct derivations, while the
records do not tie each derivation to the package-source hash that produced it.
An old successful realization is not evidence that a later definition's
build-time gates ran.

**Required action.** Once the package definition is frozen, compute its exact
pinned-channel derivation, use the resulting one output in every current
evidence record, and rerun the non-executing `--output` inspection on that
output. The review records the current implementation record's six member
hashes below. Historical outputs may remain as history only if labeled with the
package source hash/commit that produced them. Package acceptance must refer to
one self-consistent definition/derivation/output/check tuple.

### 9. Release — hashes establish identity, not independent authenticity or source correspondence

**Classification: deferred production policy.** This need not block the
explicitly non-shipping, offline package spike.

The fixed SHA-256 is valuable: it makes later asset replacement fail rather
than silently changing the package. The GitHub release API currently reports
the exact AArch64 zstd asset size as 119,968,856 bytes and its digest as
`sha256:c1182b6046e1c64b871cd13b4d11335f1d55ba89c3a5c7e8cf4dc1c8f3ac0d3a`,
matching the package. It also reports `immutable: false`. The annotated tag
object `7346147ed369e94e93976a4a0f115f51bd5f7130` targets commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, but GitHub reports
`verified: false`, reason `unsigned`.

SHA-256, SHA-512, and the API digest all describe the same publication channel;
they are not three independent authenticators. Nor does inspection of a static
binary prove that it was built from the tagged source. The package and README
now disclose most of this accurately.

**Required release decision.** Name the accepted trust root and threat model.
Options include an independently verified upstream signature/attestation, a
reviewed reproducible source build, a project-controlled verified mirror plus
reviewed provenance record, or an explicit decision that content-addressed
GitHub release assets are sufficient. Record the binary-to-source claim that
is and is not being made. Do not present additional hashes from the same
unsigned release as independent provenance.

## Gate-specific blockers

### Package acceptance

1. Correct the false embedded-fallback claims in
   `pinenote/packages/gvisor.scm` and
   `doc/book-computer-execution-spike.md` (finding 2).
2. Make the cheap checker compare the exact package member list with its
   expected manifest, with a false-green mutation test (finding 7).
3. Reconcile the current package definition, derivation, output, and evidence
   record (finding 8).

After those corrections, I find **no package-content, AArch64 target, standard
helper-layout, or offline-resolution blocker** for accepting `gvisor-bin` as a
non-shipping spike package. A source build or stronger provenance is a release
decision, not a prerequisite for this bounded functional experiment.

### First disposable-VM execution

1. State whether the run is **functional/DirectFS** or the intended isolation
   candidate. The latter requires an exact kernel with user namespaces and
   explicit `--directfs=false`; never let omission choose (finding 1).
2. Pin strict sidecar use/release matching, sanitize the launcher environment,
   and observe the resolved package helper paths (finding 2).
3. Use the no-network, private-console, throwaway-disk QEMU envelope in finding
   3. Existing reader QEMU commands must not be copied unchanged.
4. Generate and statically validate the exact narrow OCI closure/mount policy
   before launch; make output import safe and bounded (finding 4).
5. Preflight the cgroup hierarchy and fail closed on unavailable required
   limits; collect whole-domain process/cgroup evidence (finding 5).
6. For integrated protocol acceptance, implement the inherited socketpair and
   its lifecycle/backpressure assertions (finding 6). A preliminary
   `runsc --version` or `/bin/true` run may precede this, but cannot satisfy the
   documented integrated target.

### Release of untrusted-book execution

1. Select, document, and adversarially qualify the DirectFS/user-namespace and
   root-supervisor profile on the exact shipping kernel and system.
2. Pass repeatable mount, device, network, control-socket, FD-leak, confused-
   deputy, resource-exhaustion, output-import, cancellation, descendant, and
   stale-handle denial tests. QEMU functional success is not this gate.
3. Establish whole-domain CPU/memory/PID, wall-time, diagnostic, storage, and
   broker-work limits, including cleanup across crash, reader restart, suspend,
   and power loss.
4. Decide and record release provenance/authenticity policy for the prebuilt
   runtime or replace it with the selected verified build path (finding 9).
5. Measure startup, total memory, idle wakeups/power, suspend behavior, and real
   Guile/Python workloads on PineNote. Do not infer these from x86 host sanity
   or QEMU TCG.

These are release blockers for the selected untrusted-execution feature, not
claims that today's reader image contains incomplete vulnerable code.

## Package/target/helper observations with no finding

- The package uses a fixed-output `url-fetch` origin and
  `supported-systems '("aarch64-linux")`; the reviewed cross-target command is
  consistent with the repository's foreign-binary packaging pattern.
- `gnu-build-system` preserves target identity while native `binutils` and
  `zstd` inspect/unpack the foreign bytes. The phases do not execute AArch64
  code and check AArch64 ELF machine, no interpreter, no `NEEDED` entries,
  executable mode, regular-file type, and exact two-level layout.
- The installed standard sidecars are `checkpointgofer`,
  `gvisor-sentry-prewarmer`, `gvisor_sentry`, and `runsc-metric-server`.
  Upstream's [`gvisorbinaries.All` and resolver][gvisor-binaries] name the same
  set and resolve `gvisor-bin/` next to `/proc/self/exe`, retrying after symlink
  resolution. Thus invocation through a Guix profile symlink reaches the real
  package output's adjacent directory.
- `gvisor_sentry_plugin_stack` is intentionally not in the standard `All` set
  and is selected only for the plugin network stack. It is not required by the
  proposed `--network=none` profile.
- Retaining `containerd-shim-runsc-v1` makes the upstream release installation
  complete but does not add containerd or make the direct OCI path depend on
  it.
- The dedicated system is separate from shipping flavors, installs `runsc` in
  the system profile, retains the narrower Guile/Python profile through `/etc`,
  and inherits the no-Guix-daemon base service set. These are useful static
  properties, not execution evidence.

## Review method and exact scope

Review snapshot: **2026-09-04T21:56:53Z**, repository base
`50572d7796abdb0928969f4db8836fc5e30aeb58`. Several primary files were
untracked work in progress, so the hashes below—not `HEAD` alone—define the
reviewed bytes. Later changes are outside this review.

### Primary files and reviewed scope

Whole-file hashes identify the snapshot; the architecture document was scoped
to execution/security and its delivery gates rather than reviewed as a complete
product specification.

| SHA-256 | File and scope |
|---|---|
| `2787a99de13f7ad674f8d88ee86c832d86f6c69d0fc972740e06910d316c9c4c` | `CLAUDE.md`, full file |
| `aef579f6b1126a9d0803054ee78249e75adfd0c82ac9a00ff3b021fe6ebe8f6e` | `doc/wilkbook-self-hosting-book-computer.md`, execution objects, §§7–8, implementation/release gates, evidence summary, open execution questions, non-goals, and source pointers |
| `99d11662bff218f3de97c6e9f85138ca2d0443a5ff50e97445daf90e45338810` | `doc/book-computer-implementation.md`, full file |
| `c7e1435fdc4a252d2e2db58b6eee83f5425d9c76d7848e141c6cb2ac845c774c` | `doc/book-computer-execution-spike.md`, full file |
| `6b5e1ab53d21b4ea45f119839e4a16f7de582ef6218cd7d3cf6537daf98c9b6d` | `pinenote/packages/gvisor.scm`, full file |
| `7d1829c3d6cb4fb1c91ecb9b0ba365136fb9a5ccc94148be7318cb0e82bf2720` | `pinenote/systems/pinenote-book-execution-spike.scm`, full file |
| `ace66c5393dcb3a75201dffe877d86775927b287d85d1507895e8b03d1ba0306` | `pinenote/tools/book-execution-spike/README.md`, full file |
| `1f357bd642ec07f047f9228d8fd8c0e4f937d1f1011742e988e8b6f8de94e115` | `pinenote/tools/book-execution-spike/check-gvisor-package.sh`, full file |
| `b79ec88a8291d8fe89dd690040dda0af55cf4db5c08cac442abc7c029dfffc3e` | `pinenote/tools/book-execution-spike/expected-release-members.txt`, full file |

### Supporting local evidence

The three QEMU scripts were reviewed in full. The other large files were read
only for the named orientation/config/service/target snippets; their whole-file
hashes identify the snapshot containing those snippets.

| SHA-256 | File and reviewed portion |
|---|---|
| `d5c5b233ab7ae1b2ea7a49f825f978e2dc0a399c9e2e0162164fae4c11386156` | `ROADMAP.md`, orientation/testing ladder through line 220 |
| `a6ca0fbc2a5b45775dda95da9ef295ec0504904a11d704e2cde09d0c71603320` | `doc/status.md`, current-state header and lines 1-180 only |
| `bf0a58e4feb0efb9d5ed6829342b958bee7606ec8a803543a347d0479c72f89e` | `pinenote/patches/linux-pinenote-7.0-forward-port.patch`, defconfig namespace/cgroup block only |
| `699afd669c10908324847ba1802415563c77580f55edbca0cbebc4f1bfcf7106` | `pinenote/packages/kernel.scm`, QEMU-virt config additions only |
| `a83ccf2647b971e454e1a7b230b3ed39e6b2a9edbd1c68116c4fc48a7fe98658` | `pinenote/systems/base.scm`, package/base-service composition only |
| `dca3da2107b2364e40e4f5269fe9f20bd6f68cb5eff0526f95478b20c1f3db52` | `pinenote/scripts/qemu/run-pinenote-virt.sh`, full file |
| `377f27ce9ebd82fb6e4863c077263e61431b65d39329a0cf0af729777c9b1791` | `pinenote/scripts/qemu/run-virt-assertions.sh`, full file |
| `e5b0bf6a4a8e1450ce5726c0679bdf6abf47d6bccfc55def4f575c1f36a17f60` | `pinenote/scripts/qemu/make-virt-disk.sh`, full file |
| `b56c06ce794e52707cc2ca22de604a11fc55ee89f223a2b8ce01448d424afa02` | `Makefile`, QEMU target command chains only |
| `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` | `channels.scm`, Guix revision pin |

### Exact external scope

- gVisor tag object/API record
  `7346147ed369e94e93976a4a0f115f51bd5f7130`, target commit
  `fd2f6b2674208086e324c2f739155eb7e1b48ff2`, and release API record
  `382925920`, fetched 2026-09-04.
- At that exact commit, only the relevant functions/types in:
  `runsc/config/flags.go`, `runsc/config/config.go`,
  `runsc/sandbox/sandbox.go`, `runsc/gvisorbinaries/gvisorbinaries.go`,
  `runsc/specutils/specutils.go`, `runsc/container/container.go`, and
  `runsc/cgroup/cgroup_v2.go`.
- QEMU tag `v10.2.1`, network-default text in `qemu-options.hx` only.
- The gVisor install, rootless, platform, resource, and direct-OCI guides linked
  from the spike note, used as explanatory context. Exact source behavior above
  takes precedence over live guide wording.

### Bounded checks run

```text
PASS: package source pins complete ARM64 release release-20260831.0
shell syntax: PASS
package/member manifest current equality: PASS   # independent extraction
PASS: installed output exact layout and six static AArch64 ELFs
```

The independent equality check was necessary because finding 7 shows that the
first pass does not itself perform that comparison. The installed-output check
used the current implementation record's `8wgxl0...` output and did not execute
it. The exact release API and tag records were queried. The 120 MB archive was
not downloaded again, and the package build was not duplicated.

The checked `8wgxl0...` output's exact member hashes (also equal to the local
`1zwslw...` output's members) were:

| SHA-256 | Relative member |
|---|---|
| `dffb9b463a5d3538663df0c75ca1d59a23549fed36c5e105c44e7430bb8a7e82` | `bin/containerd-shim-runsc-v1` |
| `b8679df902c900f7c5c5660a4a1b0c7f8433da19760e3c8c126eddbb238f2511` | `bin/gvisor-bin/checkpointgofer` |
| `502b8b28f6a98a345a3e4bee8e1542dadaead1839e78697ba1296791adcd7632` | `bin/gvisor-bin/gvisor-sentry-prewarmer` |
| `c49b09cd42d2ae2d2d0d33cc32f746240b5b528db1864f922097c6958312bc07` | `bin/gvisor-bin/gvisor_sentry` |
| `da7ee8385f7ab07d6bd81a0ec5ee6f6e5e9989210af3a629147ba3d9cf2b0681` | `bin/gvisor-bin/runsc-metric-server` |
| `d5679775682cd4cb11ba7bf7bd8e04235622aa8797d518dd280064e5cd27ed5d` | `bin/runsc` |

No package/system/kernel/image build, QEMU boot, ARM64 execution, device access,
SSH, UART, deployment, or hardware operation was performed. No future launcher
or OCI implementation was assumed to exist.

[gvisor-flags]: https://github.com/google/gvisor/blob/fd2f6b2674208086e324c2f739155eb7e1b48ff2/runsc/config/flags.go
[gvisor-config]: https://github.com/google/gvisor/blob/fd2f6b2674208086e324c2f739155eb7e1b48ff2/runsc/config/config.go
[gvisor-sandbox]: https://github.com/google/gvisor/blob/fd2f6b2674208086e324c2f739155eb7e1b48ff2/runsc/sandbox/sandbox.go#L1147-L1245
[gvisor-binaries]: https://github.com/google/gvisor/blob/fd2f6b2674208086e324c2f739155eb7e1b48ff2/runsc/gvisorbinaries/gvisorbinaries.go
[gvisor-container]: https://github.com/google/gvisor/blob/fd2f6b2674208086e324c2f739155eb7e1b48ff2/runsc/container/container.go
[qemu-options]: https://gitlab.com/qemu-project/qemu/-/blob/v10.2.1/qemu-options.hx#L3101-3105

## Independent implementation re-review — 2026-09-04

### Re-review verdict

The package corrections are accepted for the bounded, non-shipping package
gate. The exact package/member comparison now exists, all advertised package
mutations were killed, and the already-realized package output still has the
six expected static AArch64 ELFs and the previously recorded member hashes.
The generated OCI policy also has several sound static properties: runtime
profile selection is mandatory, the supervisor and payload environments are
constructed rather than inherited, every emitted flag exists with the emitted
value at the pinned gVisor commit, and the root and selected bind mounts are
declared read-only with the default writable overlay explicitly disabled.

Finding 1 is nevertheless **reopened**. The disposition's claim that
`functional-directfs` can run on the reviewed `CONFIG_USER_NS=n` kernel is
contradicted by the pinned runtime source. `container.New` calls
`modifySpecForDirectfs` before sandbox creation. With `--directfs=true`,
`--network=none`, and no pre-existing OCI user namespace, that function adds a
user namespace and identity UID/GID mappings. The sandbox then enters that
namespace. The non-DirectFS branch also creates the support-process user
namespace already identified by the first review. Thus **both currently
generated profiles require host user-namespace support**; Systrap itself still
does not. The current test that expects no user namespace and an empty
`requiredKernelConfig` for `functional-directfs` pins the wrong conclusion.

The cgroup record is also more specific than the disposition says. The
generator supplies neither `linux.resources` nor `cgroupsPath`, so it supplies
no CPU, memory, or PID ceiling. However, because `--ignore-cgroups=false`,
`runsc` synthesizes `/<container-id>` as `CgroupsPath`, creates it, and places
the sandbox/support-process domain in it. That is real whole-domain membership,
but with nil resources it is not a resource limit. The reviewed spike system
declares `%base-file-systems` and no `%control-groups` extension, so it contains
no declared `/sys/fs/cgroup` mount for that operation. A runtime preflight is
still required, and the exact launcher is expected to fail cgroup setup unless
the guest image adds the hierarchy.

These two issues block the exact current launch vector, not package acceptance.
They also do not make complete production budgeting, output import, or private
FD integration prerequisites for a first compatibility smoke. A first
functional disposable-VM run may remain deliberately narrow once it has a
reviewed `CONFIG_USER_NS=y` test kernel, the cgroup plumbing required by its
exact flags, the dedicated language profile, fixed boot inputs, and guest
success/failure assertions. It still cannot count as isolation acceptance.

### Finding 10 — high: `functional-directfs` also requires `CONFIG_USER_NS=y`

The relevant pinned-source sequence is:

1. `runsc/container/container.go:New` invokes `modifySpecForDirectfs`.
2. For DirectFS with non-host networking, no user namespace, and no test-only
   bypass, that function appends `specs.UserNamespace` and identity mappings.
3. `runsc/sandbox/sandbox.go` sees DirectFS plus that namespace, installs the
   mappings, and starts the sandbox in it.
4. For non-DirectFS, the alternate sandbox branch appends a new user namespace
   for the reduced-privilege support-process arrangement.

The reviewed defconfig contains `# CONFIG_USER_NS is not set`. Consequently:

- `functional-directfs.requiredKernelConfig: []` is false;
- describing it as the “only current-kernel candidate” is false;
- the OCI test's assertion that the generated spec has no `user` namespace is
  only true before `runsc` mutates the spec, not at sandbox creation; and
- no current generated profile is runnable on that kernel as written.

**Required correction.** Record `CONFIG_USER_NS=y` for DirectFS too, correct
the generator tests and execution notes, and use a separately reviewed test
kernel for the first functional attempt. Do not attribute the requirement to
Systrap and do not silently retry with host networking, a test-only runtime
flag, ptrace, native execution, or another profile.

### Finding 11 — medium: cgroup membership is synthesized, but no limits or guest mount are supplied

`runsc/container/container.go:createRoot` fills an empty `CgroupsPath` with
`/<container-id>` whenever cgroups are not ignored. It then creates/joins that
cgroup before starting the Gofer and Sentry. The generated OCI object has no
`linux.resources`, so `cgroupInstall` receives nil resources and installs no
CPU, memory, or PID budget. `--ignore-cgroups=false` therefore does more than
set an inert flag, but much less than impose the limits required for isolation
acceptance.

The system definition does not add Guix's `%control-groups` filesystem list,
and its base operating-system constructor uses `%base-file-systems`, which does
not include cgroup2. No reviewed service supplies the missing mount. This is a
launch-plumbing gap as well as an honest resource non-claim.

**Gate effect.** For a functional smoke, mount and preflight the hierarchy (or
define and review a distinct functional-only cgroup policy); production
ceilings need not precede that smoke. Before isolation acceptance, emit exact
nonzero CPU/memory/PID resources, verify the resulting host files and support-
process membership, and kill a fixture against every bound. A green payload
rlimit or scratch-size test is not that evidence.

### Closure authority and path-race recheck

The closure construction itself is exact relative to its trusted profile
argument. Requisites must resolve to unique, non-symlink, top-level store
objects; the selected profile must be among them; `python3` must resolve into
that closure; and the generator emits one bind mount per requisite rather than
one `/gnu/store` mount. A book path outside the store, through a symlink, inside
the language closure, or naming a non-regular object was rejected. The tool
does not read book manifest authority.

It does **not**, however, identify the approved profile. Any trusted caller can
select any top-level `*-profile`. The real replay selected this workstation's
`/gnu/store/v3phpz095bfiqxkjx31wb03wrp948q9x-profile`: it has 320 direct `bin/`
entries and produced 844 unique store mounts (848 mounts total). It did not
mount the whole store, but it did expose the whole closure of that broad
selected profile. The docs label this replay correctly as parsing evidence,
not approved authority. The dedicated Guile/guile-json/Python profile remains
only an unrealized derivation, and no image-preparation caller yet pins its
canonical output. The future caller must do so; profile-name suffix validation
alone is not an authority decision.

The checks are also pathname checks, not descriptor-backed snapshots. Bounded
fixtures established all three of the following:

- retargeting the input profile alias after initial resolution did **not**
  change the profile handed to the requisites runner or the mounted profile;
- replacing a validated regular book in a deliberately mutable fake store with
  a symlink before spec construction was accepted, leaving a recorded source
  that resolved outside that fake store; and
- replacing a validated bundle parent with a symlink before `mkdir` created
  the bundle below the redirected parent.

The latter two fixtures do not model an ordinary unprivileged book changing
the real Guix store. The real replay's fixture was mode 0444, its profile mode
0555, and both are retained store objects; the replay also used a mode-0700 run
directory. They show that safety depends on those external immutability,
retention, and private-parent facts rather than an FD snapshot inside the
generator. There is no shipping execution feature here to call vulnerable.
The first VM harness must preserve those facts and revalidate final staged
identity; isolation acceptance should use open descriptors/digests or an
equivalent no-follow handoff across the generation-to-launch gap.

The concurrently added disposable-QEMU runner improves the baseline-disk path:
it opens with `O_NOFOLLOW`, compares descriptor/path identity around a private
copy, and verifies the private bytes against the operator-supplied SHA-256.
Its boot inputs do not receive equivalent expected hashes, and their validated
identities are not carried into `private_snapshot`. A fixture validated a mode-
0444, single-link `Image`, replaced it by rename with another mode-0444,
single-link file, and the later snapshot accepted the replacement. Likewise,
`validate_run_base` does not retain a directory FD; swapping that parent to a
symlink before `mkdtemp` redirected creation. These are trusted preparation
inputs, so this is not guest code escaping. Before relying on the runner for a
reviewed functional boot, bind the private boot copies to recorded hashes or
validation-time descriptors and require a stable private run parent.

### Runtime flags, environment, and immutable-root recheck

No additional flag spelling/value bug was found. At commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, the runtime registers every emitted
flag. Lowercase `strict` and `always` are accepted by case-normalizing parsers;
`network=none`, `host-uds=none`, `host-fifo=none`,
`character-device-policy=emulated-only`, both exclusive file-access values,
`overlay2=none`, and both DirectFS booleans are valid. The emitted OCI umask and
rlimits are represented by the pinned runtime-spec types, and pinned
`loader.go` applies the umask and limit set.

The supervisor launch uses an absolute `runsc` path under `env -i` with only
fixed HOME/locale/PATH/private-TMPDIR values, so an inherited
`GVISOR_ENFORCE_RELEASE=SKIP` does not reach `runsc`. The payload environment is
also an exact list and Python starts with `-I`. Execution-profile selection is
required by argparse and has no fallback. These are accepted static
properties, not observations that the ARM64 binary parsed the arguments or
resolved the adjacent helpers.

The OCI root has `readonly: true`; `overlay2=none` disables the pinned release's
default root overlay; closure and input binds carry `ro`; and only `/dev` and
`/scratch` are declared tmpfs writes. Pinned `vfs.go` constructs the root mount
with `ReadOnly` from the spec and restores it read-only after submount setup.
This is sufficient static evidence for the intended immutable-root
configuration. Actual DirectFS write-denial and mount-canary behavior remain
runtime gates.

### Package checker and test-count recheck

The advertised counts are real: the OCI module exposes exactly 10 unittest
methods and the package module exactly three. The package methods execute six
remove-member subtests, six duplicate-member subtests, and one sidecar-directory
symlink case. The aggregate passed all of them plus the no-option package gate.
Independent same-count substitutions in the package list and external manifest
also failed, and a duplicate external manifest failed. Installed-output
inspection again passed on
`/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0`.

The QEMU test module changed concurrently and, at the exact snapshot below,
exposed six methods; all six fake-command tests passed. The disposition still
records five, a minor count-only bookkeeping drift. No real QEMU or `runsc` was
launched.

### Gate disposition after re-review

| Gate | Re-review disposition |
|---|---|
| Package acceptance | **Accepted for the bounded non-shipping spike.** Findings 2, 7, and 8 are closed for package content/checking/bookkeeping. Release provenance remains separate. |
| First functional disposable-VM execution | **Not ready with the exact current kernel/vector.** Fix finding 10, supply the cgroup mount required by the chosen explicit policy, pin the dedicated language profile, freeze boot input identity, and add guest assertions. Full production budgets, output import, and inherited-FD protocol acceptance may follow this narrowly labeled smoke. |
| Isolation acceptance | **Open.** Neither named profile has runtime evidence. Exact mount denials, DirectFS decision, helper identity, whole-domain limits, support-process privilege/accounting, teardown, bounded outputs, and hostile workload tests remain required. |
| Release of untrusted-book execution | **Open and later.** Isolation acceptance, provenance policy, integrated broker/FD lifecycle, recovery, and PineNote qualification are still absent. |

Missing/private-FD behavior remains future integration work. This re-review did
not turn its absence into a current vulnerability and did not require it before
the preliminary functional smoke.

### Exact re-reviewed snapshot

Snapshot time: **2026-09-04T22:35:43Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`; in-scope implementation files were
untracked concurrent work, so these hashes define the reviewed bytes. The
original report hash is its value immediately before this section was appended.

| SHA-256 | File |
|---|---|
| `a8a435c7452050ada3d14fb7a061b4d6ecc028f9e2df0bb7ffb9826c92f89015` | this report before the re-review section |
| `5c9e99743623dba9d03569f955dad98e5996e96e0e5edfe9cb73c40763ee5b4c` | `doc/reviews/2026-09-04-book-execution-adversarial-disposition.md` |
| `e69b5a3a347d7630dc49e64798e8c260bd8e90ee7b05570d6447e7b5d23b8cec` | `doc/book-computer-execution-spike.md` |
| `73bb9289b680207eb61a6c9622808d1def5b16126e036f808abfcb4e76359efb` | `doc/book-computer-implementation.md`, execution status only |
| `8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d` | `pinenote/packages/gvisor.scm` |
| `10a7a4b881cffa9b231576022b575dfd81ccd8838f9aaf1bf9e60e27e672dde7` | `pinenote/systems/pinenote-book-execution-spike.scm` |
| `020c2606e8ed484089c2083e0be438b9d0736bee1558a6b76af0d58bd23f69cf` | `pinenote/tools/book-execution-spike/.gitignore` |
| `81271637eaacfe72be3cf7c5797562637880a8a27023d1251a10ef4ee4c4787c` | `pinenote/tools/book-execution-spike/README.md` |
| `0ec06d367cd778449df158db0ff07dbdf4e3a0b9b66c4224125a31786587e2d4` | `pinenote/tools/book-execution-spike/check-gvisor-package.sh` |
| `b79ec88a8291d8fe89dd690040dda0af55cf4db5c08cac442abc7c029dfffc3e` | `pinenote/tools/book-execution-spike/expected-release-members.txt` |
| `5c868ff6935dbbf92e0b19de42b8738f3d952f07de3d9ddd83a5097dc800d60d` | `pinenote/tools/book-execution-spike/generate_oci_bundle.py` |
| `1d4792d191de273dae6ae0fa53202edfe3913ca6520940a474e84476aa779d13` | `pinenote/tools/book-execution-spike/run_disposable_qemu.py` |
| `59da2f9a08eea80b11e47902a9e9841ff27266601dc13268088d7efca4f96bef` | `pinenote/tools/book-execution-spike/run-tests.sh` |
| `7072434f9d45c754a6bf2c394c142b9c3862b8fae23fed97b9a5ae8c7534b3f5` | `pinenote/tools/book-execution-spike/test_check_gvisor_package.py` |
| `6b788a7363e89be759c2e85eac4dfafcb14855e908de33cc0da44ace7050afb4` | `pinenote/tools/book-execution-spike/test_disposable_qemu.py` |
| `b201c4dbeed036d9e2b3504cbb236b9cc05b93df86fc085805cad4381e7b7442` | `pinenote/tools/book-execution-spike/test_generate_oci_bundle.py` |
| `bf0a58e4feb0efb9d5ed6829342b958bee7606ec8a803543a347d0479c72f89e` | `pinenote/patches/linux-pinenote-7.0-forward-port.patch`, namespace/cgroup config only |
| `a83ccf2647b971e454e1a7b230b3ed39e6b2a9edbd1c68116c4fc48a7fe98658` | `pinenote/systems/base.scm`, filesystem/service composition only |
| `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` | `channels.scm` |

Pinned external scope was commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`. Whole-file SHA-256 values for the
reviewed upstream files were:

| SHA-256 | Pinned gVisor file |
|---|---|
| `2cd847cc190722fb16ac35d313ee1cb0c12f9f3050d8e36a9580bff9b690efd4` | `runsc/container/container.go` |
| `5bb26b649bbe2bbfd5c61de1cbbadb4eb537ff5d5e6b610bac2e9dd11979198e` | `runsc/sandbox/sandbox.go` |
| `1a269e91665d022fa4cc4075b9b9c991735351a4e6beb4ab4a7a5b2c5983af50` | `runsc/config/flags.go` |
| `ad760a4e98f24d6783dc4da72c6c02bd6794f71b8b4dc72ed48267b414e9cf1c` | `runsc/config/config.go` |
| `d66cc4e0e015a20c7798e80480c3ecb4e5545c7f8d0e7e0ab1f1583107759434` | `runsc/specutils/fs.go` |
| `79d16be0d6aafae06badf4930835ad9ccb71fb9044462053cbc1a2c4004db25d` | `runsc/specutils/specutils.go` |
| `96dc1ca9891516bee5ab1f32b5ff7fd57740ef11c209fa4f092210b81192c9a2` | `runsc/boot/vfs.go` |
| `70508976f5b1d52094da8c002dd805fd9f2b8cb02a07ac3037fe8d3b250d7c15` | `runsc/boot/loader.go` |
| `433c9ddb5288d72895f255e807f95b6997e956081b409cd8a17ff4cfadb7af4e` | `runsc/cgroup/cgroup.go` |
| `c33c233ca8e33f0b61b043d6684e22bcb757df892a9aad6a4ab5aff297cf83cd` | `runsc/cgroup/cgroup_v2.go` |

### Bounded checks actually run

- `run-tests.sh`: 10 OCI tests, the then-current fake-QEMU suite, three package
  mutation methods, and static package pins passed. The current six-method
  fake-QEMU module was then rerun and passed.
- Real host-profile generation: 844 unique requisite mounts, no broad-store
  mount, explicit functional label, sanitized recorded environment, read-only
  root, and no generated resources/cgroup path. Generated `config.json`
  SHA-256: `d89920574dc2037f16385c230fd9e224042e4174dde973f09ee39d82a2466424`.
- Sorted real-profile requisites SHA-256:
  `3dce3fb077edd6144d844dfabb02afddd8713d01b59729668b942b15a478b8e6`.
- Package output inspection and member SHA-256 recomputation passed without
  executing an ELF.
- Isolated package-list/manifest substitutions and mutable fake-store,
  bundle-parent, boot-file, and run-parent race fixtures produced the outcomes
  described above.
- Shell syntax and Python compilation checks passed; generated bytecode was
  removed immediately.

No kernel/system/image build, QEMU boot, real QEMU process, `runsc`, ARM64 ELF,
guest interpreter, hardware, SSH, UART, deployment, or source implementation
operation was performed. Only this review document was changed.
