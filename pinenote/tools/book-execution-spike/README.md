# Book-execution spike host tools

These are host-testable preparation tools for the non-shipping execution
spike. Trusted bundle generation, launch policy, and outer-QEMU supervision are
Guile. Python is used only as the sandbox payload and as an independent host
test/reference oracle. The cheap tests inspect ARM64 files but never execute
them: they do not invoke `runsc`, start the real QEMU, contact a PineNote, or
build a kernel, system closure, rootfs, or image. Disposable-runner tests
execute only tiny fake `qemu-system-aarch64` and `qemu-img` fixtures.

Run the complete cheap gate:

```sh
pinenote/tools/book-execution-spike/run-tests.sh
```

It covers the Guile OCI generator against the retained Python oracle, Guile
JSON escaping, the Guile disposable-QEMU outer boundary, package/member
mutation tests, supervisor-owned bounded capture and child cleanup, static
package pins, and static system/profile/cgroup wiring.
The package mutation suite removes and adds every release member in turn and
replaces the sidecar directory with a symlink; every mutation must be rejected.

Process style was checked against the repository-pinned Guix commit
`f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c` and GNU Shepherd 1.0.9:
`(guix build utils)` uses command argument vectors plus explicit `waitpid`,
`(guix scripts environment)` constructs pure environments and maps signal exits
to `128+signal`, and Shepherd's `(shepherd service)` / `(shepherd system)` reset
child signal handlers, mark unrelated descriptors `FD_CLOEXEC`, create a new
process domain, reap children, and terminate whole groups TERM-then-KILL. The
small synchronous spike code follows those applicable conventions directly;
it does not import Shepherd or Fibers and this style correspondence is not a
security proof.

## Narrow OCI bundle generator

`generate-oci-bundle.scm` loads the trusted implementation in `oci-bundle.scm`
and takes trusted operator/system inputs, not fields from a book manifest.
`generate_oci_bundle.py` is retained only as the independently implemented
host-test oracle used to compare parsed policy; it is not runtime-core code.
Inputs are:

- one Guix profile (the ordinary profile symlink chain is allowed);
- the exact transitive closure printed by `guix gc --requisites PROFILE`;
- one canonical regular-file fixture in a separate immutable store item;
- a new canonical bundle path and constrained container ID; and
- a mandatory execution-profile name.

Every requisite must be an existing, non-symlink, top-level Guix store object.
The trusted profile must resolve to one real top-level store directory and
occur in that closure; Guix permits its output name to be caller-selected. The
generator requires a regular profile `manifest`, and executable `bin/python3`
and `bin/guile` targets whose store items belong to the enumerated closure. The
fixture must be a canonical regular file beneath a different store item.
Relative paths, `..`, `//`, missing objects, nested requisite paths, duplicate
requisites, unexpected object types, arbitrary book symlinks, the whole
`/gnu/store`, and pre-existing bundle destinations fail closed. The generator
mounts each closure item separately at its original path; it never mounts the
broad store.

The resulting OCI policy has a read-only root, a read-only/nosuid/nodev
language closure, one read-only/nosuid/nodev/noexec input file, a 16 MiB
noexec tmpfs at `/scratch`, and a minimal tmpfs `/dev`. It exposes no `/data`,
`/dev/kvm`, Guix socket, host runtime directory, filesystem control socket, or
unrelated store item. The fixed Python compatibility smoke reads `/book/input`,
writes only a byte count under `/scratch`, and requires an external IPv4
connection attempt to fail. For this fixed fixture it emits one exact captured
diagnostic sentinel containing that computed count; the guest supervisor checks
the complete output. It is not a protocol adapter or general stdout result
channel. A future broker transport uses a separately reviewed private inherited
descriptor.

### Mandatory runtime profile

There is deliberately no default execution profile:

