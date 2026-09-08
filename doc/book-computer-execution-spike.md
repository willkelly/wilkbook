# Book-computer execution spike: ARM64 gVisor under QEMU

**Current status (2026-09-06):** the corrected-CONTROL compatibility result
below remains accepted. Later work also independently accepted Book Session FD
donation to both fixed ARM64 books and one complete QEMU/virtio-serial path in
which their four nonce-bearing results reached real packaged KOReader offscreen.
See the [protocol/state reference](book-computer-protocols.md),
[demonstration record](book-computer-demo.md), and
[chronological implementation record](book-computer-implementation.md). Those
later results do not establish a general book launcher, hostile-book isolation,
durable state, a shipping image, or hardware behavior.

**Historical status at the 2026-09-05 compatibility checkpoint:** the one
separately approved corrected-CONTROL QEMU/TCG run passed the frozen checker:
`OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0;
GUEST-ASSERTIONS=PASS`. This was the first functional compatibility evidence
for real ARM64 gVisor/Systrap and both fixed language payloads. It used kernel
7.1.8 with only the `CONFIG_USER_NS` test delta, QEMU TCG with `-cpu max` and no
NIC, `isolation-userns`, `--directfs=false`, and the unpatched source-built
six-file CONTROL artifact from commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, with `STABLE_VERSION`
`release-20260831.0`. It did not use the reusable Guix `gvisor-source` package
or the diagnostic Sentry. This note narrows phase 1 of
`doc/wilkbook-self-hosting-book-computer.md`; no result in it is PineNote
hardware acceptance.

### How to read this chronology

The v2–v5 “no payload,” “pending,” and blocker statements below are retained as
dated failure evidence. They describe those exact attempts, not current status.
The matched diagnostic later attributed the failure to inherited
`RLIMIT_FSIZE`; the corrected CONTROL run then succeeded without a gVisor or
kernel patch. Subsequent Book Protocol and reader joins are summarized above
rather than retroactively rewriting each earlier paragraph.

## Headline

Use a **dedicated, non-shipping system** to run the complete, exactly pinned
gVisor release directly from a narrow OCI bundle with `--platform=systrap`.
Both explicit runtime profiles require `CONFIG_USER_NS=y` at the pinned commit:
`functional-directfs` (`--directfs=true`) remains functional evidence only,
while `isolation-userns` (`--directfs=false`) is the preferred first candidate
now that it costs no extra kernel prerequisite. Keeping both names preserves
the tested launch ABI; neither name is isolation acceptance. Do not add Docker
or containerd, relax `--network=none`, use a test-only runtime bypass, modify a
shipping flavor/kernel, or use `runsc do` as the security boundary.

## Corrected source-built CONTROL result — 2026-09-05

The exact image accepted by
`build/corrected-control-image-focused-review-packet-v1.txt` received one
separate run authorization and completed successfully. The retained evidence is
deliberately only the launcher's wrapper and two-line accepted summary:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
RUN-STATUS=0 CHECKER-STATUS=0
```

The preserved directory is
`pinenote/tools/book-execution-spike/build/corrected-control-runtime-evidence-20260905-v1/`.
Its accepted summary has SHA-256
`bff1228fac510ef01209b530446d6190fa352baa15fbc67781aeaa194760a43a`.
The current runner exports a full console only on failure, so no raw successful
console or individual Python/Guile sentinel is retained. Both payloads are
accepted only through the already frozen guest assertion chain; this record
does not reconstruct or claim separately stored sentinel lines.

The earlier Systrap failure was a fixture bug, not evidence for a gVisor or
kernel compatibility patch: a 4 MiB supervisor `RLIMIT_FSIZE` crossed exec and
made Sentry's 1 GiB `systrap-memory` `ftruncate` fail with `EFBIG`. The corrected
harness bounds parent-owned stdout/stderr captures and the separate direct
debug/panic stores without imposing that process-wide limit. The sandboxed OCI
payload retains `RLIMIT_FSIZE=1048576`. The successful run reused the accepted
kernel and unpatched source-built CONTROL binaries; no runtime patch was needed.
The separate 52/52 bounded-store/capture regression remains preserved as
`build/diagnostic-store-error-unwind-focused-v6.log` (SHA-256
`b3c3aab50807ee2935573493814ab49260dae90e3aab5da074f5fd063335264b`).

The corrected-CONTROL result itself establishes the fixed compatibility
workload only. It did not pass a Book Protocol descriptor through runsc, run
arbitrary books, provide a reader-private channel, test resource ceilings under
pressure, or establish hardware behavior. Later separately reviewed fixtures
did add the fixed Book Protocol descriptor and reader-private channel; they do
not broaden this CONTROL result or close its remaining general/resource gaps.

The repository now has a checked gVisor package, a one-option non-shipping
PineNote test-kernel definition, an explicit cgroup2 mount and launcher
preflight, host-tested Guile OCI/QEMU boundaries, and a fixed Guile guest
fixture that runs Python and Guile through separate `isolation-userns` OCI
bundles and emits serial assertions. At this compatibility checkpoint, the
exact kernel/rootfs boot, ARM64
`runsc --version`, Gofer and Sentry startup, Systrap payload execution, and both
fixed language assertions were observed. This checkpoint did **not** have cgroup
resource ceilings or Book Protocol FD donation/output import; later fixed-book
work added the descriptor path but not general output import or pressure-tested
ceilings.
The current reader rootfs was not reused.

## 1. Scope and non-claims

The first result should answer:

1. Does the exact PineNote kernel/config boot an AArch64 `runsc` Sentry with
   Systrap under QEMU TCG?
2. Can Guile and Python from one pinned Guix environment execute through the
   same one-shot protocol?
3. Does the constructed bundle expose only its declared read-only closure,
   input, private scratch/output, and protocol channel?
4. Does forced shutdown remove the whole execution domain?

A green `isolation-userns` first run would be useful rung-4 compatibility and
selected-OCI evidence, but would not by itself count as isolation acceptance.
A separately labeled `functional-directfs` result would be weaker. Any green
run would **not** prove:

- PineNote startup latency, memory pressure, wakeups, idle power, or battery
  impact;
- KVM availability or performance (AArch64 QEMU on this x86_64 host uses TCG);
- security against a hostile workload beyond the particular denial tests;
- compatibility of real book libraries merely because trivial Guile and
  Python programs start;
- any RK3566, display, input, suspend, or e-ink behavior.

No PineNote deployment or hardware operation was used by this spike. The later
read-only device prerequisite inspection is availability/configuration evidence,
not execution or acceptance. In the historical v2–v5 attempt sequence, two
attended QEMU/TCG attempts used the immutable `-v2` baseline. The first guest
stage is unknown because its pre-diagnostic cleanup discarded the console; the
second failed before gVisor. V3 executed ARM64 `runsc --version` but failed
before Sentry startup; v4 reached `runsc run` and the sandbox-child startup wait,
but that child exited before its ready notification. V5 identified that child as
the real Sentry and retained its Systrap-initialization panic. The authorized
`--cores=2 --max-jobs=1`
cross-build produced the dedicated kernel
at
`/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote`.
The full installed-config diff against the exact current base output contains
one change: `# CONFIG_USER_NS is not set` becomes `CONFIG_USER_NS=y`. The exact
system closure and raw image were then built and staged privately. The kernel,
root mount, Shepherd startup, mount boundary, clean shutdown, ARM64 `runsc`
version assertion, Gofer startup, and Sentry panic had real QEMU evidence; no
Sentry-ready or sandbox-language result had been produced by v5. Host tests of the
outer supervisor itself execute only fake QEMU commands, while v5 exercised its
real bounded failure export.
The previously recorded `runsc do /bin/true` sanity
did execute the installed x86-64 host runtime; the package gates inspect but
never execute the ARM64 files.

## 2. Existing offline path

There are two distinct QEMU configurations; keep their claims separate.

### Generic Guix userspace smoke

`pinenote/systems/qemu-aarch64-smoke.scm` is a generic AArch64 Guix VM. It has
reached its login prompt and is useful for userspace construction, but it does
not use the PineNote kernel, initrd, device tree, waveform path, or services:

```sh
guix system vm -L . --target=aarch64-linux-gnu \
  pinenote/systems/qemu-aarch64-smoke.scm
guix shell qemu -- /gnu/store/...-run-vm.sh \
  -M virt -cpu max -nographic -no-reboot
```

An initially considered userspace-only shortcut is already cached:
`/gnu/store/vvyar1rc5rjk43q647i43a2r848cc2r4-linux-libre-7.0.11/Image` is an
ARM64 kernel with `CONFIG_USER_NS=y`, cgroups/memory/PID/CPU accounting, and
seccomp filters enabled. Reusing it avoids the full PineNote kernel cross-build
and can answer ARM64 runsc/Guile/Python compatibility under TCG. It cannot
answer exact PineNote-kernel compatibility. The operator explicitly rejected
that shortcut for the first run; no generic execution image or kernel was built.

The old realized generic VM is not itself an acceptable baseline: its generated
launcher exposes all of the host `/gnu/store` through 9p, uses the old generic
system closure, and does not pin `-nic none`. A fresh generic execution-spike
image must embed only its declared closure and use the reviewed disposable
envelope. That image/rootfs still has to be constructed; no VM was started
during this investigation.

### Exact PineNote kernel/initrd/rootfs on `virt`

The execution proof should extend this path instead:

- `pinenote/scripts/qemu/run-pinenote-virt.sh` boots the staged PineNote
  `Image`, initrd, and rootfs on `-M virt -cpu max -smp 4 -m 2048`.
- `pinenote/scripts/qemu/make-virt-disk.sh` constructs the synthetic
  `waveform` + `os2` GPT disk under `/tmp/wilkbook`.
- `pinenote/scripts/qemu/run-virt-assertions.sh` demonstrates the reusable
  console-socket pattern: wait for login, log in as root, assert guest state
  from `/var/log/messages`, emit sentinels, and power off cleanly.
- `%pinenote-qemu-virt-config-lines` in
  `pinenote/packages/kernel.scm` builds in the virtio disk/network and PL011
  support needed by this boot.

The existing `run-virt-assertions.sh` has reader-specific service assertions
and lacks the disposable adversarial envelope required here, so it must not be
called or copied unchanged. The new
`pinenote/tools/book-execution-spike/run-disposable-qemu.scm` supplies the outer
boundary: explicit `-nic none`, private mode-0700 per-run state, private boot
copies and raw-baseline snapshot, a raw-backed qcow2 overlay, private root
console/log, sanitized QEMU environment, foreground timeout, and bounded
TERM-to-KILL process-group cleanup. The first independent Guile review found
that uncatchable owner `SIGKILL` left its process group and run tree; the focused
2026-09-05 UTC recheck accepted the process/run-root guardians and fail-closed
cgroup-probe removal at the hashes it records. The corrected automatic guest
fixture has no serial `agetty`. After QEMU exits, the outer runner calls the
bounded Guile parser inside its existing guarded run-root scope and before
cleanup; only unique ordered markers plus clean power-down produce success.
That boundary was accepted for the two v2 attempts. Their two guest-fixture
findings and the resulting v3 image are the current focused-review boundary.

## 3. Facts established locally

### Host tools

The pinned channel file names Guix commit
`f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c`. On this host:

| Tool | Observed state | Relevance |
|---|---|---|
| Guix | Present at the repository pin | Can evaluate the proposed package/system. |
| QEMU | `qemu` 10.2.1 is already realized in the Guix store | `guix shell qemu -- ...` supplies it; it is not on the ordinary `PATH`. |
| `sgdisk` | Not on the ordinary `PATH` | `guix shell gptfdisk -- ...` supplies it. |
| `runsc` | `/usr/local/bin/runsc`, x86-64 static binary | Host-only sanity instrument; cannot be put in an ARM64 image. |
| Docker/containerd/runc | Present | Not needed for direct OCI execution. |
| `bwrap`, `unshare`, `newuidmap` | Present | Host investigation only. |
| podman/skopeo/umoci | Absent | No reason to add them to the first path. |

