# Dedicated book-execution baseline and guest-smoke adversarial review

Date: 2026-09-05 UTC

Repository base: `50572d7796abdb0928969f4db8836fc5e30aeb58`

Focused snapshot: 2026-09-05T00:24:03Z

## Verdict

**The dedicated baseline construction and its kernel/config evidence are
accepted at the exact hashes below. The first real QEMU boot is not yet
authorized.** Three finite source/integration corrections remain:

1. the outer runner has no path that consumes `console.log` before its private
   run root is deleted;
2. the Python and Guile PASS markers are based only on `run.sh` exit zero, not
   on distinct, checked payload output; and
3. the inherited default serial `agetty` is eligible to run concurrently with
   the smoke on the same QEMU console.

These are narrow first-compatibility acceptance blockers, not production or
hostile-book requirements. No cgroup resource ceilings, Book Protocol FD,
bounded output import, sidecar isolation result, hardware qualification, or
release claim is required to close them.

The 7.1.8 USER_NS kernel output can be reused. Corrections 2 and 3 change the
guest/system closure, so the system, image, private baseline, and their hashes
must be regenerated after those corrections; there is no reason to rebuild the
kernel if its derivation remains unchanged.

Do **not** execute
`pinenote/tools/book-execution-spike/build/first-boot-after-guest-review.command`
at its reviewed hash.

## Scope

This review directly inspected:

- the fixed in-guest Guile smoke and its host tests;
- the serial-log assertion module and entry point;
- the non-shipping execution-spike operating system and static checks;
- the exact kernel-config delta checker and mutation tests;
- private baseline staging and non-mounting inspection scripts;
- the realized kernel, system metadata, retained profiles, language closure,
  image metadata, staged boot bundle, and private raw baseline; and
- the unexecuted first-boot command.

The previously accepted OCI generator and disposable-QEMU runner were checked
only where their exact behavior joins this integration. Their broader reviews
remain in `2026-09-04-book-execution-guile-adversarial.md`.

No kernel, system, rootfs, image, or package was built or lowered by this
review. No real QEMU, ARM64 executable, `runsc`, network, mount, loop device,
hardware, SSH, UART, or deployment was used. The builder's completed outputs
were only read and hashed. Temporary host fixtures were removed.

## Accepted baseline construction

### Exact kernel and configuration

The realized test kernel is:

```text
/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote
```

Its package identity is `linux-pinenote-book-execution-test` version
`7.1.8-pinenote`; `CONFIG_LOCALVERSION=""`, the source is Linux 7.1.8, and the
runtime assertion therefore expects exactly `7.1.8`. The staged `Image` is an
ARM64 Linux boot image. The final config includes the QEMU/root/runtime
prerequisites checked here, including:

```text
CONFIG_ARM64=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_PIDS=y
CONFIG_MEMCG=y
CONFIG_NAMESPACES=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_USER_NS=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
```

`check_kernel_config_delta.py` parses every config symbol, rejects duplicate
symbols and malformed/empty allowlists, computes the union of symbol names,
and compares the complete changed-symbol map for exact equality with the
allowlist. The allowlist contains only `CONFIG_USER_NS n y`.

An independent invocation against the realized base and test-kernel configs
passed with exactly:

```text
CONFIG_USER_NS: n -> y
```

The generated full diff contains that one line transition and no other hunk.
Thus `make olddefconfig` introduced no unreviewed dependent change. The three
checker mutation methods also passed: exact delta acceptance, unlisted-symbol
rejection, and wrong-transition rejection.

### System, profiles, and closure authority

The realized system and source image are:

```text
/gnu/store/laq3v5csnh5p8i9njv5vrap0kls5ay5g-system
/gnu/store/vvrp8i9af77sacic7rqnmcjiacpgd74a-disk-image
```

The system's own immutable build manifest identifies the test kernel, exact
kernel output/config, `isolation-userns`, `directfs=false`, `network=none`,
`platform=systrap`, `ignore-cgroups=false`, and the pinned gVisor output. Static
evaluation confirms one cgroup2 hierarchy at `/sys/fs/cgroup`, no Guix daemon,
one guest-smoke service, and the complete `gvisor-bin` package.

The system closure contains byte-identical store copies of the reviewed OCI
generator and guest fixture:

```text
0cbbdb0da74b20c3420af47fafbaea8af4fa357b04825713d024deeec1c2ca4f  wilkbook-book-execution-oci-bundle.scm
35ed3417dcc7b339e7b612cb21b1c258fdcb1cae044b5954d8c114dad3f2fe08  wilkbook-book-execution-guest-smoke.scm
```

The retained language profile is exactly:

```text
guile       3.0.9
guile-json  4.7.3
python      3.12.12
```

The separate trusted supervisor profile is exactly Guile 3.0.9 plus
`guile-json` 4.7.3 and contains no Python. The generated language reference
list contains 45 unique string paths. It contains the language profile and its
transitive requisites, but no gVisor output, supervisor profile, system profile,
or system output. The accepted OCI generator validates each path and mounts
only these individual closure items plus the selected immutable book; it does
not mount the guest's whole `/gnu/store` into the sandbox.

The exact accepted runtime vector has all 17 common hardening flags plus
`--directfs=false`, followed by `run`, the private bundle, and its fixed
container ID. The sandbox root, language closure, and book are read-only;
`/scratch` and `/dev` are bounded tmpfs mounts. No host share, Guix socket,
`/data`, host device, or network is added.

### Private raw baseline and boot bundle

The staging script accepts only a canonical Guix system output and disk-image
output, verifies that the image references that system exactly once, resolves
the kernel/config/DTB to the exact test-kernel output, and refuses overwrite.
It copies only regular files, checks link counts, and publishes through a
private temporary directory. It never mounts an image or creates a loop device.

The source image SHA-256 independently matches its manifest:

```text
e04bdb0c7274eb807f4e6c8a531eb6070a50e180e4ab2d6ecf8ca7c79d348c61
```

It has one ext4 root partition at sector 2048, length 3,998,344 sectors. A
read-only probe found the source label `Guix_image`; the staged private copy has
label `PNGuixRoot`, with the same UUID, filesystem size, partition geometry,
and total image size. The first 1 MiB, including the partition table, has the
same SHA-256 in source and private copy:

```text
e37b0fe8db55cd326c7e3c56bd35e33f8e7d99c10a0440f103e2b07df21b7a47
```

The recorded `e2fsck` output completes all five read-only check passes without
an error. The log does not itself encode the command-line flags, so this review
can verify the clean result and unchanged published hash, while the builder's
statement that it used no-write mode remains an operator record. No mount was
used by either staging script or this review.

The supplied inspector passed independently. Every published input is a real,
single-link, non-writable file; the containing directories are mode 0500 and
the baseline is mode 0400. All content hashes match both manifests. The
extlinux entry has one matched `gnu.system`/`gnu.load`, one
`root=PNGuixRoot`, and one PineNote hardware console. The accepted runner
replaces that console with `ttyAMA0` only in its SHA-verified private config
copy.

The QEMU device graph remains acceptable for this narrow smoke. The baseline
is copied and hash-verified again under a fresh mode-0700 run root, used as the
raw read-only backing of a private writable qcow2 overlay, and never passed as
a reusable writable device. The sole guest block device is that overlay. There
is no 9p/virtiofs share, QEMU network device, KVM device, monitor, or display.
The guest necessarily has a writable disposable root disk; the accepted claim
is that it has no writable **host-authority or reusable input** device.

## Guest assertion flow that is already sound

The one-shot Shepherd service runs after `user-processes` with a constructed
environment and absolute Guile/source/profile/closure/book paths. It invokes
the immutable fixture, then calls `sync` and absolute `halt` on both pass and
failure. The guest's Python and Guile OCI bundles are fresh, fixed-ID,
`isolation-userns` bundles generated from the reviewed OCI source.

Before launching either bundle, the fixture checks:

- exact running kernel release `7.1.8`;
- exactly the loopback network interface and no IPv4 default route;
- no 9p, virtiofs, NFS, whole-store, or `/data` mount;
- no `/dev/kvm` or Guix daemon socket;
- all six version-matched gVisor executables under one package directory; and
- `runsc --version` containing `release-20260831.0`.

Runtime startup is fail-closed: spawn/exec failure becomes nonzero, timeout
terminates the owned process group, nonzero `runsc` status throws, every thrown
failure attempts a `BOOKEXEC-SMOKE-FAIL` serial record, and the service still
halts. After each zero-status run, the fixture rejects a surviving explicit
cgroup path. The final cgroup/smoke markers occur only after both runs.

The standalone console parser is also sound as a parser: it bounds the input at
16 MiB, rejects non-regular inputs and failure/panic fragments, requires each
of eight exact marker lines once and in order, and requires a kernel power-down
line. Its mutation cases for missing, duplicate, reordered, failure, panic, and
missing-powerdown logs all passed. These parser tests are not VM evidence.

## Open blocker 1 — no integrated consumer of the console evidence

The accepted runner creates `console.log` only beneath its random private run
root. After QEMU exits it deliberately prints:

```text
OUTER-QEMU-EXIT=0; GUEST-ASSERTIONS=NOT-RUN
```

and its `dynamic-wind` cleanup removes the run root, including `console.log`.
Neither the runner, the system, the staging scripts, nor the first-boot recipe
invokes `assert-guest-console.scm`. There is therefore no supported point at
which the current parser can read the completed log.

An independent fake-QEMU counterexample wrote all eight required markers plus
`reboot: Power down` into the exact `logfile=` argument and exited zero. The
runner correctly still reported `GUEST-ASSERTIONS=NOT-RUN`, then removed the log.
This does not count the fake as functional evidence; it proves the acceptance
handoff is absent.

The reviewed first-boot recipe also lacks `set -e`. If interpreted by `sh`, a
failed runner followed by successful `rmdir "$run_base"` can leave the recipe's
final status at zero. It contains no assertion command in any case.

### Required correction

Before the first boot, make the trusted outer path parse the completed bounded
console log **after QEMU has been reaped and before run-root deletion**. It must
return nonzero on parser failure and report guest success only after the parser
passes. Keep private-root deletion on both outcomes. Add a focused fake-QEMU
wiring regression, but label it parser/orchestration evidence rather than a
functional result. Make the reviewed invocation fail-fast (`set -eu` or an
equivalent explicit status check) so cleanup cannot mask failure.

No general console driver, persistent output-import protocol, or production
logging facility is required.

## Open blocker 2 — language markers are not bound to payload output

Both fixed payloads read `/book/input` and write a byte count to
`/scratch/book-size`, but `/scratch` is the container-private tmpfs and is gone
when `runsc run` returns. `run-bundle` does not inspect that file or any success
output. On success it checks only the command status and stale cgroup path, then
the trusted supervisor itself emits the language PASS marker. The host test
explicitly requires both payloads to leave stdout unused.

An independent focused fixture supplied a `run.sh` containing only `exit 0` to
`run-bundle`. Without running Python, Guile, OCI generation, or gVisor, that was
sufficient for `BOOKEXEC-PYTHON-SYSTRAP-PASS` to be emitted. In the real image
the fresh bundle path and immutable runsc package make substitution much
harder, but the requested assertion is actual execution and output from both
languages, not merely trust in a zero-returning wrapper.

### Required correction

