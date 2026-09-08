# gVisor matched ARM64 source artifacts adversarial review — 2026-09-05

## Scope and verdict

**Accepted for the control-image runtime gate.** The completed v12 build
produced a coherent six-file ARM64 control release and a diagnostic release
whose only binary difference is the reviewed Sentry instrumentation. The
complete source-built control release may now be packaged into a separately
reviewed control image. It must run before any diagnostic image.

This is artifact acceptance, not runtime success. No binary reviewed here has
been executed. The control has not yet reproduced the v5
`subprocess.go:219` panic, the diagnostic has not attributed an errno, and no
functional, Book Protocol, output-import, release-acceptance, or hostile-book
isolation gate is closed by this build.

This build also is not the reusable Guix runtime package. It used an explicitly
network-enabled preparation container, Bazel's owned repository/action caches,
and upstream's prebuilt protoc path. The separately accepted reusable vendor
closure selects source-built protoc and remains a distinct packaging graph.

## Reviewed identities

| item | identity |
|---|---|
| result record | `pinenote/tools/book-execution-spike/build/proposed-v6-source-build-v12-result.txt`, SHA-256 `8bbbe31073cd51ea4693d4f33434b77183e69c324d6d9f02fbf20365dcf8ca9b` |
| gVisor source | commit `fd2f6b2674208086e324c2f739155eb7e1b48ff2`, label `release-20260831.0` |
| source archive | SHA-256 `1e8fab6800b4b60cf55d55d28fcf1a2b8436363a109d3d2d394c8236058ccd82` |
| diagnostic patch | SHA-256 `9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e` |
| v12 recipe | SHA-256 `f20a6fff812ced51afd7bb97b8a797638396a9f39a35a6635bfb91dba6543399` |
| v11→v12 diff | SHA-256 `3e9fd82a0e01d7a734597d3a0ab3d658c1cb4af6373e09f61111d3dc8991bd12` |
| v12 launcher | SHA-256 `1a68ea78defa2d4e6a372a44e2f4741f13fe72307fe809e21dde66ed1d49c41c` |
| cross-GCC wrapper source | SHA-256 `3da0c015cf4c8383f01502be427eeae8ad09a1376a60ec5521deb3f033a70ca7` |
| Bazel launcher | 8.3.1, SHA-256 `17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c` |
| resolved module lock | SHA-256 `8402c7beb4baf2c666f4b78e400ea3f15514b56117598c2cb5411d6a35208d34` |
| control manifest | SHA-256 `50b5e11bcf9ca4c2a254caca51f4e353af0c98736bda751fc29a5c381773a61a` |
| diagnostic manifest | SHA-256 `8be4e6429bcac48371819cb5ff9c3dbbf559819e7f0a7da020e41f62e727e4fb` |

The retained recipe copy is byte-identical to the repository recipe. A fresh
`git archive --format=tar` of the pinned commit independently reproduced the
retained source-archive hash, and the pinned checkout was clean at review time.
Both source trees have byte-identical, mode-0444 lockfiles at the accepted lock
hash.

The builder's separate audit reports
`INDEPENDENT-SOURCE-RELEASE-AUDIT=PASS`; I treated that only as retained
evidence. Its script, log, artifact details, source delta, and input manifest
have the hashes recorded in the result file. The conclusions below were
independently recomputed from the source snapshots and artifacts.

## Six-file release artifacts

Both directories contain exactly these six regular executable files and no
others. Every file independently inspected as an ELF64 little-endian AArch64
`EXEC`, with no `PT_INTERP` and no `DT_NEEDED` entry.

| path | control SHA-256 | diagnostic disposition |
|---|---|---|
| `containerd-shim-runsc-v1` | `7fbaf0e090b1bb10ecf35a25ff2d22c6c9ccdc0d3ada6a1ab548a7ece259c548` | byte-identical |
| `gvisor-bin/checkpointgofer` | `19451cc0b04ce9d2baaa7a8e2a5abeb0b06c9c0f43bc7c182bc9954b97514846` | byte-identical |
| `gvisor-bin/gvisor-sentry-prewarmer` | `1e0d994e39f3f8d7746890a0df09cb7b88de79f90da8489c274e2fa9b0e3a81a` | byte-identical |
| `gvisor-bin/gvisor_sentry` | `b586873e1f32fc4bde4c1535780a0dae4bc4ad873a8a3858588430153878437f` | differs as `9e8548183b612dbce3a800ca2ad807dd625d9295caa183f75633a46b0378334f` |
| `gvisor-bin/runsc-metric-server` | `080fde2370aa27f176ef1af02c8a89c73644fc2970b5fbe2d30072d86cb180dc` | byte-identical |
| `runsc` | `a5aca591653e0f504d75093b1d37d301dca23e14b18f1140c406d68732b16ed3` | byte-identical |

All modes are `0555`. The prewarmer is 1,184 bytes. The other five executables
contain the `go1.26.3` marker. `runsc`, `checkpointgofer`, `gvisor_sentry`, and
`runsc-metric-server` each contain exactly one
`release-20260831.0` string in both releases. The intentionally unversioned
shim and prewarmer contain none. Control and diagnostic Bazel stable-status
files are identical and contain the same fixed release label.

All six control artifacts differ from the corresponding official prebuilt
release artifacts. In particular, the control Sentry is not byte-identical to
the Sentry that produced v5. Therefore source provenance is sufficient to
authorize the control experiment, but not to skip it: the complete control
release must reproduce the exact accepted v5 failure before diagnostic output
can be interpreted.

## Exact diagnostic boundary

The pre-build regular-file manifests each cover 4,217 files. Their SHA-256
values are:

- control: `3e40434774d3b14b34ba6d64e5d5f43fb1d10d7805fca709d222573ac4e5ee9c`;
- diagnostic: `de8466229edc6a735cb320d3507d2ba2622db59bba7360779748990b6b454120`.

Each post-build manifest is byte-identical to its pre-build manifest. A
separate full tree inventory, excluding only the two lockfiles and Bazel's
generated top-level output symlinks, found exactly three changes:

| file | control SHA-256 | diagnostic SHA-256 |
|---|---|---|
| `pkg/sentry/pgalloc/pgalloc.go` | `b854802cd6cc07fe51c678afa296627f0cc1c9cb05cffcf44e2da2e76201befa` | `6f4fc255dd7371cc8f6ab8ad8d5a2e97b89deb6c579530c501ee127499326114` |
| `pkg/sentry/platform/systrap/subprocess.go` | `e8e01b49e5abd5ccbd3ff35db98dd1fc0d3dd480d7bc6484d1edec4a0865abad` | `06a076a5e87446cc5fb347c07373e00469b942b624531a3bc5788cf2d8a7082a` |
| `pkg/sentry/platform/systrap/syscall_thread.go` | `4bef3b275e3b12d9c8951cc5b62e190533566de7dc712e75bf957a338cf32a91` | `f15d6cd9d8f076e8d5e3439984e93669940361157f69fceb1bc9c0b5230bbb2b` |

The accepted patch reverse-applies cleanly with
`--check --reverse --whitespace=error-all`. It changes only failure reporting:

- wraps MemoryFile truncate and backing-map errors with old/new size,
  length, offset, and preserved error identity;
- replaces the generic line-219 panic with the complete
  `maximumUserAddress` value (`linux.TaskSize`) and the returned error chain;
- adds length/offset/address context to allocation, Sentry mmap, and the two
  fixed stub mappings.

The patch does not change a syscall number or argument, address calculation,
mapping flag, backend, allocation policy, branch condition, runtime option, or
successful return. The final read-write error branch is a semantic expansion
of the former `return err`: error still returns and success still returns nil.

The control Sentry retains `failed to create a syscall thread` and contains
none of the seven diagnostic strings. The diagnostic Sentry lacks that
discarded panic and contains all seven exact reviewed context strings. No other
release binary differs.

## Recipe lineage and build execution

The accepted v3 recipe has an exact, continuous checked diff chain through
v12. Every committed transition diff independently matched its corresponding
two recipe files. The changes after v3 are build-environment corrections:

- add zlib and a controlled action `PATH`;
- pin Clang 14.0.6, libbpf 0.8.1, Linux 6.12.17 UAPI headers, and the i686
  compatibility header needed by the seven host-executed BPF genrules;
- account for Guix's two-output i686 libc;
- introduce target-specific AArch64 and x86-64 GCC wrappers with matching
  6.12.17 target UAPI headers and explicit x86-64 binutils;
- retain source manifests around both builds and prove the environment-cleared
  release-file shell boundary;
- remove upstream's `no-sandbox` execution requirement from
  `GoStandardLibraryAnalysis` and `GoStaticAnalysis`; and
- replace v11's failed read-only-directory overlay copy with explicit
  no-overwrite assembly of five control files followed by diagnostic Sentry.

The key Bazel option is deliberately subtractive:

```text
--modify_execution_info=GoStandardLibraryAnalysis=-no-sandbox,GoStaticAnalysis=-no-sandbox
```

It removes `no-sandbox`; it does not request unsandboxed execution. The same
invocation sets `--spawn_strategy=sandboxed` and `--worker_sandboxing`, and no
opposite `+no-sandbox` or standalone/local strategy occurs in the frozen
recipe. Retained targeted evidence identifies both corrected action mnemonics
with the `linux-sandbox` runner. The successful v12 process summaries report:

- control: 3,648 disk-cache hits, 1,532 internal actions, and 65
  `linux-sandbox` processes;
- diagnostic: 3,043 disk-cache hits, 1,420 internal actions, and one
  `linux-sandbox` process.

Neither success summary contains a local, standalone, or worker runner. This
proves the v12 policy and newly executed processes; it does not relabel disk
cache hits as newly executed actions.

The control build completed `//:release` with 5,245 total actions. The
diagnostic build used a separate output base and the read-only lock in
`--lockfile_mode=error`, targeted only
`//runsc/cmd/sentry:gvisor_sentry`, and completed with 4,464 total actions. It
did not build diagnostic `//:release`; the other five diagnostic release files
are the already-validated control bytes copied explicitly by the assembly
step.

Tool evidence records Bazel 8.3.1, GCC 14.3.0 for native/AArch64/x86-64
compiler identities, GNU gold/binutils 2.44, Python 3.11.14, Clang 14.0.6,
libbpf 0.8.1, target UAPI 6.12.17, and Go 1.26.3 in the resulting Go binaries.
The cross-GCC wrappers resolve to Guix store compilers and matching target
header store paths. The build used two Bazel jobs and bounded requested memory;
the measured peaks were 3,839,452 KiB control and 3,170,384 KiB diagnostic.
The artifact tree is 616,002,664 bytes and was reviewed in place without being
duplicated.

The network-enabled container and reused mutable caches are accepted for this
bounded matched-source diagnostic experiment only. Download volume was not
measured, and this evidence does not establish a networkless or cache-empty
reusable package build. Those properties remain requirements of the separate
source-package path already under development.

## Sidecar and runtime disposition