A pinned `guix shell --dry-run qemu` required no realization, and cached
version-only commands reported both `qemu-system-aarch64` and `qemu-img` as
10.2.1. No machine was started by those queries.

The host `runsc` identifies itself as:

```text
runsc version release-20260202.0-126-g85cecb9f1a93
spec: 1.1.0-rc.1
sha256 74376f9e40c25c6c0a973057b77eaeecb8f1a9fd775168417e34c72421ac9ba9
```

This host-only Systrap sanity exited zero:

```sh
d=$(mktemp -d -p "$PWD" runsc-state.XXXXXX)
/usr/local/bin/runsc \
  --root="$d" \
  --rootless=true \
  --platform=systrap \
  --network=none \
  --ignore-cgroups=true \
  do /bin/true
rm -rf "$d"
```

Without `--rootless=true`, this particular unprivileged host invocation failed
with `newuidmap failed: exit status 1`. This proves only that the installed
x86-64 runtime can enter Systrap on this host. `runsc do` exposes the host
filesystem read-only by default and is therefore unsuitable for the real
boundary.

### Kernel configuration in the current artifact

The configuration was read directly from
`/tmp/wilkbook/pinenote-rootfs-artifacts/pinenote-reader-PNGuixRoot-20260903.ext4`:

```sh
debugfs -R 'cat /boot/config' \
  /tmp/wilkbook/pinenote-rootfs-artifacts/pinenote-reader-PNGuixRoot-20260903.ext4
```

Relevant results:

```text
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
CONFIG_CGROUP_PIDS=y
CONFIG_CPUSETS=y
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
# CONFIG_USER_NS is not set
CONFIG_CHECKPOINT_RESTORE=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_FUSE_FS=m
CONFIG_OVERLAY_FS=m
```

These are encouraging prerequisites, not a gVisor compatibility result. At the
pinned release, both explicit modes require host user namespaces. With
DirectFS plus `--network=none`, `container.New` adds a user namespace before
sandbox creation; without DirectFS, the support-process path creates one too.
Systrap itself does not require user namespaces.

Therefore neither named profile can run on this `CONFIG_USER_NS=n` artifact.
The separately built non-shipping kernel variant changes only
`CONFIG_USER_NS=y` through a post-configure override and verifies the resulting
`.config`; a full symbol comparison after `olddefconfig` found no dependent or
incidental change. It does not edit the forward-port patch or a shipping kernel.
`isolation-userns`/`--directfs=false` is the preferred first candidate. The
still-explicit `functional-directfs` mode remains available for an A/B only and
would produce functional/DirectFS evidence, never isolation acceptance. No
networking, ptrace, native, test-only-flag, or profile fallback exists.

### Current reader rootfs is not the test environment

Inspection of the same artifact found no `runsc`, Python, Guile, `jq`, `tar`,
`unshare`, or `newuidmap` at the checked system-profile paths. It should not be
mutated or treated as a nearly complete spike image. Build a separate system
closure instead.

## 4. Guix package gap

Both the ambient Guix and the repository pin return the same gVisor-related
search results:

```sh
guix search gvisor
guix time-machine -C channels.scm -- search gvisor
```

They contain `go-gvisor-dev-gvisor` and gvisor-tap-vsock packages, but no
`runsc` package. `go-gvisor-dev-gvisor` is not a runtime:

- version `0.0.0-1.9414b50`, commit
  `9414b50a5633100fd7299a5a7998742575dcb669` (2025-02-05);
- source-only, with `#:skip-build? #t`;
- its package comments record that a full build depends on Bazel.

Derivation-only native-system and cross-target queries resolve, but only for
that source package:

```sh
guix build --no-grafts --no-substitutes --derivations \
  -s aarch64-linux go-gvisor-dev-gvisor
guix build --no-grafts --no-substitutes --derivations \
  --target=aarch64-linux-gnu go-gvisor-dev-gvisor
```

Consequently, installing `go-gvisor-dev-gvisor` would not put `runsc` in the
guest and cannot satisfy the spike.

## 5. Candidate release pin

For the first spike, repackage an official release distribution rather than
introducing a Bazel source build. The exact candidate selected on 2026-09-04
is:

```text
tag:                  release-20260831.0
annotated tag object: 7346147ed369e94e93976a4a0f115f51bd5f7130
target commit:        fd2f6b2674208086e324c2f739155eb7e1b48ff2
published:            2026-09-04
```

Recommended source:

```text
https://github.com/google/gvisor/releases/download/release-20260831.0/gvisor-aarch64.tar.zstd
size:         119,968,856 bytes
sha256 hex:   c1182b6046e1c64b871cd13b4d11335f1d55ba89c3a5c7e8cf4dc1c8f3ac0d3a
Guix base32:  0fhdmkrwihadrzlcg9f3i6x5a7az6c8lsfyi3j3lpip18rh2n661
```

Equivalent bzip2 asset, retained as a fallback for simpler unpacking:

```text
https://github.com/google/gvisor/releases/download/release-20260831.0/gvisor-aarch64.tar.bz2
size:         152,982,848 bytes
sha256 hex:   24e91d9b2e02079d18837380a7c9d32cb04c58ccbb1f95901f09d10057f1261d
Guix base32:  0796y5bh1l893y89a7xvric4rc1csg4sg03khcc9s1q25sdivs94
```

The SHA-256 is published in the release's `SHA256SUMS`; the independently
downloaded `SHA512SUMS` entry also matched the local archive:

```text
sha512: 92705c4f339715e34435e9ca553484d9edde0df21137d35aa89b66c3215069e009bfc6e0cc8f8fe8da681059b4c06daa70ce34f166978742742e99685c08730a
```

The release API's asset digest agrees with the SHA-256. GitHub reports the
annotated tag as unsigned, so this is checksum/content verification, **not
signature verification**. The checksum files come from the same unsigned
release publication; they do not add an independent signing identity.

### Package the complete distribution

Current upstream installation guidance requires the release layout to stay
together:

```text
$out/bin/runsc
$out/bin/containerd-shim-runsc-v1
$out/bin/gvisor-bin/...
```

Releases since 2026-07 use sidecar files under `gvisor-bin/`; runtime
auto-download is being removed. At this exact release, however, the
`DEFAULT` sidecar-usage policy still permits the old embedded fallback.
Packaging only `runsc` is incomplete, and a missing adjacent helper could be
concealed unless the launcher explicitly selects
`--sidecar-usage-policy=strict` and
`--sidecar-release-enforcement-policy=always` under a sanitized environment.

The 119,968,856-byte archive was downloaded under
`/tmp/opencode/wilkbook-gvisor-release-20260831.0`, checked against both
upstream checksum files, listed before extraction, and then inspected with
native `file`, `readelf`, and `strings`. Its exact layout is seven tar members:

```text
containerd-shim-runsc-v1
runsc
gvisor-bin/
gvisor-bin/checkpointgofer
gvisor-bin/gvisor-sentry-prewarmer
gvisor-bin/gvisor_sentry
gvisor-bin/runsc-metric-server
```

All six files are executable, static AArch64 ELFs with no ELF interpreter or
`NEEDED` entries. That includes the 1,208-byte
`gvisor-sentry-prewarmer`—despite its size, it is an ELF, not a script. There
are no archive symlinks. The `runsc` bytes contain the
`release-20260831.0` marker; the binary was not executed on the x86-64 host.

`pinenote/packages/gvisor.scm` now implements the fixed-output unpack/copy
package with the exact URL, hash, member list, executable modes, static ELF
shape, AArch64 machine, and embedded version marker as build-time gates. It
installs all six files together and performs no runtime download. The
containerd shim is retained for a complete release installation, but
containerd is not installed in the spike system.

The bounded build (`--cores=2 --max-jobs=1`) produced:

```text
/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0
```

The installed file list is exact, all six installed files again inspect as
static AArch64 ELFs, and their SHA-256 values are byte-for-byte identical to
the verified archive members. No ARM64 executable ran during these checks.
The generated cross-build `PATH` placed native binutils first, followed by
native zstd; GNU tar, grep, findutils, coreutils, and bash-minimal were also
present. Cross-binutils was present separately for target work, but the plain
`readelf` and `strings` used by the gates came from native binutils.

### ARM64 status is still a test question

Upstream documents ARM64 and reports 253 of 295 Linux syscalls fully or
partially implemented. That is not a Guile/Python compatibility guarantee.