Give each fixed compatibility payload a distinct fixed sentinel on its bounded
captured stdout (or another already-captured diagnostic channel), including
the expected byte count. `run-bundle` must accept the expected language/result,
read the bounded capture after exit zero, and reject empty, wrong,
cross-language, or duplicate sentinels before emitting the serial PASS marker.
Keep the serial control marker different from the payload sentinel.

Add mutations proving that a no-op `exit 0`, wrong-language sentinel, wrong
byte count, and duplicate sentinel all fail without a language PASS marker.
The exact correct Python and Guile outputs should be the only successful host
fixtures. The eventual real run, not those host mocks, supplies ARM64/runsc
compatibility evidence.

This is a fixed smoke-only diagnostic and does not require the Book Protocol,
general output import, or arbitrary book output.

## Open blocker 3 — serial login races and can author marker text

The dedicated system appends unmodified `%pinenote-base-services`. Static
evaluation shows one default `agetty` service and a login configuration that
allows empty passwords. The default agetty dynamically selects the first
non-virtual kernel `console=` device. The accepted runner rewrites
`console=ttyS2,1500000n8` to `console=ttyAMA0`, so the agetty selects the same
serial stream used by `/dev/console` markers and the captured log.

The smoke requires only `user-processes`. The agetty requires
`user-processes`, `host-name`, and `udev`; it is not ordered after the smoke and
can start while the two runsc commands execute. Even without a login, its
non-newline prompt can share a line with an exact marker and create a false
negative. Any successful console session can also print every expected marker,
defeating the intended fixed-fixture writer provenance. The current static
check's description that the hardware console is for outer steering only does
not check or establish that claim.

### Required correction

Remove/disable the serial agetty in this one-shot, non-shipping baseline (and
preferably all interactive gettys, which this headless disposable test does not
need) while retaining the kernel serial console for logs and fixed marker
output. Add a static system check that no `agetty`/serial-login Shepherd service
is present. The smoke service should remain automatic and halt on both pass and
failure; no interactive login is needed for this first compatibility run.

## Bounded checks run

- 5/5 current guest-smoke host methods passed.
- 3/3 kernel-config checker mutation methods passed.
- 5/5 non-lowering execution-system checks passed.
- 7/7 non-lowering guest-system checks passed; the console/getty gap above is
  an omitted assertion, not a failure those checks currently cover.
- Both staging and inspector scripts passed `sh -n`.
- The supplied private-input inspector passed against the completed artifact.
- Actual base-vs-test kernel configs independently passed the one-symbol
  allowlist; regenerated evidence hashes matched the committed build evidence.
- Source/private labels, UUID, geometry, first MiB, modes, link counts, and all
  manifest SHA-256 values were checked without mounting.
- Two isolated counterexamples reproduced the missing assertion integration
  and the exit-zero-only language marker behavior.

The five guest host methods inspect/mutate source and synthetic logs. They do
not execute ARM64 code or gVisor and must not be cited as functional success.

## Exact reviewed hashes

### Trusted and test source

| SHA-256 | File |
|---|---|
| `35ed3417dcc7b339e7b612cb21b1c258fdcb1cae044b5954d8c114dad3f2fe08` | `pinenote/tools/book-execution-spike/guest-smoke.scm` |
| `8ca12d52a9366295f262fa7bfad4ad1e6068b899501cb632499aa69b77caa005` | `pinenote/tools/book-execution-spike/guest-console-assertions.scm` |
| `0a3fac213fc555143f836723213af33a98f3de9417578a64de7fbff7fb5ed036` | `pinenote/tools/book-execution-spike/assert-guest-console.scm` |
| `e3cf6e09affcfbb6e406ecfc8b43300f625e9a21b67f0ffde9ca3228eed202db` | `pinenote/tools/book-execution-spike/test_guest_smoke.py` |
| `f2cf74f16e2736a90e57453a702c93d4c04dc6c33f27089107ff637335bd18d7` | `pinenote/tools/book-execution-spike/check-guest-smoke-system.scm` |
| `f88220cfaf6bd90457e146610b33cd65d6b70e6cbdae4ac9e4f97fd2309202ed` | `pinenote/systems/pinenote-book-execution-spike.scm` |
| `f32f0eb807eb5a3e06ec31844ee6ce0d84e51463f67b49bd39bb51a36db98d03` | `pinenote/tools/book-execution-spike/stage-private-qemu-inputs.sh` |
| `2d407bda8b0dec77a36dbfad82e49884156d3a0c02ed08603f821376d4107400` | `pinenote/tools/book-execution-spike/inspect-private-qemu-inputs.sh` |
| `699488aaf83f0f8986027ca5b5bef9fc31d83d0c7daabc8c4e7c72df2cc42484` | `pinenote/tools/book-execution-spike/check_kernel_config_delta.py` |
| `7dea0f70044f81e2671cd718103e77c34a9f6fb03ca99aa76f1ac36f9a972526` | `pinenote/tools/book-execution-spike/test_kernel_config_delta.py` |
| `9d92fc3bc4d33a69b87c0d465224e2bb592b127f42067fa978816b6f6eedf465` | `pinenote/tools/book-execution-spike/expected-kernel-config-delta.txt` |
| `c12dcb9d6855347267d063929bcab112951adb108243f715a20234b90b7c45b1` | `pinenote/tools/book-execution-spike/check-execution-system.scm` |
| `0cbbdb0da74b20c3420af47fafbaea8af4fa357b04825713d024deeec1c2ca4f` | accepted `pinenote/tools/book-execution-spike/oci-bundle.scm` |
| `25812ffd6dbe998c60941d499fe90f4153045f968e3c04a62f791de794346f9e` | accepted `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | accepted `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` |
| `8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d` | `pinenote/packages/gvisor.scm` |
| `699afd669c10908324847ba1802415563c77580f55edbca0cbebc4f1bfcf7106` | `pinenote/packages/kernel.scm` |
| `a83ccf2647b971e454e1a7b230b3ed39e6b2a9edbd1c68116c4fc48a7fe98658` | `pinenote/systems/base.scm` |
| `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` | `channels.scm` |

### Built metadata and evidence

| SHA-256 | File |
|---|---|
| `e895ccc34ed93114681c3e2de27db15fe1cc8bca904579fc44e21922853133e4` | `build/kernel-build-manifest.txt` |
| `9307fd37cdb5165c12b66c43ac1513df4832f963c0ea79119bd8a7561f37b034` | `build/baseline-review-manifest.txt` |
| `c686a4f9bbc4124d2f248a5c0761471aa605a2f37f81e2b1891653bba588b637` | private artifact `manifest.txt` |
| `57f2b2c62c45bea341de806b173671626eebf7b6f184b130c2b2206ef6c886cd` | unexecuted `build/first-boot-after-guest-review.command` |
| `0255f100e4699e528da9177c4a34194fe3d7d430480586f55f9988137ca60329` | `build/kernel-config-evidence/kernel-config-full.diff` |
| `7854a9fee8e3fa4a569f5c9337673881ca062e52c28bb4d50a315a70dd2643dc` | `build/kernel-config-evidence/kernel-config-symbol-delta.tsv` |
| `5f04ec98fd00ac8a2a0d778a101486e351d0fdc238e02a06974296efd425075b` | `build/private-baseline-e2fsck.log` |

### Immutable run inputs

| SHA-256 | Input |
|---|---|
| `f16b1ef41980ab1dfa1694102f2335956cb5c6372b69a1dbdc01d231791bcaf7` | `baseline.raw` |
| `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` | `boot-bundle/extlinux/Image` |
| `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` | `boot-bundle/extlinux/config` |
| `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` | `boot-bundle/extlinux/rk3566-pinenote-v1.2.dtb` |
| `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` | `boot-bundle/extlinux/initrd.cpio.gz` |
| `dfcddbcc06f456b693202c617c2fbf813904c6db7b0b3079f562f771fa2a1921` | `boot-bundle/extlinux/extlinux.conf` |

The first-boot recipe's `config_sha256` correctly names the extlinux config
hash, not the separately staged kernel `.config` hash.

## Minimal gate to re-review

The next review need cover only a stable snapshot showing:

1. distinct checked Python and Guile payload sentinels, with the four negative
   mutations above;
2. no serial/interactive getty in the dedicated system and a static regression;
3. completed-log parsing before private cleanup, with failure propagated and a
   fail-fast invocation; and
4. a newly realized system/image/private-baseline manifest embedding those
   exact guest/system hashes (the accepted kernel output may remain unchanged).

Once those four items pass, this review adds no further preboot requirement for
one attended, explicitly labelled **functional compatibility smoke**. That run
will not by itself establish hostile-book isolation or release acceptance.

## Focused v2 three-finding recheck — 2026-09-05 UTC

### Verdict

**All three guest-integration findings are closed at the exact v2 hashes below.
The exact v2 recipe is ready for the first real functional-compatibility QEMU
run.** No further source correction is required before that run.

This supersedes only the preboot-blocked verdict at the top of this historical
review. It does not change the accepted scope: the first run may establish that
the exact ARM64 7.1.8 guest boots and that pinned runsc/systrap executes the two
fixed language payloads under `isolation-userns`. It is not hostile-book
isolation, production resource-limit, Book Protocol FD/output, release,
hardware, or deployment acceptance.

Run only the reviewed, mode-0600 recipe
`pinenote/tools/book-execution-spike/build/first-boot-after-guest-review-v2.command`
at SHA-256
`8df7875c0ce3669c9132676ad4640ef9109f9fce4411602787fbd94365f78da4`,
with the source and artifact hashes below still unchanged. A functional PASS
requires the recipe itself to exit zero and print exactly the runner status

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

followed by `RUN-STATUS=0 CHECKER-STATUS=0`. Host fake-QEMU methods remain only
parser/process-wiring evidence and must never be reported as the real result.

Focused snapshot time: **2026-09-05T00:55:05Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The pre-v2-review report SHA-256
was `d041913da482799d85e05a9e15c38dc5613e427ed8d6a5c59fcb4e103f072335`.

### Finding 1 closed — parser runs before cleanup and failure propagates

At `disposable-qemu.scm` hash
`318e437dd912e17fb698ac6fcb5ced002a33afde8caf0b95154c5010b5ec44c7`,
the trusted outer module imports `guest-console-assertions` and calls
`assert-guest-console-file` only after `run-owned-process` has reaped QEMU and
accepted its zero exit status. The call still occurs inside the existing
`dynamic-wind` body, before its identity-checked run-root cleanup. A missing,
oversize, non-regular, malformed, failed, or incomplete log throws through
`runner-error`; cleanup still runs and no PASS line is printed. Only a passed
parser produces the exact combined outer/checker/guest PASS line.

The parser source at
`aa6023ddb2dae1594bdd0470e66dbb8b71b2584e314d194c9d6d7bdc3660d911`
adds only the file-level exported entry needed by the runner; its existing
16 MiB bound, regular-file check, exact unique ordered markers, failure/panic
rejection, and power-down requirement remain the authority.

The original counterexample was independently repeated outside the committed
test method: a fake QEMU exited zero but omitted the Python marker from its
private `console.log`. The runner invoked the parser, returned nonzero with the
missing marker in its error, emitted no `GUEST-ASSERTIONS=PASS`, and removed the
entire private run tree. The positive fake-QEMU case produces the combined PASS
line and likewise leaves no run residue; that proves wiring only.

The v2 recipe is now `set -eu`, captures runner stdout in a private temporary
file, preserves the runner's nonzero status, requires exactly one expected
status line and no extra line, prints explicit run/checker status, and removes
the run base without allowing successful cleanup to mask an earlier failure.
It passed `sh -n` but was not executed.

### Finding 2 closed — markers require exact language payload output

The Python OCI payload at `oci-bundle.scm` hash
`26e92e2a81c5e3f9ef6169ebe8b7150abb4b55c57cb9dc1cbd06365ece71ffd8`
now emits exactly:

```text
BOOKEXEC-PAYLOAD-PYTHON book-bytes=<computed length>
```

after its fixed book read, scratch write, and failed external-network probe.
An exact diff against the previously accepted store copy showed no other OCI
implementation change: all profile selection, closure/mount authority,
environments, runtime flags, cgroup preflight, and launcher behavior are
preserved. An independent direct `make-launch-argv` comparison also matched the
entire accepted `isolation-userns` vector, including all 17 common flags and
explicit `--directfs=false`.

At `guest-smoke.scm` hash
`f90ba0f62eae82ba7bd2da1a0f57005189fce4d9ab42d0101344ea9336901533`,
the fixed Guile payload emits the distinct
`BOOKEXEC-PAYLOAD-GUILE book-bytes=<computed length>` line. The supervisor gets
the expected size from the immutable book store file, reads the already-bounded
runsc stdout capture after exit zero, and requires byte-for-byte equality with
the one expected language line before checking cgroup teardown and emitting the
serial language PASS marker. Empty, wrong-language, wrong-count, duplicated,
or extra output all fail closed.

Both original forms of the counterexample were independently repeated. A
no-op `run.sh` exiting zero with empty output failed before its language PASS;
a zero-exit script emitting the exact Guile sentinel while Python was expected
also failed before PASS. The focused supplied mutation method independently
passed all four negative cases and the exact positive Python and Guile cases.
Those positives are host command fixtures, not evidence that ARM64 runsc has
executed either language; that is precisely what the authorized first run will
test.

### Finding 3 closed — no serial agetty in the dedicated guest

At system source hash
`fae8742c4a4fa59d6185f7dd88f9ec372a3eecf443d5bbc249939b7e67ead539`,
the dedicated non-shipping system derives a headless base service set by
deleting `agetty-service-type` before adding the one-shot smoke. It retains the
kernel serial console solely for fixed logs/markers. The six virtual-terminal
mingetty services remain to satisfy Guix console-font provisions, but they name
virtual terminals and cannot select the QEMU `ttyAMA0` serial device.

Independent static evaluation observed exactly zero `agetty` services, one
`book-execution-guest-smoke` service, and six `mingetty` services. The updated
static checker pins the zero-agetty condition. The realized v2 system embeds
byte-identical OCI and guest source objects at the reviewed hashes.

### Accepted v2 immutable baseline

The corrected realized boundary is:

```text
system: /gnu/store/0rlw7zk22cnc4vcrlxz4c91xlphn6489-system
image:  /gnu/store/klgw7f4nypj4mhfz9l1py3rqmx5l1cm4-disk-image
```

The image SHA-256 independently matched
`f85c4e1de80ada942f99b2674beb234496bb208e978b02f128c3ac90b5aeb1ee`.
The system's immutable manifest still selects the exact accepted 7.1.8 test
kernel, `isolation-userns`, `directfs=false`, `network=none`, systrap, cgroup2,
the retained language/supervisor profiles, and pinned gVisor package.

The accepted kernel was reused unchanged:

```text
/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote
```

Its staged Image and config hashes are identical to the prior accepted
artifacts. The v2 packet records the same independently accepted exact config
delta, `CONFIG_USER_NS: n -> y`, with no other symbol change. This focused
recheck did not rebuild or broaden that already-accepted kernel review.

The non-mounting private-input inspector passed against
`build/artifacts/pinenote-book-execution-userns-20260904-v2`. Independent tree
inspection found only real directories/files, mode 0500 directories, mode 0400
files, link count one, and no aliases. Every SHA-256 matched the artifact and
review manifests. The private baseline remains one ext4 partition labelled
`PNGuixRoot`; the boot configuration identifies the matched v2 system and the
accepted runner will use only SHA-verified private copies plus its disposable
qcow2 overlay.

### Focused checks

- The independent no-op and wrong-language-output counterexamples now fail
  before a language PASS marker.
- The independent QEMU-zero/missing-marker counterexample now invokes the
  parser, fails, and cleans the private run tree.
- The supplied focused payload-output mutation method passed.
- The supplied missing-console-marker runner method passed.
- One positive exact-vector/private-copy/parser runner method passed.
- The owner-`SIGKILL` guardian regression passed unchanged, confirming the
  accepted liveness/PGID cleanup remains intact after parser integration.
- All 8 current non-lowering guest-system assertions passed, including zero
  agetty and one cgroup2 mount.
- The exact accepted `isolation-userns` runtime vector matched independently.
- The v2 inspector and recipe shell syntax passed.
- No fixture process, private run tree, Python bytecode cache, or review
  temporary remained.

The builder's aggregate logs were read as packet metadata, not substituted for
these focused independent checks. No real QEMU, runsc, ARM64 executable,
network, mount, build, lowering, hardware, SSH, UART, or deployment was used.

### Exact v2 hashes

| SHA-256 | Reviewed source or packet |
|---|---|
| `fae8742c4a4fa59d6185f7dd88f9ec372a3eecf443d5bbc249939b7e67ead539` | `pinenote/systems/pinenote-book-execution-spike.scm` |
| `26e92e2a81c5e3f9ef6169ebe8b7150abb4b55c57cb9dc1cbd06365ece71ffd8` | `pinenote/tools/book-execution-spike/oci-bundle.scm` |
| `f90ba0f62eae82ba7bd2da1a0f57005189fce4d9ab42d0101344ea9336901533` | `pinenote/tools/book-execution-spike/guest-smoke.scm` |
| `aa6023ddb2dae1594bdd0470e66dbb8b71b2584e314d194c9d6d7bdc3660d911` | `pinenote/tools/book-execution-spike/guest-console-assertions.scm` |
| `318e437dd912e17fb698ac6fcb5ced002a33afde8caf0b95154c5010b5ec44c7` | `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | unchanged `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` |
| `71678754c438ff293dc30a45949d1d2f76d12ce5ee735cdf8d747d97a229b17e` | `pinenote/tools/book-execution-spike/test_guest_smoke.py` |
| `05f755a127197fc521ce20bbe401ae6c3da504ee26d97268e0494aedb8116f0a` | `pinenote/tools/book-execution-spike/test_disposable_qemu.py` |
| `fa4e2d7be705009d9bd022ea963b735ff53a844b51bfacb9ec31aee2fb8117ff` | `pinenote/tools/book-execution-spike/check-guest-smoke-system.scm` |
| `685855096da1c203431788b655c4d824b284903ee6e8578ff72f5962c12f2fbe` | `build/baseline-review-manifest-v2.txt` |
| `8df7875c0ce3669c9132676ad4640ef9109f9fce4411602787fbd94365f78da4` | `build/first-boot-after-guest-review-v2.command` |
| `cfde18fece90f8a56e2d13170b2ea45dd4d4f85967be37f200e94f3b321351bf` | v2 private artifact `manifest.txt` |