- `--execution-profile functional-directfs` emits explicit
  `--directfs=true` and records `CONFIG_USER_NS=y`. Any future result is
  **functional/DirectFS only, not isolation acceptance**. Rootful
  DirectFS gives the host-side Sentry elevated filesystem privilege; the
  numeric non-root payload, empty payload capabilities, and
  `noNewPrivileges` do not make the Sentry or Gofer least-privileged.
- `--execution-profile isolation-userns` emits explicit `--directfs=false`
  and records the same `CONFIG_USER_NS=y` prerequisite. Prefer this as the
  first compatibility candidate now that both choices need the same kernel
  facility; its name is retained as tested ABI, not as an acceptance claim.

The current PineNote kernel has user namespaces disabled, so neither profile
runs there. Pinned gVisor adds a user namespace for DirectFS when networking is
not host mode; its non-DirectFS support-process branch also creates one. The
system scaffold therefore selects a separate non-shipping, one-option test
kernel variant. There is no networking relaxation, test-only gVisor flag, or
runtime-profile fallback, and no shipping-kernel change.

Both profiles pin the same release-specific runtime choices:

```text
--platform=systrap
--network=none
--sidecar-usage-policy=strict
--sidecar-release-enforcement-policy=always
--ignore-cgroups=false
--host-uds=none
--host-fifo=none
--character-device-policy=emulated-only
--allow-suid=false
--allow-flag-override=false
--allow-rootfs-tar-annotation=false
--overlay2=none
--rootless=false
--file-access=exclusive
--file-access-mounts=exclusive
--net-raw=false
--allow-packet-socket-write=false
```

The v5 startup-rootcause fixture additionally supplies fixed trusted diagnostics
only; these values cannot come from book data:

```text
--debug=true
--debug-log-format=text
--alsologtostderr=true
--debug-log=BUNDLE/runsc-debug/
--panic-log=BUNDLE/runsc-panic/runsc.panic.%COMMAND%.log
```

The root-owned mode-0700 `runsc-debug` and `runsc-panic` mountpoints are empty
when generated. Immediately before each run, the Guile supervisor mounts a
private `nosuid,nodev,noexec` tmpfs on each: debug gets 4 MiB and ten file
inodes, while panic independently gets 1 MiB and two file inodes. The split is
intentional. Pinned runsc rejects its internal `--debug-log-fd` and
`--panic-log-fd` flags on the public `run` command, while a shared FIFO would
merge concurrent per-command writers. Separate finite stores preserve runsc's
normal run/boot/gofer files and reserve late-panic capacity even if debug output
fills its store. Neither directory is present in the OCI mount table or payload
root.

After the process group is reaped, the supervisor verifies the exact tmpfs
source, flags, byte quota, and inode quota, then counts every entry plus regular
file logical and allocated bytes. A full byte or inode budget, an oversized
logical file, or a non-regular entry emits
`BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW` and fails before any payload PASS. On a
nonzero `runsc run`, the guest reports status/cgroup/state metadata and escaped
bounded head/tail ranges for stdout, support stderr, at most ten debug plus two
panic files, and the kernel log. Every source newline is escaped and every
rendered data line is prefixed, so diagnostic content cannot synthesize an
exact success marker. Both stores are unmounted in reverse order and their
identity-checked empty mountpoints removed before a success marker. Missing or
malformed diagnostics and cleanup failures remain explicit failures. This
instrumentation does not select a different platform, DirectFS, network,
cgroup, sidecar policy, or fallback.

The guest supervisor captures runsc stdout and stderr through two parent-owned
pipes. It concurrently drains both streams, stores no more than 4 MiB from each,
continues draining and counting discarded excess so the child cannot deadlock,
and reports overflow with
`BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW`. Overflow is a failed fixture result, not
a truncation that can pass exact payload comparison. This limit is deliberately
not `RLIMIT_FSIZE`: a process-wide limit would be inherited by runsc/Sentry and
would constrain unrelated runtime backing files. The generated OCI payload
retains its separate 1 MiB `RLIMIT_FSIZE`.