The six-file layout supplies every standard on-disk sidecar. The matching
release stamps are compatible with
`--sidecar-release-enforcement-policy=always`. The source still contains
upstream's deprecated embedded fallback; it is runtime policy—not artifact
absence—that disables it. The control image must retain
`--sidecar-usage-policy=strict`, must not set `GVISOR_ENFORCE_RELEASE` to a skip
form, and must fail rather than use a missing-sidecar fallback.

The next authorized sequence is finite:

1. package all six **control** hashes above into the otherwise accepted image;
2. independently review that image identity and verify strict sidecar use,
   release enforcement, and absence of prebuilt/source mixing;
3. run the unchanged accepted kernel/QEMU/OCI/Systrap configuration and require
   the exact v5 `subprocess.go:219` panic;
4. stop on any other result; and
5. only after matched-control reproduction, separately authorize an image in
   which all five unchanged files remain the control hashes and only
   `gvisor_sentry` becomes the diagnostic hash above.

No CPU-model A/B is justified by this artifact review. It remains prohibited
unless the future diagnostic output identifies a high fixed stub mapping.
DirectFS, ptrace, native execution, networking, sidecar fallback, and every
other compatibility relaxation remain prohibited.

This review inspected immutable source snapshots, manifests, logs, and ELF
files in place. It did not execute an ARM binary, invoke Bazel or Go, compile or
copy artifacts, mutate a source tree or cache, inspect the active image build,
run QEMU/runsc, or access hardware, SSH, UART, mounts, or a device. This review
created only this file.

## Addendum: matched control-image first-reproduction review

**Accepted for exactly one 600-second source-built control run.** This addendum
reviews the completed control-image packet against the artifact acceptance
above. The pre-addendum review snapshot had SHA-256
`0fa12cd200b4687670f0bde467cedb54c0bc224cbcba980ad5c750aff6e15005`.
That accepted snapshot, not this addendum's eventual whole-file hash, is the
matched-source-artifact input to this decision.

The exact focused packet is
`pinenote/tools/book-execution-spike/build/source-control-focused-review-packet.txt`,
SHA-256
`0cef79a24e51c309847f443c07f925f619c33b612bfb376f0302f3763eeffff0`.
Its immutable-baseline record is
`source-control-baseline-review-manifest.txt`, SHA-256
`6f4dec304ff6d901e089432602b958268ba1799da56f7449a5f969067d9c6fb5`.
The packet's other decision-bearing inputs independently retained their stated
hashes:

| input | SHA-256 |
|---|---|
| `pinenote/packages/gvisor-local-test-artifacts.scm` | `4e722eecd1db0a0f6c100e03690b22259c0e4bb2bd83b6fd433ad91c40b35a2b` |
| `pinenote/systems/pinenote-book-execution-source-control.scm` | `9465f7b2e75b970106ae31a8862d949b3444ebd76c87b8d09a6bb651039fc170` |
| staged `manifest.txt` | `1b8063904edba1c50ba4f5cf77f39c74c4f18db167048448cbab3ef8edb52d87` |
| `source-control-package-inspection.log` | `f24d7816f074d3f7c7050d7dd524f5ef38bb53acc05e382250e6e22fa5622cb0` |
| `source-control-static-check.log` | `ccc8018c0ec943340e15cc6ee3d282f64b3a30bb822cc7d386a14c64aeca658a` |
| `source-control-realized-profile-validation.log` | `66fa81d00261feac3dfbd001793fd76b79de73403af9cc56c5c3ec4a80e15564` |
| `source-control-staging-inspection.log` | `2756f6c5be927ee0cf9dd8f6f60de9398c9bd33cbc35cef87814c85126950386` |
| `source-control-root-e2fsck.log` | `4cf0b692daa70ba477e0e3436c2bf6ff88aaaa8f570a59423c5fed7e3a09938c` |
| `first-source-control-after-review.command` | `86b7136fac92ebe4b9d8cc723ce034efe09a08acd8df4896adc91bf97760902b` |
| `interpret-source-control-result.sh` | `3bcf1355d7dd02b6a1cacd0f1190bafdad64a9a3ed02515cd10c249c8ac7fa0b` |
| `doc/book-computer-execution-spike.md` | `5e504ac011b907da031503a357a293ed7a4ebc0336165afe296a6604ea6d0328` |

### Package and closure boundary

The selected local test package is exactly:

```text
/gnu/store/b9a3sd53w0hka2n78657x8vid68x98ph-gvisor-v12-control-local-test-artifact-20260831.0
```

Its `bin/` tree contains exactly the six accepted control files. Independent
hashing reproduced all six hashes in the table above; every installed file is
byte-identical to its control artifact. The installed control Sentry differs
from the diagnostic Sentry, while the other five files are the expected common
bytes. All six remain mode `0555`, AArch64 ELF executables with no `PT_INTERP`
or `DT_NEEDED`. The package output has zero runtime references.

The package derivation names only the six **control** local-file inputs, the
control release manifest, the control lockfile, the originating recipe, and
native wrapping tools. No diagnostic input occurs. The diagnostic wrapper is
declared by the module but was not lowered, built, selected, or included in a
runtime closure.

The realized control system and image are exactly:

```text
/gnu/store/fj6nklg1cxzc2j9gbx790wpsnv41imxi-system
/gnu/store/k74iqqs52fq6qkmv2jcilh00xl441ih8-disk-image
```

The image is 2,048,135,168 bytes and independently reproduced SHA-256
`04649db97f8a8c9973b7be6127d82c7332f9dacd8df71969349e9984e02ab770`.
The system closure has 329 paths and the image closure has 331. Each contains
the control package exactly once and contains neither the frozen official
prebuilt output nor a diagnostic local-artifact package. Neither closure
contains Bazel, protoc, protobuf, Clang, compiler/binutils outputs, the source
inventory, or the release vendor inputs. An AArch64 GCC `lib` output remains as
an ordinary target runtime-library dependency; it contains no compiler
executable and is not a source-build tool input.

The realized system profile resolves `runsc` and every on-disk sidecar directly
into the one control package above. Its build manifest identifies
`gvisor-artifact-set=control`, the accepted source commit, release, manifest,
recipe, lock, and independent-audit hashes. The system profile contains no
official-prebuilt or diagnostic package entry.

### Staged boot boundary

The one-run launcher consumes only the private staged directory
`pinenote-book-execution-source-control-20260905-v1`. Its baseline is a
single-link, mode-`0400`, 2,048,135,168-byte regular file with independently
reproduced SHA-256
`192754f6a16a8c68b8d5c438777e08d3a73e0d6e1becee09ad34ae3b13e532ff`.
Non-mounting probes found exactly one Linux `0x83` partition at sector 2048,
3,998,216 sectors long. It is ext4, UUID
`a454a7b0-be49-f492-406f-5fb9a454a7b0`, and label `PNGuixRoot`. The source
store image still reads `Guix_image`; only the private copied partition was
relabeled. The retained read-only `e2fsck -fn` result is clean.

All staged boot members are single-link, mode-`0400` regular files. The kernel
Image, `.config`, PineNote DTB, and initrd are byte-identical to the v5 members
and to the selected Guix store objects:

| member | SHA-256 |
|---|---|
| `Image` | `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` |
| `config` | `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` |
| `rk3566-pinenote-v1.2.dtb` | `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` |
| `initrd.cpio.gz` | `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` |

The config still contains `CONFIG_USER_NS=y`; the accepted sole kernel delta
remains `CONFIG_USER_NS: n -> y`. The staged extlinux file has SHA-256
`0873607539b490d8cc9ab3308b6bd0e2d9430b7e8b9f2e774138c4c54f344a3c`.
After normalizing the system path, it is byte-identical to v5: only
`gnu.system` and matching `gnu.load` now name the reviewed
`fj6nkl…-system`; `root=PNGuixRoot` and all kernel arguments are unchanged.

The language and supervisor profile paths are unchanged. The language profile's
actual recursive closure and the declared closure each contain the same 45
paths. The independently retained realized-bundle comparison found only fresh
host-side bundle-root names; after normalizing those names, the Python and Guile
OCI bundles are byte-identical to v5. Thus payloads, read-only closure/book
mounts, empty capabilities, namespaces, cgroups, no-new-privileges, resource
limits, and environment remain the accepted inputs.

### Runner and result semantics

The launcher binds the following unchanged source hashes before doing runtime
work:

| source | SHA-256 |
|---|---|
| `disposable-qemu.scm` | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| `run-disposable-qemu.scm` | `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` |
| `guest-console-assertions.scm` | `fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908` |
| `guest-smoke.scm` | `41b010ea46a413a29576be35b01acad230bb13aca1a170818b835aa6bb4fc69f` |
| `oci-bundle.scm` | `fa28fb8e09b086447079d095e6b2c821f03fafc21919d861f92271315df93271` |

The unchanged QEMU graph remains `virt`, TCG multi-threaded, `-cpu max`, four
vCPUs, 2 GiB RAM, `-nic none`, no monitor, and `-no-reboot`. The launcher passes
one `--dedicated-baseline` and one `--timeout-seconds 600`; the runner snapshots
all writable runtime inputs into a private run root, writes only a qcow2
overlay, and has bounded process-group termination plus identity-checked
cleanup. It retains the complete console before cleanup within its finite
escaped-data bound and emits an explicit incomplete marker instead of claiming
full retention on overflow or mutation.

The generated runtime command still selects `isolation-userns`, Systrap,
`directfs=false`, no networking, strict on-disk sidecars, release enforcement
`always`, and cgroup enforcement. No `GVISOR_ENFORCE_RELEASE` skip form appears.
No ptrace, native execution, DirectFS, networking, or sidecar fallback is
introduced by the control system or launcher.

Runtime success remains only the exact single line:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

The expected matched-control result is instead an ordinary failed guest run:
one `BOOKEXEC-SMOKE-FAIL`, source-built `runsc` status 128, the original
`panic: failed to create a syscall thread`, and
`pkg/sentry/platform/systrap/subprocess.go:219`. The launcher must retain
`RUN-STATUS=1 CHECKER-STATUS=1` and exit nonzero for that result. The separate
classifier may print `CONTROL-EXPECTED-FAILURE-REPRODUCED=true`, but also prints
`CONTROL-RUNTIME-SUCCESS=false`; it neither edits the immutable run log nor
changes launcher, guest, or payload status. It also rejects diagnostic/prebuilt
paths, incomplete console export, any Python payload PASS, and any synthesized
runtime PASS.

### Exact authorization

The parent/operator may execute **exactly once**, without editing, the mode
`0600` launcher:

```text
pinenote/tools/book-execution-spike/build/first-source-control-after-review.command
```

at SHA-256
`86b7136fac92ebe4b9d8cc723ce034efe09a08acd8df4896adc91bf97760902b`.
This authorization covers only the source-built **control** image and its one
600-second QEMU runtime attempt. It authorizes no diagnostic package or image,
no diagnostic run, no CPU-model A/B, no rebuild, no device/hardware operation,
and no relaxation of isolation policy. Stop on any result other than the exact
line-219 reproduction. A surprising full runtime PASS is evidence to retain and
review separately, not permission to run the diagnostic.