| SHA-256 | Immutable v2 artifact |
|---|---|
| `e142c244dd5b6de83da4cdf9121fd128504bedfa8c9b873b94f7311f308a7e5d` | `baseline.raw` |
| `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` | `boot-bundle/extlinux/Image` |
| `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` | `boot-bundle/extlinux/config` |
| `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` | `boot-bundle/extlinux/rk3566-pinenote-v1.2.dtb` |
| `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` | `boot-bundle/extlinux/initrd.cpio.gz` |
| `9c37225ddc174288dfc01686f70457bc16d4ca50763e42c909edee4273b4a0b4` | `boot-bundle/extlinux/extlinux.conf` |

There is no surviving required bug in these three findings. If the exact
recipe and hashes remain frozen, the parent may release the first functional
run without another preboot review. Any result must retain the narrow label
above and separately record the real QEMU console/result; deferred production
gates remain deferred rather than silently promoted.

## First-attempt preparation follow-up — 2026-09-05 UTC

### Verdict

**The first attempt was a preparation failure, not a QEMU, gVisor, kernel, or
guest failure. The bare `HASH-system` compatibility fix is correct, but the
updated runner is not yet re-authorized because two directly requested
fail-closed APPEND mutations still pass.** The image, kernel, OCI policy, guest
fixture, console assertions, entry point, and v2 recipe do not need to change or
be rebuilt.

The attempted recipe stopped at `read-fixed-append` with:

```text
FAIL: APPEND must contain one canonical Guix gnu.system path
RUN-STATUS=1 CHECKER-STATUS=1
```

This occurs at the beginning of `run`, before run-root creation, executable
resolution, private copies, qemu-img, or QEMU. The log contains Guix-shell
profile realization followed by that parser error and no outer/guest PASS.
Nothing in it is evidence about ARM64, runsc, the USER_NS kernel, or the guest.

Attempt log reviewed read-only:
`/tmp/opencode/wilkbook-first-qemu-v2.eXvWVP.log`.

### Exact tiny delta

Current runner SHA-256:

```text
abe1db34cd579393ec9498a7a7e5fb20a949ec1cfa613c2f27a93a57e19d106c
```

The only change from the accepted
`318e437dd912e17fb698ac6fcb5ced002a33afde8caf0b95154c5010b5ec44c7`
runner is the explanatory comment and:

```scheme
(make-regexp "^/gnu/store/[0-9a-z]{32}-(.+-)?system$")
```

Replacing that block in-memory with the prior two-line definition reproduced
the accepted SHA-256 exactly. No guardian, process, parser-call, cleanup, QEMU
vector, environment, hash, or device-graph line changed.

Current fake-QEMU test SHA-256:

```text
49eb1dfd5af696f8969062125dd3f0d8a8ce00abb6f8e2e817a360bc7216701c
```

Its delta is the two-line explanation plus changing the fixture system from
`HASH-test-system` to the real `HASH-system` shape. Reversing those bytes
in-memory reproduced the accepted v2 test hash
`05f755a127197fc521ce20bbe401ae6c3da504ee26d97268e0494aedb8116f0a`.
The implementer's reported 9/9 fake-QEMU pass is consistent with this focused
change; the suite was not broadly rerun here.

### What now passes

Calling private `read-fixed-append` directly, without QEMU, against the actual
staged config now succeeds. It accepts the real system path:

```text
/gnu/store/0rlw7zk22cnc4vcrlxz4c91xlphn6489-system
```

and still transforms the sole PineNote serial console to `ttyAMA0`. A temporary
config using the previous valid named shape
`/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-system` also succeeds.
Missing `root=PNGuixRoot`, duplicate `root=PNGuixRoot`, a short store hash, and
a mismatched `gnu.load` all reject before execution.

The staged extlinux config remains unchanged at
`9c37225ddc174288dfc01686f70457bc16d4ca50763e42c909edee4273b4a0b4`.
The v2 recipe remains unchanged at
`8df7875c0ce3669c9132676ad4640ef9109f9fce4411602787fbd94365f78da4`.
No baseline/image rehash was repeated.

### Concrete remaining parser bug

Two isolated APPEND vectors that must be rejected are currently accepted:

1. With the required token still present, appending a second different root,
   `root=/dev/vda`, passes. The current code counts only tokens exactly equal to
   `root=PNGuixRoot`; it does not require that this be the only `root=` token.
   Kernel command-line selection can therefore differ from the parser's stated
   root identity.
2. A matched pair such as
   `/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo/../bar-system` and that
   same text plus `/boot` passes. In POSIX regex, `.+` matches `/`, so the regex
   does not establish a top-level, traversal-free Guix store output even though
   the error and review call it canonical.

These are not new guest or hostile-profile requirements. They are direct
counterexamples to the existing parser's exact-root/canonical-system claims and
to this recheck's requested malformed-root/traversal gate. The actual staged
APPEND contains neither defect, but accepting it cannot substitute for the
explicit fail-closed parser check.

### Minimal correction and recheck

Before retrying the recipe:

- require the complete set of `root=` tokens to equal exactly
  `("root=PNGuixRoot")`;
- constrain `gnu.system` to one top-level store component after the 32-character
  hash (for example, do not permit `/` in the optional named suffix), while
  accepting both `HASH-system` and valid `HASH-name-system` forms; and
- pin direct parser tests for the actual bare form, prior named form, second
  different root, slash/`..` traversal, and mismatched `gnu.load`.

Only the runner and focused test hashes then need another quick review. The
accepted v2 system/image/baseline and recipe hashes can remain unchanged because
the recipe intentionally invokes the reviewed outer source from the frozen
worktree rather than embedding a runner hash.

No source was edited by this review. No QEMU, qemu-img, runsc, ARM64 code,
build, lowering, network, mount, hardware, SSH, UART, or deployment was used.

## APPEND parser finite-fix recheck — 2026-09-05 UTC

### Verdict

**The two remaining APPEND parser cases are closed. The first functional QEMU
attempt may be retried with the unchanged exact v2 recipe and artifacts, using
the updated outer runner at SHA-256
`15626868e8feee7b42b927eadb8536a41e91ccd7837ab0a6a809bfbf192a17db`.**

This supersedes only the blocked retry verdict immediately above. All scope
limits from the focused v2 acceptance remain: this authorizes one functional
compatibility smoke, not hostile-book isolation, production resource limits,
Book Protocol integration, release acceptance, hardware, or deployment.

### Focused inspection and counterexamples

The runner's system-output regexp is now:

```scheme
^/gnu/store/[0-9a-z]{32}-([0-9A-Za-z+._-]+-)?system$
```

It accepts both Guix's real bare `HASH-system` output and a named
`HASH-test-system` output, while its optional name component cannot contain
`/`. The root check now filters **all** `root=` tokens and requires the result
to equal exactly `("root=PNGuixRoot")`.

Private `read-fixed-append` was called directly against the unchanged staged
extlinux config. The actual accepted system path
`/gnu/store/0rlw7zk22cnc4vcrlxz4c91xlphn6489-system` passed. Both previously
surviving counterexamples now reject:

- `root=PNGuixRoot root=/dev/vda`;
- matched `gnu.system`/`gnu.load` paths containing
  `HASH-foo/../bar-system`.

The added direct-parser test covers exactly five vectors: real bare system,
named system, dual root, matched traversal, and load mismatch. That focused
test passed independently. Removing only this new test method in memory
reproduced the immediately prior test hash
`49eb1dfd5af696f8969062125dd3f0d8a8ce00abb6f8e2e817a360bc7216701c`,
confirming the test-source delta is confined to the claimed regression. The
new test SHA-256 is
`bf638e67eecfe96e857a5b7535c3008048801e7742fd9151d7d8dfe5aee024fc`.

The first attempt remains classified solely as an APPEND preparation failure
before QEMU. No new evidence implicates gVisor, the kernel, guest, or image.
The accepted v2 recipe is unchanged at
`8df7875c0ce3669c9132676ad4640ef9109f9fce4411602787fbd94365f78da4`;
its image and boot-input hashes remain as recorded above and were intentionally
not rebuilt or rehashed for this source-only recheck.

No implementation source was edited by this review. No QEMU, qemu-img, runsc,
ARM64 executable, build, lowering, network, mount, hardware, SSH, UART, or
deployment was used.

## Focused v3 two-bug pre-run review — 2026-09-05 UTC

### Verdict

**Both finite v3 corrections are accepted. The exact 600-second v3 functional
compatibility recipe is authorized.** Run only
`pinenote/tools/book-execution-spike/build/first-boot-after-v3-review.command`
at SHA-256
`fa4d454d52b4a33b98b4a0867efcb706e17962d0e0cd85f7166f809d4a886dbf`
with the source and private-artifact hashes below unchanged.

This authorizes one functional compatibility attempt. It does not establish or
expand hostile-book isolation, production cgroup limits, Book Protocol,
general output import, release, hardware, or deployment acceptance.

Focused snapshot time: **2026-09-05T02:14:01Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. Review packet:
`build/baseline-review-manifest-v3.txt`, SHA-256
`8071a62c95d56772db9e34ea7b61447ce7bf276341cb4cc364ab99576745179b`.

### What the v2 diagnostic actually proved

The bounded v2 console establishes a real QEMU boot through Linux 7.1.8,
`PNGuixRoot`, Guix system activation, and Shepherd 1.0.9. It then records, in
order:

```text
BOOKEXEC-KERNEL-IDENTITY-PASS
BOOKEXEC-NETWORK-ABSENT-PASS
BOOKEXEC-SMOKE-FAIL ... "guest exposes a forbidden host/share mount"
```

There is no forbidden-mount PASS, runsc-version PASS, or language marker.
Thus runsc and both payloads were not reached. The old synchronous halt cycle
then explains why QEMU remained alive until the 150-second outer diagnostic
timeout once the failed smoke returned.

The v2 message did not include its offending mount line. The Guix source and
realized service make the read-only `/gnu/store` self-bind the supported
explanation, but that identity is **presumed for v2, not observed in its log**.
The first actual v3 evidence for the exception must be the ordered
`BOOKEXEC-FORBIDDEN-MOUNTS-PASS` canary in the next runtime console.

### Correction 1 accepted — precise immutable-store self-bind

The v3 guest now parses Linux mountinfo fields rather than matching substrings.
It permits a `/gnu/store` entry only when all of these hold:

- mountpoint is exactly `/gnu/store`;
- mount root is exactly `/gnu/store`;
- per-mount options contain `ro` and not `rw`;
- device number, filesystem type, and source exactly match the unique `/`
  mount.

This corresponds to pinned Guix `%immutable-store`, whose realized service
bind-mounts `/gnu/store` onto itself read-only. The exception is not a general
store/share allowance. Filesystem types `9p`, `virtiofs`, `nfs`, and `nfs4`
are rejected globally before it; writable, foreign-type/source/device,
different-root, nested `/gnu/store`, and `/data` mounts reject. Malformed
mountinfo and zero or multiple root entries also fail closed.

Only the offending line enters the failure message. It is limited to 2,048
UTF-8 source bytes, escapes backslash, controls, and non-ASCII bytes, and marks
truncation. The diagnostic includes the selected root device/type but cannot
inject an unescaped control sequence or grow with the whole mountinfo file.

Independent focused tests accepted the exact Guix self-bind and ordinary
pseudo-filesystems, and rejected the four share types, foreign store,
writable store, wrong bind root, different device, nested store, `/data`, and
malformed input. The bounded/escaped diagnostic mutations also passed.

### Correction 2 accepted — supervised child owns shutdown

The smoke is now a normal, non-respawning Shepherd service using
`make-forkexec-constructor` and `make-kill-destructor`; it is no longer a
synchronous one-shot start callback. Pinned Shepherd marks the successfully
execed child running before that child performs the smoke. After
`guest-smoke-main` returns, the same supervised process:

1. calls `sync`;
2. reports and force-flushes the returned status; and
3. replaces itself with the immutable `halt` client via `execl`.

Consequently root shutdown sees a running service, not a service whose start
future is waiting on the shutdown client. It can stop that client and complete
the shutdown; the old starting-future cycle is absent. The cached private
Shepherd 1.0.9 test independently observed the service running and
non-respawning before child release, followed by root stop, service stop,
Shepherd exit, and no surviving child.

Failure cannot become success through this lifecycle. `guest-smoke-main`
catches a smoke error, force-emits one `BOOKEXEC-SMOKE-FAIL`, and returns 1;
the entry requests shutdown regardless. A direct mutation independently
observed status 1, exactly one failure sentinel, and no PASS marker. If even
failure reporting breaks, required markers remain absent. The trusted outer
parser still rejects any failure sentinel and requires every unique ordered
PASS plus clean power-down; halt status is not the success oracle.

### Exact source and realized boundary

The v3 diff files independently reverse-applied to the current
sources and reproduced the accepted v2 hashes exactly:

| Boundary | v2 SHA-256 | v3 SHA-256 | Diff SHA-256 |
|---|---|---|---|
| guest smoke | `f90ba0f62eae82ba7bd2da1a0f57005189fce4d9ab42d0101344ea9336901533` | `810ad7e27521c109fe15cde71504784d641ea50b1cdeee6dfe2f53420fc537ca` | `b210381322181787bb2d44d2f2a6b35e4e3615d7fb4abe1ef0b7c930a746ebf8` |
| system lifecycle | `fae8742c4a4fa59d6185f7dd88f9ec372a3eecf443d5bbc249939b7e67ead539` | `60922b7ee6dc0cc82e4e0c4f8e325649bde032a9aeb1f567e49addc85881ca49` | `b9aea0e95291a07da3a952965999744a5385378fed9f6d29d2c99c4ddae65ccc` |

The realized image system is
`/gnu/store/k0a2rvacjh05c1zgh723mq51gqhgw7yc-system`. Its requisite guest source
is byte-identical to reviewed v3 source at `810ad7e2…`. The realized entry and
Shepherd service hashes are respectively
`0828bde79986f19e46d390c3fb5801f7c5ec8fc85e8a504a7401b4891fd875cb`
and
`da72180d0c407a6184be683857e84c556695b867024bb410a92f0ca101f536d4`;
inspection confirms the entry's flush/sync/`execl halt` sequence and the
service's non-one-shot, non-respawning fork/exec construction.

The corrected image boundary recorded by the packet is:

```text
image:        /gnu/store/rx9pnklbcbb1mhm0dxr7f4pa46hyayfx-disk-image
image SHA-256: 41abc30779cbc4a242ea7b4a9f3b5f401f783279f77de68966533434ac2fd61b
```

The image itself was intentionally not rehashed in this focused review. The
non-mounting private-input inspector did independently pass the staged v3
directory. Its fixed tree contains only real directories and regular files:
directories are mode 0500; files are mode 0400 with link count one; no symlink
or hard-link alias is present. The inspector verified every manifest hash,
the one ext4 `PNGuixRoot` partition, and fixed APPEND identity.

| SHA-256 | Exact v3 private boundary |
|---|---|
| `3db85e1cb33a8ee382b6344ae2a03b9809340fb579e378521030fcd7aed60a3e` | private artifact `manifest.txt` |
| `f9e8d915cc963fc9984d10398b70f001b8fa10af72cb11d309428b82ab52961f` | `baseline.raw` |
| `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` | unchanged kernel Image |
| `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` | unchanged kernel config |
| `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` | unchanged DTB |
| `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` | unchanged initrd |
| `1cf0a1c3d5702ad4710d48ec82bd73c9e62a68e40c882639909ec5b341dc9494` | v3 extlinux config |