Open issue [gVisor #13361][gvisor-idle] reports high ARM64 Systrap idle CPU in
a different environment. Several fixes discussed there landed before the
candidate release (including the ARM64 timeout-frequency correction and work
to park the fast-path monitor, Timekeeper, and watchdog), but the issue remains
open. The release may be a better starting point; it has **not** demonstrated
acceptable PineNote idle behavior. Idle wakeups and power remain later
hardware measurements.

## 6. Non-shipping implementation scaffold

Four offline prerequisites are now implemented:

1. `pinenote/packages/gvisor.scm` packages the complete pinned ARM64 release.
2. `pinenote/systems/pinenote-book-execution-spike.scm` defines a dedicated
   system based on `make-pinenote-operating-system`. It installs `gvisor-bin`,
   selects a non-shipping `CONFIG_USER_NS=y` kernel variant, declares cgroup2,
   retains a narrow Guile/`guile-json`/Python language profile, and retains a
   separate trusted Guile/`guile-json` supervisor profile without Python.
3. `pinenote/tools/book-execution-spike/generate-oci-bundle.scm` and
   `oci-bundle.scm` construct the fixed Python compatibility-smoke bundle in
   trusted Guile from the exact `guix gc --requisites` closure and one selected
   immutable store file. `guile-json` 4.7.3 emits JSON with `#:unicode #t` so
   all C0 controls are escaped. The reviewed Python generator remains only an
   independent host-test oracle.
4. `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` and
   `disposable-qemu.scm` own the private, networkless, TCG-only QEMU process and
   disk envelope in Guile. Python drives fake-QEMU host tests only; the old
   Python runner remains reference material and is not the runtime path.

Both separate profiles are Guix `profile` objects referenced by the system's
`/etc` service, so they are retained by that system generation. Keeping the
trusted supervisor separate avoids a Guile version collision in the broad
system profile and keeps Python out of trusted supervision. The same service
retains a tiny `plain-file` fixture at
`/etc/wilkbook-execution-spike/smoke-book` for a future interpreter/mount/no-
network smoke; it is trusted system configuration, not protocol content. The
definition does not evaluate book-supplied manifests, add a Guix daemon, or add
network services. Neither this system nor the package is referenced by a
shipping flavor. The sibling protocol implementation now imports `(json)` and
is tested against `guile-json` 4.7.3, so the retained profile uses the pinned
`guile-json-4` package; its ARM64 cross derivation resolves independently. The
broker interface remains owned by that separate work.

`pinenote/tools/book-execution-spike/` now contains host-side package/archive
checks, mutation tests for the package/member gate, the narrow Guile OCI
generator/tests, and the Guile disposable QEMU runner/tests. Protocol
integration, bounded output import, runtime sidecar-resolution probes, guest
denial/lifecycle probes, cgroup ceilings/accounting, and a QEMU console
assertion driver remain future work. The tools should be invoked directly at
first; no shared `Makefile` change is needed.

The successful pinned gates were:

```sh
# Package derivation.
guix time-machine -C channels.scm -- \
  build --no-grafts --derivations -L . --target=aarch64-linux-gnu \
  -e '(@ (pinenote packages gvisor) gvisor-bin)'

# Bounded package build only—no kernel or system-closure realization.
guix time-machine -C channels.scm -- \
  build --no-grafts --cores=2 --max-jobs=1 -L . \
  --target=aarch64-linux-gnu \
  -e '(@ (pinenote packages gvisor) gvisor-bin)'

# Static system/profile/kernel/cgroup inspection only.
guix time-machine -C channels.scm -- \
  repl -L . -q \
  pinenote/tools/book-execution-spike/check-execution-system.scm
```

They resolved to:

```text
package derivation: /gnu/store/x8k6gpr9cv9h77gagbdjrvqsvk7n1gw4-gvisor-bin-20260831.0.drv
package output:     /gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0
guile-json cross:   /gnu/store/v1sdxsifd8x52ykxdrkd6ln0pzyr4glr-guile-json-4.7.3.drv
smoke fixture:      /gnu/store/rpvzi1xj70l5gg14xd5y2izaf02w1gkm-wilkbook-book-execution-smoke.txt
test kernel drv:    /gnu/store/6xgyq3awmj54ks6w7mm27qc69sail51r-linux-pinenote-book-execution-test-7.1.8-pinenote.drv
test kernel output: /gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote
```

`guix gc --derivers` on the recorded output returns the recorded package
derivation. The exact current `pinenote/packages/gvisor.scm` SHA-256 for this
tuple is `8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d`.
The authorized full cross-build used `--cores=2 --max-jobs=1`. Against the exact
base derivation/output, the complete final config diff is one line:

```diff
-# CONFIG_USER_NS is not set
+CONFIG_USER_NS=y
```

The output's `.config` SHA-256 is
`0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309`;
its ARM64 `Image` SHA-256 is
`f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223`.
The cached generic shortcut was explicitly rejected. The exact system/image
build and private staging gate completed; later v2/v3 runs booted it and the v3
guest executed the pinned ARM64 `runsc --version`. Sentry and payload execution
remain later gates.

The dedicated outputs are:

```text
system drv:    /gnu/store/3msfrhabf37wdlih7rfvwzgr9axjavi1-system.drv
system output: /gnu/store/laq3v5csnh5p8i9njv5vrap0kls5ay5g-system
image drv:     /gnu/store/d01lkpyfnqcjqys3rsq579gwcqjs5i6s-disk-image.drv
image output:  /gnu/store/vvrp8i9af77sacic7rqnmcjiacpgd74a-disk-image
```

Both were realized with `nice -n 10`, `--no-grafts`, `--cores=2`, and
`--max-jobs=1`. The image directly references that exact system once, its
closure contains the exact USER_NS kernel and gVisor output, and it contains no
generic 7.0.11 kernel. The store image SHA-256 is
`e04bdb0c7274eb807f4e6c8a531eb6070a50e180e4ab2d6ecf8ca7c79d348c61`.

Guix's `raw-with-offset` intermediate labels its sole ext4 partition
`Guix_image`. The spike-only staging helper therefore copies the store image to
a private regular file, extracts only that copy's sole type-`0x83` partition,
sets its label to `PNGuixRoot`, and writes it back at the same offset. It uses no
mount, loop device, root privilege, or device path and does not modify the Guix
output. The resulting 2,048,200,704-byte baseline has an unchanged first 1 MiB
including its MBR, one partition at byte 1,048,576, and a read-only `e2fsck`
passes. Its SHA-256 is
`f16b1ef41980ab1dfa1694102f2335956cb5c6372b69a1dbdc01d231791bcaf7`.

The immutable private artifact is under the gitignored path:

```text
pinenote/tools/book-execution-spike/build/artifacts/pinenote-book-execution-userns-20260904/
```

Its `manifest.txt` SHA-256 is
`c686a4f9bbc4124d2f248a5c0761471aa605a2f37f81e2b1891653bba588b637`.
It records the kernel config, kernel, initrd, DTB, extlinux configuration, source
image, transformed root disk, exact system/kernel paths, partition geometry,
`isolation-userns`, and no host share/network. The wider private review manifest,
including exact guest source hashes, is
`build/baseline-review-manifest.txt`; its SHA-256 is
`9307fd37cdb5165c12b66c43ac1513df4832f963c0ea79119bd8a7561f37b034`.
The exact, deliberately non-executable launch recipe is
`build/first-boot-after-guest-review.command`, SHA-256
`57f2b2c62c45bea341de806b173671626eebf7b6f184b130c2b2206ef6c886cd`.
It has not been run.

That artifact remains preserved as the review's accepted construction evidence;
it was not overwritten. The same review withheld boot authorization and required
three source/integration corrections. The corrected `-v2` snapshot reuses the
exact kernel derivation and has these new outputs:

```text
system drv:    /gnu/store/k3nrd3a0xanqkq06s5hbis8fc99di9f8-system.drv
system output: /gnu/store/0rlw7zk22cnc4vcrlxz4c91xlphn6489-system
image drv:     /gnu/store/8ygqb7zcbarppbv747jnwqkp1zk1zxim-disk-image.drv
image output:  /gnu/store/klgw7f4nypj4mhfz9l1py3rqmx5l1cm4-disk-image
image SHA-256: f85c4e1de80ada942f99b2674beb234496bb208e978b02f128c3ac90b5aeb1ee
```

The build again used `nice -n 10`, `--no-grafts`, `--cores=2`, and
`--max-jobs=1`. Its plan contained only the changed guest/system/image
derivations; the kernel remained the already-realized `/gnu/store/4d614…`
output. A fresh comparison again found exactly `CONFIG_USER_NS: n -> y`, with
the same config and Image hashes recorded above. The new image references the
new system, exact kernel, and exact gVisor output once each, and no generic
7.0.11 kernel.

The new immutable artifact is
`build/artifacts/pinenote-book-execution-userns-20260904-v2/`. Its source image,
artifact manifest, and relabelled root hashes are respectively:

```text
source image:      f85c4e1de80ada942f99b2674beb234496bb208e978b02f128c3ac90b5aeb1ee
artifact manifest: cfde18fece90f8a56e2d13170b2ea45dd4d4f85967be37f200e94f3b321351bf
root disk:         e142c244dd5b6de83da4cdf9121fd128504bedfa8c9b873b94f7311f308a7e5d
```

The 2,048,106,496-byte root disk retains the source's first 1 MiB/MBR,
contains one ext4 partition at byte 1,048,576 with size 2,047,057,920 and label
`PNGuixRoot`, and passes read-only `e2fsck`. Inspection found no writable files,
symlinks, hard-link aliases, or staging residue; a repeated stage request was
rejected without changing hashes. The consolidated private review manifest is
`build/baseline-review-manifest-v2.txt`, SHA-256
`685855096da1c203431788b655c4d824b284903ee6e8578ff72f5962c12f2fbe`.
The non-executable, `set -eu` launch recipe is
`build/first-boot-after-guest-review-v2.command`, SHA-256
`8df7875c0ce3669c9132676ad4640ef9109f9fce4411602787fbd94365f78da4`.
It checks and reports explicit runner/checker status. After focused acceptance,
the exact v2 recipe reached its 600-second outer timeout; that pre-diagnostic
runner correctly cleaned its private tree but consequently retained no console.

### First boot evidence and the v3 two-bug correction

The subsequent authorized 150-second diagnostic-only run used the same immutable
v2 image and the accepted failure-diagnostic runner. Its escaped serial log is
preserved privately as `build/first-qemu-v2-diagnostic-150s.log`, SHA-256
`a5d981ad6348c271655a0ca07124a610839efae738596665bda204b466edf585`.
It directly observed:

- Linux 7.1.8 on `linux,dummy-virt`;
- virtio block device `vda`, partition `vda1`, and `PNGuixRoot` mounted ext4 at
  2.192 seconds;
- Shepherd 1.0.9 starting at 4.610 seconds;
- `BOOKEXEC-KERNEL-IDENTITY-PASS` and
  `BOOKEXEC-NETWORK-ABSENT-PASS`; then
- `BOOKEXEC-SMOKE-FAIL` for the forbidden-mount assertion.

There is no `BOOKEXEC-RUNSC-VERSION-PASS`, payload marker, or clean powerdown.
Therefore the run is kernel/root/early-fixture evidence only: it does not show
that the ARM64 gVisor binary executed. The old service then deadlocked exactly as
the pinned Shepherd source predicts: its synchronous one-shot start callback
called `halt`; root shutdown tried to stop that still-starting service and waited
for its start future, while the callback waited for `halt`'s reply.

The mount failure was also a fixture bug. The old predicate rejected every
mountinfo row whose mountpoint was `/gnu/store`. The pinned Guix
`%immutable-store` definition deliberately binds `/gnu/store` onto itself with
`read-only`, `bind-mount`, and `no-atime` flags after the root filesystem. The
diagnostic run did not print the actual offending mountinfo row, so none is
claimed as measured. The v3 predicate instead parses mountinfo fields and allows
only an exact read-only `/gnu/store` self-bind whose device, filesystem type,
and source match `/`; it still rejects malformed input, writable or foreign
store mounts, nested store mounts, `/data`, and 9p/virtiofs/NFS mounts at any
mountpoint. Failure now reports the reason, root device/type, and an escaped
offending line bounded to 2,048 source bytes.

The v3 service is a non-respawning `make-forkexec-constructor` service with
`make-kill-destructor`. Shepherd owns one process; after the smoke returns and
its forced serial markers are complete, that process syncs, flushes, and
replaces itself with `halt`. A host Shepherd 1.0.9 test on a private socket
observed the analogous fork-exec service as running before allowing its child to
request root shutdown, then observed clean service stop and process reaping. It
did not contact the host service manager or invoke host poweroff.

The two corrected sources were rebuilt with `nice -n 10`, `--no-grafts`,
`--cores=2`, and `--max-jobs=1`. The image contains the exact prior USER_NS
kernel output once and no generic 7.0.11 kernel; the installed config delta is
still only `CONFIG_USER_NS: n -> y`. The review boundary is:

```text
image system drv: /gnu/store/8fz7xr4shps5c3m449avwqbjdmm0zvlr-system.drv
image system:     /gnu/store/k0a2rvacjh05c1zgh723mq51gqhgw7yc-system
image drv:        /gnu/store/rr9rq1w9di1jj8s1wsaabx7n3i8kdaxi-disk-image.drv
image:            /gnu/store/rx9pnklbcbb1mhm0dxr7f4pa46hyayfx-disk-image
image SHA-256:    41abc30779cbc4a242ea7b4a9f3b5f401f783279f77de68966533434ac2fd61b
artifact:         build/artifacts/pinenote-book-execution-userns-20260904-v3/
artifact manifest SHA-256: 3db85e1cb33a8ee382b6344ae2a03b9809340fb579e378521030fcd7aed60a3e
root disk SHA-256:         f9e8d915cc963fc9984d10398b70f001b8fa10af72cb11d309428b82ab52961f
review manifest SHA-256:   8071a62c95d56772db9e34ea7b61447ce7bf276341cb4cc364ab99576745179b
```

The v3 baseline has one ext4 partition at byte 1,048,576, label
`PNGuixRoot`, UUID `a454a7b0-be49-f492-406f-5fb9a454a7b0`, and passes the
non-mounting inspector plus read-only `e2fsck`. Repeated staging refuses to
overwrite it. `build/baseline-review-manifest-v3.txt` records the exact sources,
two v2-to-v3 diffs, build logs, service outputs, and evidence hashes. The
prepared mode-0600 recipe `build/first-boot-after-v3-review.command`, SHA-256
`fa4d454d52b4a33b98b4a0867efcb706e17962d0e0cd85f7166f809d4a886dbf`,
was subsequently authorized and executed.

### v3 runtime evidence and the v4 profile-authority correction

The v3 run completed guest shutdown rather than timing out. Its escaped log is
preserved as `build/first-qemu-v3-focused-run.log`, SHA-256
`d59c9ca2437bcf2b5bc600690ba208e247817adea24f147ccbaafac86b0abd3d`.
It emitted, in order:

```text
BOOKEXEC-KERNEL-IDENTITY-PASS
BOOKEXEC-NETWORK-ABSENT-PASS
BOOKEXEC-FORBIDDEN-MOUNTS-PASS
BOOKEXEC-RUNSC-VERSION-PASS
BOOKEXEC-SMOKE-FAIL ... profile store item lacks -profile suffix ...
```

The root filesystem was remounted read-only during orderly shutdown and QEMU
reported power-down at 14.115 seconds; QEMU stderr was empty. The outer checker
correctly rejected the failure marker (`RUN-STATUS=1 CHECKER-STATUS=1`). The
version PASS means the guest really executed the packaged ARM64 `runsc` and its
output contained `release-20260831.0`. Bundle generation follows that check, so
no Sentry, Python, Guile, or cgroup-teardown result is implied.

The failure exposed another fixture assumption, not a gVisor result. A Guix
profile's output name is caller-selected; the realized profile is legally named
`kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-wilkbook-book-execution-languages`.
The v4 generator no longer treats a `-profile` suffix as authority. It still
requires the trusted selected path to resolve to one canonical top-level store
directory and occur exactly in the enumerated closure, and now additionally
requires a real regular `manifest` plus executable `bin/python3` and `bin/guile`
targets whose owning store items occur in that closure. Tests accept a valid
custom name and reject a directory without a manifest or either language entry.

Before rebuilding, the actual retained ARM profile, immutable book fixture, and
guest closure manifest were replayed through the Guile generator on the host.
The manifest contains 45 unique paths and exactly equals
`guix gc --requisites` for that profile. Both the Python bundle and the
Guile-rewritten bundle generated successfully. Each has exactly 45 individual
read-only closure binds and one separate noexec book bind—not the historical 844
workstation-profile mounts. Structural validation checked the complete OCI
configs, rootfs placeholders, process records, Systrap/directfs/network/cgroup
and strict-sidecar flags, generated cgroup/FD preflight ordering, Scheme/shell
syntax, and that every generated guest executable path maps to an existing
ARM64 file in the realized image system. It did not execute those target files.
Replay and validation commands and hashes are in the private v4 manifest.

The one-source correction was rebuilt with `nice -n 10`, `--no-grafts`,
`--cores=2`, and `--max-jobs=1`; the full cheap aggregate passes. The v4 image
contains the exact prior USER_NS kernel output once and no generic 7.0.11
kernel. Its installed config delta remains only `CONFIG_USER_NS: n -> y`:

```text
image system drv: /gnu/store/8dq1n3zd9r7viszsbq4k01r62cb9gyk4-system.drv
image system:     /gnu/store/7m9iyf4f41grj342ifkw1dlxxmnvjx0a-system
image drv:        /gnu/store/fa3p5mxb08x6jby6cby6h0052b1aqgi1-disk-image.drv
image:            /gnu/store/qa2lg7szbgfx3fgk9ajkngkyiwg3irc8-disk-image
image SHA-256:    3b060e54a02d5947a41abf3e774ab814b0384785fe209eb949abcb2090871ea3
artifact:         build/artifacts/pinenote-book-execution-userns-20260904-v4/
artifact manifest SHA-256: 86732f72ea08047ab38262ed6fe01cc99aac706cf755b1e949d2529ab9fd1c42
root disk SHA-256:         d8d3bf39b155e410eac1a906ff764185bd2da5ab8279fd008048beb657979cb8
review manifest SHA-256:   09f04ec69a06beeeb35132a80ab174e60e85699862637cefc64f2949cfba7979
```

The v4 baseline has the same one-partition geometry, `PNGuixRoot` label, and
UUID as v3; it passes the non-mounting inspector and read-only `e2fsck`, and
repeat staging refuses to overwrite it. The focused primary-source diff is
`build/v4-profile-authority.diff`, SHA-256
`f902bb89053eba605a221f35d304958c8828a938178e0b587e04fa2553c88c1f`.
The mode-0600 recipe `build/first-boot-after-v4-review.command`, SHA-256
`b3fa89d672828202e4b1303e7ae1f9c2e6b0c5f2c639a7814ab97f0ef353d454`,
was subsequently authorized and executed once.

### v4 runtime evidence and bounded v5 startup diagnostics

The exact v4 run is preserved privately as
`build/first-qemu-v4-focused-run.log`, SHA-256
`abae083c9016721361f177c21837906ae78a3eb16dce4eb48a5ca6b09a81f815`.
It emitted the four prior PASS markers, then reached the first Python bundle's
real launch. Profile validation no longer failed. Instead `runsc run` exited 128:

```text
running container: creating container: cannot create sandbox:
cannot read client sync file: waiting for sandbox to start: EOF
```

No Python or Guile payload sentinel, language Systrap PASS, or cgroup-teardown
PASS appeared. The root remounted read-only and QEMU powered down at 15.408
seconds; QEMU stderr was empty. The outer result correctly remained
`RUN-STATUS=1 CHECKER-STATUS=1`, so the exact outer success line was absent.
This is QEMU-only evidence; there was no hardware, SSH, UART, deployment, or
device operation.

At pinned commit `fd2f6b2674208086e324c2f739155eb7e1b48ff2`,
`sandbox.New` starts the sandbox child, closes its local startup-pipe writer, and
reports this EOF when the child closes its inherited writer before writing one
byte. The Sentry `boot` command writes that byte only after spec/chroot setup,
capability changes, loader creation, and metric initialization. By default its
stdio is disconnected; `--debug` preserves child stderr, while `--debug-log`
files are opened by the parent and donated to the Gofer and Sentry. Therefore
the v4 line is only the parent symptom—not evidence for a CPU incompatibility,
permission failure, or general inability to run gVisor.

The v5 fixture retains the exact profile, `isolation-userns`, Systrap,
`--directfs=false`, `--network=none`, strict sidecars and release enforcement,
`--ignore-cgroups=false`, payload checks, cgroup teardown, kernel, outer runner,
and shutdown lifecycle. Trusted generator policy adds no test-only or
book-selected flag; it adds only `--debug=true`, text debug logs,
`--alsologtostderr=true`, and private bundle-local debug/panic paths. On nonzero
`runsc`, the guest emits fixed-size escaped head/tail ranges from captured
stdout, support stderr, up to twelve debug/panic files, and `dmesg`, plus exit,
cgroup-presence, runtime-state, exact resolved-helper-path, and actual version
records. Source newlines remain escaped and every rendered data line is
prefixed, so captured content cannot forge an exact PASS line. Missing,
non-regular, excessive, or unreadable diagnostics report bounded metadata and
never replace the original failure.

Host regressions cover missing/non-regular logs, the debug-file-count bound,
head/tail elision, control escaping, and attempted PASS text injection. The
Guile generator still matches the independent Python oracle, and tests require
the original security flag vector unchanged and in order, with the diagnostic
flags separate. Private pinned-source and permission traces plus the exact
v4-to-v5 primary diff are in the v5 diagnostic packet. At that point no v5 QEMU
run was permitted before focused review of the packet and newly staged immutable
image.

The current source re-resolves image derivation
`/gnu/store/bs5qp28pbp761qy57dyxn7ihbvqmqz3x-disk-image.drv`, realized as
`/gnu/store/rglixigcv4rvhp0vikk3bxxf3b4acg6p-disk-image` (SHA-256
`38f0d63b0cfba5e1f6b2d9f77c30f3fce58e0a0e020ea03c5abfdd7bdc71e2fc`).
Its image system is `/gnu/store/3iqcxdwb38g0grwqlj201b9lfsnr75aj-system`.
Both its links and the staged boot bundle resolve to the accepted unchanged
USER_NS kernel output `/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-…`;
the Image/config hashes remain `f3da1a22…` and `0a885ef8…`. The immutable
private v5 baseline is under
`build/artifacts/pinenote-book-execution-userns-20260904-v5/`, with manifest
SHA-256 `3473bf9a…` and transformed-baseline SHA-256 `4f1e2c73…`; non-mounting
inspection, `PNGuixRoot`/UUID inspection, read-only `e2fsck`, and overwrite
refusal pass. The final cheap aggregate is `55913695…`; exact-profile replay is
`5d0c8545…`; the 603-line exact focused diff is `7e62edcd…`. The gated recipe
`build/first-boot-after-v5-review.command` is mode 0600 and SHA-256 `9bbb0a30…`;
it was later authorized and executed exactly once. `build/baseline-review-manifest-v5.txt`
records the full values and non-claims.

The focused v5 review then found one outer-only retention gap before authorizing
execution: the accepted runner exported only the first and last 32 KiB of the
serial log, while the bounded v5 guest packet can place the decisive child line
in the middle. The accepted correction did not rebuild or alter the v5 image,
kernel, recipe, or runsc arguments. After QEMU is reaped it streams the complete
private console to parent stderr before cleanup under a 3,423,172-byte source
limit. The source-derived selected-data maximum is 1,326,020 bytes: 16 file
ranges × (8 KiB head + 8 KiB tail) × 5 guest escaping, plus twelve 255-byte
debug filenames × 5. A further 2 MiB covers framing and boot/control/shutdown
output; the prior raw v4 console was 21,338 bytes. Parent escaping writes
directly from a source bytevector capped at the limit plus one byte and can
expand bounded content by at most another 5× (17,115,860 bytes), without an
unbounded whole-port string read or an in-memory expanded copy. Overflow or a
changed source emits an explicit
`BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE` record and cannot become success. Host
regressions place a distinctive prewarmer child fatal beyond 64 KiB inside the
actual v5 aggregate budget, require every selected evidence token at parent
stderr, and cover timeout, nonzero, parser-error, overflow, terminal escaping,
and private-root cleanup. This was preparation evidence; the runtime result is
recorded next.

### v5 runtime evidence and offline Systrap narrowing

After the focused outer-retention review and separate execution authorization,
the unchanged v5 recipe ran exactly once. The complete parent log is preserved
privately as
`build/v5-runtime-evidence/wilkbook-qemu-v5-diagnostic.GABjDe.log`, SHA-256
`db9ba050d605fb611756d2f0a2a7024926807aa9070cb6dee6f8c86dd3ed819f`.
It is 130,635 bytes. Its outer framing records a complete 121,841-byte source
console, no diagnostic-incomplete marker, and an empty QEMU stderr. The run
ended with `RUN-STATUS=1 CHECKER-STATUS=1`; the exact outer success line is
absent.

The guest again emitted kernel-identity, network-absence, forbidden-mount, and
ARM64 runsc-version PASS. It selected the packaged prewarmer, Sentry, and Gofer
under strict sidecar enforcement with `isolation-userns`, Systrap,
`--directfs=false`, `--network=none`, and `--ignore-cgroups=false` unchanged.
The Gofer served the root, the exact individual store mounts, and the selected
book input. The Sentry entered its real Go `main`, read the OCI spec, set
`GOMAXPROCS=4`, selected Systrap, created the Systrap memory file, and initialized
the stub. It then wrote a complete 10,013-byte `runsc.panic.panic.log` beginning:

```text
panic: failed to create a syscall thread
```

The stack is `initSyscallThread` line 219 → `newSubprocess` line 379 →
`systrap.New` line 316 → `createPlatform` line 1094 → `boot.New` line 730 → the
Sentry boot command and `sentry_main.go:26`. `runsc run` exited 128 with the
parent-side startup-pipe EOF. The guest recorded both the cgroup and runtime
state as still present, emitted `BOOKEXEC-SMOKE-FAIL`, synced, remounted the root
read-only, and powered QEMU down at 15.668 seconds. It emitted no payload,
language-Systrap, cgroup-teardown, or overall PASS.

The panic wording is broader than its source location. At pinned commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, `systrap.New` calls
`newSubprocess(createStub, mf, false)`. Reaching `initSyscallThread` proves that
`createStub` returned successfully. That path had already completed its direct
legacy `clone` with `CLONE_FILES|SIGCHLD`, child stop/wait, ptrace attach and
options, register read/write, and one ptrace-injected `munmap`. The failing call
is therefore **not** the later thread-clone path. In `forkStub`, a zero clone
return is the child branch, which enters the stub and cannot return a `thread` to
`newSubprocess`; only the parent's nonzero child PID can reach the observed
function.

`initSyscallThread` panics whenever `syscallThread.init(false)` returns any
error, but drops that error instead of formatting it. For this call the remaining
error-producing stages are exactly:

1. allocate an 8 KiB range from the fresh Systrap `MemoryFile`; a first
   uncommitted allocation can extend and map its sparse 1 GiB backing chunk;
2. ptrace-inject a fixed, read-only 4 KiB file `mmap` into the stub;
3. ptrace-inject the adjacent fixed, read-write 4 KiB file `mmap`; or
4. map the same 8 KiB range into the Sentry itself.

For either injected map, ARM64 setup copies the stopped stub registers, puts the
syscall number in X8 and six arguments in X0–X5, writes `NT_PRSTATUS` with
`PTRACE_SETREGSET`, continues to the stub's post-`svc` trap, waits for SIGTRAP,
then reads `NT_PRSTATUS` and decodes signed X0. Set/get-register, continue, wait,
or unexpected-exit failures have separate panic text; none was retained. A
negative X0 becomes the ordinary `unix.Errno` that `initSyscallThread` currently
discards.

Seccomp-notify installation is skipped because the recorded argument is false.
The first two stub mappings use the already-validated ptrace injection mechanism,
but their six-argument `mmap` operation differs from the earlier successful
`munmap`. The stub's own generated filter explicitly allows ARM64 syscall 222
(`mmap`), while the Sentry's final sandbox filter is installed only after loader
creation and was not reached. Neither the panic file nor any other retained
diagnostic logs the selected stage or errno; the omitted middle of the ordinary
debug log cannot contain a value that this source never emits. The bounded
`dmesg` tail contains no OOM, seccomp, audit, ptrace, or process-limit report
around the failure, but ordinary `mmap` errors need not produce one.

The exact kernel config has `CONFIG_USER_NS=y`, all selected namespace and
cgroup prerequisites, `CONFIG_SECCOMP=y`, `CONFIG_SECCOMP_FILTER=y`, and
`CONFIG_MEMFD_CREATE=y`. The parent recorded Sentry ambient capabilities 8, 18,
19, and 21, including `CAP_SYS_PTRACE`, and the successful early ptrace sequence
is stronger runtime evidence than config alone. The OCI payload's
`RLIMIT_NOFILE=64` is not the Sentry limit, and the OCI object declares no
`linux.resources` ceilings. QEMU supplied 2 GiB and Linux reported 1,998,068 KiB
available during boot. This failing function performs no clone, so
`RLIMIT_NPROC` and cgroup `pids.max` cannot directly explain its return;
memory/address-space failures remain possible until the discarded errno is
captured. `CONFIG_BPF_SYSCALL` is unset, but the stub's classic seccomp-BPF
filter installed before the successful attach; there is no evidence connecting
that unrelated syscall option to this error. The retained packet does not expose
the Sentry's `/proc/self/status`, inherited rlimits, cgroup PID/memory counters,
or `memory.events`; those remain missing evidence rather than assumed-normal
values.

This QEMU used `-cpu max`. Linux detected LPA2 with a 52-bit VA config, and
gVisor logged `stubStart=0xff2dc9c3ef000` and
`stubSysmsgStack=0xffd3bf4db8000`: both are above 2^48 and below 2^52. Thus the
52-bit path is observed and differs from the PineNote's Cortex-A55 path, but it
is not yet a root cause: the Sentry had already mapped stub code above 2^48 and
the child inherited it before the failure, but the separately randomized
`stubSysmsgStack` target had not yet been mapped.

No test in the pinned tree directly exercises `initSyscallThread` or
`mapMessageIntoStub`. The locally available `origin/master` snapshot from
2026-09-04 has byte-identical versions of all eight traced Systrap/pgalloc files;
it contains no post-pin fix for this path. Earlier ARM64 work covers TLS, sysmsg
thread initialization, and 39/48/52-bit address-space selection, not this
discarded initialization error. This is an offline, shallow-checkout history
result, not a claim about unexamined upstream history.

The smallest proposed discriminator is a separately reviewed throwaway gVisor
diagnostic build and one new immutable diagnostic image—not a blind v5 retry.
Keep the accepted kernel, QEMU `virt`/TCG/`max` CPU and four-vCPU topology, OCI
JSON, workload, Systrap backend, and every runtime/security flag unchanged. The
first unapplied proposal at
`build/v5-runtime-evidence/proposed-v6-systrap-init-error-context.patch`
(SHA-256 `1e4eb93a490691eca102a6ce57d9e70db6d82b19de94f3dadb6be5002cfaa6e2`)
is retained as review evidence, not as the build candidate. Review at
`doc/reviews/2026-09-04-book-guest-smoke-adversarial.md` SHA-256
`ca6c44ee0fd9e31bdc46dfc48f1660d27608f4339ddeb95781a883101b24cc33`
required `%w` for the backing `mmap` errno and task-size plus applicable
address/length/file-offset context through the whole panic chain. The
parent-authorized proposal revision is the distinct
`build/v5-runtime-evidence/proposed-v6-systrap-init-error-context-v2.patch`
(SHA-256 `9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e`).
It contains exactly those message-only corrections and passes
`git apply --check --whitespace=error-all` against clean commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`; it has not been applied to that
checkout. Its five labels distinguish backing-file truncate, backing-file map,
read-only stub map, read-write stub map, and Sentry map. The existing ARM64
return decoder will then print the actual negative-X0 errno for either injected
map; ptrace register or wait failures retain their already-distinct panic paths.

### v6 source-build gate (completed offline)

The installed `gvisor-bin` package is a fixed-output repack of upstream's
prebuilt release, not a source-build base. A diagnostic Sentry must therefore
not be dropped into that package. The exact pinned source's canonical
`//:release` target assembles all six required ARM64 files: top-level `runsc`
and `containerd-shim-runsc-v1`, then `checkpointgofer`,
`gvisor-sentry-prewarmer`, `gvisor_sentry`, and `runsc-metric-server` under
`gvisor-bin/`. Four carry `STABLE_VERSION`; the shim and one-page C prewarmer
do not. A fixed workspace-status command must give every version-bearing binary
`release-20260831.0`; accepting the diagnostic checkout's automatic `-dirty`
label would defeat strict release matching.

The first non-executed recipe,
`build/proposed-v6-source-build.command` (SHA-256
`110c1b2fb85ca1fd5101fc6466879bf708f21d88e728b2ec301e12c48c13b457`),
is retained as review evidence and must not be run. It incorrectly required
`.git` to be a directory even though this checkout is a worktree with a `.git`
file, and its direct `$0` container re-exec was neither explicitly exposed nor
executable at mode 0600.

The corrected non-executed candidate is the distinct
`build/proposed-v6-source-build-v2.command` (SHA-256
`8b5e001c2267fc31ed440d173fc30809f46e0bb80c506b93ff126182043aba5c`).
It verifies both Git worktree roots through `git rev-parse`, requires its own
runtime SHA as a second authorization value, and refuses an existing output
root. Before entering the container it copies that exact recipe read-only into
the private build root and records/rechecks its SHA. The Guix container uses
`--no-cwd`, exposes only that writable root and the read-only prerequisite
directory, changes directory to the root, and invokes the frozen copy through
the pinned FHS `/bin/sh`; it does not depend on the repository being visible.
A bounded mock exercised the authorized source-entry gate, existing-root
refusal, and frozen-copy shell handoff. All passed without creating a surviving
build root, writing either source tree, consulting a global Bazel cache, or
running Guix, Bazel, a compiler, or the network.

The v2 recipe archives the clean pinned commit into separate control and
diagnostic trees under `/tmp/opencode`, applies the diagnostic patch only to
the latter snapshot, and uses direct Bazel rather than the Docker-default
Makefile. The complete control `//:release` is built first. Only
`//runsc/cmd/sentry:gvisor_sentry` is then built in the diagnostic tree, using a
separate output base but the same captured Bzlmod lockfile, repository cache,
disk action cache, fixed status command, Guix toolchain, and Bazel install. The
diagnostic six-file artifact is a byte-for-byte copy of the source-built
control with only that source-built Sentry replaced. It must reject any change
in the other five files and any byte-identical control/diagnostic Sentry.

Each Bazel invocation is batch-mode and sequential, with `--jobs=2`,
`--local_cpu_resources=2`, `--local_ram_resources=8192`, a 4 GiB JVM heap,
sandboxed actions, no system or home rc files, no remote cache/executor, and
finite six-hour control/two-hour diagnostic wall limits inside a twelve-hour
outer limit. The two-job and RAM values are Bazel scheduler bounds, not a hard
whole-process cgroup ceiling; GNU `time` therefore records peak RSS for both
builds. No kernel, system image, QEMU, runsc, hardware, network-policy, OCI,
platform, or backend operation is in the command.

At the initial proposal checkpoint, the source-build structure was finite but
its prerequisites were not ready and compilation was not yet authorized:

- `.bazelversion` requires exactly Bazel 8.3.1. Its extracted 8.3.1 install is
  present in an existing cache, but no launcher is in `PATH`; an extracted
  install is not an executable bootstrap. The smallest self-contained proposal
  is the official 64,028,260-byte Linux x86-64 launcher, SHA-256
  `17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c`,
  staged read-only under `/tmp/opencode/wilkbook-gvisor-v6-prereqs/` after
  separate authorization.
- The upstream crosstool calls `/usr/bin/aarch64-linux-gnu-*` and passes
  `-fuse-ld=gold`. The realized Guix GCC 14.3.0/default AArch64 binutils 2.44
  supply the expected compiler tools but no `aarch64-linux-gnu-ld.gold`. The
  pinned Guix catalog can construct cross `binutils-gold` 2.44; the exact dry
  run still lists its source archive and derivation as not realized. The recipe
  proposes that one package in an unprivileged Guix FHS container and stops
  rather than falling back to host packages or changing the crosstool.
- Upstream also documents Python as a direct-build prerequisite. The exact
  pinned `python@3.11` selected by the recipe is not realized either; its
  no-substitute dry run lists Python 3.11.14 source/output derivations. Whether
  an authorized substitute lookup avoids that local compile is not yet known.
- `go.mod` requests the Bazel-managed Go SDK 1.26.3, no
  `MODULE.bazel.lock` is committed, and the shallow local metadata inspected so
  far belongs to other workspace snapshots/older Go SDKs. The first authorized
  control resolution must create the lockfile; the diagnostic build then uses
  the copied lock in error-on-change mode. Existing caches are neither edited
  nor claimed complete.

At that checkpoint, download volume, dependency-resolution time, resulting
build-tree size, and peak memory were unknown. The completed-build measurements
below supersede those unknowns except for exact network bytes, which were not
measured and are not inferred from cache sizes.

#### 2026-09-05 source-build host-tool and completed-build follow-up

The early authorized source-build attempts stopped before compiling gVisor. The
v3 attempt could not start Bazel's bundled JDK because `libz.so.1` was absent.
With pinned `zlib@1.3.1`, v4 analyzed `//:release`, but protobuf's authenticity
action ran under `env -` and Guix Bash's deliberately empty default path; its
bare `grep` and `cat` commands were not found. That output did **not** establish a
protoc-version mismatch. V5 added only
`--action_env=PATH=/bin:/usr/bin`; protobuf validation then passed and the next
real action exposed the undeclared host compiler: the XDP eBPF genrule invokes
bare `clang`.

Pinned source does not specify an exact Clang version. Its direct-Bazel image is
Ubuntu 22.04 and installs unversioned `clang` and `libbpf-dev`. The source has
seven `bpf_program` genrules, all of which run the host execution-platform
command `clang -O2 -Wall -Werror -target bpf -c ...`; their ELF BPF objects are
embedded as data and are not ARM executables. No source build command invokes
`llvm-objcopy`, LLD, `llvm-ar`, `llc`, or `opt`. For the reproducible Guix
environment, `clang@14.0.6` was therefore chosen as a compatibility match for
the Ubuntu 22.04 Clang major—not misrepresented as an upstream exact pin. Its
standard grafted output is
`/gnu/store/asrqw852f0hlaw3hkliqcvlf18l2q63i-clang-14.0.6`. Five of the seven C
inputs directly include `bpf/bpf_helpers.h`, so `libbpf@0.8.1` was selected as
the closest older version offered by the pinned channel, again as a
compatibility choice rather than an upstream pin; its output is
`/gnu/store/2cr8cxdgsngzszl42yaj6i0alsgxdfrz-libbpf-0.8.1`.

A bounded check then built the **actual pinned upstream targets** in the v5
control snapshot, with its captured Bzlmod lock, `--config=aarch64`, production
sandbox/resource flags, and existing private repository/action caches. The
targets were `//tools/xdp/cmd/bpf:tcpdump_ebpf` and protobuf's real prebuilt
authenticity target. The real `linux-sandbox` action found Clang through the
declared path but stopped at:

```text
tools/xdp/cmd/bpf/tcpdump.ebpf.c:17:10: fatal error: 'linux/types.h' file not found
```

The FHS preflight sees `/usr/include/linux/types.h`,
`/usr/include/linux/bpf.h`, and `bpf/bpf_helpers.h`; the env-cleared sandboxed
Clang invocation does not search the first path as currently packaged. The
before/after manifest of every regular control-source file is identical. No BPF
object or protobuf validation output was produced. The exact build log is
`/tmp/opencode/wilkbook-gvisor-v6-source-build-v5/logs/upstream-prereq-smoke.log`
(SHA-256
`de55f01aba475154cf39041fe35f3fa2856287f5d5aff4f642f0a40969ba4e88`).
Scratch standalone WORKSPACE smoke roots are retained but are not evidence for
the pinned graph; their unrelated Bazel-default `rules_cc` bootstrap is why the
real upstream targets replaced them. The accepted host-Clang wrapper adds only
the pinned Linux 6.12.17 UAPI root, libbpf 0.8.1 include root, and a private
`gnu/stubs-32.h`; it is confined to the Bazel action `PATH`. All seven real
`bpf_program` targets subsequently produced `EM_BPF` objects, protobuf's
unchanged authenticity action printed exactly `libprotoc 33.4`, and the regular
source-file manifests remained identical before and after both gates.

Later attempts exposed build-tool packaging rather than source behavior. The
upstream split-architecture Systrap rule needs both
`/usr/bin/aarch64-linux-gnu-*` and `/usr/bin/x86_64-linux-gnu-*`; one pinned Guix
wrapper package supplies both GCC 14.3.0 command names and gives each compiler
only its matching cross-kernel UAPI root. The real
`sighandler_{binary,go}_arch` targets built verified AArch64 and x86-64 objects.
The pinned nogo rules mark `GoStandardLibraryAnalysis` and `GoStaticAnalysis`
`no-sandbox` only to avoid a stated FUSE performance cost. Bazel's
`--modify_execution_info` removes those two keys by exact mnemonic while the
global spawn strategy remains `sandboxed`; non-null real-target execution logs
record `runner: linux-sandbox` for both action classes. No local or standalone
fallback was admitted. Finally, Guix Bash's env-cleared fallback path was given
only pinned `grep`, `cat`, `cp`, `dirname`, and `mkdir`; the exact six-file
`ReleaseFiles` body passed in isolation.

V12 is the completed matched build. Recipe
`build/proposed-v6-source-build-v12.command` has SHA-256
`f20a6fff812ced51afd7bb97b8a797638396a9f39a35a6635bfb91dba6543399`.
The canonical control `//:release` completed 5,245 actions in 30.69 seconds at
3,839,452 KiB peak RSS. With the same tool inputs and copied mode-0444 lockfile
(SHA-256
`8402c7beb4baf2c666f4b78e400ea3f15514b56117598c2cb5411d6a35208d34`),
the diagnostic build targeted only `//runsc/cmd/sentry:gvisor_sentry` and
completed 4,464 actions in 19.12 seconds at 3,170,384 KiB peak RSS. Cache hits
make these elapsed figures warm-build observations, not clean-build estimates.
The final root is 3,212,864,945 bytes; the two artifact trees together are
616,002,664 bytes. Repository/action caches were 5,293,694,244 and
2,347,396,704 bytes when recorded. Exact network bytes were not measured.

The complete releases are preserved at
`/tmp/opencode/wilkbook-gvisor-v6-source-build-v12/artifacts/control` and
`.../artifacts/diagnostic`. Their manifest-file hashes are respectively
`50b5e11b…` and `8be4e642…`; the full result record is
`build/proposed-v6-source-build-v12-result.txt` (SHA-256 `8bbbe310…`). Both
contain exactly six regular, executable, static AArch64 ELFs with no
interpreter. The four version-bearing binaries contain exactly
`release-20260831.0`; the shim and 1,184-byte prewarmer remain intentionally
unversioned. All five Go binaries contain `go1.26.3`. The five non-Sentry files
are byte-identical between variants; control Sentry is `b586873e…`, diagnostic
Sentry is `9e854818…`, and all six control files differ from the upstream
prebuilt release. An independent read-only audit passed at
`/tmp/opencode/wilkbook-gvisor-v6-source-build-v12-independent-audit/`
(`audit.log` SHA-256 `18b05497…`) and found exactly the three reviewed source
files changed.

#### 2026-09-05 matched source control and diagnostic preparation

The matched unpatched source-built control is mandatory and is now prepared for
review without claiming that the local artifacts are a reproducible Guix source
package. `pinenote/packages/gvisor-local-test-artifacts.scm` is separate from the
source-packaging work in `gvisor-source.scm` and `gvisor-dependencies.scm`. It
names each of the six control files explicitly with `local-file`, fixes each
expected file hash in the package definition, and authenticates the preserved
six-line release manifest (`50b5e11b…`), v12 recipe (`f20a6fff…`), and copied
Bzlmod lock (`8402c7be…`) before installation. Its native `readelf` checks the
foreign objects without executing them. The resulting exact six-file output is:

```text
/gnu/store/b9a3sd53w0hka2n78657x8vid68x98ph-gvisor-v12-control-local-test-artifact-20260831.0
```

It has no runtime store references. Independent output inspection rechecked the
manifest, exact regular-file layout, executable modes, AArch64 machine type,
absence of `PT_INTERP` and dynamic dependencies, and passed. Four failed wrapper
attempts remain preserved rather than overwritten: incomplete Guile module
closure (v1), `cmp` assigned to the wrong package (v2), cross rather than native
`cmp` selected (v3), and an incorrect assumption that single-file `local-file`
transport retained the source executable bit (v4). V5 passed; none executed an
ARM binary. At this control-preparation gate the diagnostic wrapper declaration
existed separately but had not been lowered, built, or selected.

`pinenote/systems/pinenote-book-execution-source-control.scm` inherits the
accepted v5 OS and changes exactly one package-list position plus the matching
`/etc/wilkbook-execution-spike/build-manifest` value. This replacement is
necessary: merely shadowing `runsc` would leave the old manifest's prebuilt
store reference in the closure. The realized system has one control-package
reference and zero references to either the frozen prebuilt release or the
diagnostic package. Kernel Image/config/DTB, initrd, boot parameters, language
profile, supervisor profile, OCI source, smoke workload, and guest diagnostics
are unchanged. The regenerated language closure still has exactly 45 paths; its
structural validator again passed the exact Systrap, `directfs=false`,
`network=none`, cgroup, strict-sidecar, strict-release, and fixed diagnostic
flags. The kernel was reused, not rebuilt.

The realized outputs are:

```text
system: /gnu/store/fj6nklg1cxzc2j9gbx790wpsnv41imxi-system
image:  /gnu/store/k74iqqs52fq6qkmv2jcilh00xl441ih8-disk-image
image SHA-256: 04649db97f8a8c9973b7be6127d82c7332f9dacd8df71969349e9984e02ab770
```

They were copied through the existing non-mounting stage tool into the new
immutable baseline at
`build/artifacts/pinenote-book-execution-source-control-20260905-v1/`.
Its manifest is `1b806390…`; `baseline.raw` is `192754f6…`. The inspector and a
read-only extracted-partition `e2fsck -fn` both pass with root label
`PNGuixRoot`. The staged kernel, config, DTB, and initrd hashes are identical to
v5. The extlinux file differs only in the required new canonical `gnu.system`
and matching `gnu.load=SYSTEM/boot` paths.

The control launcher
`build/first-source-control-after-review.command`, SHA-256 `86b7136f…`, was
subsequently run under separate authorization. The complete source-built
control reproduced the required failure before either payload passed: runsc
status 128, `panic: failed to create a syscall thread`, and
`pkg/sentry/platform/systrap/subprocess.go:219`. The guest emitted
`BOOKEXEC-SMOKE-FAIL`, the outer checker rejected that forbidden marker, the
launcher recorded `RUN-STATUS=1 CHECKER-STATUS=1`, and shutdown reached clean
power-down at kernel time 15.991751. Thus the control is matched, but runtime
success is **false**; no success gate was synthesized. The complete read-only
console/runner transcript is
`build/source-control-runtime-evidence-20260905/console-and-runner.log`
(SHA-256 `2e749e1f…`), its wrapper record is `01fccec3…`, and the evidence
manifest is `b2e41222…`. The post-run classifier still reports
`CONTROL-RUNTIME-SUCCESS=false`. The operator reports parent verification of
the same reproduction; separate independent reviewer confirmation remains
assigned.

After that reproduction, diagnostic **image preparation only** was authorized.
The existing v12 diagnostic local-artifact wrapper was lowered and realized as:

```text
package: /gnu/store/rjki4xg2algxlsb4rkfg0pkzfp5fzk40-gvisor-v12-diagnostic-local-test-artifact-20260831.0
system:  /gnu/store/46rqh3ga3bh680kc870mq9271lk8x19d-system
image:   /gnu/store/awfhjccvxi29bn1qs8ws80s6cw46pn8p-disk-image
image SHA-256: 85a0e2aaf1144e6bb30d0a717171ac73527dc7bd22681c18d1525a1497468531
```

The package has exactly the six static AArch64 release files and zero runtime
store references. Its five non-Sentry files are byte-identical to control;
only `gvisor-bin/gvisor_sentry` changes from `b586873e…` to `9e854818…`.
Inspection finds the seven reviewed context strings for backing truncate/map,
top-level task size, syscall-message allocation/Sentry map, and read-only and
read-write stub maps. Those messages report the actual failing stage with the
applicable address, length, offset, task size, and wrapped errno; no additional
instrumentation generation was introduced. The patch remains exactly
`9193de57…` and the independent source-tree audit still limits its delta to
`pgalloc.go`, `subprocess.go`, and `syscall_thread.go`.

`pinenote/systems/pinenote-book-execution-diagnostic.scm` inherits the complete
control system and replaces its six-file package plus corresponding provenance
manifest. Static and realized checks show no runtime-configuration delta:
kernel Image/config/DTB, initrd, boot parameters, language and supervisor
profiles, 45-path closure, OCI configs, workload, and guest/outer diagnostics
remain unchanged. Both variants retain Systrap, `isolation-userns`,
`--directfs=false`, `--network=none`, `--ignore-cgroups=false`,
`--sidecar-usage-policy=strict`, and
`--sidecar-release-enforcement-policy=always`; neither uses an enforcement skip,
embedded fallback, or prebuilt helper. The 329-path system closure contains one
diagnostic package and no control/prebuilt package, Bazel, compiler, source
inventory, lockfile, or source-build input. The accepted USER_NS kernel and
initrd were reused without rebuilding.

The image is staged separately and immutably at
`build/artifacts/pinenote-book-execution-diagnostic-20260905-v1/`; its manifest
is `3351b8df…` and baseline is `91e969a2…`. One non-mounting inspection and one
read-only extracted-partition `e2fsck -fn` passed with root label `PNGuixRoot`.
Against control, staged boot files are identical except extlinux's canonical
`gnu.system` and matching `gnu.load=SYSTEM/boot` paths. Fresh OCI fixture trees
are byte-identical after normalizing only their private bundle-root paths.

The diagnostic launcher
`build/first-diagnostic-after-review.command`, SHA-256 `d5cbc8b3…`, mode 0600,
was subsequently run under separate authorization. It retained the same outer
runner, TCG, `-cpu max`, `-nic none`, console/stderr bounds, 600-second timeout,
and status handling. The matched diagnostic reached the first syscall-thread
allocation and reported:

```text
task-size=0x10000000000000:
allocate syscall-thread message length=0x2000:
truncate MemoryFile backing old-size=0x0 new-size=0x40000000:
truncate systrap-memory: file too large
```

Runsc returned 128 before either payload. The guest emitted
`BOOKEXEC-SMOKE-FAIL`, the outer checker rejected it, the launcher retained
`RUN-STATUS=1 CHECKER-STATUS=1`, and the kernel powered down cleanly at
15.924763 seconds. This is **not guest success**. The complete read-only record
is `build/diagnostic-runtime-evidence-20260905-v1/console-and-runner.log`,
SHA-256 `9ac39e29…`; corrected evidence manifest `manifest-v2.txt` is
`b8ca95af…`. Independent review accepted the exact Linux/gVisor causal chain in
`doc/reviews/2026-09-05-gvisor-matched-source-artifacts-adversarial.md`
(current review SHA-256 begins `91985cd5…`).

The concrete in-tree candidate is an accidental limit-domain collision.
`guest-smoke.scm` set a 4 MiB process-wide `RLIMIT_FSIZE` immediately before
`exec` of runsc. That limit is inherited by Sentry and applies to every regular
file it opens, not only redirected stdout/stderr, while the diagnostic shows
Sentry's first `MemoryFile` extension requesting a 1 GiB sparse backing file.
The focused correction removes only that supervisor-side process limit. Child
stdout and stderr now go through separate parent-owned pipes; the Guile
supervisor drains both concurrently, retains at most 4 MiB per stream, discards
excess while counting all observed bytes, and emits an explicit
`BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW` record. Overflow remains a failed run and
cannot become a payload PASS. Process deadlines, TERM/KILL group cleanup,
bounded final pipe drain, exact payload comparison, bounded debug-file
head/tail emission, and outer reporting remain in place.

That first correction was incomplete: direct runsc debug and panic files still
had no during-run storage bound, and an independent host child retained a
4,206,649-byte debug file while stdout/stderr overflow both remained false. The
follow-up keeps the accepted stdout/stderr pipes and places runsc's direct files
on two separate Guile-managed, root-owned mode-0700 tmpfs stores mounted before
the runtime starts. Debug retains its per-command run/boot/gofer files inside a
hard 4 MiB/10-file store. Panic moved only from `runsc-debug/` to
`runsc-panic/`, a distinct hard 1 MiB/2-file store, so a debug flood cannot
consume late-panic capacity. Both mounts are `nosuid,nodev,noexec`, are absent
from the OCI mount table/payload root, and are verified against their exact
tmpfs source, mount flags, byte quota, and inode quota.

After runsc and its owned writers have exited, Guile counts all entries and
regular-file logical/allocated bytes while the stores are still mounted. A
full byte/inode budget, oversized logical file, or non-regular entry emits
`BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW`, retains bounded head/tail evidence, and
fails before payload comparison. Unmount is reverse-order and non-lazy, so an
open writer makes cleanup fail rather than silently detach; original empty
mountpoint identities are then checked and removed. Payload PASS is emitted
only after both unmounts complete. The selected diagnostic count remains
exactly 16 channels: four fixed files plus ten debug and two panic files, so the
accepted outer console bound is unchanged.

This does not alter the OCI payload's separate 1 MiB `RLIMIT_FSIZE`. Focused
host regressions prove that a supervised child can sparsely truncate an 8 MiB
`systrap-memory` file without inheriting the old 4 MiB limit, a 4 MiB+ output is
fully drained but stored at exactly 4 MiB and reported as overflow, integrated
bundle overflow cannot emit its PASS marker, and a TERM-resistant timed-out
child is killed and reaped. These are host-only supervision tests; Python is
the child/oracle, not trusted runtime implementation. A private unprivileged
user+mount+PID+network namespace test additionally exercised the real tmpfs
quotas: one direct file and a multi-file aggregate both hit `ENOSPC` without
exceeding the physical cap, the actual inode cap rejected another file, a late
panic remained available after debug exhaustion, normal stores unmounted before
PASS, and a TERM-resistant direct writer was killed/reaped before both mounts
were removed. No corrected guest image has been prepared and no follow-up QEMU,
kernel, gVisor, hardware, SSH, UART, or deployment operation is authorized or
claimed.

Do not replay the existing reader QEMU commands as an adversarial execution
envelope. Their omitted network option lets QEMU create its default user-mode
network, their supplied disk is writable/reusable, and their root console
socket is not created inside a private run directory.

The replacement outer runner requires canonical, non-writable, non-aliased
boot files plus a dedicated non-writable raw baseline and its expected SHA-256.
It makes a private reflink or sparse copy, checks the private bytes, and gives
`qemu-img` only that copy as explicit raw backing for a private qcow2 overlay.
QEMU receives only SHA-verified private kernel/initrd/config/baseline copies and
the private overlay, plus `-no-user-config`,
`-nodefaults`, `-accel tcg,thread=multi`, and `-nic none`; its one root console
socket and all logs stay beneath the mode-0700 run directory. QEMU gets a
constructed environment with no caller credentials. The foreground Guile
owner starts a new process group, applies the wall-clock cap itself, and uses
bounded TERM then KILL, waits, and removes the run directory on its handled
paths. Nine fake-QEMU tests prove cleanup for normal valid-marker exit, a clean
parent exit that leaves a resistant descendant, preparation failure, timeout,
an external TERM while a descendant ignores TERM, and zero QEMU exits with a
missing or forbidden guest marker. They also pass a deliberate descriptor 199
and `SIGCHLD=SIG_IGN` into the Guile owner, then prove the descriptor is absent
from both fake execs and both direct children remain waitable/reaped. The first
independent review killed the owner with uncatchable `SIGKILL` and found its
QEMU group and run tree survived. The focused recheck accepted the added
process/run-root guardians at `disposable-qemu.scm` SHA-256 `25812ffd…` and
fail-closed cgroup probe removal at `oci-bundle.scm` SHA-256 `0cbbdb0d…`.
Those mechanisms remain. The outer runner used for v5 has SHA-256 `0fe3668f…`;
the unchanged accepted guest smoke has SHA-256 `41b010ea…`.

The caller's baseline must be a fresh execution-spike artifact, not a current
reader/release disk or one another test is using. It is never attached to QEMU,
but it must still not mutate during the initial private-copy operation. The v5
failure run tested these arguments once. After QEMU has exited and been
reaped, the current runner consumes `console.log` through the same bounded Guile
assertion module used by the executable checker, before the guarded run root is
removed. QEMU status zero with missing/bad markers is therefore a failure; only
an exact successful parse reports
`OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS`.
Parser failure still traverses unconditional process/run-root cleanup. V5
confirmed failure-path export and rejection with a real guest. The separately
approved corrected-CONTROL run later confirmed this exact success path with a
real guest; because success does not trigger console export, its retained
record is the two-line accepted summary described above.
The exact safe test and future invocation commands are in the tool README.
Without reflink support, preparation may consume up to the baseline's allocated
data plus qcow2 growth and must read the baseline's full logical size for its
hash; no host disk quota is claimed.

The package output check that passed was:

```sh
out=$(guix time-machine -C channels.scm -- \
  build --no-grafts --cores=2 --max-jobs=1 -L . \
  --target=aarch64-linux-gnu \
  -e '(@ (pinenote packages gvisor) gvisor-bin)')

guix shell binutils zstd -- \
  pinenote/tools/book-execution-spike/check-gvisor-package.sh \
  --output "$out"
```

This checks all six files, not only `runsc` and the shim. The later v3 guest
executed `runsc --version` and required `release-20260831.0` in its output;
that is stronger than finding the marker with native `strings`, but it is not a
Sentry or sidecar execution result.

## 7. Narrow OCI bundle contract

`oci-bundle.scm` now generates OCI JSON and the launcher from trusted, fixed
inputs; it does not accept arbitrary mounts, hooks, annotations, namespaces,
environment, or runtime flags from a book. `generate_oci_bundle.py` is retained
only as an independently implemented test oracle. The Guile generator validates:

- a normal profile symlink chain that resolves to one real top-level Guix store
  directory with a regular profile manifest; its caller-selected store name is
  not an authority check;
- the exact output of `guix gc --requisites` for that resolved profile, with
  every path existing, canonical, unique, and naming one top-level store
  object, including the selected profile and the store objects owning its
  executable `bin/python3` and `bin/guile` targets;
- a selected canonical regular file under a separate immutable store object;
- a new canonical bundle destination and constrained container ID; and
- a mandatory `functional-directfs` or `isolation-userns` profile name.

It emits:

- a read-only root;
- exactly the Guile/guile-json/Python profile's enumerated transitive store
  objects,
  individually mounted read-only at their original `/gnu/store/...` paths;
- one selected read-only/nosuid/nodev/noexec input file;
- a private noexec scratch tmpfs with a declared 16 MiB size;
- `proc` and the minimum synthetic `/dev`, but no host devices;
- numeric non-root process credentials, an empty capability set, and
  `noNewPrivileges`;
- no `/data`, host root, broad `/gnu/store`, framebuffer/input devices,
  `/dev/kvm`, Guix daemon socket, credentials, or `runsc` state/control path;
- a sanitized payload environment and fixed working directory; and
- one explicit run-owned OCI `cgroupsPath`;
- a `launch.json` audit record plus a one-shot shell/Guile launcher that checks
  root and cgroup2, then runs `runsc` through a constructed environment with
  only fixed values and a private `TMPDIR`.

The explicit DirectFS profile is exactly and visibly functional-only:

```text
env -i HOME=/nonexistent LANG=C LC_ALL=C \
  PATH=/run/current-system/profile/bin TMPDIR=BUNDLE/supervisor-tmp \
  /run/current-system/profile/bin/runsc \
  --root=BUNDLE/runsc-state \
  --debug=true \
  --debug-log-format=text \
  --alsologtostderr=true \
  --debug-log=BUNDLE/runsc-debug/ \
  --panic-log=BUNDLE/runsc-debug/runsc.panic.%COMMAND%.log \
  --platform=systrap \
  --network=none \
  --sidecar-usage-policy=strict \
  --sidecar-release-enforcement-policy=always \
  --ignore-cgroups=false \
  --host-uds=none \
  --host-fifo=none \
  --character-device-policy=emulated-only \
  --allow-suid=false \
  --allow-flag-override=false \
  --allow-rootfs-tar-annotation=false \
  --overlay2=none \
  --rootless=false \
  --file-access=exclusive \
  --file-access-mounts=exclusive \
  --net-raw=false \
  --allow-packet-socket-write=false \
  --directfs=true \
  run --bundle=BUNDLE wilkbook-python-smoke
```

The `isolation-userns` profile changes only the evidence label and explicit
flag to `--directfs=false`; both profiles record `CONFIG_USER_NS=y`, and neither
runs on the shipping/current artifact. There is no implicit selection or
fallback. Prefer `isolation-userns` for the first compatibility smoke. Both
profiles exclude `GVISOR_ENFORCE_RELEASE=SKIP` by constructing the supervisor
environment from scratch. The fixed Python program is only a future
interpreter/mount/no-network smoke: it reads `/book/input`, writes its byte
count under `/scratch`, and requires one external IPv4 connection attempt to
fail. For this fixture only, Python and Guile emit distinct exact stdout
sentinels containing the byte count they computed inside their respective
languages. The trusted guest supervisor captures and compares each whole output
before emitting that language's serial PASS marker; exit zero with empty,
cross-language, wrong-count, or duplicate output fails. No wrapper prints the
claim. These diagnostics are not the Book Protocol: the separately designed
broker will use a private inherited FD, not stdout or a host filesystem socket,
and that integration is not implemented here.

Host tests assert the exact mounts, process settings, profile labels, security
flags, and sanitized environment, and exercise invalid path/object cases. They
do not establish runtime behavior. In particular, strict mode still needs an
in-guest positive observation that the adjacent packaged helpers were selected
and a negative fixture where missing adjacent `gvisor-bin/` fails rather than
starting an embedded helper.

A historical host-only replay used the real `guix gc --requisites` output for
the workstation profile and generated 844 separate closure mounts. It is only
evidence that broad host output parsed and is not an approved guest fixture or
execution result. The executable fake-store gate compares parsed `config.json`,
`launch.json`, layout, modes, rejection behavior, fixed flags, both USER_NS
records, custom-name profile validation, and C0/supplementary-Unicode JSON
escaping against the independent Python oracle. The v4 preparation additionally
replayed the exact retained narrow AArch64 profile, its 45-path guest manifest,
and the immutable book through both Python and Guile bundle construction and
validated the generated outputs as recorded above. No target `runsc` or payload
was executed during that offline replay.

At the v5 scaffold checkpoint, no bounded **Book Protocol** output/import path
existed; v5's bounded escaped
failure diagnostics are a fixed test channel, not that protocol. The declared
scratch mount and configured payload rlimits were present in the successful
ARM64 compatibility run, but their ceilings have not been exercised by a
pressure/limit-kill test. The system declares cgroup2, the OCI
object names `/wilkbook-execution-<id>`, and the Guile launcher refuses a
missing hierarchy, a stale target, or inability to create/remove a child before
`runsc --ignore-cgroups=false`. The generator intentionally emits no OCI
`linux.resources`; this establishes launch plumbing and expected whole-domain
membership, not CPU, memory, PID, Book-output, or wall-time budgets. OCI
payload rlimits do not cover every support process, and in-container PID counts
must not be reported as host cgroup PID accounting.

Once a runtime harness exists, forced cleanup must target every process in the
domain and remove its state:

```sh
runsc --root="$state" kill --all "$id" KILL
runsc --root="$state" delete --force "$id"
```

The harness must verify the container is absent from `runsc list`, support
processes are gone, and a deliberately persistent descendant cannot produce a
post-kill sentinel. Killing only the initial interpreter is not sufficient.
The state-matched listing command is:

```sh
test -z "$(runsc --root="$state" list --quiet)"
```

## 8. Stop-on-failure gate order

Stop at the first red gate:

1. **Package integrity:** release checksum matches; exact archive layout is
   known; the package's canonical member list exactly equals the external
   manifest; all sidecars and both executables are installed together;
   binaries are AArch64. The first guest must report the pinned
   `runsc --version`, use adjacent helpers under strict mode, and fail the
   missing-helper negative test.
2. **Bundle generation:** exact trusted profile requisites and selected input
   produce the expected read-only/narrow OCI mounts, non-root payload, empty
   capabilities, sanitized supervisor environment, mandatory named runtime
   profile, and no fallback launch vector.
3. **System evaluation:** static pinned evaluation selects the non-shipping
   USER_NS test kernel, cgroup2, exact language profile, and Python-free trusted
   supervisor profile; no shipping flavor changed. The build was explicitly
   authorized and its final config passed the one-symbol allowlist before image
   construction.
4. **Outer QEMU envelope:** fake-command tests prove exact `-nic none`, TCG,
   private console/environment/copies, raw-backed qcow2 overlay, timeout, and
   TERM-resistant process-group cleanup. The focused recheck independently
   accepted the owner-`SIGKILL` guardians and fail-closed cgroup-probe removal at
   the earlier hashes. The later bounded failure diagnostic was separately
   accepted and captured the v2 console before cleanup. Fake tests prove the
   post-exit marker parser accepts the exact sequence and makes
   missing/forbidden markers fail while cleanup still runs.
5. **Disposable QEMU boot:** v2 established the exact kernel identity, root
   mount, Shepherd startup, no non-loopback interface/default route, and no
   serial login under TCG. V3 added forbidden-mount PASS, ARM64
   `runsc --version`, and clean shutdown, then found a profile-name fixture bug
   before Sentry startup. V4 validated the corrected profile and reached the
   strict-sidecar sandbox child, which exited before its startup notification.
   V5 proved that the selected Sentry reached Go and Systrap initialization,
   then retained its pre-notification panic. Payload and cgroup teardown
   assertions remain required for success.
6. **Named Systrap profile:** start with `isolation-userns`; state whether any
   run is that compatibility candidate or functional/DirectFS. Explicit
   `--platform=systrap`, `--network=none`, and the selected `--directfs` value
   start or fail closed. There is no native, ptrace, namespace-only, test-flag,
   host-network, or alternate-profile retry branch.
7. **Same environment/protocol:** Guile and Python both answer a non-trivial
   request from the same profile through the same bounded framing.
8. **Positive access:** declared input is readable, private scratch/output is
   writable, and the host can import the expected bounded result.
9. **Negative access:** host-only canary, unrelated store path, `/data`, Guix
   daemon socket, display/input devices, and external network are unreachable;
   input and program closure reject writes.
10. **Resource behavior:** first verify the declared cgroup2 hierarchy,
    explicit path, and whole-domain membership. Later nonzero task, memory, CPU,
    diagnostic-output, and disk limits must terminate or reject their fixtures
    predictably. Do not mask a failure with `--ignore-cgroups=true`.
11. **Lifecycle:** cancellation and `kill --all` prevent descendants from
   surviving, cleanup removes runtime state, and a new domain receives no old
   scratch, handles, or process state.
12. **Real compatibility:** selected Guile and Python libraries used by the
     first book workload run. `/bin/true` and `print(1)` alone do not pass this
     gate.

Only after these functional gates should timing be collected. QEMU numbers may
compare regressions in the same TCG setup but must be labeled simulation
numbers. Cold start, warm-sandbox `runsc exec`, warm-interpreter response,
whole-domain memory, idle wakeups/power, suspend, and KVM are separate later
measurements; PineNote power/performance claims require the device.

## 9. Historical v5 blockers and still-open qualifications

This list captures the v5 checkpoint and is retained to preserve the actual
failure investigation. The later `RLIMIT_FSIZE` correction closed the fixed
payload compatibility failure, and later fixtures accepted fixed Book Session
FD donation, runsc/cgroup cleanup, private UI carriage, and real KOReader
offscreen presentation. Statements below that no language payload ran are
historical, not current. Still open are the general hostile-book, resource,
missing-sidecar, durable-state, shipping, and physical-device qualifications.

1. The dedicated PineNote USER_NS kernel is built and booted under QEMU TCG. Its
   exact current-base versus variant installed-config diff is only
   `CONFIG_USER_NS: n -> y`; no shipping kernel source or forward-port patch
   changed. The v2 root mounted and reached the first guest assertions; v3
   passed mount policy, executed the pinned ARM64 runtime's version command, and
   powered down cleanly. V4 additionally validated the profile and reached the
   sandbox startup synchronization wait, then got EOF before the child ready
   byte. The unchanged v5 system/image and private immutable `PNGuixRoot`
   baseline then ran once after review and retained the Sentry's
   `initSyscallThread` panic. All earlier baselines remain preserved, and the
   cached generic shortcut was not selected.
2. The narrow Guile OCI generator and Guile disposable-QEMU outer supervisor
   are host-tested and require fixed boot hashes. The automatic guest fixture
   now validates exact computed Python/Guile outputs, has no serial `agetty`, and
   feeds its bounded serial-marker parser through the runner before private
   cleanup. V3 QEMU confirmed the corrected mount parser and supervised
   shutdown, then rejected the legal custom-named profile before bundle
   construction. V4 confirmed the profile correction in QEMU and exposed the
   pre-ready child EOF. V5 retained the complete panic, full bounded outer
   console, and clean failure shutdown; another run is not authorized. Production
   cgroup ceilings, bounded Book Protocol output import, and private-FD
   integration were later work at this checkpoint. The fixed private-FD path
   subsequently passed; general output import and enforceable ceilings remain
   open.
3. ARM64 `runsc --version` has run under QEMU and matched the pinned release.
   V5 establishes strict sidecar resolution, Gofer startup, the prewarmer/Sentry
   child spawn, Sentry Go startup, and entry into Systrap platform creation. V5
   did not establish the Sentry ready notification, and no Guile or Python
   payload had run in that image. The later corrected CONTROL and fixed Book
   Session runs close that historical payload fact; the missing-sidecar strict
   failure remains untested.
4. `isolation-userns` is the preferred first compatibility candidate, but its
   name does not grant isolation acceptance. Both it and `functional-directfs`
   need the separately reviewed USER_NS test kernel; no shipping change is
   approved, and DirectFS still cannot count as isolation.
5. Guest cgroup mounting/writability now has declared/preflight plumbing, but
   runtime membership, controller state, teardown, and enforceable whole-domain
   budgets need explicit tests.
6. ARM64 Systrap compatibility and idle issue #13361 remain measurement
   questions; merged fixes are not PineNote evidence.
7. Official prebuilt binaries are the shortest path to an execution result,
   but source-build reproducibility and release authenticity remain separate
   supply-chain decisions.

## References

- [gVisor installation and complete release layout][gvisor-install]
- [gVisor platforms (including Systrap)][gvisor-platforms]
- [Direct OCI execution][gvisor-oci]
- [Rootless operation][gvisor-rootless]
- [ARM64 syscall compatibility][gvisor-arm64]
- [ARM64 Systrap idle report][gvisor-idle]
- [Candidate release][gvisor-release]
- [2026-09-04 adversarial execution/package review](reviews/2026-09-04-book-execution-adversarial.md)
- [2026-09-04 Guile runtime/runner review](reviews/2026-09-04-book-execution-guile-adversarial.md)

[gvisor-install]: https://gvisor.dev/docs/user_guide/install/
[gvisor-platforms]: https://gvisor.dev/docs/architecture_guide/platforms/
[gvisor-oci]: https://gvisor.dev/docs/user_guide/quick_start/oci/
[gvisor-rootless]: https://gvisor.dev/docs/user_guide/rootless/
[gvisor-arm64]: https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/
[gvisor-idle]: https://github.com/google/gvisor/issues/13361
[gvisor-release]: https://github.com/google/gvisor/releases/tag/release-20260831.0