This addendum used read-only hashing, ELF/store-closure inspection, non-mounting
filesystem probes, and source/call-graph review. It did not run QEMU or runsc,
execute an ARM binary, build an image or package, mutate a Guix/Bazel cache,
mount a filesystem, or access hardware, SSH, UART, or a device.

## Addendum: source-built control runtime result

**Accepted: the required matched-control failure was reproduced.** This closes
the control prerequisite for diagnostic errno attribution, scoped strictly to
the already accepted v12 control/diagnostic artifact pair. It does not establish
runtime compatibility, payload success, Book Protocol success, output import,
release acceptance, or hostile-book isolation acceptance.

The pre-result review and authorization snapshot had SHA-256
`c8d83629c0784eb3698052beb4142589117ce8743febfd85bfbee302df5c5a21`.
The authorized launcher and runner still independently hash as:

- `first-source-control-after-review.command`:
  `86b7136fac92ebe4b9d8cc723ce034efe09a08acd8df4896adc91bf97760902b`;
- `disposable-qemu.scm`:
  `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca`.

The 182-byte wrapper record is
`/tmp/opencode/wilkbook-qemu-source-control.luJNWR.log`, SHA-256
`01fccec313affb03d1f436fb2b6c6ef925afba8bddccddc7a3b580429d721190`.
It identifies the authoritative retained evidence, repeats its hash, and records
`RUN-STATUS=1 CHECKER-STATUS=1`. It is only a locator/status record, not the
runtime evidence itself.

The authoritative transcript is the canonical, non-symlink, single-link,
mode-`0400` regular file:

```text
/tmp/opencode/wilkbook-qemu-source-control.IsJQLG.log
```

It is 130,882 bytes with SHA-256
`2e749e1f93bc5d8161b6eecdaa5a822ba7a17d3cf83e52822ab5e4502ecc625d`.
The outer framing declares and contains exactly 122,040 console bytes. An
independent decoder of the runner's finite escaping format recovered exactly
122,040 bytes, SHA-256
`c77c9020eeea6da76a98417e90ce76b8b4953ac959043ccacb55428501512232`.
The begin, content, and `retention=full` end records each occur once; no
`BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE` record occurs. QEMU stderr is present as
an independently framed zero-byte diagnostic.

### Actual runtime identity and policy

The retained console proves the accepted 7.1.8 kernel booted with PREEMPT_RT,
four CPUs, the reviewed `fj6nkl…-system`, and `root=PNGuixRoot`. It reports the
QEMU-`max`-relevant LPA2/52-bit VA feature and `linux,dummy-virt` machine. This
matches the hash-bound runner's reviewed `virt`, TCG multi-threaded, `-cpu max`,
four-vCPU, 2 GiB, and `-nic none` graph; no CPU-model A/B occurred.

Before invoking the runtime, the guest emitted exactly one each of:

- `BOOKEXEC-KERNEL-IDENTITY-PASS`;
- `BOOKEXEC-NETWORK-ABSENT-PASS`;
- `BOOKEXEC-FORBIDDEN-MOUNTS-PASS`; and
- `BOOKEXEC-RUNSC-VERSION-PASS`.

The version record is `release-20260831.0`, Go 1.26.3, ARM64. Six unique
canonical-executable records resolve `runsc` and every expected sidecar to:

```text
/gnu/store/b9a3sd53w0hka2n78657x8vid68x98ph-gvisor-v12-control-local-test-artifact-20260831.0/bin/
```

No official-prebuilt or diagnostic-package path occurs. The actual sandbox
launch names both the prewarmer and `gvisor_sentry` under that source-built
control package. It retains Systrap, `network=none`, strict sidecars, release
enforcement `ALWAYS`, `ignore-cgroups=false`, `directfs=false`, no host UDS or
FIFO, and rootless false. Its process record says `Ptrace:false`, has the
expected single-ID user/group mappings, and uses the cgroup FD. No missing
sidecar, embedded fallback, release mismatch, or release-enforcement skip is
reported.

The complete top-level `runsc` argument vector is byte-identical to the v5
vector. This independently excludes a changed runtime flag, backend, container
ID, bundle path, or debug-diagnostic path as the explanation for the result.

### Exact failure reproduction

The source-built control Sentry emitted exactly one:

```text
panic: failed to create a syscall thread
```

Its first frame is
`systrap.(*subprocess).initSyscallThread`, followed by exactly
`pkg/sentry/platform/systrap/subprocess.go:219 +0x190` with PC `0x9f4ad0`.
The remaining path proceeds through `newSubprocess`, `systrap.New`,
`createPlatform`, `boot.New`, Sentry `Boot.Execute`, `cli.Run`, and
`sentry_main.go:26`.

This is not acceptance based only on the generic panic text. After normalizing
only ASLR/stack argument addresses, all 19 gVisor function/source records in the
panicking goroutine are identical to the accepted v5 transcript. Source lines,
code offsets, and PCs remain unnormalized and match exactly. The normalized
call-chain SHA-256 is
`3e27333d9fdc61f92675a4398fa4f1675a6d93517ed1bc0d43f0016f2a2ddc4b`.

The failure then remains correctly classified, exactly once, as
`BOOKEXEC-SMOKE-FAIL` with
`wilkbook-python-smoke failed with status 128; bounded diagnostics emitted`.
Neither language payload PASS marker, `BOOKEXEC-SMOKE-PASS`, nor the outer
runtime PASS oracle appears. The system remounted the root filesystem read-only
and reached `reboot: Power down` at 15.991751 seconds. The final retained status
is exactly `RUN-STATUS=1 CHECKER-STATUS=1`; there was no timeout, QEMU stderr,
kernel panic, launcher-incomplete marker, or leftover private run-base tree.

### Disposition

The source-built control has therefore reproduced the same Systrap
initialization failure as the official v5 Sentry under the matched kernel,
QEMU, OCI, runtime-policy, and helper graph. The fact that all six source-built
control files differ from the official release no longer blocks using the
matched diagnostic Sentry to attribute the failing operation and errno.

That is the only gate closed here. The diagnostic image and its baseline still
require their own exact hash/closure review and separate runtime authorization.
No diagnostic run, CPU-model A/B, compatibility fallback, or isolation
relaxation is authorized by this result.

This result review read and hashed only the immutable control transcript, its
small wrapper record, the accepted v5 transcript, and the already reviewed
launcher/runner sources. It did not modify code, build a package/image/kernel,
run QEMU or runsc, execute an ARM binary, inspect or poll diagnostic-image
preparation, mutate a cache, mount a filesystem, or access hardware, SSH, UART,
or a device.

## Addendum: matched diagnostic-image review and one-run authorization

**Accepted for exactly one 600-second matched diagnostic run.** The required
source-built control reproduction above is complete, and the prepared
diagnostic image preserves that control's kernel, QEMU, guest, OCI, and runtime
policy while replacing only the complete gVisor package and its corresponding
provenance record. This authorization is solely to obtain the exact failing
operation and errno. It is not compatibility acceptance or payload success.

The pre-addendum matched-source/control review snapshot had SHA-256
`6b1dc5727a82fe6f56869e0ec6e6377b03beeb314b7d172aeaeae9cd15f045cd`.
The exact diagnostic packet is
`pinenote/tools/book-execution-spike/build/diagnostic-focused-review-packet.txt`,
SHA-256
`7e7134ab32557b5df97c159551d3410b14f8a3585056365176b87ee9bf74453a`.
Its baseline record has SHA-256
`6d384592da9c79eb2030edd360bfcb742ef7157dd80752194541c1787f0b154d`.
Independent hashing reproduced all 24 decision-bearing packet and external
provenance hashes with zero mismatches, including the accepted diagnostic
patch, local-wrapper module, diagnostic system module, retained control
evidence, staged manifest, launcher, release manifest, and independent build
audit.

### Diagnostic package and closure boundary

The selected diagnostic package is exactly:

```text
/gnu/store/rjki4xg2algxlsb4rkfg0pkzfp5fzk40-gvisor-v12-diagnostic-local-test-artifact-20260831.0
```

Its `bin/` tree contains exactly six regular mode-`0555` AArch64 static ELF
files with no `PT_INTERP` or `DT_NEEDED`. Each is byte-identical to the accepted
diagnostic artifact. The five non-Sentry files retain the control hashes in the
table above; only `gvisor-bin/gvisor_sentry` differs from control, at SHA-256
`9e8548183b612dbce3a800ca2ad807dd625d9295caa183f75633a46b0378334f`.
The package output has zero runtime store references.

The realized system and image are exactly:

```text
/gnu/store/46rqh3ga3bh680kc870mq9271lk8x19d-system
/gnu/store/awfhjccvxi29bn1qs8ws80s6cw46pn8p-disk-image
```

The image is 2,048,135,168 bytes and independently reproduced SHA-256
`85a0e2aaf1144e6bb30d0a717171ac73527dc7bd22681c18d1525a1497468531`.
The system and image closures contain 329 and 331 paths respectively. Each
contains the diagnostic package exactly once and contains neither the control
package nor the frozen official prebuilt. Neither closure contains Bazel,
protoc/protobuf, Clang, compiler or binutils executables, gVisor source
inventory, reusable vendor inputs, build recipe, lockfile, or release manifest.
The two GCC `lib` outputs present are ordinary target runtime libraries, not
compiler executables or source-build inputs.

The diagnostic system inherits the accepted control and changes one package
list position from the complete control release to the complete diagnostic
release, plus the corresponding provenance manifest. Its profile resolves
`runsc` and every sidecar directly into the diagnostic package above. Kernel,
config, DTB, initrd, parameters, cgroup2 filesystem, service order,
language/supervisor profiles, 45-path language closure, workload, and generated
Python and Guile OCI bundles remain matched. Normalizing only fresh bundle-root
and selected-system paths leaves the control and diagnostic bundles
byte-identical.

One packet statement is now historical rather than true of the live worktree:
the separately developed reusable-package module `pinenote/packages/gvisor-source.scm`
changed after diagnostic preparation, so its current hash does not equal the
baseline record's `8c733e…` snapshot. This is not a diagnostic-run blocker. The
local artifact wrapper explicitly does not import that module; neither the
diagnostic system nor its base system imports it; and it is absent from the
package, system, image, staged baseline, and launcher runtime graphs. The drift
invalidates only the packet's present-tense claim that this unrelated packaging
file is untouched, not any realized or hash-bound diagnostic input.

### Staged baseline and runner boundary

The launcher consumes only
`pinenote-book-execution-diagnostic-20260905-v1`. Its baseline is a canonical,
single-link, mode-`0400`, 2,048,135,168-byte regular file at SHA-256
`91e969a21750d4c61da82cb5af7bb5e16774d393f3b5cf338d306944d492a8bc`.
It contains one Linux partition at sector 2048, 3,998,216 sectors long, with
ext4 UUID `a454a7b0-be49-f492-406f-5fb9a454a7b0` and label `PNGuixRoot`; the
source store image retains label `Guix_image`. The retained non-mounting
inspection and sole extracted-partition `e2fsck -fn` passed.