The outer diagnostic runner remains accepted and unchanged at
`e64175dd34ea5bab5e7e15f4b93c83c68875f91a39f78e14d301cf5bdf09b7b5`;
the entry remains
`354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b`.
OCI, guest-console assertions, gVisor, kernel output/config delta, profiles,
runtime flags, and QEMU device graph are unchanged and were not broadly
re-reviewed. The v3 recipe is mode 0600, passes `sh -n`, names the exact v3
private hashes, preserves fail-fast result checking, and was not executed.

There is no surviving offline blocker in these two corrections. The next run
must still earn functional success from actual runtime evidence: boot, the v3
forbidden-mount canary, live runsc/version, exact Python and Guile payload
sentinels, cgroup teardown, final smoke PASS, clean power-down, and the trusted
outer PASS/status checks.

No implementation source was edited by this review. No build, QEMU, qemu-img,
runsc, ARM64 execution, network access, mount, hardware, SSH, UART, or
deployment was performed.

## Focused v4 profile-authority review — 2026-09-05 UTC

### Verdict

**The single profile-name authority bug is closed. The exact 600-second v4
functional compatibility recipe is authorized.** Run only
`pinenote/tools/book-execution-spike/build/first-boot-after-v4-review.command`
at SHA-256
`b3fa89d672828202e4b1303e7ae1f9c2e6b0c5f2c639a7814ab97f0ef353d454`
with the reviewed source and v4 private artifacts unchanged.

This remains a functional compatibility gate. It does not add hostile-book
isolation, production limits, Book Protocol/output, release, hardware, or
deployment acceptance.

Focused snapshot time: **2026-09-05T02:40:59Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. Review packet:
`build/baseline-review-manifest-v4.txt`, SHA-256
`09f04ec69a06beeeb35132a80ab174e60e85699862637cefc64f2949cfba7979`.

### What v3 actually established

The retained v3 QEMU console proves, in order:

```text
BOOKEXEC-KERNEL-IDENTITY-PASS
BOOKEXEC-NETWORK-ABSENT-PASS
BOOKEXEC-FORBIDDEN-MOUNTS-PASS
BOOKEXEC-RUNSC-VERSION-PASS
BOOKEXEC-SMOKE-FAIL ... "profile store item lacks -profile suffix"
reboot: Power down
```

Power-down occurred at 14.114936 seconds. Thus v3 runtime-validated the kernel,
root/system boot, Shepherd lifecycle fix, no-network check, precise mount
canary, ARM64 runsc release check, and clean shutdown. It failed during OCI
input validation before `runsc` Sentry started; neither Python nor Guile ran in
a sandbox. V3 is not a compatibility PASS.

### Profile authority fix accepted

Guix profile store names are caller-selected and are not required to end in
`-profile`. The v4 OCI generator removes only that invalid suffix authority and
requires structural authority instead:

- the selected profile resolves canonically to one top-level Guix store item;
- that item is a real directory with a real regular `manifest`;
- the exact enumerated closure contains that canonical profile item;
- `bin/python3` and `bin/guile` both resolve successfully;
- each resolved target is a regular executable; and
- each target's containing top-level store item belongs to that exact closure.

Input profile aliases remain usable only because they are canonicalized to the
selected top-level store item. Requisite aliases, nested paths, duplicates, and
items outside the store remain rejected by the previously accepted closure
validator. The profile name itself no longer grants or denies authority.

The supplied v4 diff has SHA-256
`f902bb89053eba605a221f35d304958c8828a938178e0b587e04fa2553c88c1f`.
Reverse-applying it to current OCI source reproduced the accepted v3 OCI hash
`26e92e2a81c5e3f9ef6169ebe8b7150abb4b55c57cb9dc1cbd06365ece71ffd8`
exactly. The reviewed v4 OCI source hash is
`f8b09550f59a8eccf00220994885a772f20ab41a83fef02ec858578b90f919ac`.
No flag, mount, bundle lifecycle, cgroup preflight, payload, or launcher change
is present in this diff.

### Independent focused counterexamples

A separate temporary fake-store fixture exercised current Guile directly,
without runsc. A custom-named profile selected through a two-link input alias
was accepted when its regular manifest and both executable entry targets were
inside the supplied exact closure. Each of these failed before retaining a
bundle:

- missing manifest;
- manifest symlink rather than a real regular file;
- missing `bin/python3`;
- missing `bin/guile`;
- `bin/guile` resolving into a store item outside the enumerated closure; and
- a closure-member target without execute permission.

This closes the fixture-name blindness without replacing it with arbitrary
directory authority. In this image the profile and closure are immutable,
system-selected inputs—not book-selected paths.

### Actual ARM profile and generated OCI

Current Guile independently generated fresh temporary Python and Guile bundles
from the actual custom-named ARM profile:

```text
/gnu/store/kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-wilkbook-book-execution-languages
```

The trusted closure file contained 45 unique items and matched a fresh
read-only `guix gc --requisites` query exactly. The profile itself was a member;
its manifest was regular; both language targets were executable ARM64 ELF
files whose containing store items were members. No ARM file was executed.

Both independently generated OCI configs exposed exactly the 45 closure items
as read-only bind mounts plus the separate read-only/no-exec book. Python and
Guile process paths and distinct payload sentinels were correct. The generated
launch records retained the exact accepted systrap, `network=none`,
`directfs=false`, cgroup, sidecar, host-IPC, rootless, file-access, and raw-net
flags; `linux.resources` remained absent. Generated launchers still place the
cgroup preflight before runsc exec. Neither launcher nor payload was executed.

### Realized v4 and private boundary

The v4 image system is
`/gnu/store/7m9iyf4f41grj342ifkw1dlxxmnvjx0a-system`. Its requisite embedded OCI
source is byte-identical to reviewed source at `f8b09550…`; the unchanged guest
fixture is byte-identical at
`810ad7e27521c109fe15cde71504784d641ea50b1cdeee6dfe2f53420fc537ca`.
The realized Shepherd service references that exact embedded OCI object. Its
service and entry hashes are respectively
`1ac6500b51e593570c964ca2123e1e0ac5f98e99d6b641c911b452451c5a824e`
and
`0828bde79986f19e46d390c3fb5801f7c5ec8fc85e8a504a7401b4891fd875cb`.

The packet records the corrected source image as:

```text
/gnu/store/qa2lg7szbgfx3fgk9ajkngkyiwg3irc8-disk-image
SHA-256 3b060e54a02d5947a41abf3e774ab814b0384785fe209eb949abcb2090871ea3
```

The large source image was intentionally not rehashed in this focused review.
The non-mounting private-input inspector passed the staged v4 directory,
including every private manifest hash, fixed APPEND identity, and its one ext4
`PNGuixRoot` partition. Independent tree inspection found only mode-0500 real
directories and mode-0400 regular files with link count one—no aliases.

| SHA-256 | Exact v4 private boundary |
|---|---|
| `86732f72ea08047ab38262ed6fe01cc99aac706cf755b1e949d2529ab9fd1c42` | private artifact `manifest.txt` |
| `d8d3bf39b155e410eac1a906ff764185bd2da5ab8279fd008048beb657979cb8` | `baseline.raw` |
| `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` | unchanged kernel Image |
| `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` | unchanged kernel config |
| `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` | unchanged DTB |
| `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` | unchanged initrd |
| `acc95fa521f2e306c23f3c7c0555d69743b76848bb84aedc59f4c8470a7233d2` | v4 extlinux config |

The outer diagnostic runner remains unchanged at
`e64175dd34ea5bab5e7e15f4b93c83c68875f91a39f78e14d301cf5bdf09b7b5`;
its entry remains
`354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b`.
The kernel, config delta, guest fixture, system lifecycle, console parser,
profiles, QEMU graph, and other accepted components were not broadly
re-reviewed.

The v4 recipe is mode 0600, passes `sh -n`, names the exact private hashes,
retains the 600-second timeout and fail-fast outer-status check, and was not
executed. There is no remaining pre-run blocker in this profile-authority
change. Functional success still requires actual Sentry start, both exact
language payloads, cgroup cleanup, all ordered guest markers, clean power-down,
and the trusted outer PASS/status checks.

No implementation source was edited by this review. No build, QEMU, qemu-img,
runsc, ARM64 execution, external network, mount, hardware, SSH, UART, or
deployment was performed.

## Diagnostic-only outer-runner recheck — 2026-09-05 UTC

### Verdict

**Authorized: one 150-second diagnostic-only QEMU attempt using outer runner
SHA-256
`e64175dd34ea5bab5e7e15f4b93c83c68875f91a39f78e14d301cf5bdf09b7b5`,
the already accepted v2 inputs, and the already accepted runtime flags.** The
only invocation change from
`first-boot-after-guest-review-v2.command` is
`--timeout-seconds 150` instead of `600`.

This run is authorized to recover bounded boot-stage evidence, not to claim a
functional-compatibility PASS. It adds no hostile-book, production-resource,
Book Protocol, release, hardware, or deployment acceptance. If the guest does
unexpectedly produce the complete previously reviewed success evidence, that
result still requires separate disposition under the functional gate.

The review packet is
`pinenote/tools/book-execution-spike/build/first-qemu-timeout-diagnostic-review.txt`
at SHA-256
`e8bce7632519eaeaf11bad9770837861056669cd529f56cf782e8381770ddb6c`.
The original v2 recipe remains unchanged at
`8df7875c0ce3669c9132676ad4640ef9109f9fce4411602787fbd94365f78da4`;
the image and boot inputs were not rebuilt or rehashed for this review.

### Diagnostic delta accepted

Inspection against the last accepted `15626868…` runner found only the claimed
diagnostic additions: binary-port/bytevector imports, fixed 32 KiB head/tail
constants, bounded byte readers and escaped rendering, and calls on QEMU
timeout, nonzero QEMU exit, and guest-console parser failure. There is no new
CLI output path, retained run root, image path, QEMU device/flag change,
guardian-policy change, or success-path diagnostic output.

The only diagnostic source paths are the existing private
`RUN-ROOT/console.log` and `RUN-ROOT/qemu.stderr`. `run-owned-process` has
returned—and therefore the accepted guardian has reaped QEMU and its owned
group—before timeout/nonzero diagnostics run. Parser-failure diagnostics run
after zero-exit QEMU has likewise been reaped. All calls remain inside the
existing `dynamic-wind`; successful diagnostics, unavailable diagnostics, and
diagnostic exceptions all continue through identity-checked private-root
cleanup. The emitter catches its own read/render errors so they do not replace
the selected QEMU/parser failure.

For each file, source consumption is at most 65,536 bytes: the whole file when
no larger, otherwise exactly a 32,768-byte head and 32,768-byte tail with the
middle omitted. Rendering is byte-oriented. LF, CR, tab, backslash, all control
bytes, and every non-ASCII byte are escaped; every physical content line is
prefixed `| `. Thus guest bytes cannot emit a terminal escape or an unprefixed
runner diagnostic. Expansion is bounded by five output bytes per consumed
source byte plus fixed metadata—at most about 320 KiB per file, about 640 KiB
for both—not an unbounded console dump. No source log survives normal cleanup.

Two focused fake-QEMU tests were run independently:

- timeout of a TERM-resistant process group: bounded head/tail present, middle
  absent, descendants reaped, run root removed;