The generated `run.sh` starts the generated Guile launcher through `env -i`.
That launcher refuses a non-root supervisor, verifies a cgroup2 hierarchy at
`/sys/fs/cgroup`, proves it can create and remove a child, refuses a stale
explicit `cgroupsPath`, constructs the final environment, and `exec`s `runsc`.
Failure to remove the child on the normal preflight path is fatal and prevents
`runsc` from being executed; cleanup after another preflight error is best
effort and preserves the original exception.
Only fixed `HOME`, locale, `PATH`, and a private `TMPDIR` reach the runtime. In
particular it cannot inherit `GVISOR_ENFORCE_RELEASE=SKIP`, which would bypass
the pinned sidecar-release check. `launch.json` records the root UID, exact
argument vector, cgroup path, sanitized environment, profile name, evidence
classification, and kernel prerequisite. There is no ptrace, KVM, native,
embedded-sidecar, networking, test-flag, or profile-selection fallback.

### Narrow generation replay

Do not use the workstation profile for this replay: its closure expands to 844
store mounts. Once the dedicated system/profile is realized, generate from its
exact retained language profile and stage the bundle at its final guest path:

```sh
set -eu
umask 077
profile=/gnu/store/...-wilkbook-book-execution-languages
book=/gnu/store/rpvzi1xj70l5gg14xd5y2izaf02w1gkm-wilkbook-book-execution-smoke.txt
run=$(mktemp -d /tmp/opencode/wilkbook-execution-spike.XXXXXX)
chmod 0700 "$run"

guix time-machine -C channels.scm -- \
  shell guile@3.0.9 guile-json@4.7.3 -- \
  pinenote/tools/book-execution-spike/generate-oci-bundle.scm \
    --profile "$profile" \
    --book "$book" \
    --bundle "$run/bundle" \
    --container-id wilkbook-python-smoke \
    --execution-profile isolation-userns

python3 -m json.tool "$run/bundle/config.json" >/dev/null
python3 -m json.tool "$run/bundle/launch.json"
```

The placeholder profile output does not exist yet; the unbuilt system scaffold
will retain it. The completed host gate instead generates from
a four-item fake-store closure and compares parsed Guile `config.json` and
`launch.json` against the Python oracle. The historical 844-mount workstation
replay remains parser evidence only and is not an approved fixture or promise.

Do **not** execute the generated `run.sh` merely because generation and JSON
inspection pass. No ARM64 runtime assertion has run yet.

## Disposable QEMU outer runner

`run-disposable-qemu.scm` loads the trusted Guile supervisor in
`disposable-qemu.scm`. `run_disposable_qemu.py` remains test/reference material
and is never called by the aggregate. The Guile runner requires trusted inputs:

1. a canonical boot-bundle directory containing fixed, non-symlink, non-
   writable `extlinux/Image`, `extlinux/initrd.cpio.gz`, and
   `extlinux/extlinux.conf` files;
2. a canonical, non-writable, single-link regular-file raw disk created only
   for this spike; and
3. mandatory lowercase SHA-256 values for every boot file and the raw baseline;
4. an explicit canonical caller-owned mode-0700 run-base directory; and
5. `--dedicated-baseline` acknowledgement.

Do not point it at a reader/release disk, a disk used by another test session,
or a file being modified concurrently. The write-bit and hard-link checks are
guardrails, not authority to repurpose an artifact. The runner never attaches
the caller's baseline to QEMU: under a new mode-0700 `mkdtemp` directory it
makes a private reflink when supported, otherwise a sparse copy, verifies every
private boot/baseline copy against its supplied SHA-256, marks those snapshots
read-only, and
uses `qemu-img create -f qcow2 -F raw -b PRIVATE-BASE PRIVATE-OVERLAY`. Only the
private qcow2 overlay reaches the guest block device. The caller's kernel,
initrd, and config are likewise privately copied before launch.