Every staged boot or manifest file is likewise regular, single-link, mode
`0400`, and not a symlink. The kernel Image, config, DTB, and initrd retain the
accepted hashes:

| member | SHA-256 |
|---|---|
| `Image` | `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` |
| `config` | `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` |
| `rk3566-pinenote-v1.2.dtb` | `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` |
| `initrd.cpio.gz` | `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` |

The staged extlinux file has SHA-256
`e5b42a093a2f7d6220200787a5b47ffefedc766ffbc7194b630c792235a89018`;
relative to control, only `gnu.system` and matching `gnu.load` select the
diagnostic system. `CONFIG_USER_NS=y`, `root=PNGuixRoot`, and all other kernel
arguments are unchanged.

The mode-`0600` diagnostic launcher has SHA-256
`d5cbc8b3e95f6731c41f4ca9a6ef2f5c6981ca2f9ad7589588405e868d94cd6a`.
After changing only staged-input identities and the diagnostic log prefix, its
runtime logic is byte-identical to the consumed control launcher. It hash-gates
the staged manifest and the same five runner/guest/OCI sources, including
`disposable-qemu.scm` at
`0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca`.
It creates a fresh private run root and log, requires the runner to verify the
baseline, kernel, initrd, and config hashes, and passes exactly one
`--dedicated-baseline` and one `--timeout-seconds 600`.

The unchanged graph remains `virt`, TCG multi-threaded, `-cpu max`, four vCPUs,
2 GiB RAM, `-nic none`, no monitor, and `-no-reboot`. Guest execution remains
`isolation-userns` on Systrap with `directfs=false`, `network=none`, cgroups
enforced, strict sidecars, release enforcement `always`, no ptrace/native
fallback, and no release-enforcement skip. Complete finite escaped console and
QEMU-stderr retention occurs before identity-checked cleanup; incomplete or
overflowed retention fails visibly.

The launcher adds no PASS marker and preserves failed guest status. Runtime
success remains only the exact one-line oracle:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

A diagnostic Systrap failure must therefore remain nonzero with
`RUN-STATUS=1 CHECKER-STATUS=1`, just as the matched control did. Its additional
operation/address/task-size/errno text is evidence, not a synthesized success.

### Exact diagnostic authorization

The parent/operator may execute **exactly once**, without editing, this launcher:

```text
pinenote/tools/book-execution-spike/build/first-diagnostic-after-review.command
```

at SHA-256
`d5cbc8b3e95f6731c41f4ca9a6ef2f5c6981ca2f9ad7589588405e868d94cd6a`.
This authorization covers one matched diagnostic QEMU attempt, bounded to 600
seconds. Preserve the emitted immutable transcript and its SHA-256, then stop
for review of the exact operation, error chain, errno, address, and task-size
context. It authorizes no rerun, CPU-model A/B, config or kernel change, source
edit or rebuild, runtime-policy relaxation, alternative backend, networking,
hardware, SSH, UART, mount, or device operation. A high fixed stub mapping in
the retained diagnostic output is the prerequisite for separately considering
any CPU-model experiment.

This addendum used read-only hashes, ELF/store-closure inspection, retained
non-mounting filesystem evidence, and source/launcher review. It did not run
QEMU or runsc, execute an ARM binary, build or alter a package/image/kernel,
mutate a Guix/Bazel cache, mount a filesystem, or access hardware, SSH, UART, or
a device.

## Addendum: diagnostic runtime attribution and causal host control

**Accepted: the diagnostic run identified the operation and the source-level
cause.** The Sentry's first 8 KiB syscall-thread message allocation expands its
empty `systrap-memory` memfd to the allocator's 1 GiB chunk size. The host
kernel rejects that `ftruncate` with `EFBIG` because the test supervisor imposed
a 4 MiB process-wide `RLIMIT_FSIZE` before executing runsc. Runsc, the
prewarmer, and the Sentry inherit that host limit unchanged.

This closes diagnostic attribution and identifies a test-harness defect. It
does **not** yet prove that Systrap initializes after the harness is corrected,
that either language payload runs, or that any functional, Book Protocol,
output-import, resource, release-acceptance, or hostile-book isolation gate
passes. It also does not establish that no later ARM64/QEMU compatibility issue
exists.

### Retained diagnostic evidence

The parent reports that it consumed the exact one-run authorization using the
unchanged launcher at SHA-256
`d5cbc8b3e95f6731c41f4ca9a6ef2f5c6981ca2f9ad7589588405e868d94cd6a`.
That launcher and its five hash-gated runner/guest/OCI sources still reproduce
the accepted hashes after the run.

The authoritative transcript is the canonical, single-link, mode-`0400`
regular file:

```text
/tmp/opencode/wilkbook-qemu-diagnostic.Q34tp4.log
```

It is 130,971 bytes with SHA-256
`9ac39e291ce4b6de468cd2ad46f2c18387e4ea1b29a559419115fa1ad3ab15b9`.
The separate 178-byte wrapper locator is
`/tmp/opencode/wilkbook-qemu-matched-diagnostic.Bnq9lB.log`, reviewed at
SHA-256
`c4fdb88f66ca4e904466c057ffcd4723bbd6d7be635ef8f2538677c4d3c88e8d`.
It names the authoritative transcript and records
`RUN-STATUS=1 CHECKER-STATUS=1`. The wrapper was mode `0600` at review time, so
its hash is a review snapshot; the immutable transcript is the evidence.

An independent decoder of the runner's finite escaping recovered exactly
122,195 console bytes, SHA-256
`f3611fa2f4abcc4e43aafc42084e4ad7a5089f1797043ba7c13ce180bcf2d20b`.
The declared and decoded byte counts agree. This is 3,300,977 bytes below the
3,423,172-byte full-console limit. The begin, content, and full-retention end
records each occur once, no incomplete/changed/overflow record occurs, and
QEMU stderr is retained as exactly zero bytes.

The console identifies the reviewed diagnostic system and all six executables
under the accepted `rjki4x…` diagnostic package. It retains the accepted
kernel, Systrap, `directfs=false`, `network=none`, strict sidecars, release
enforcement `ALWAYS`, cgroups, and `Ptrace:false` process record. The exact
diagnostic panic occurs once; the old generic panic does not occur:

```text
panic: failed to initialize a syscall thread task-size=0x10000000000000:
allocate syscall-thread message length=0x2000:
truncate MemoryFile backing old-size=0x0 new-size=0x40000000:
truncate systrap-memory: file too large
```

The call chain proceeds from `initSyscallThread` at the instrumented
`subprocess.go:219` through `newSubprocess`, `systrap.New`, `createPlatform`,
`boot.New`, and Sentry boot. The Python run fails with status 128, exactly one
`BOOKEXEC-SMOKE-FAIL` is retained, and no Python, Guile, smoke, or outer PASS
appears. The root is remounted read-only and reaches `reboot: Power down` at
15.924763 seconds. There is no timeout, kernel panic, retention failure, or
nonzero QEMU-stderr payload.

### Exact operation and errno

The diagnostic context fixes the failing operation before any address mapping:

1. Systrap creates a host memfd named `systrap-memory` and wraps it in
   `pgalloc.MemoryFile`.
2. `syscallThread.init` requests `0x2000` bytes with top-down allocation.
3. `MemoryFile.Allocate` finds no existing chunk and calls
   `extendChunksLocked`.
4. `pgalloc` has `chunkShift=30`, hence `chunkSize=0x40000000` (1 GiB). Even
   this first 8 KiB allocation therefore requires one full sparse file-size
   chunk.
5. `os.File.Truncate` attempts to grow the empty memfd from zero to 1 GiB and
   receives “file too large”. On Linux this is `EFBIG`, errno 27.
6. The failure occurs before `extendChunksLocked`'s following host `mmap`, and
   before either syscall-thread message mapping.

Thus the reported `task-size=0x10000000000000` is diagnostic context, not an
operand of the failing syscall. No fixed high address was attempted. The
52-bit/LPA2 and high-stub-address hypotheses do not explain this observed
failure, so no CPU-model A/B is justified. The run also continued to select
Systrap; changing to the ptrace backend remains irrelevant and prohibited.

### Inherited-limit source chain

The exact guest fixture at SHA-256
`41b010ea46a413a29576be35b01acad230bb13aca1a170818b835aa6bb4fc69f`
defines `max-capture-bytes` as 4 MiB. In `spawn-command`, its child redirects
stdout/stderr and then executes:

```scheme
(setrlimit 'fsize max-capture-bytes max-capture-bytes)
...
(apply execl (car argv) argv)
```

For the workload, that child executes the generated `run.sh`; the shell execs
`env`, which execs the generated Guile launcher, which finally execs runsc.
None resets `RLIMIT_FSIZE`, and exec preserves process resource limits.

The exact gVisor source confirms the rest of the inheritance chain:

- `createSandboxProcess` changes only host `RLIMIT_MEMLOCK`; it does not change
  `RLIMIT_FSIZE`.
- It starts the on-disk prewarmer and Sentry with `exec.Command`, with no
  rlimit-related `SysProcAttr` setting.
- The one-page prewarmer performs only FD-table `fcntl`/open/close work before
  directly calling `execve` on `gvisor_sentry`; it contains no rlimit syscall.
- No `RLIMIT_FSIZE` setter occurs in the prewarmer, Sentry command, or Systrap
  source paths. `runsc/boot/limits.go` reads the inherited host value to seed
  gVisor's **internal guest** limits; it does not reset the Sentry's host limit.

The OCI specification's 1 MiB `RLIMIT_FSIZE` is a separate sandbox-task limit.
It is applied to the eventual payload's internal limit set and does not cause
the earlier host memfd failure during Sentry platform construction. It should
remain unchanged by the harness fix.

### Exact Linux 7.1.8 check

The kernel derivation used the already realized patched 7.1.8 source archive:

```text
/gnu/store/0rl832rjv65dy2avs0xcmd04kh8mqax8-linux-7.1.8.tar.zst
```

The archive has SHA-256
`871bbd631d41f923e363286663ec1cde7943a58898cd1cccf512233d4c60ff13`.
The decision-bearing source-file hashes are:

| file | SHA-256 |
|---|---|
| `fs/open.c` | `340e10469b1fc0988a540d2d25fe8e006d4ede3b461be6a16432ec0b0ca6a45f` |
| `fs/attr.c` | `468e2e9dc28a1f4362b9fbde7e720f9f2c450bb5c849bab941d4e0b6a53d4184` |
| `mm/shmem.c` | `9298f0a760669f796ed51b083b6a3e6ed596686d359b9fde1799da08a101f1ff` |