- zero-exit guest-parser failure with ESC, CR/LF, and invalid UTF-8 bytes:
  bytes escaped, no raw ESC, failure preserved, run root removed.

Both passed. The builder's 11/11 runner result was read as packet metadata and
was not broadly repeated. Current focused test SHA-256 is
`e06f3d755ac8541d697b080922bbccc2386f57512951a1f4bbe01154bdb78bc7`.

### Prior timeout and Shepherd source finding

The prior retained outer log contains only the 600-second timeout and failed
status check. Its private console was cleaned, so the guest boot stage remains
unknown; the timeout is not evidence against gVisor, the kernel, or any
particular guest stage.

The current image source does contain the builder-reported shutdown cycle.
The one-shot smoke runs synchronously inside its Shepherd `start` callback and
calls `halt` only after `guest-smoke-main` returns. Shepherd 1.0.9's halt client
sends root `power-off` and waits for a reply; root shutdown stops services; a
stop request for the still-`starting` smoke waits on its start future; and that
callback is waiting for `halt`. This is source-proven and reachable if the
guest completes the smoke and reaches final halt. It cannot identify the prior
timeout stage without the deleted console, so the diagnostic attempt—not an
image change—is the bounded next action authorized here.

No implementation source was edited by this review. No QEMU, qemu-img, runsc,
ARM64 executable, build, lowering, network, mount, hardware, SSH, UART, or
deployment was used.

## Focused v5 pre-sync diagnostic review — 2026-09-05 UTC

### Verdict

**Not yet suitable for the diagnostic run. Do not execute the v5 recipe.** The
in-guest diagnostic delta correctly captures bounded child stderr and gVisor
debug/panic files before guest shutdown, but the unchanged outer runner may
discard their rendered middle before its private run tree is deleted. This is
an evidence-retention blocker, not evidence of a gVisor, kernel, user-namespace,
Systrap, mount, capability, or OCI failure.

No functional compatibility is accepted here. V4 still proves only guest boot,
the kernel/network/mount canaries, ARM64 `runsc --version`, strict Sentry and
prewarmer lookup, successful return from the sandbox-child start call, the
parent-side startup-sync EOF, and clean power-down. It proves neither that the
prewarmer execed `gvisor_sentry` nor that either language payload ran.

Focused snapshot time: **2026-09-05T03:29:24Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The review began from this
document's SHA-256
`5be56f04fbb895cc73a840bbf14cd318c23749d5daa358b3fab1970b9c352c5f`.

| SHA-256 | Exact v5 review object |
|---|---|
| `e980743631fa0b5edc4145707d28d259dbd9539cc6cc3238f1c859e6d24b0237` | `build/v5-focused-review-packet.txt` |
| `7e62edcd32cfc534895dd03687ce51e42fb7ce3edba2d49686ab94005147cfcb` | `build/v5-focused-diagnostic.diff` |
| `12575b07f74cc82d7891d69e8b7c2770082b739b21871bb3af16488d7a57b811` | `build/baseline-review-manifest-v5.txt` |
| `41ffe50bcc9b256f5bb7b39396662d283d9726be782b366c375ae95a259e8ea8` | `build/v5-pinned-source-and-layout-trace.txt` |
| `55913695df71e454f41aed0e20cf945418d7e979d53e60d8b02509c0465f85f4` | `build/v5-final-aggregate.log` |
| `5d0c8545d91074208fce328886c26fe5791ed5e1d15fbb336c863b6a5b73f881` | `build/v5-realized-profile-validation.log` |
| `3473bf9acf51bd622b84b65d1ba0b26ed55d403d080cf073627b3baf9325d7c7` | private v5 `manifest.txt` |
| `9bbb0a304ebe12271e2d4680974759ac6dab3b1f8774c95e68a3f54adbd654cc` | gated `first-boot-after-v5-review.command` |

### Diagnostic delta and immutable image

The implementation part of the v4-to-v5 diff is diagnostic-only. It adds
`--debug=true`, text debug logs, `--alsologtostderr=true`, a mode-0700
bundle-local debug directory, and bundle-local debug/panic paths. It adds no
`--debug-command` filter, retry, DirectFS, ptrace, native, sidecar, networking,
rootless, cgroup-ignore, mount, or flag-override fallback. The ordered pinned
security flags in the immutable v4 and v5 OCI sources are byte-identical.
Payload arguments, OCI mounts, the 45-item closure, cgroup path and preflight,
strict sidecar/release policy, Shepherd lifecycle, and success markers are
unchanged.

The reviewed source hashes are:

| SHA-256 | Source |
|---|---|
| `fa28fb8e09b086447079d095e6b2c821f03fafc21919d861f92271315df93271` | `oci-bundle.scm` |
| `41b010ea46a413a29576be35b01acad230bb13aca1a170818b835aa6bb4fc69f` | `guest-smoke.scm` |
| `3783f94f4e9d8f37d94ab5f9e0d53e6b0175c1a9fe48a2fdb872aa24ef3f76c7` | execution-spike system |
| `e64175dd34ea5bab5e7e15f4b93c83c68875f91a39f78e14d301cf5bdf09b7b5` | unchanged outer runner |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | unchanged outer entry |
| `aa6023ddb2dae1594bdd0470e66dbb8b71b2584e314d194c9d6d7bdc3660d911` | unchanged guest-console assertions |

The realized v5 system is
`/gnu/store/3iqcxdwb38g0grwqlj201b9lfsnr75aj-system`. Its requisite embedded
sources are byte-identical to those two reviewed implementation files:
`/gnu/store/x2j3zl0s4x4ly8crlwmkwg25fjydnw5l-wilkbook-book-execution-oci-bundle.scm`
and
`/gnu/store/rmymf5dzk4yfq2xgnlib2sna0xs5br8l-wilkbook-book-execution-guest-smoke.scm`.
The image is
`/gnu/store/rglixigcv4rvhp0vikk3bxxf3b4acg6p-disk-image`, SHA-256
`38f0d63b0cfba5e1f6b2d9f77c30f3fce58e0a0e020ea03c5abfdd7bdc71e2fc`.

Independent hashing confirmed the exact private baseline and boot inputs:

| SHA-256 | Private input |
|---|---|
| `4f1e2c73e80db4d5df9339750ef4d449efdc63a2523d12331c44fe69f3ddb76b` | `baseline.raw` |
| `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` | unchanged kernel Image |
| `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` | unchanged kernel config |
| `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` | unchanged DTB |
| `e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c` | unchanged initrd |
| `778f5cc27167e0d667f18b298e4b5244c5542979820ab0ab44c483a1549f3bbd` | v5 extlinux config |

The private artifact tree contains only real mode-0500 directories and
mode-0400 one-link regular files; it has no symlinks or other aliases. The
mode-0600 recipe passes `sh -n`, names those hashes exactly, retains the
dedicated-baseline requirement and 600-second limit, and contains no device,
mount, SSH, UART, or network operation. These checks do not release its explicit
execution gate.

### What the inner diagnostics establish offline