The mode-0700 run-base descriptor protects creation, but later copies, QEMU
paths, and cleanup use the reconstructed pathname. Treat the run base and all
source inputs as quiescent trusted-owner state for this spike: a same-UID owner
rename/replacement during preparation can make the operation fail and strand
the descriptor-created directory under the renamed original base.
Descriptor-relative access and cleanup remain release hardening, not a guest
authority boundary or a blocker for the narrowly attended smoke.

Capacity is deliberately not hidden: if the run filesystem cannot reflink,
the sparse-copy fallback can consume up to the baseline's allocated data, the
SHA-256 check reads its full logical size once, and the qcow2 overlay can grow
with guest writes. This runner sets no host disk quota. Check free space and
use a small dedicated baseline before authorizing the real run.

The fixed QEMU graph includes:

```text
-no-user-config
-nodefaults
-M virt
-accel tcg,thread=multi
-nic none
-display none
-monitor none
one private serial console socket/log beneath the run directory
one virtio-blk device backed by the private qcow2 overlay
```

There is no QMP socket, host share, `-netdev`, `/dev/kvm`, arbitrary device,
credential environment, or caller-selected console path. QEMU and `qemu-img`
receive a newly constructed environment containing only private HOME/tmp/XDG
paths, `C` locale, and the QEMU executable directory. Each subprocess is forked
by a small Guile guardian that is a Linux child subreaper. A setup gate keeps
the exec child blocked until its exact private process group exists; the
guardian then applies the wall-clock timeout, performs bounded TERM-to-KILL
escalation, and reaps the group including orphaned descendants. An owner-only
liveness pipe gives that guardian cleanup authority after owner death. A
second run-lifetime guardian removes only the identity-checked private run tree
after the process-cleanup bound. Exec children explicitly close all guardian
and liveness descriptors before `exec`, in addition to the general
`FD_CLOEXEC` sweep.

Normal, error, timeout, interrupt, HUP, and TERM paths still unwind through the
owner. Uncatchable owner `SIGKILL` is different: no signal handler claims to
handle it; EOF on the two liveness pipes independently drives process-group
and run-tree cleanup. Guardian setup and teardown are bounded, and fallback
signals name only the recorded guardian PID or owned PGID—there is no PID/name
scan. The synchronous owner and process guardians reset inherited `SIGCHLD`;
the process guardian, rather than PID 1, reaps descendants.

After QEMU is reaped, the runner calls the bounded Guile console-file assertion
inside the guarded run-root scope and before cleanup. Missing, malformed,
duplicate, reordered, panic/failure, or no-powerdown evidence makes the runner
nonzero; the same identity-checked cleanup still runs. Success is reported only
as the single exact line:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

On timeout, nonzero QEMU status, or a console-parser error, the runner exports
the **whole** private `console.log` to parent stderr before cleanup, provided it
fits the fixed 3,423,172-byte source bound. That value is tied to the v5 guest
source rather than a store-name or runtime claim: 16 selected file diagnostics
(runsc stdout, support/prewarmer/Sentry stderr, at most 12 Gofer/Sentry
debug/panic files, and dmesg stdout/stderr) × 16,384 selected source bytes × 5
worst-case guest escaping, plus 12 × 255-byte generated filenames × 5, is
1,326,020 serial bytes. The remaining 2 MiB is framing and boot/control/shutdown
headroom; the pre-diagnostic v4 serial record was 21,338 bytes. Parent escaping
can expand the bounded console content by at most another 5×, to 17,115,860
bytes. The size preflight and export each use a bytevector capped at the source
limit plus one byte, rather than trusting `stat` length or using an unbounded
whole-port string read; escaping writes directly to parent stderr without
constructing the expanded form in memory. Controls, newlines, and backslashes
remain escaped and every rendered data line remains prefixed. If the source
exceeds the bound or changes during export, the runner prints
`BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE` and a completed QEMU invocation is not
allowed to report success. QEMU stderr remains a separate bounded 32 KiB
head/32 KiB tail diagnostic. No console or disk is retained after the existing
identity-checked private-root cleanup.