In that exact source, `ftruncate` enters `do_ftruncate`, which calls
`do_truncate`; `notify_change` dispatches memfd/shmem to `shmem_setattr`;
`shmem_setattr` calls `setattr_prepare`; and `setattr_prepare` calls
`inode_newsize_ok`. When growing a file, `inode_newsize_ok` reads the current
process's `RLIMIT_FSIZE`, sends `SIGXFSZ` if the requested offset exceeds the
finite limit, and returns `-EFBIG`. Shmem's independent filesystem maximum is
`MAX_LFS_FILESIZE`, so a 1 GiB request does not hit that alternative bound.

### Minimal trusted-host control

A bounded Python oracle tested the same kernel primitive in two reaped child
processes on the x86-64 host's Linux 7.0.11 kernel. Python was only the host test
driver and is not a proposed production dependency. Each child ignored
`SIGXFSZ`, created a private memfd, attempted only one 1 GiB sparse
`ftruncate`, performed no data write, closed the memfd, and exited. The parent
never changed its own limits.

The exact observations were:

```text
parent-before=(-1, -1)
no-inherited-limit limit=(-1, -1) truncate=success size=1073741824 expected=PASS
inherited-4MiB-limit limit=(4194304, 4194304) truncate=error errno=27 name=EFBIG message=File too large size=0 expected=PASS
parent-after=(-1, -1)
HOST-MEMFD-RLIMIT-FSIZE-ORACLE=PASS
```

The control varies only the child `RLIMIT_FSIZE`. Together with the exact 7.1.8
source path and the diagnostic error chain, this establishes the inherited
4 MiB limit as the direct cause of the observed Sentry initialization failure.
It does not substitute for the next fixed-image guest proof.

### Fix boundary and review criteria

No gVisor source, compiler, Bazel graph, kernel, Systrap backend, CPU model,
OCI payload limit, cgroup policy, or isolation setting needs to change for this
cause. The accepted source-built control and diagnostic binaries remain valid;
no further Bazel build is justified. A corrected system/image may reuse the
control package and should change only the guest supervisor's capture
implementation and the resulting system/image identities.

An acceptable minimal fix must bound the **capture sinks**, not impose a finite
host `RLIMIT_FSIZE` on runsc or any process in the prewarmer/Sentry ancestry.
Review should require all of the following:

1. runsc, the prewarmer, Sentry, gofers, and sidecars inherit no supervisor
   capture-file-size limit; an offline inheritance test must prove it;
2. stdout, stderr, panic, and debug capture files remain private and have
   explicit hard byte/count bounds enforced at the sink or containing storage,
   not merely during later serial rendering;
3. an over-limit producer yields an explicit non-spoofable failure, cannot
   block on a full pipe, is terminated and reaped with its owned process group,
   and cannot leave a larger retained file or stale runtime tree;
4. normal and over-limit tests prove diagnostics are collected before cleanup,
   finite head/tail escaping remains exact, and no truncation is silently
   reported as complete retention;
5. the existing 180-second process timeout, cleanup identity checks, strict
   sidecars, Systrap, no networking, `directfs=false`, cgroups, and OCI payload
   `RLIMIT_FSIZE=1 MiB` remain unchanged; and
6. no new production cgroup or resource-policy gate is introduced to solve a
   logging-scope bug.

A parent-owned pipe plus bounded sink is one suitable shape for stdout/stderr:
the trusted parent writes at most the declared cap, marks overflow, and keeps
draining or terminates/reaps the producer so it cannot deadlock. Runsc's panic
and per-command debug files need the same actual-storage guarantee, either by
equivalent bounded sinks or by a separately finite private diagnostic store.
Merely deleting `setrlimit`, increasing it above 1 GiB, or relying on the later
serial head/tail renderer is insufficient.

After that design passes offline review, the next guest proof is a separately
authorized matched run using the accepted **control** release. It must prove
Systrap initialization, live runsc, both Python and Guile payloads, teardown,
and clean power-down under the unchanged isolation policy. A new failure after
the memfd truncate succeeds is new evidence to diagnose; it must not be treated
as permission for a compatibility fallback.

This addendum inspected and decoded only the retained diagnostic evidence,
reviewed already realized source files, and ran the finite child-only host memfd
oracle above. It did not run QEMU, runsc, gVisor, or ARM code; build or modify a
package, image, kernel, source tree, compiler cache, or binary; alter a process
limit outside the reaped test child; mount a filesystem; or access hardware,
SSH, UART, or a device. Only this review document was changed.

## Addendum: capture-scope implementation review

**Blocked before corrected-control image preparation.** The new parent-owned
stdout/stderr capture is accepted as a sound partial correction: it removes the
causal inherited 4 MiB `RLIMIT_FSIZE`, bounds both retained streams, drains
concurrently, fails closed on overflow, and performs bounded process/EOF
cleanup. But it does not satisfy the already accepted requirement for actual
runsc debug and panic storage. Those paths remain directly opened regular files
with no during-run byte or aggregate bound after the process-wide limit was
removed. Their later head/tail serial rendering is not a storage bound.

The pre-addendum diagnostic/root-cause review snapshot had SHA-256
`a8d758061b167731f32ea94c84c812f327f5bafcd62c413f26252a1de72030d2`.
The focused packet is
`pinenote/tools/book-execution-spike/build/capture-scope-focused-review-packet.txt`,
SHA-256
`0b1aa81e20a7d96aad728bb416d7a935fa1c2445befbc687528d90f895fb0191`.
Its decision-bearing implementation and evidence identities reproduce:

| item | SHA-256 |
|---|---|
| `guest-smoke.scm` | `77b65b6854e08189463350bfe17be61158a3e7cff59bbeabc4eb8017cb73d151` |
| focused source diff | `d9f734d7350a4aa3ed07d134ff1fdc2590d4e14d74ac668c89ee9f3ea9341e62` |
| `test_guest_smoke.py` | `10d3b3f9e09376b4ccce59f2962d7f7a838756b64cb3d21e0f38be3851228cd7` |
| focused 14-test log | packet-retained success; independently rerun below |
| complete host log | `fe6e4999f35d686fadbd12828684a0577d6c48b829846ec68e862b1fd46e4151` |
| controlled-scope log | `593fd47bee67878fa97c8bf02fea185959f21611eda71dd8e9faee6ebd4c2dcb` |
| `oci-bundle.scm` | `fa28fb8e09b086447079d095e6b2c821f03fafc21919d861f92271315df93271` |

The retained complete log reports 54 Python tests plus the static Guix checks
passing, with exit zero. The controlled check names only `guest-smoke.scm` and
its test as changed runtime/test sources; OCI payload policy, outer runner,
console assertions, realized gVisor/kernel, and system definitions remain the
accepted inputs. No image has been prepared.

### Accepted stdout/stderr portion

`spawn-command` now creates separate stdout and stderr pipes, marks both
original ends close-on-exec, and gives the child only duplicated descriptors 1
and 2. The parent alone opens the mode-`0600`, `O_EXCL` retained files. Thus the
runtime descendants do not hold writable descriptors for those files and do
not inherit a capture-related `RLIMIT_FSIZE`.

The parent waits with `select` over both live read ends. Each cycle performs at
most one bounded bytevector read from every ready stream, which prevents one
continuously ready stream from excluding the other. The descriptors remain
blocking, so `EAGAIN` is not part of this path; after `select`, no other reader
can consume the readiness. Reads above the remaining retention allowance are
counted and discarded. The retained count cannot exceed 4,194,304 bytes per
stream, while the observed count includes all drained bytes.

When the direct child exits, the `dynamic-wind` cleanup terminates any surviving
owned process group before final capture draining. Final EOF collection has the
existing grace-period deadline; a writer leaked outside the group therefore
causes an explicit failure instead of an unbounded wait. Timeout still applies
TERM then KILL, and overflow is included in the bundle failure condition before
payload comparison or PASS emission. Runsc-version overflow also fails closed;
dmesg overflow remains subordinate diagnostic evidence.

The focused 14-test suite independently reran at the packet's source hash: all
14 tests passed in 2.281 seconds. Additional independent host-only stress tests
used the actual `run-command` implementation and produced:

```text
supervised-memfd-1GiB status=0 inherited=(-1,-1) size=1073741824 PASS
mixed-flood stdout-observed=4206649 stderr-observed=4248625 retained=(4194304,4194304) elapsed=0.071s PASS
timeout-dual-flood pid-reaped=true retained=(4194304,4194304) elapsed=0.668s PASS
parent-rlimit-unchanged=(-1, -1) PASS
INDEPENDENT-CAPTURE-SCOPE-HOST-STRESS=PASS
same-group-descendant reaped=true eof-finalized=true elapsed=0.187s PASS
DESCENDANT-EOF-CLEANUP=PASS
```

The first case uses a private memfd named `systrap-memory` and the same 1 GiB
sparse truncate that previously returned `EFBIG`; it now succeeds through the
corrected supervisor, without changing the parent limit. The mixed case starts
simultaneous writers on both streams and verifies exact observed counts and
both physical retained-file caps. The timeout case continuously floods both
streams, ignores TERM, and is killed/reaped within the shortened test deadline.
The final case leaves a TERM-resistant same-group descendant holding both pipe
writers after the leader exits; cleanup kills it and reaches EOF within the
bound. These tests execute Python only as a trusted host oracle, not as a
production supervisor dependency.

The OCI payload's distinct 1 MiB `RLIMIT_FSIZE` remains present and unchanged.
It continues to constrain sandbox payload files rather than the host Sentry
memfd.

### Concrete debug/panic storage blocker

The generated runtime still passes:

```text
--debug-log=BUNDLE/runsc-debug/
--panic-log=BUNDLE/runsc-debug/runsc.panic.%COMMAND%.log
```

At the pinned gVisor source, `specutils.OpenDebugLogFile` resolves the directory
or pattern and calls `log.OpenFile` with `O_WRONLY|O_CREATE|O_APPEND`.
`donation.DonateDebugLogFile` then donates that already-open regular file to the
Sentry as `--debug-log-fd` or `--panic-log-fd`. These writes do not pass through
the new stdout/stderr pipes.

`emit-runsc-debug-diagnostics` runs only after runsc exits. It sorts the
directory, selects at most twelve names for **serial emission**, and reads at
most an 8 KiB head plus 8 KiB tail from each selected file. It never constrains,
truncates, or rejects the source file's during-run size. The twelve-file value
is likewise an emission count, not an actual-storage count or aggregate quota.

An independent bounded host regression demonstrated the gap through the actual
new supervisor. Its child wrote one direct debug file of 4 MiB + 12,345 bytes
while emitting only `ok` on stdout. The result was:

```text
direct-debug-file-bytes=4206649 stdout-overflow=False stderr-overflow=False
later-render=head-tail-only file-remains-oversize=true
DIRECT-DEBUG-STORAGE-BOUND=FAIL
```

The emitter correctly reported bounded head/tail serial data, but the complete
4,206,649-byte file remained in `runsc-debug/`. A real runsc or Sentry can do
the same through its donated file descriptors. On the guest's private `/run`
tree this can consume backing memory or filesystem capacity throughout the
180-second run, potentially filling the runtime store before post-exit
diagnostics execute. Neither stdout/stderr overflow state nor the payload PASS
gate observes it.