Pinned gVisor commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2` confirms the diagnostic split:

- `sandbox.New` creates the startup pipe, starts the child, closes the parent's
  writer, and then requires one byte. EOF identifies no child stage.
- Strict `gvisor_sentry` and `gvisor-sentry-prewarmer` resolution happens before
  child start. Successful `StartInNS` return proves that the prewarmer started,
  not that its later raw `execve` of `gvisor_sentry` succeeded.
- The prewarmer writes a target-exec failure to stderr and exits 127. With
  `--debug=true`, that stderr reaches the captured `runsc-support-stderr` file.
- Before dropping child credentials, the runsc parent opens and donates the
  `boot` debug and panic files. Parent `run` and internal `gofer` debug logs are
  likewise opened from the fixed private pattern. An empty debug-command filter
  means all commands.
- `boot.Execute` writes the ready byte only after setup/re-exec, spec and mount
  processing, loader/platform/filesystem creation, and metric initialization.
  Post-exec pre-sync fatals therefore belong in the donated boot/panic evidence.

On runsc failure, the guest waits for or kills and reaps its owned process group,
then emits runsc status, cgroup/runtime-root presence, bounded 8 KiB head and
8 KiB tail ranges for stdout/stderr, at most twelve sorted debug/panic entries,
and bounded dmesg before reporting the original failure and shutting down. File
errors fail soft. Source newlines, controls, backslashes, and non-ASCII bytes are
escaped; rendered data lines are prefixed, so captured contents cannot create an
exact success line. Existing per-process `RLIMIT_FSIZE` bounds each source log
at 4 MiB.

Focused host-only checks passed for diagnostic truncation/escaping/error paths,
the twelve-file cap, exact-marker non-spoofing, Python generation determinism,
and Guile/Python policy-oracle equality. The Guile checks used only the cached
v5 supervisor profile's architecture-independent `guile-json` source with the
ambient host Guile; no ARM executable was run. An initial ambient Guile attempt
lacked `(json)` and exercised no fixture code; it was rerun correctly before
this verdict.

### Blocking end-to-end retention defect

The unchanged outer runner does not preserve the complete bounded guest
diagnostic stream. On the expected guest-console assertion failure it emits
only a 32 KiB head and 32 KiB tail from private `console.log`. Its surrounding
`dynamic-wind` then recursively deletes the private run root. The gated recipe
does not name any other retained console or diagnostic destination.

V5's inner bound is much larger than that outer 64 KiB window. Each file can
render up to 16 KiB of source bytes, with up to five output bytes per source
byte; up to twelve debug/panic files are allowed, in addition to runsc stdout,
support stderr, and dmesg. Thus even though every individual emission is finite,
one or more `run`, `boot`, `gofer`, panic, or prewarmer records can fall entirely
inside the outer runner's discarded middle. Expected small logs do not prove
otherwise, and the missing child fatal is the sole purpose of v5.

Before authorization, the reviewed recipe must guarantee that every selected
bounded child/debug artifact needed to classify the pre-sync failure reaches
retained parent evidence before outer cleanup. This can be satisfied by a
focused, bounded retention correction; it does not justify changing the
accepted kernel, outer QEMU device graph, security flags, OCI data encoding, or
runtime profile.

### Root-cause hypotheses remain unproven

There is still no root-cause finding. Pinned control flow leaves several
classes open: the prewarmer may fail or be signalled before/while execing
`gvisor_sentry`; the Sentry may issue a fatal or panic during userns/credential,
chroot, spec/mount, Systrap/seccomp, loader/filesystem, or metrics setup; or the
child may be terminated by a host-kernel signal/OOM condition. Bundle mode,
UID/GID 65534, QEMU CPU behavior, and every named kernel feature remain
hypotheses only. None supports a configuration delta or fallback before the
child evidence is retained.

No implementation source was edited by this review. No build, QEMU, qemu-img,
runsc, ARM64 executable, external network, mount, hardware, SSH, UART, or
deployment was performed.

## Focused v5 outer-retention recheck — 2026-09-05 UTC

### Verdict

**The outer truncation blocker is closed. The retention correction is accepted
for the separately authorized v5 diagnostic-only run.** This acceptance does
not itself authorize execution and does not establish functional compatibility,
hostile-book isolation, production resource limits, Book Protocol/output,
release, hardware, or deployment acceptance.

Focused snapshot time: **2026-09-05T03:56:18Z**. Repository base remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. This recheck began from the prior
review document at SHA-256
`72368b400b86f31b0eb62e3565ab9a670059e39739e777b0db2569a96362bb75`.

| SHA-256 | Exact focused object |
|---|---|
| `19c7c02cf18d5c2a96d0470422f141b513a9834406cf3b1f203c4ac6c9bba79d` | `build/v5-outer-retention-review/focused-review-packet.txt` |
| `256f6bd5782764f9ae50aa2dda3fa7a43beb87e411d82fb113b216d201d05b70` | focused outer-retention diff |
| `ff8d2b0a0ccbdf78ceb596b57ca6d67b49ad37b05e12b64130d5a30c8744d90a` | focused manifest |
| `b10d2b92488dec7f4fe419e05d4a248fa2c6112a21e6c5516653ca71785685e0` | supplied 32-test host log |
| `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` | accepted corrected `disposable-qemu.scm` |
| `fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908` | bounded guest-console checker |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | unchanged outer CLI entry |
| `9bbb0a304ebe12271e2d4680974759ac6dab3b1f8774c95e68a3f54adbd654cc` | unchanged gated v5 recipe |

Reverse dry-running the supplied diff against current source succeeded for all
five listed files. Its only executable changes are the focused runner retention
path, the checker's bounded whole-port read, and host regressions; the remaining
changes are documentation. The pre-correction snapshots match the formerly
accepted runner/checker/test hashes. The v5 guest and OCI sources remain
byte-identical at `41b010ea…` and `fa28fb8e…`; the image, accepted kernel,
runtime flags, QEMU argv, guardian, cleanup, and recipe are unchanged.

### Bound and lifecycle recheck

The 3,423,172-byte full-console source limit correctly covers every selected v5
guest file channel:

```text
16 × (8192 + 8192) × 5 = 1,310,720
12 × 255 × 5          =    15,300
selected-data maximum = 1,326,020
boot/framing headroom = 2,097,152
source limit          = 3,423,172 bytes
```

The sixteen channels are runsc stdout, runsc/support/prewarmer stderr, at most
twelve selected debug/panic files, and dmesg stdout/stderr. Per-file metadata,
prefixes, fixed canaries, status/failure records, boot, Shepherd, and shutdown
output consume the separate 2 MiB headroom. That headroom is about 98 times the
preserved 21,338-byte v4 raw console and is reasonable for this unchanged
kernel/image. Exceeding it is an explicit failed diagnostic rather than silent
loss.

The guest byte renderer expands by at most five bytes per selected source byte:
LF is the worst case because its escaped spelling plus physical line break and
new prefix totals five; controls and non-ASCII bytes use four, backslash uses
two, and ordinary ASCII uses one. Generated ext4 filenames are at most 255
source bytes and use the same renderer. The outer renderer independently has
the same five-times ceiling, so full-console content can contribute at most
17,115,860 parent-stderr bytes. It streams from the source bytevector and does
not construct that expanded copy in memory.

The exporter reads at most source-limit plus one byte—3,423,173 bytes—after
QEMU and owned descendants have been reaped. Within the limit it emits the
whole escaped console and checks the file identity, size, mtime, and ctime after
export. Overflow emits
`BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE ... state=overflow`; mutation emits
`state=changed`; read failure emits `state=unavailable`. Missing and non-regular
console states are also explicit. Every path remains a failure and therefore
cannot synthesize outer success. The completed-console path performs the same
limit-plus-one preflight before parsing; the parser's independent 16 MiB limit
now also uses `get-string-n` rather than an unbounded whole-port read.

The path remains the runner-generated private `RUN-ROOT/console.log`; no output
destination or arbitrary retained-root option was added. `qemu.stderr` keeps
its accepted 32 KiB head/tail bound. Export still occurs inside the existing
`dynamic-wind` before identity-checked private-root deletion. Guardian,
process-group reaping, and cleanup source are untouched.

### Independent focused tests

Two host-only fake-command tests were independently rerun from current source:

- a parser failure with the fatal beyond 64 KiB and sixteen distributed v5
  evidence tokens exported the head, middle fatal, every token, and tail, then
  removed the private run root;
- a console over the full-retention limit emitted the explicit incomplete
  overflow record, emitted no console completion or outer success, and removed
  the private run root.

Both passed. The supplied log's broader 8 Guile-policy, 14 outer-runner, and 10
guest tests also all report PASS, including owner-`SIGKILL` guardian and
TERM-resistant descendant coverage; those already-closed surrounding suites
were not broadly rerun here.

The exact candidate boundary for separate parent authorization is therefore:

```text
outer runner  0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca
v5 recipe     9bbb0a304ebe12271e2d4680974759ac6dab3b1f8774c95e68a3f54adbd654cc
```

The run remains diagnostic-only. The v4 startup EOF has no established root
cause, and this correction creates no production prerequisite or basis for a
kernel/configuration change or compatibility fallback.

No implementation source was edited by this review. No build, real QEMU,
qemu-img, runsc, ARM64 executable, external network, mount, hardware, SSH,
UART, or deployment was performed.

## V5 retained-panic source analysis — 2026-09-05 UTC

### Finding

V5 replaced the generic parent EOF with a concrete cause at the Sentry layer:
the ARM64 `gvisor_sentry` executed, completed the pre-platform loader work, and
panicked while initializing Systrap's **source-pool subprocess syscall thread**.
The trace is against pinned commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2` and runtime output
`/gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0`.
The retained log is `/tmp/opencode/wilkbook-qemu-v5-diagnostic.GABjDe.log`,
SHA-256 `db9ba050d605fb611756d2f0a2a7024926807aa9070cb6dee6f8c86dd3ed819f`.
It records the complete panic file and stack:

```text
panic: failed to create a syscall thread
systrap.(*subprocess).initSyscallThread  subprocess.go:219
systrap.newSubprocess                     subprocess.go:379
systrap.New.func1                         systrap.go:316
boot.createPlatform                      loader.go:1094
```

This is now an evidenced failure class, not a hypothesis. It excludes a
prewarmer target-exec failure, a parent-only startup handshake failure, an
external signal/OOM kill, and failures before spec/resolved-mount processing.
It occurred before either payload and before the Sentry ready byte. Python,
Guile, and cgroup-teardown PASS markers remain absent. Guest failure handling
then remounted the root read-only and powered down cleanly at 15.667798 kernel
seconds; outer status remained failure.

The wording “create a syscall thread” is broader than the exact code. No
syscall-thread `clone` returned nil here. `newSubprocess` had already created
the initial traced stub; `initSyscallThread` obtained stack ID 0 and repurposed
that existing stub as the syscall thread. A failed stack-pool allocation would
have produced the different panic `unable to allocate a sysmsg stub thread`,
and a failed initial `createStub` would have returned from `newSubprocess`
before line 379. Both are excluded by the observed stack.

With the observed `seccompNotify=false`, only these non-panicking error returns
from `syscallThread.init` can reach the generic line-219 panic:

1. `MemoryFile.Allocate(8192, TopDown)` fails. Since this is the first
   allocation from the newly created Systrap memory file and allocation mode is
   uncommitted, its live fallible path is expansion of the memfd to one 1 GiB
   chunk: `ftruncate(1 GiB)` or a 1 GiB shared Sentry mapping.
2. The ptrace-injected read-only fixed mapping of the first 4 KiB message page
   into the stub returns a syscall errno.
3. The ptrace-injected read/write fixed mapping of the second 4 KiB message
   page into the stub returns a syscall errno.
4. The final non-fixed shared 8 KiB mapping of both pages into the Sentry
   returns a syscall errno.

The seccomp-user-notification installation branch is not reachable because the
stack records the third `initSyscallThread` argument as zero and the source-pool
call is `newSubprocess(createStub, mf, false)`. Ptrace transport failures while
setting/getting registers, continuing, or waiting would themselves panic with
specific `ptrace ... failed` text; none can be converted into the retained
generic panic. If either fixed mmap returned an errno, its cleanup also
completed without replacing the panic with the distinct `munmap failed` panic.

The underlying `err` is deliberately discarded at line 219. The retained boot
head/tail therefore cannot distinguish the four sites or recover an errno. Its
37,418-byte middle is elided, as are 31,944 bytes of parent stderr, so values
not present in the selected ranges remain unknown. What is retained is enough
to pin: release `20260831.0`, ARM64, 4 KiB pages, four CPUs, Systrap,
`directfs=false`, network none, Sentry UID/GID 65534, parent ambient capability
numbers `[21 18 8 19]`, successful memory-file and stub-initialization
milestones, and the generated stub addresses. The complete panic contains no
underlying errno. Dmesg contains no runtime OOM or kernel fault; its 1,945-byte
elision lies between 0.122 and 0.198 boot seconds, before this failure.

### Prerequisite and QEMU boundary

The accepted config remains exactly
`0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309`
and its Image remains
`f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223`.
It has ARM64/64-bit/MMU/4 KiB pages, user/PID/network/IPC/UTS namespaces,
seccomp and seccomp-filter with the ARM64 filter hook, memfd/shmem/tmpfs,
futex, `KCMP`, checkpoint/restore, and procfs. `CONFIG_BPF_SYSCALL=n`,
`CONFIG_USERFAULTFD=n`, and `CONFIG_SECURITY=n` do not disable the classic-BPF
seccomp, ptrace, mmap, or memfd operations in this reached path.

Systrap declares `CAP_SYS_PTRACE` as its sole platform capability requirement.
The launch record contains ambient capabilities 21/18/8/19
(`SYS_ADMIN`, `SYS_CHROOT`, `SETPCAP`, `SYS_PTRACE`), and execution got farther
than a static-capability assertion: the initial child installed its restrictive
seccomp filter, stopped, was attached, had ptrace options and registers
initialized, and completed an injected `munmap`. Thus a blanket “ptrace or
seccomp is unavailable” diagnosis is contradicted. This does not prove which
of the later mmap/allocation operations returned an error.

The failure is presently QEMU-specific evidence, not PineNote evidence. The
frozen runner uses `-cpu max`; V5 reports MIDR `0x000f0510`, LPA2 and 52-bit
virtual addressing. The pinned gVisor probes host task size and selected its
52-bit ARM64 path, confirmed by stub addresses above `1<<48` such as
`0xff2dc9c3ef000`. Existing PineNote hardware evidence records MIDR
`0x412fd050` (Cortex-A55) and does not report LPA2/52-bit VA
(`doc/artifacts/pinenote-deep-suspend-hang-20260802/dmesg-pre.txt`, kernel
7.0.11; this is CPU evidence, not a claim that it ran the accepted test
kernel). The exact 7.1.8 kernel source and 52-bit-capable config fall back
through `vabits_actual` on hardware without that feature. Therefore this run
neither proves that the PineNote takes the failing address-space path nor proves
that QEMU caused the failure: the unresolved allocation and Sentry-local mmap
sites are not intrinsically 52-bit-specific.

### Smallest discriminating probe

The panic narrows the subsystem enough, but not the root cause enough for any
kernel, privilege, profile, or fallback change. The next evidence should be a
diagnostic-only build of the exact pinned gVisor source which preserves the
error at line 219 and assigns distinct stage names to: memory-file allocation
(including 1 GiB truncate versus chunk mmap), stub RO mmap, stub RW mmap, and
Sentry mmap. One bounded internal record should include stage, errno, detected
`linux.TaskSize`, requested address/length, and backing-file offset. No OCI,
mount, network, credential, capability, kernel, or execution-profile change is
needed to obtain that distinction.