Replay its safe host tests, including timeout, externally signaled cleanup,
and owner-`SIGKILL` cleanup of a TERM-resistant fake-QEMU child, with:

```sh
PYTHONDONTWRITEBYTECODE=1 \
  python3 pinenote/tools/book-execution-spike/test_disposable_qemu.py
```

## Native-reader/guest interaction successor

The source-only successor specified by
`doc/reviews/2026-09-06-book-interaction-qemu-seam-design.md` is separate from
the accepted automatic protocol image and runner. Its guest system inherits
the accepted protocol-control system, replaces only the one-shot authority and
source/build manifests, and requires `udev` for the exact named character port:

```text
/dev/virtio-ports/org.wilkbook.book-interaction
```

`guest-virtio-book-ui.scm` owns a bounded nonblocking, `FD_CLOEXEC` character-
port adapter. `guest-book-interaction.scm` remains the trusted authority for
the fixed Guile-then-Python order, action/request IDs, fresh nonces, Book
Session endpoints, committed presentations, runsc groups, and cleanup. The
native Lua side never chooses a language. The sandboxed books still receive
only their distinct Unix Book Protocol endpoint at FD 3 through the accepted
literal `run --pass-fd=3:3` path.

The outer path is also a sibling:

- `reader-qemu-graph.scm` adds exactly one private socket chardev, one
  virtio-serial controller, and one named port to the accepted QEMU vector;
- `disposable-reader-qemu.scm` reuses the accepted process and run-root
  guardians, makes the hash-checked fixed coordinator the direct guarded
  child, and requires coordinator/native lifecycle success plus the strict
  guest reader protocol/cleanup/power-down chain; and
- `run-disposable-reader-qemu.scm` is the separate entry. The accepted
  `run-disposable-qemu.scm` and default QEMU path are unchanged.

The fixed coordinator receives exactly four named options and the complete
QEMU vector without `argv[0]`. It owns only QEMU/KOReader process and private-
socket lifetimes. It does not parse protocol bytes or accept a language,
input, nonce, result, or expected-result option. Its source and four runtime
Lua files are copied into the identity-guarded run root only after their frozen
SHA-256 values match. The outer also accepts only the exact independently
reviewed native package output
`/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`.

Host-only regressions use real native Guile/Python fixture books behind fake
runsc, a PTY-backed character-device symlink, and fake QEMU/KOReader children.
They cover framing and pump bounds, exact authority routing, malformed/stale/
duplicate/disconnect cleanup, the full QEMU vector, strict serial labels,
joined success/failure, coordinator source drift, timeout cleanup, and the
unchanged accepted outer. They do not run QEMU, runsc, ARM code, or an image.
The joined-outer cases create a real Unix socket node and the complete fake
`reader-ui` evidence tree. Normal, child-failure, TERM, timeout, and owner-
`SIGKILL` paths leave no recorded PID/start-time alive and remove the private
tree only after resistant writers are gone. A deliberate run-root replacement
is instead preserved and forced nonzero; the reader wrapper never recursively
cleans the foreign inode.

Guix discovery uses
`prepare_reader_interaction_module_view.py`: exactly the accepted v4 19-module
roster plus the reader system module is visible through `GUILE_LOAD_PATH`,
while the sole build-command `-L` directory contains zero Scheme files.
Derivation-only evaluation produced distinct protocol/reader system
derivations but the same
`/gnu/store/89mdjnh0l5mkbjyv94lid7p4fjb8aw2j-raw-initrd.drv`. Their derivation
build-closure rosters contain 2,549 and 2,558 paths (18 removed, 27 added); the
new-only side contains source/service/system objects and no new package. This
is not a realized runtime closure or image result.

No actual named virtio port, guest character node, cross-boundary disconnect,
native paint joined to ARM execution, or runtime cleanup has been observed.
In particular, the host disconnect tests model owner cleanup but do **not**
prove that a real QEMU virtio disconnect propagates to guest EOF. Any actual
QEMU launch still needs an independently reviewed image and a new one-use
authorization.