The current test named
`test_runsc_debug_directory_absence_errors_and_file_limit` does not cover this
property: it creates fourteen small files and proves only that twelve are
selected for emission. The separate bounded-diagnostic test proves escaped
head/tail output, not source storage. Consequently the 14/14 and 54-test green
results do not close the direct-file requirement.

### Narrow required follow-up

Keep the accepted pipe supervisor and remove neither diagnostic observability
nor any runtime/isolation policy. Before image preparation, the implementation
must add a hard during-run byte and count/aggregate bound for the debug and
panic sinks themselves. Acceptable shapes include routing those channels
through equivalent parent-owned bounded pipes, or placing their private files
on a separately finite diagnostic store. Any design must retain late panic
evidence, not only the beginning of a saturated stream.

The follow-up must **not**:

- restore or merely enlarge inherited `RLIMIT_FSIZE`;
- truncate oversized files only after runsc exits;
- rely on the 2 GiB guest root or general `/run` capacity as the log quota;
- remove `--debug-log`/`--panic-log` without proving equivalent prewarmer,
  Sentry, and panic observability; or
- change Systrap, sidecar strictness, networking, DirectFS, cgroups, CPU/kernel,
  OCI payload limits, gVisor binaries, or release enforcement.

Focused regressions must exercise both direct debug and panic paths, a file over
the per-file cap, more files than the actual count cap, and aggregate
exhaustion. They must prove physical storage never exceeds the declared bound
during the run, overflow is explicit and non-spoofable, late panic/tail evidence
is retained, all writers are stopped/reaped, cleanup reaches EOF, and no PASS
can be emitted. The already green 1 GiB memfd, mixed-stream flood, timeout, and
descendant-EOF cases must remain green.

Until that narrow gap is closed and independently re-reviewed, preparing a
corrected **control** image is not authorized. The next eventual guest gate is
the accepted source-built control release proving live Systrap/runsc, both
language payloads, teardown, and clean power-down; the diagnostic panic does
not need to be reproduced again.

This addendum read source, packet, diff, and retained host-test records; reran
only host Guile/Python fixture tests; and used bounded temporary host files that
were automatically removed. It did not edit the implementation, build or stage
an image/package/kernel, execute gVisor/runsc/ARM code or QEMU, mutate a build
cache, mount a filesystem, or access hardware, SSH, UART, or a device. Only this
review document was changed.

## Focused review: finite direct debug/panic stores — blocked on timeout evidence retention

**Verdict: the physical store bounds are sound, but this source gate is not
accepted.** A timeout destroys the bounded direct debug and panic evidence
before it is serialized to the retained console. This violates the standing
requirement to collect diagnostics before cleanup and retain them end to end.
Corrected-control image preparation therefore remains blocked.

### Exact reviewed inputs

The review started from these identities:

```text
diagnostic-store-focused-review-packet.txt  f218a28479e2b8c14024450e9a0a287cdfa86dd108fd61baabe76074036a5a8d
diagnostic-store-focused-v3.log             dd9c313a415e0b9404ceb17f4180cc9d47cf7076e12f3d010b1dc13e18c14584
guest-smoke.scm                             660b733f215c8e0c2f729767dc1fdd7759407f9a90f740df37ccb159c24da1d1
oci-bundle.scm                              a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c
diagnostic-store-gvisor-path-audit.txt      89ebaadb1253fdcc516e833d517031787ed2f7f114ba333dc63d857df42f9da3
test_guest_smoke.py                         3b598626783f5f3d4608ba2a6a0955065665abb278fe43fa78ee94aac023dfca
test_disposable_qemu.py                     6cbdb6e49cd1ca7b43e47f40234ba0dfd0a5538fe33db3c8012d9be07f0529a1
prior review                                91985cd58f76434805a6ff43f05b7ffa17dc1b06f8c3ad6230c80376230bbf97
```

The pinned checkout remained clean at
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, and all six source hashes in the
path audit reproduced. That source confirms that public `runsc run` cannot use
`--debug-log-fd` or `--panic-log-fd`: runsc opens the regular files and donates
already-open descriptors to boot, gofer, and Sentry. Separate finite stores are
therefore a justified design for this pinned release.

The packet's exact four-part host launcher was rerun independently at these
source identities. All 51 tests passed (17 guest-supervisor, 12 Python OCI, 8
Guile OCI, and 14 outer-runner tests). No Bazel/package/image/kernel build,
runsc, QEMU, ARM execution, hardware, shared mount-namespace mutation, or device
access occurred.

### Properties that did pass review

The two mounts are narrow and independent: 4 MiB plus 10 usable file inodes for
`BUNDLE/runsc-debug`, and 1 MiB plus 2 usable file inodes for
`BUNDLE/runsc-panic`. Each mount is a private root-owned mode-0700 tmpfs with
`nosuid,nodev,noexec`; its source, type, byte limit, inode limit, mountpoint
identity, and eventual unmount are checked. The `nr_inodes=max-files+1`
calculation accounts for the mounted root directory. Observation treats an
entry count *equal* to the usable-file limit, or allocated bytes equal to the
byte capacity, as exhaustion. Thus an unanticipated new runsc file cannot
silently turn the count ceiling into fallback storage: the next create receives
`ENOSPC`, the at-limit observation is an explicit
`BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW`, and no payload PASS follows. Non-regular
entries also fail closed.

These directories are trusted host runtime paths under the private bundle, not
OCI mounts visible to the book. The sandbox receives only the fixed already-open
diagnostic descriptors; the book cannot select or write their host paths. The
Systrap `systrap-memory` memfd and other Sentry memory are unrelated to either
mounted tmpfs. No capture-oriented process `RLIMIT_FSIZE` was restored, and the
independent 1 GiB sparse-memfd regression remains green. The OCI payload's
separate 1 MiB `RLIMIT_FSIZE` remains unchanged.

On an ordinary return from `run-command`, both store observations and bounded,
escaped file head/tail diagnostics are emitted while the mounts still exist.
Only then does `dynamic-wind` unmount them, and only after that can the payload
PASS marker be emitted. Saturating the debug tmpfs cannot consume the separate
panic reserve; the real namespace saturation test retained
`LATE-PANIC-AFTER-DEBUG-FLOOD`, reported both overflows, reaped the writer,
unmounted both stores, and emitted no PASS. The existing outer budget remains
four fixed channels plus ten debug files plus two panic files, sixteen total.

### Concrete timeout-path blocker

`wait-command` terminates and reaps the owned process group at the deadline, but
then throws `book-execution-guest-smoke-error` instead of returning a
`command-result`. Consequently `run-bundle` never reaches
`observe-diagnostic-stores` or either bounded file emitter. Its surrounding
`dynamic-wind` immediately unmounts the two tmpfs instances and removes the
mountpoints. Only after that destructive cleanup does `guest-smoke-main` catch
the exception and emit the generic smoke failure.

An independent private user/mount/PID/network-namespace counterexample used the
actual `run-bundle` and a TERM-resistant child. Before waiting, the child wrote
one direct-debug sentinel and one late-panic sentinel to the separately mounted
stores. The shortened real supervisor timeout produced:

```text
timeout-elapsed=0.728s writer-reaped=True mounts-removed=true pass-absent=true
debug-evidence-retained=false panic-evidence-retained=false store-observation-retained=false
TIMEOUT-DIAGNOSTIC-PRECLEANUP-RETENTION=FAIL
```

There was no residue in any inspected mount namespace and the exact writer was
gone, so this is not a cleanup or quota failure. It is evidence loss caused by
the ordering of exception propagation and store cleanup. The checked-in timeout
test proves only bounded termination, writer reaping, and unmounting; it does
not put recognizable data in both stores or assert its presence in retained
output. The same ordering can discard direct diagnostics for another exception
raised before `run-command` returns, including a final pipe-EOF failure.

### Narrow required correction

Keep the accepted stdout/stderr supervisor and the finite tmpfs design. After
all runtime writers have been stopped/reaped, but while both stores are still
mounted, an execution exception must still cause both store observations and
their bounded escaped file diagnostics to be emitted. Cleanup must then unmount
both stores, the original failure must remain a failure, and no payload PASS may
be relabelled or emitted. A focused regression must place recognizable debug
and panic records in the stores, force the real timeout path, and prove all of:
retained observations and contents, exact writer reaping, verified unmount,
bounded completion, and PASS absence. A capture-finalization/EOF exception
should receive the same ordering or a separate regression.

The source gate must be re-reviewed after that correction. The three system
provenance manifests intentionally still described the former panic path when
this source-only packet was reviewed; their current hashes were:

```text
pinenote-book-execution-spike.scm           b56fafc9c64cf3ba816de85d6766b562fe1e62aac9956bfc2506af49c8336c09
pinenote-book-execution-source-control.scm  341ca90202c24a2144087bf7f8e070880c0d27f08ad2240525ff303c1ea6a5c6
pinenote-book-execution-diagnostic.scm      6a1c42eea0c4949fa21d77579b89bef742d1a446027144d3c3e379bfdcad55ed
```

That deferred provenance correction is required after source acceptance and
before any image build, but it is not the present source blocker. No system or
implementation file was changed by this review.

## FINAL2 focused review: direct-store error unwind accepted

**Verdict: accepted at `guest-smoke.scm` SHA-256
`74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa`.**
The timeout/final-capture evidence-loss blocker recorded immediately above is
closed. The finite direct-store source and corrected active provenance are fit
as inputs to a separately authorized corrected **CONTROL** image preparation.
This acceptance does not authorize an image build, QEMU execution, or any other
runtime gate.

### Exact FINAL2 inputs

```text
diagnostic-store-error-unwind-focused-review-packet-v1.txt  d91bac0c2d9342b9d69efa759713ec9854e031e60de71e8cc3cb8faca34004ae
guest-smoke.scm                                             74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa
test_guest_smoke.py                                         d653081598b0e1465171105eb942ccc8b4c2056f9328a7473568fbf3d4dc59f6
oci-bundle.scm                                              a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c
diagnostic-store-error-unwind-source-v1.diff                64800e76e986e7b6b8bc4a2842306889eae7c9cb5d5b7d278632b5c32057cf5a
diagnostic-store-error-unwind-test-v2.diff                  fb26ea56ed95a46ca1e945230e907f7c609c51db8f0c459ad5e38a75467d124c
diagnostic-store-error-unwind-review-cases-v6.log           6422ea8a5307269ba722fb461757c7508f0724a96d7665dcd5fbc978c961b56b
diagnostic-store-error-unwind-focused-v6.log                b3c3aab50807ee2935573493814ab49260dae90e3aab5da074f5fd063335264b
diagnostic-store-error-unwind-controlled-v1.log             5016ceb18be26e93bafdb8cc8e23cd20431f1bdda9fc2d405f323a0da16e1e7d
diagnostic-store-error-unwind-system-static-v1.log          58b1493ab79efbb92ebb3cfc7f59fb09e803355847bd8307895e875eca71e982
prior review                                                499b85b7706ba5d9c6e1d189d558f3189692e252f483cfce971e3a839c23e458
```