For a smaller reproducer than the full book smoke, pinned
`pkg/sentry/platform/systrap/systrap_test.go` already enters the same path by
calling `New(platform.Options{...})`; a single instrumented ARM64 test case
under the same user-namespace/capability envelope is sufficient. First run it
with the frozen QEMU `max` CPU. Only if the result identifies one of the high
fixed stub mappings should a separate diagnostic A/B use a Cortex-A55 CPU
model, with every other guest and QEMU input fixed, to test the 52-bit/QEMU
hypothesis without consuming hardware time. That A/B would be probe evidence,
not a change to the accepted functional runner.

The accepted v5 image and runner remain frozen, and no rerun is authorized by
this analysis. No implementation source was edited. No build, QEMU, runsc,
network, mount, hardware, SSH, UART, or device operation was performed.

## Proposed v6 Systrap error-context patch review — 2026-09-05 UTC

### Verdict

**Do not build the patch as submitted.** Patch SHA-256
`1e4eb93a490691eca102a6ce57d9e70db6d82b19de94f3dadb6be5002cfaa6e2`
applies cleanly to exact commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`, follows the five evidenced
operations, and leaves their calls and cleanup ordering unchanged. Two small
message-only corrections are required before a diagnostic build:

1. The backing-chunk mmap wrapper uses `%v`, losing the original `unix.Errno`
   identity for every `MemoryFile.Allocate` caller. It must use `%w`.
2. The messages name all five operations but omit the task size and the
   requested address/length/file offset needed to interpret an ARM64 52-bit
   failure without relying on a possibly elided debug-log line.

No patch hunk changes a syscall number, mmap protection/flag/argument, seccomp
rule, address calculation, allocation direction/mode, profile, or OCI input.
The read/write stub branch's explicit `return nil` is equivalent to the former
`return err` when `err == nil`. All existing `destroy` calls remain in the same
places and the success path performs no new formatting.

The added formatting is safe in context. `extendChunksLocked`,
`initSyscallThread`, `syscallThread.init`, and `mapMessageIntoStub` are normal
parent-side Go functions. None is `//go:nosplit`, `//go:norace`, or the
post-fork child routine. Holding `MemoryFile.mu` or locking the runtime OS
thread does not impose a no-allocation rule; the pinned code already uses
`fmt.Errorf`/`fmt.Sprintf` on neighboring failure paths. All new allocation is
failure-only. `fmt` is already imported by all three files.

### Minimal required hunk correction

Revise only the proposed added return/panic lines as follows; no new import is
needed:

```diff
- return fmt.Errorf("truncate MemoryFile backing to %#x bytes: %w", newFileSize, err)
+ return fmt.Errorf("truncate MemoryFile backing old-size=%#x new-size=%#x: %w", oldFileSize, newFileSize, err)

- return fmt.Errorf("map MemoryFile backing chunk: %v", errno)
+ return fmt.Errorf("map MemoryFile backing chunk addr-hint=0 length=%#x offset=%#x: %w", incFileSize, oldFileSize, errno)

- panic(fmt.Sprintf("failed to initialize a syscall thread: %v", err))
+ panic(fmt.Sprintf("failed to initialize a syscall thread task-size=%#x: %v", maximumUserAddress, err))

- return fmt.Errorf("allocate syscall-thread message: %w", err)
+ return fmt.Errorf("allocate syscall-thread message length=%#x: %w", syscallThreadMessageSize, err)

- return fmt.Errorf("map syscall-thread message into sentry: %v", errno)
+ return fmt.Errorf("map syscall-thread message into sentry addr-hint=0 length=%#x offset=%#x: %v", syscallThreadMessageSize, fr.Start, errno)

- return fmt.Errorf("map read-only syscall-thread page into stub: %w", err)
+ return fmt.Errorf("map read-only syscall-thread page into stub addr=%#x length=%#x offset=%#x: %w", t.stubAddr, hostarch.PageSize, t.stackRange.Start, err)

- return fmt.Errorf("map read-write syscall-thread page into stub: %w", err)
+ return fmt.Errorf("map read-write syscall-thread page into stub addr=%#x length=%#x offset=%#x: %w", t.stubAddr+syscallStubMessageOffset, hostarch.PageSize, t.stackRange.Start+hostarch.PageSize, err)
```

This yields one finite panic record containing the exact failed operation,
errno text, detected task-size boundary, mapping address or hint, length, and
backing offset. The truncate record has old/new size rather than inapplicable
mapping fields. `%w` preserves standard `errors.Is`/`errors.As` behavior on the
two newly wrapped low-level errors; the final panic still renders them with
`%v`. The Sentry mmap retains the pinned function's existing non-wrapping
error semantics while adding values.

### Source-build control requirement

The shipping input is an upstream prebuilt release binary, whereas v6 would be
a Guix/Bazel source build. Compiler, Go runtime, linker, Bazel configuration,
layout, and timing could therefore change the very allocation/mmap behavior
being diagnosed. The errno from a patched source build cannot by itself be
assigned to the prebuilt release.

A matched unpatched source-built control is required unless the builder first
reproduces the shipped `gvisor_sentry` byte-for-byte. This does **not** require
two complete kernel/closure/image builds: build only matched unpatched and
patched `gvisor_sentry` targets with the identical pinned source, toolchain,
Bazel options, and resource limits, and share all possible surrounding inputs.
The builder still must propose how both binaries receive otherwise identical
immutable guest invocations; this review does not assume that the accepted
image can be modified in place. The control must reproduce the same line-219
Systrap panic under the frozen v5 envelope before the patched twin's
stage/errno is treated as an explanation of v5. If the control differs, stop
and classify a build/toolchain confound.

No CPU-model A/B is justified yet. Consider it only if the corrected record
selects a high fixed stub mmap and supplies an address/errno consistent with
that hypothesis. This review does not establish source-build feasibility or
authorize a build or execution.

No implementation source was edited. No build, QEMU, runsc, network, mount,
hardware, SSH, UART, or device operation was performed.

## Corrected v2 patch and source-build recipe review — 2026-09-05 UTC

### Diagnostic patch verdict

**Accepted for the diagnostic source build only.** Patch SHA-256
`9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e`
applies with `--whitespace=error-all` to the clean exact commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2`. It closes both finite
obligations from the preceding review:

1. The MemoryFile backing-chunk mmap error is wrapped with `%w`, preserving
   the original `unix.Errno` identity.
2. The complete panic chain now carries the detected task size and the
   applicable bounded numeric context: truncate old/new sizes; backing mmap
   address hint, length, and offset; message-allocation length; stub RO/RW
   addresses, lengths, and offsets; and Sentry mmap address hint, length, and
   offset.

The patch still changes only failure messages. It changes no syscall,
argument, protection, flag, address calculation, allocation policy, seccomp
rule, success path, or cleanup order. This verdict authorizes compiling the
matched diagnostic Sentry; it does not authorize an image or runtime.

### Frozen source-build v2 recipe verdict

**Finite blocker; do not authorize recipe SHA-256
`8b5e001c2267fc31ed440d173fc30809f46e0bb80c506b93ff126182043aba5c`.**
At the pinned Guix revision, bare `gcc-toolchain` resolves to 16.1.0, but the
recipe immediately requires `gcc -dumpfullversion` to equal 14.3.0. The
explicit AArch64 cross compiler correctly selects `gcc-14`; the native shell
input must likewise select `gcc-toolchain@14.3.0`, which is available at the
pinned revision. Without that correction the command deterministically stops
at its native-GCC version gate before Bazel starts.

No other static command, target, output-path, or stamping blocker was found in
this snapshot. In particular, the exact source declares `//:release` as the
six-file release assembly and
`//runsc/cmd/sentry:gvisor_sentry` as the diagnostic-only target; the release
rule writes under `bazel-bin/release`, and the pinned rules_go output naming
places the direct binary at
`bazel-bin/runsc/cmd/sentry/gvisor_sentry_/gvisor_sentry`. The workspace rc
enables stamping, while the later command-line workspace-status override fixes
`STABLE_VERSION` to `release-20260831.0`. The control creates the initially
absent Bzlmod lock; the diagnostic receives the same read-only lock in
error-on-change mode and uses the same Bazel, Guix toolchain, options,
repository cache, action cache, two-core/two-action limits, and sequential
one-job Guix realization envelope. The complete diagnostic release is copied
from the complete control release and substitutes only the diagnostic Sentry;
the exact six-member, architecture, static-link, version, Go-toolchain, and
non-Sentry identity gates are appropriate for future STRICT/ALWAYS use.

The worktree-aware Git checks, private frozen recipe copy and hash,
`--no-cwd` container boundary, read-only prerequisite exposure, `/bin/sh`
handoff, existing-root refusal, separate recipe-hash authorization, and finite
six-hour/two-hour/twelve-hour limits address the two previously reported
entrypoint defects. After changing only the native GCC package specification,
the resulting new recipe hash still requires a final identity check before a
parent may authorize: the hash-pinned official Bazel 8.3.1 download/staging,
the pinned Guix gold/Python/toolchain realizations, and the bounded control plus
diagnostic source builds only.

Even after a successful build, no runtime is implied. Unless the source-built
control Sentry is byte-identical to the official release Sentry, the complete
source-built control must first reproduce the v5 line-219 Systrap panic under
the frozen envelope. Stop on any different result. Only that later, separately
authorized control result can permit a diagnostic runtime and attribution of
its stage/errno to v5.

No implementation or gVisor source was edited. No Bazel/Guix realization,
fetch, compilation, image build, QEMU, runsc, network, mount, hardware, SSH,
UART, or device operation was performed.

### Frozen source-build v3 identity check

**Finite blocker; do not authorize recipe SHA-256
`52cafcff32a67a18199abb8ab772d51e4a92001b3dc58bcee0615e2257e2935c`.**
Its only byte-level change from the rejected v2 recipe is the required
`gcc-toolchain` to `gcc-toolchain@14.3.0` correction, and its POSIX-shell
syntax checks pass. However, the renamed v3 file still assigns both `recipe`
and `frozen_recipe` to the `proposed-v6-source-build-v2.command` basename.
When v3 is invoked, its own SHA is therefore compared with v2's SHA at the
canonical-recipe gate and the command stops before Guix. Change those two
self-reference basenames to v3, issue a new recipe hash, and recheck that
finite identity correction. Diagnostic patch SHA-256
`9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e`
remains accepted for the source build.

No build, fetch, VM, or source edit was performed.

### Corrected frozen source-build v3 verdict

**Accepted for the bootstrap/prerequisite realization and bounded source builds
only.** Final recipe SHA-256
`e1ac43bd36c9d720568e752249efa5ba4a746e1e609a1f8b38d209cce7612984`
differs from the reviewed v2 recipe only in the three required v3
self-reference basenames and the required
`gcc-toolchain@14.3.0` package pin. Both shell syntax checks pass, all three
self-identities name v3, and the prior deterministic entrypoint and native-GCC
blockers are closed.

This verdict permits the separately authorized hash-pinned Bazel 8.3.1
download/staging, pinned Guix prerequisite realizations, and the recipe's
bounded complete control plus diagnostic-Sentry source builds. It does not
authorize image construction, QEMU, runsc, or any runtime. Diagnostic patch
SHA-256 `9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e`
remains the accepted patch. The source-built control reproduction gate remains
mandatory after the build unless its Sentry is byte-identical to the official
release Sentry.

No build, fetch, VM, or source edit was performed by this review.