For the accepted automatic (non-reader) runner, after a dedicated raw baseline
has been built, inspected, removed from every other session, and made read-only,
the historical future invocation shape is:

```sh
set -eu
umask 077
bundle=/absolute/path/to/fixed-book-execution-boot-bundle
baseline=/absolute/path/to/dedicated-book-execution-baseline.raw
baseline_sha256=$(sha256sum "$baseline" | cut -d ' ' -f 1)
kernel_sha256=$(sha256sum "$bundle/extlinux/Image" | cut -d ' ' -f 1)
initrd_sha256=$(sha256sum "$bundle/extlinux/initrd.cpio.gz" | cut -d ' ' -f 1)
config_sha256=$(sha256sum "$bundle/extlinux/extlinux.conf" | cut -d ' ' -f 1)
expected_status='OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS'
run_base=$(mktemp -d /tmp/opencode/wilkbook-qemu-runs.XXXXXX)
status_file=
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  [ -z "${status_file:-}" ] || rm -f -- "$status_file"
  if ! rmdir "$run_base"; then
    printf 'FAIL: run base is not empty: %s\n' "$run_base" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0700 "$run_base"
status_file=$(mktemp /tmp/opencode/wilkbook-qemu-status.XXXXXX)
chmod 0600 "$status_file"

if guix time-machine -C channels.scm -- shell qemu guile@3.0.9 -- \
     guile --no-auto-compile -L pinenote/tools/book-execution-spike \
       pinenote/tools/book-execution-spike/run-disposable-qemu.scm \
       --boot-bundle "$bundle" \
       --baseline "$baseline" \
       --kernel-sha256 "$kernel_sha256" \
       --initrd-sha256 "$initrd_sha256" \
       --config-sha256 "$config_sha256" \
       --baseline-sha256 "$baseline_sha256" \
       --run-base "$run_base" \
       --dedicated-baseline \
       --timeout-seconds 600 > "$status_file"
then
  run_status=0
else
  run_status=$?
fi
cat "$status_file"
checker_status=1
if [ "$run_status" -eq 0 ] &&
   [ "$(grep -Fxc "$expected_status" "$status_file" || true)" -eq 1 ] &&
   [ "$(wc -l < "$status_file")" -eq 1 ]
then
  checker_status=0
fi
printf 'RUN-STATUS=%s CHECKER-STATUS=%s\n' "$run_status" "$checker_status"
[ "$run_status" -eq 0 ] || exit "$run_status"
[ "$checker_status" -eq 0 ] || exit "$checker_status"
```

That command has **not** been run. A focused re-review must first approve the
regenerated dedicated baseline and integrated guest-console assertion phase.
The latter asserts no
non-loopback interface/default route before it can launch the preferred
`isolation-userns` profile; outer `-nic none` and inner `runsc --network=none` are
separate evidence.

### Resource and lifecycle non-claims

The OCI process has small `RLIMIT_CORE`, `RLIMIT_FSIZE`, and `RLIMIT_NOFILE`
values, and scratch declares a 16 MiB tmpfs size. Neither behavior has been
observed under the pinned ARM64 runtime. The system now declares cgroup2, the
OCI object names one run-owned `cgroupsPath`, and the launcher performs a
writable-hierarchy preflight before `runsc --ignore-cgroups=false`. This is
whole-domain membership plumbing only: `linux.resources` remains absent, so no
CPU, memory, or PID ceiling is claimed. Controller enablement, nonzero limits,
whole-domain accounting, support-process identity, limit-kill fixtures, and
cgroup teardown are later isolation gates. In-container PID counts are not
host cgroup PID accounting. Wall time, diagnostic output, bounded output
import, sidecar-path observation/negative fallback testing, and runtime
teardown assertions are also still pending.