All supplied hashes reproduced. The retained complete ladder reports 18/18
guest-supervisor, 12/12 Python OCI, 8/8 Guile/Python OCI-parity, and 14/14
outer-runner tests: 52/52 total. This focused review did not repeat that whole
already-reviewed ladder; it reran the two affected tests and added independent
fixtures for both failure paths.

### Source and exception-order review

`run-bundle` now places `run-command`, observation, and all later bundle policy
checks inside one catch while both diagnostic tmpfs mounts remain active. On an
exception, `emit-store-evidence-once!` reports the stores and bounded file
contents before `apply throw key arguments` rethrows the original key and exact
argument list. The emitted guard is set before reporting, so a subordinate
diagnostic failure cannot recurse into or duplicate the store report.

If the ordinary observation list does not yet exist, each mounted store is
observed independently. Debug- and panic-file rendering are likewise wrapped
independently. `call-secondary-diagnostic` converts a subordinate failure to a
bounded, escaped, prefixed unavailable record and cannot replace the primary
command exception. Returned nonzero, stream-overflow, and store-overflow paths
use the same one-shot reporter; their subsequent intentional `fail` passes
through the catch without duplicating evidence. On success, only observations
are emitted. The payload PASS marker remains outside
`call-with-diagnostic-stores`, after verified unmount.

No mount, quota, TERM/KILL, reap, pipe-capture, OCI, cgroup, isolation, kernel,
gVisor, or QEMU policy changed in this increment. In particular, the parent
stdout/stderr stores remain independently capped at 4 MiB, the debug and panic
tmpfs limits remain 4 MiB/10 files and 1 MiB/2 files, and the OCI payload's
separate 1 MiB `RLIMIT_FSIZE` is unchanged.

### Independent failure-path evidence

The supplied two-test command was rerun at the reviewed hashes and passed both
cases in 1.189 seconds.

A separate timeout fixture used new debug and panic sentinels, a TERM-resistant
writer, and the real 0.5-second `run-command` deadline. A cleanup wrapper read
the flushed console and verified both sentinels while both stores were still
mounted, before calling the real unmount helper. The result was:

```text
INDEPENDENT2-TIMEOUT=PASS elapsed=0.748s writer-reaped=true observations-once=true evidence-before-unmount=true original-preserved=true no-pass=true no-residue=true
```

The exact propagated exception remained:

```scheme
(book-execution-guest-smoke-error
 "guest command exceeded 0.5 second timeout")
```

A separate final-capture fixture wrote different unique records, forked and
reaped a same-group descendant, and only then forced the real
`finalize-captures!` deadline branch. Its panic renderer first emitted the real
panic content and then raised a long, newline-bearing secondary error. The
secondary report was one prefixed bounded line, represented 5,078 source bytes,
retained the embedded text without creating an exact PASS line, and did not
mask the primary error. The cleanup wrapper again proved that both contents and
the secondary record were observable while both stores remained mounted:

```text
INDEPENDENT2A-FINAL-EOF=PASS elapsed=0.480s descendant-reaped=true observations-once=true both-contents=true secondary-bounded=true secondary-source-bytes=5078 single-prefixed-secondary-line=true evidence-before-unmount=true original-preserved=true original-last=true no-pass=true no-residue=true
```

The exact propagated exception remained:

```scheme
(book-execution-guest-smoke-error
 "capture pipe remained open after owned process-group cleanup")
```

Two preceding versions of the independent EOF oracle are preserved here as
reviewer-test failures rather than relabelled results. The first guessed 5,068
formatted source bytes where the implementation correctly reported 5,078. The
second expected `\x0a`, overlooking that Scheme `~s` first renders an embedded
newline as `\n` before the bounded escaper escapes that representation. Both
failed only those reviewer assertions after reaching the bounded secondary
record; both namespaces exited with no writer or mount residue. The final
semantic oracle checks one bounded prefixed line, truncation, embedded text, and
absence of an exact spoofed PASS instead of pinning that internal escape
spelling.

### Provenance and guarded next gate

The active manifests now each name
`private-bundle/runsc-panic/runsc.panic.%COMMAND%.log`, with versioned
bounded-diagnostics manifest identities:

```text
pinenote-book-execution-spike.scm           b56fafc9c64cf3ba816de85d6766b562fe1e62aac9956bfc2506af49c8336c09
pinenote-book-execution-source-control.scm  341ca90202c24a2144087bf7f8e070880c0d27f08ad2240525ff303c1ea6a5c6
pinenote-book-execution-diagnostic.scm      6a1c42eea0c4949fa21d77579b89bef742d1a446027144d3c3e379bfdcad55ed
provenance-only-system-manifests-v1.diff    70642bd5593401108bd8c7c8e9a14bdd73951992158c3cfcb8b02bb020edb80b
```

The diff contains only the three old-to-new panic paths and corresponding
manifest-name/version changes. The prior realized control manifest at
`/gnu/store/2fy5qpxd12yk6jlfyljfna1q6hizg0d7-wilkbook-book-execution-source-control-build-manifest`
still contains its historical `runsc-debug/runsc.panic...` path, correctly
preserving the old artifact as evidence rather than rewriting its provenance.

The next-control metadata and guarded recipe reproduced as:

```text
corrected-control-next-image-metadata-v2.txt       fe30a2a8c24a71d8e28a727cc1ce51c768aa241e85752d162b8183b22606df4e
corrected-control-next-image-build-v2.command      f81776e5128adaef6aec950d5b878ca9d0b77dedd83492208cb4781095873a9d
corrected-control-next-image-build-gate-v2.log     529ed7a37aeb7f4552e0a2c60140e6d02af2a934c53f4e4547b170aa66daf01b
```

The recipe passed `sh -n`. An independent invocation with its authorization
variable explicitly absent exited 125 with the exact refusal, created no
dry-run log, and started no image build. It pins the accepted complete six-file
control package and accepted USER_NS kernel; it does not select the diagnostic
variant.

This closes only the finite diagnostic-store source/provenance gate. A human
must separately authorize execution of the guarded corrected-control image
recipe. Any resulting image then needs identity/closure review, and a later
CONTROL QEMU run requires its own separate authorization. Functional success,
Book Protocol, output import, production resources, hostile-book isolation, and
release acceptance remain open gates.

This FINAL2 review ran only small host Guile/Python tests in private
user/mount/PID/network namespaces. It found no residual writer or mount. It did
not build or execute gVisor, build a package/kernel/system/image, run QEMU or ARM
code, access hardware, SSH, UART, or a device, or compete with the separate
native package compilation. Only this review document was changed.

## Corrected CONTROL image review and one-run authorization

**Verdict: image accepted for exactly one separately launched, 600-second
CONTROL functional run.** The realized image binds the FINAL2-reviewed capture
source to the accepted source-built CONTROL gVisor release without changing the
kernel, initrd, language profiles, runtime policy, or QEMU graph. Runtime
success is not yet claimed.

### Exact image packet

```text
corrected-control-image-focused-review-packet-v1.txt  d9c672bd432400fd0707b4b3517daf7897030de25d7a8c139df01cc34be176f4
corrected-control-image-review-manifest-v1.txt         b0568b9673cfee0f8ec61fdd0f15326aacfd6843ecee7771140b1aed2cc00c84
FINAL2 source review before this addendum              c304ea0816a9c79195c3c62e0f7bdcc9c885c97d01774d05d616313232632bc2
image                                                   /gnu/store/if4vn9iyg0zmgz0q17dyyzjm4d6kjj61-disk-image
image SHA-256                                          9d169276c6367e10ae2dc189fc34ff9cbac3e06b833522debe43943242e502a2
image bytes                                             2048163840
system                                                  /gnu/store/09s4nxixkadh737an3rqnbn0gkxr4vn5-system
image derivation                                        /gnu/store/dji7krziv7jm209fpdv2jr0yvjxms921-disk-image.drv
```

Every packet, manifest, build, closure, staging, delta, controlled-check, and
launcher hash cited below reproduced. The authorized build log records exit 0
in 24.10 seconds and lists only fourteen source/service/system/image assembly
derivations. It did not list or build the accepted kernel or gVisor package;
Bazel and gVisor source compilation did not run.

### Direct image-content binding

One independent read-only pass over the immutable store image simultaneously
computed its full SHA-256 and copied its sole partition to a private temporary
regular file. `debugfs` then read that ext4 filesystem without mounting it. The
temporary partition and extracted small files were removed after inspection;
no mount or loop device was created. The pass reported:

```text
IMAGE-SINGLE-PASS-SHA256=9d169276c6367e10ae2dc189fc34ff9cbac3e06b833522debe43943242e502a2 bytes=2048163840 partition-bytes=2047115264
IMAGE-NONMOUNTING-CONTENT-INSPECTION=PASS fs-label=Guix_image guest=74491a0f oci=a3a4c4e6 manifest=574e0f5a helper=a0c12be4 shepherd=1d52834f control-files=6 old-panic-path=absent payload-fsize=1048576 inherited-fsize=absent
```

The files read from the image itself were:

```text
/gnu/store/z27k71zzx0j5a0v764bm365dhsgclmll-wilkbook-book-execution-guest-smoke.scm
  74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa
/gnu/store/230xnw23wfz3xablg3c4xn201frj6fss-wilkbook-book-execution-oci-bundle.scm
  a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c
/gnu/store/fsk8dx7c3jbc4dkfn3fnbsf3r7q6grf9-wilkbook-book-execution-source-control-build-manifest-bounded-diagnostics-v1
  574e0f5a9aee3257d506d120e51bce4270e460c78e9b0a28782a7c04c4e12320
/gnu/store/72cdjgp5azqcf5x11gs15kwvbap463fs-wilkbook-book-execution-guest-smoke
  a0c12be4f10cffdd56e3fb0c85e972f9f80ba52d5f5b16aa3e1f54be2ba7635a
/gnu/store/g646i9s058jwzy2izkim0czdh0rp63f0-shepherd-book-execution-guest-smoke.scm
  1d52834fcc4eca2938f7f0298e1d0f3f3ceb8f93eee5f8442927c822bab1e0d7
```

The fixed helper primitive-loads that exact guest source. The Shepherd service
selects that helper, the exact OCI source, accepted language profile and
45-path closure, and kernel release `7.1.8`. The guest source requires gVisor
`release-20260831.0`, contains the independent 4 MiB debug and 1 MiB panic
stores, and contains no inherited capture `setrlimit`. The OCI source alone
retains the payload's 1,048,576-byte `RLIMIT_FSIZE`. Its panic flag and the
realized build manifest both name
`private-bundle/runsc-panic/runsc.panic.%COMMAND%.log`; the former
`runsc-debug/runsc.panic...` path is absent from those active image inputs.

All six regular mode-0555 CONTROL files read directly from the image matched
the accepted release hashes:

```text
containerd-shim-runsc-v1             7fbaf0e090b1bb10ecf35a25ff2d22c6c9ccdc0d3ada6a1ab548a7ece259c548
gvisor-bin/checkpointgofer            19451cc0b04ce9d2baaa7a8e2a5abeb0b06c9c0f43bc7c182bc9954b97514846
gvisor-bin/gvisor-sentry-prewarmer    1e0d994e39f3f8d7746890a0df09cb7b88de79f90da8489c274e2fa9b0e3a81a
gvisor-bin/gvisor_sentry              b586873e1f32fc4bde4c1535780a0dae4bc4ad873a8a3858588430153878437f
gvisor-bin/runsc-metric-server        080fde2370aa27f176ef1af02c8a89c73644fc2970b5fbe2d30072d86cb180dc
runsc                                 a5aca591653e0f504d75093b1d37d301dca23e14b18f1140c406d68732b16ed3
```

The first inspector attempt is retained as a reviewer-oracle failure: `mktemp`
had already created the destination while the Python helper requested exclusive
creation. It failed before reading any image byte and cleanup removed the empty
temporary files. The corrected invocation opened that same private destination
for replacement and performed the single successful image pass above. No
failed result was relabelled.

### Closure and staged runtime input

Independent `guix gc --requisites` traversal reproduced the sorted closure
seals and counts:

```text
system  329 paths  2e998417afed190c230abbdf643f70d7d919154d0f39f70ba6ba9ad3ba09d981
image   331 paths  ec91ad95e728ebb4cdd248766c3a16e008d53182d82e5959d65b55df99cf0d83
```

Each contains the CONTROL package exactly once, the diagnostic and prebuilt
packages zero times, and one exact guest source, OCI source, and corrected
manifest. The CONTROL package has zero runtime references. Bazel, compilers,
vendor/source inventories, protobuf/protoc, and other source-build inputs are
absent from the runtime closure. The separate reusable native-package build and
its mutable working-tree package source are therefore neither inputs to nor
gates for this functional image.

The 12-out/12-in system and 14-out/14-in image deltas are restricted to the
accepted guest/OCI capture sources, corrected manifest, and their generated
service/activation/boot/system/extlinux/image identity cascade. The CONTROL
gVisor package, kernel, initrd, supervisor/language profiles, and 45-path
language closure do not participate in the delta.

The staged baseline remains a private mode-0400, one-link, 2,048,163,840-byte
regular file. Its ext4 partition reports label `PNGuixRoot`, UUID
`a454a7b0-be49-f492-406f-5fb9a454a7b0`, offset 1,048,576, and size
2,047,115,264 bytes. The builder already performed the sole read-only
`e2fsck -fn` pass successfully; this review did not repeat it or the unchanged
2 GiB baseline hash. The launcher rechecks the exact accepted baseline SHA-256
`008d8b727bcc786bc74be161bd296d2ff1e67ce5f787f2c3aa9951b6d8a55da0`
before QEMU. The staged kernel, config, DTB, initrd, and extlinux hashes all
reproduced; kernel and initrd remain byte-identical to the prior CONTROL.

### Launcher and exact authorization

The accepted launcher is:

```text
pinenote/tools/book-execution-spike/build/first-corrected-control-after-review-v1.command
SHA-256 fddd931afd6db86ee475a89f928e0eead0793d85a62b8c20991c8cd6c7dabdd5
```

It passed `sh -n`. An independent invocation with its authorization variable
explicitly absent exited 125 with the exact refusal, created no run log or run
directory, and did not start QEMU. It pins the immutable corrected baseline and
manifest, accepted kernel/initrd/config, unchanged outer runner and parser,
TCG, CPU `max`, `-nic none`, dedicated-baseline handling, and a 600-second
outer timeout. It invokes the CONTROL image only; neither the diagnostic image
nor the old direct-panic reproduction chain is selected.

**Authorization is now granted to the parent for exactly one invocation that
passes this launcher's pre-QEMU identity checks:**

```sh
WILKBOOK_CORRECTED_CONTROL_RUN_AUTHORIZATION=CORRECTED_CONTROL_IMAGE_ACCEPTED_AND_RUN_SEPARATELY_AUTHORIZED \
  sh pinenote/tools/book-execution-spike/build/first-corrected-control-after-review-v1.command
```

The token is exactly:

```text
CORRECTED_CONTROL_IMAGE_ACCEPTED_AND_RUN_SEPARATELY_AUTHORIZED
```

If a pre-QEMU identity check refuses, preserve the evidence and stop rather
than changing inputs or retrying. Once QEMU starts, this authorization is
consumed regardless of success, failure, or timeout. It does not authorize a
second run, a diagnostic run, a modified launcher, a different image, or any
hardware action.

Functional success requires exactly one outer status line:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

The unchanged checker additionally requires boot, live pinned runsc, both
Python and Guile payload PASS markers, cgroup teardown, overall smoke PASS, and
clean power-down; any `BOOKEXEC-SMOKE-FAIL`, missing/duplicate/out-of-order
marker, nonzero QEMU status, checker failure, timeout, or output-budget failure
remains failure. The resulting immutable run log, its SHA-256, `RUN-STATUS`,
and `CHECKER-STATUS` must be retained before deciding the next gate.

This image review and authorization do not establish functional compatibility,
hostile-book isolation, Book Protocol, output import, production-resource
policy, or release acceptance. No production budget or resource gate was
added. The review used only store/closure reads and one non-mounting private
image inspection; it did not edit source, build anything, execute
QEMU/gVisor/ARM code, or access hardware, SSH, UART, or a device. Only this
review document was changed.

## Corrected CONTROL run: scoped functional compatibility passed

**Verdict: the one authorized corrected CONTROL run passed the fixed functional
compatibility smoke.** This is checker-authenticated summary evidence, not a
retained raw success-console transcript. The distinction is material and is
part of the accepted record.

### Exact retained evidence

The approved launcher, image, and source identities remained:

```text
launcher  pinenote/tools/book-execution-spike/build/first-corrected-control-after-review-v1.command
          fddd931afd6db86ee475a89f928e0eead0793d85a62b8c20991c8cd6c7dabdd5
image     /gnu/store/if4vn9iyg0zmgz0q17dyyzjm4d6kjj61-disk-image
          9d169276c6367e10ae2dc189fc34ff9cbac3e06b833522debe43943242e502a2
guest     74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa
OCI       a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c
outer     0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca
entry     354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b
checker   fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908
```

The launcher wrapper output is
`/tmp/opencode/wilkbook-qemu-corrected-control.qVapIe.log`, SHA-256
`8f68acaef767835a6f1d9edb0e8f83e80bcdf7334e8bd4062a923edb68efba70`.
It names the authoritative retained evidence and reports zero run/checker
status. The retained evidence is the mode-0400, one-link, 97-byte file
`/tmp/opencode/wilkbook-qemu-corrected-control.gfvyBD.log`, SHA-256
`bff1228fac510ef01209b530446d6190fa352baa15fbc67781aeaa194760a43a`.
Its complete contents are exactly:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
RUN-STATUS=0 CHECKER-STATUS=0
```

No QEMU process or private run-root residue remained when the evidence was
reviewed. The one-run authorization is consumed. No rerun is authorized by
this verdict.

### What the summary proves

The accepted outer runner writes the first evidence line only after all of the
following have happened in its frozen call path:

1. It privately snapshots and hash-checks the accepted kernel, initrd, boot
   configuration, and corrected baseline.
2. It starts QEMU with TCG, CPU `max`, `-nic none`, the private overlay, and the
   600-second bound.
3. QEMU exits zero rather than timing out.
4. `assert-console-retainable` accepts the bounded completed console.
5. `assert-guest-console-file` finds exactly one of each required marker, in
   order: kernel identity, network absent, forbidden mounts absent, pinned
   runsc version, Python/Systrap payload, Guile/Systrap payload, cgroup teardown,
   and overall smoke PASS.
6. The same checker finds no `BOOKEXEC-SMOKE-FAIL`, kernel panic, `BUG:`, or
   `Oops:` fragment and finds a clean kernel power-down line.

The launcher then accepts only one exact outer-status line and appends
`RUN-STATUS=0 CHECKER-STATUS=0`. A zero QEMU exit by itself cannot produce this
accepted result: a missing, duplicate, out-of-order, forged, oversized, or
failure-bearing console makes the checker and launcher fail. The runner's
identity-checked private run-root cleanup also completed; otherwise its final
status could not remain zero.

The frozen guest path separately establishes what those accepted markers mean.
It checks the exact six-executable sidecar layout and live runsc release before
creating two distinct fixed bundles. Each generated `run.sh` executes the
generated Guile launcher, which performs cgroup2 preflight and then `exec`s
runsc with `--platform=systrap`, `--directfs=false`, `--network=none`, strict
sidecars, release enforcement, `ignore-cgroups=false`, and the other accepted
runtime flags. Python and Guile emit different fixed payload sentinels; the
supervisor requires each captured output to equal its language-specific
sentinel and computed book-byte count exactly.

For each language, nonzero runsc status, stdout/stderr overflow, direct-store
overflow, payload mismatch, or stale cgroup throws before that language PASS.
The debug and panic stores are identity-checked and unmounted before the PASS
marker outside their dynamic extent. Both language runs must complete before
the cgroup-teardown and overall-smoke markers. Thus the accepted semantic
summary proves boot, live pinned runsc under ARM64/Systrap, both fixed Python
and Guile payload probes, bounded capture/store policy, cleanup, and clean
power-down for this exact PineNote test-kernel image.

### Evidence limitation and gate boundary

The raw successful `console.log` was not retained. By accepted design, this
version of the outer runner emits the full console only on failure; on success
it validates the private console and removes the private run tree, retaining
only the semantic status above. Consequently this record must not be described
as an independently re-readable raw transcript of each marker, timestamp, or
runsc line. Acceptance relies on the frozen, previously tested checker chain
and its measured zero statuses. Retrofitting a future concise semantic record
may improve auditability, but the absence of raw success output does not
retroactively invalidate this run or justify a rerun.

This closes the **functional compatibility smoke gate only** for the exact
custom source-built CONTROL package and image above. It does not establish
hostile-book security qualification, Book Protocol or a runtime book FD,
output import, cancellation/timer semantics, durable execution, production
resource policy, or release acceptance. Fixed-fixture network and mount
assertions passed as part of the smoke; they are not a substitute for the
separate hostile-book gate.

The reusable native Guix package build remains a separate packaging/input-graph
gate. This successful runtime used the already accepted custom six-file CONTROL
artifact; it neither used nor validates a reusable `gvisor/source` package
output, and mutable package-source files outside this image closure do not
affect this verdict.

This review only read the two retained status files and the frozen acceptance
call path. It did not edit source, build anything, rerun QEMU, execute gVisor or
ARM code, or access hardware, SSH, UART, or a device. Only this review document
was changed.