The retained language profile now contains Guile 3.0, `guile-json` 4.7.3, and
Python. A second trusted supervisor profile contains only Guile and
`guile-json`; this both keeps Python out of trusted supervision and avoids the
broad system profile's Guile-version conflict. The exact pinned `(gnu packages
guile)` variable is `guile-json-4`. The sibling protocol agent still owns the
broker/framing interface; adding the codec dependency here does not claim that
integration exists.

## ARM64 package checks

Cheap source and exact package/member-manifest pins:

```sh
pinenote/tools/book-execution-spike/check-gvisor-package.sh
```

Inspect a separately downloaded release against both upstream checksum files,
the exact seven-member archive layout (six files plus `gvisor-bin/`), the
AArch64 ELF machine, and the absence of dynamic dependencies:

```sh
stage=/tmp/opencode/wilkbook-gvisor-release-20260831.0
guix shell binutils zstd -- \
  pinenote/tools/book-execution-spike/check-gvisor-package.sh \
    --archive "$stage/gvisor-aarch64.tar.zstd" \
    --sha256sums "$stage/SHA256SUMS" \
    --sha512sums "$stage/SHA512SUMS"
```

Evaluate the package derivation at the repository channel pin:

```sh
pinenote/tools/book-execution-spike/check-gvisor-package.sh --derivation
```

After building, inspect the installed output without running it:

```sh
out=$(guix time-machine -C channels.scm -- \
  build --no-grafts --cores=2 --max-jobs=1 -L . \
  --target=aarch64-linux-gnu \
  -e '(@ (pinenote packages gvisor) gvisor-bin)')
pinenote/tools/book-execution-spike/check-gvisor-package.sh --output "$out"
```

Inspect the dedicated non-shipping system without lowering/building its kernel,
rootfs, or image:

```sh
guix time-machine -C channels.scm -- \
  repl -L . -q \
  pinenote/tools/book-execution-spike/check-execution-system.scm
```

The current test-kernel package derivation is
`/gnu/store/6xgyq3awmj54ks6w7mm27qc69sail51r-linux-pinenote-book-execution-test-7.1.8-pinenote.drv`.
It has no realized output. A system/kernel lowering attempt unexpectedly began
the uncached full cross-build and was terminated at the command timeout before
producing a kernel output; do not repeat it without explicit build approval.

The release checksum files and the GitHub release API agree with the package
pin, but the annotated upstream tag is unsigned. These checks establish exact
downloaded content and layout, not signed provenance or correspondence to a
reproducible source build. At the pinned source, the runtime's `DEFAULT`
sidecar policy still allows embedded fallback; only the explicit strict launch
flags above fail closed when adjacent helpers are absent.

## 2026-09-04 Guile adversarial-review implementation disposition

This section records the implementation response to
`doc/reviews/2026-09-04-book-execution-guile-adversarial.md`; it does **not**
edit that review, declare its blocked verdict accepted, or authorize a real
QEMU run. Re-review owns the resulting gate decision.

- Finding 1: implemented with the process and run-lifetime Guile guardians
  described above. The new host regression sends uncatchable `SIGKILL` to the
  owner after the TERM-resistant fake QEMU descendant is live, under inherited
  `SIGCHLD=SIG_IGN`. It independently records exact PID/start-time identities,
  verifies both guardians, fake QEMU, and descendant are gone, and verifies the
  private run tree is removed. Its failure cleanup signals/reaps only those
  identities. The original six fake-QEMU methods remain and the suite now has
  seven.
- Finding 2: implemented in generated `launch.scm`. Normal probe `rmdir`
  failure throws a fatal preflight error before `runsc`; the outer error path
  retries removal best-effort and rethrows the original error. A generated-code
  host test injects both failures through lexical filesystem-operation hooks,
  so it requires no cgroup mount or privilege.
- Finding 3: intentionally unchanged except for the explicit trusted-owner,
  quiescent-input assumption above. Descriptor-relative later access remains a
  release-hardening item, as the review classified it.

No kernel, system, package, session, protocol, or reader source is part of this
disposition. No real QEMU, `runsc`, VM, network, hardware, or device action is
evidence for it.
