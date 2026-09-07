# Disposition of the 2026-09-04 book-execution adversarial review

**Date:** 2026-09-04

**Scope:** follow-up implementation and host-only checks

**Reviewed report:**
[`2026-09-04-book-execution-adversarial.md`](2026-09-04-book-execution-adversarial.md)

This is a separate disposition record. The original review remains unchanged.
“Addressed” below describes local implementation or bookkeeping only; it does
not turn an unrun runtime gate into acceptance evidence.

| Finding | Disposition |
|---|---|
| 1/10 — DirectFS/kernel mismatch | **Implementation and build gate corrected; acceptance open.** Both explicit profiles record `CONFIG_USER_NS=y`: pinned gVisor adds a user namespace for DirectFS plus `network=none`, while the non-DirectFS support-process branch creates one too. The one-option non-shipping PineNote test kernel built without editing the permanent patch or shipping kernel. Its complete installed-config diff against the exact base output is only `CONFIG_USER_NS: n -> y`. There is no default, networking relaxation, test-flag, or fallback. Prefer `isolation-userns` for the first compatibility run; neither profile has runtime or isolation evidence. |
| 2 — sidecar fallback default | **Claim and launcher corrected; runtime gate open.** Package/docs now say the pinned `DEFAULT` permits embedded fallback. Both profiles pin strict sidecar use and always-on release matching, and `runsc` is emitted under `env -i` without `GVISOR_ENFORCE_RELEASE`. An in-guest resolved-helper observation and missing-sidecar negative run remain required. |
| 3 — unsafe QEMU envelope | **Process boundary independently accepted; narrow guest-check hook awaits re-review.** `run-disposable-qemu.scm` pins `-nic none`, TCG, no user config/default devices, private mode-0700 state/console/environment, SHA-verified private copies of every boot input and the raw baseline, and a private qcow2 overlay with explicit raw backing format. The focused recheck accepted the process/run-root guardians at `disposable-qemu.scm` SHA-256 `25812ffd…`. The current `318e437d…` source retains those mechanisms and adds only the required post-exit bounded console callback before guarded cleanup. Nine fake-QEMU methods cover valid, missing-marker, forbidden-marker, timeout, signal, descendant, and owner-`SIGKILL` paths with no fixture process or run-root residue. No real QEMU command, login, or boot result exists. |
| 4 — narrow filesystem/output contract | **Partially implemented.** The generator mounts only the selected profile's canonical `guix gc --requisites` objects plus one canonical immutable store file; the root/input/closure are read-only, scratch is a size-declared tmpfs, and forbidden broad paths/devices/state are absent in host tests. The fixed compatibility fixture now captures and exactly checks distinct computed Python/Guile diagnostic sentinels; this is not a general output-import path or the Book Protocol. Bounded product output import and runtime mount/canary evidence remain open. |
| 5/11 — cgroup plumbing and whole-domain budgets | **Preflight correction independently accepted; budgets remain later.** The system declares cgroup2, OCI names one run-owned `cgroupsPath`, and the generated Guile launcher checks root, exact cgroup2 mount presence, child create/remove ability, and stale-target absence before `runsc --ignore-cgroups=false`. The focused recheck accepted fatal normal-path probe-removal failure at `oci-bundle.scm` SHA-256 `0cbbdb0d…`. `linux.resources` remains intentionally absent, so this can establish membership only, not CPU/memory/PID ceilings. Those production ceilings are not prerequisites for the first compatibility smoke; runtime membership and teardown observations still belong in later evidence. |
| 6 — inherited-FD transport | **Open.** The compatibility smoke does not use stdout as a protocol and introduces no filesystem socket. Private inherited-FD ownership, framing integration, backpressure, and lifecycle tests remain with the protocol/integration work. |
| 7 — package checker false green | **Addressed for the host gate.** The checker evaluates `%gvisor-release-members` and compares exact sorted content to the external six-file manifest. Mutation tests remove and add every member in turn and replace `gvisor-bin/` with a symlink; all mutations are rejected. This is not runtime helper-resolution evidence. |
| 8 — inconsistent realization record | **Addressed for the current definition.** Pinned queries and installed-output inspection identify the tuple below; `guix gc --derivers` returns the same derivation. |
| 9 — release authenticity/source correspondence | **Open deferred production policy.** No new provenance claim is made. |

## Current queried package tuple

```text
package definition SHA-256: 8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d
derivation: /gnu/store/x8k6gpr9cv9h77gagbdjrvqsvk7n1gw4-gvisor-bin-20260831.0.drv
output:     /gnu/store/8wgxl0a0092i88hzmgcx9kmnjilrdbn8-gvisor-bin-20260831.0
```

The output checker found the exact six-file layout and six static AArch64
ELFs. Recomputed member SHA-256 values match the table in the original review.
The current non-shipping USER_NS test-kernel package and output are:

```text
/gnu/store/6xgyq3awmj54ks6w7mm27qc69sail51r-linux-pinenote-book-execution-test-7.1.8-pinenote.drv
/gnu/store/4d614dvj4lw6kpif8cmgnlifk2kyvc9d-linux-pinenote-book-execution-test-7.1.8-pinenote
```

The authorized exact cross-build completed with `--cores=2 --max-jobs=1`. Its
installed `.config` SHA-256 is
`0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309`;
its `Image` SHA-256 is
`f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223`.
The complete configured-symbol delta against base output
`/gnu/store/i905hja13pr2iv9kqwbdvij3c63jrsd8-linux-pinenote-7.1.8-pinenote`
is exactly `CONFIG_USER_NS: n -> y`. The already-realized gVisor tuple above
remains unchanged.

A cached generic alternative was inspected without running it:
`vvyar1rc5rjk43q647i43a2r848cc2r4-linux-libre-7.0.11/Image` is ARM64 and has
USER_NS, cgroup memory/PID/CPU accounting, and seccomp filters enabled. It can
avoid the PineNote-kernel build for a userspace-only gVisor run, but the operator
explicitly rejected that weaker shortcut for the first run. No generic image or
kernel was built. The old generic VM around it is independently unacceptable
because its launcher shares all of host `/gnu/store` over 9p and does not pin
`-nic none`.

## Checks actually run

```sh
pinenote/tools/book-execution-spike/run-tests.sh
pinenote/tools/book-execution-spike/check-gvisor-package.sh --derivation

guix shell binutils zstd -- \
  pinenote/tools/book-execution-spike/check-gvisor-package.sh \
    --archive /tmp/opencode/wilkbook-gvisor-release-20260831.0/gvisor-aarch64.tar.zstd \
    --sha256sums /tmp/opencode/wilkbook-gvisor-release-20260831.0/SHA256SUMS \
    --sha512sums /tmp/opencode/wilkbook-gvisor-release-20260831.0/SHA512SUMS

out=$(guix time-machine -C channels.scm -- \
  build --no-grafts --cores=2 --max-jobs=1 -L . \
  --target=aarch64-linux-gnu \
  -e '(@ (pinenote packages gvisor) gvisor-bin)')
guix shell binutils zstd -- \
  pinenote/tools/book-execution-spike/check-gvisor-package.sh --output "$out"
guix gc --derivers "$out"

guix time-machine -C channels.scm -- \
  repl -L . -q \
  pinenote/tools/book-execution-spike/check-execution-system.scm
```

The current cheap aggregate passed 10 retained Python OCI-oracle tests, 3 exact
kernel-config mutation tests, 6 Guile-generator/oracle tests, 9 Guile
disposable-QEMU tests, 6 guest-fixture/parser tests, and 3 package mutation
methods (including all per-member subtests), plus static package and system
checks. Guile tests compare parsed OCI/launch policy with the Python
oracle, prove both profile records require USER_NS, exercise every C0 control
plus supplementary Unicode through `guile-json` 4.7.3 `#:unicode #t`, and check
fail-closed inputs. QEMU tests execute fake commands only; they assert exact
arguments, all four input hashes, sanitized environment, run-parent identity,
closure of a deliberately inherited descriptor, recovery from inherited
`SIGCHLD=SIG_IGN`, exact accepted guest markers, rejection of missing/forbidden
markers, and resistant-child cleanup. Guest fixture tests additionally prove
that exit-zero `run.sh` with empty, cross-language, wrong-count, or duplicate
payload output cannot emit a language PASS marker. The archive, package
derivation, and installed-output gates passed.
The historical real
workstation-profile replay emitted 844 mounts but is explicitly rejected as an
approved fixture; the retained narrow AArch64 profile has not been realized.

The exact USER_NS kernel, dedicated system closure, and raw image were built.
The image was copied privately, its sole ext4 partition relabelled from the
generic intermediate's `Guix_image` to `PNGuixRoot`, and its immutable boot
bundle and hashes staged beneath the gitignored tool build directory. No real
QEMU machine was started. No ARM64 `runsc`, guest interpreter, device, SSH,
UART, deployment, or hardware operation ran. The focused Guile recheck accepts
the two corrected runner findings only; the exact new guest assertion and
baseline snapshot still needs its own review and is not isolation acceptance.

## Initial Guile review boundary

These hashes identify the implementation that passed the aggregate above:

| SHA-256 | File |
|---|---|
| `d294f9391733e4db2274d2ce1e387d21cdb9f847122e4aa4b55e9d56c53d5a94` | `pinenote/tools/book-execution-spike/oci-bundle.scm` |
| `ef3b554ad8aa03126f8134669e8d600835f648271748bd50edf2464f5024d7c4` | `pinenote/tools/book-execution-spike/generate-oci-bundle.scm` |
| `123355ca88de19435a48f9137503ab7fcf3bfbfc69287a1474cc420c100b6362` | `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` |
| `ef918c5b0465b08d326dd98a404dbc67dc4e6894d82b896c2c9c04530ff44545` | `pinenote/tools/book-execution-spike/test_guile_oci_bundle.py` |
| `36d7d8904f88d414025968de0e07b9dd57ae686235bf30a6188ee968749f2abb` | `pinenote/tools/book-execution-spike/test_disposable_qemu.py` |
| `5a4d2d84cf8fcacd3180b7496ebeceb19cfe87de4719b429a2875f7b28dae71e` | `pinenote/systems/pinenote-book-execution-spike.scm` |

Process conventions were checked against repository-pinned Guix commit
`f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c` and GNU Shepherd 1.0.9. This is a
style/convergence reference, not security evidence or acceptance.

## Focused recheck and built-baseline boundary

The focused recheck appended to
`2026-09-04-book-execution-guile-adversarial.md` closes its two first-run
findings at these exact implementation hashes:

| SHA-256 | File |
|---|---|
| `25812ffd6dbe998c60941d499fe90f4153045f968e3c04a62f791de794346f9e` | `pinenote/tools/book-execution-spike/disposable-qemu.scm` |
| `354a56ac13c07c8c07a466de28cbd42d95d0643913fb51976991f56ca910314b` | `pinenote/tools/book-execution-spike/run-disposable-qemu.scm` |
| `0cbbdb0da74b20c3420af47fafbaea8af4fa357b04825713d024deeec1c2ca4f` | `pinenote/tools/book-execution-spike/oci-bundle.scm` |

The independently reviewable private evidence is:

```text
system output: /gnu/store/laq3v5csnh5p8i9njv5vrap0kls5ay5g-system
image output:  /gnu/store/vvrp8i9af77sacic7rqnmcjiacpgd74a-disk-image
artifact dir:  pinenote/tools/book-execution-spike/build/artifacts/pinenote-book-execution-userns-20260904/
artifact manifest SHA-256: c686a4f9bbc4124d2f248a5c0761471aa605a2f37f81e2b1891653bba588b637
review manifest SHA-256:   9307fd37cdb5165c12b66c43ac1513df4832f963c0ea79119bd8a7561f37b034
root disk SHA-256:         f16b1ef41980ab1dfa1694102f2335956cb5c6372b69a1dbdc01d231791bcaf7
kernel config SHA-256:     0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
kernel Image SHA-256:      f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223
initrd SHA-256:            e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c
```

The private review manifest records the exact guest/system/staging source
hashes, derivations, build logs, one-symbol config diff, partition geometry,
root label, and non-execution statements. It and the guest fixture remain a new
review boundary. The prepared command is
`build/first-boot-after-guest-review.command`; it has not been executed.

## Guest-smoke corrections and regenerated boundary

The later focused guest review is preserved unchanged at
`2026-09-04-book-guest-smoke-adversarial.md`, SHA-256 `d041913d…`. It accepted
the exact kernel/config construction above but withheld boot authorization for
three finite corrections. The implementation now:

1. invokes the same bounded console-file assertion module directly from the
   outer Guile runner after QEMU is reaped and before unconditional guarded
   cleanup; parser failure propagates to the runner result;
2. requires exact, distinct
   `BOOKEXEC-PAYLOAD-{PYTHON,GUILE} book-bytes=<actual-size>` output computed by
   the language payload before its serial PASS marker; and
3. removes `agetty-service-type` only from the dedicated spike image. Static
   evaluation reports zero serial agetty services and one smoke service; the
   virtual-terminal services Guix needs for console-font provisions remain and
   cannot select `ttyAMA0`.

No general book-program option or protocol transport was added. The sentinels
are captured fixed-fixture diagnostics, not Book Protocol stdout. Production
cgroup ceilings, bounded Book Protocol output import, missing-sidecar rejection,
and private-FD integration remain outside this finite correction.

The corrected system/image were rebuilt with `nice -n 10`, `--no-grafts`,
`--cores=2`, and `--max-jobs=1`. The already-realized USER_NS kernel was reused;
a fresh full comparison still reports only `CONFIG_USER_NS: n -> y`. The prior
artifact, review manifest, and launch recipe retain their hashes above. The new
evidence is versioned separately:

```text
system drv:     /gnu/store/k3nrd3a0xanqkq06s5hbis8fc99di9f8-system.drv
system output:  /gnu/store/0rlw7zk22cnc4vcrlxz4c91xlphn6489-system
image drv:      /gnu/store/8ygqb7zcbarppbv747jnwqkp1zk1zxim-disk-image.drv
image output:   /gnu/store/klgw7f4nypj4mhfz9l1py3rqmx5l1cm4-disk-image
image SHA-256:  f85c4e1de80ada942f99b2674beb234496bb208e978b02f128c3ac90b5aeb1ee
artifact dir:   pinenote/tools/book-execution-spike/build/artifacts/pinenote-book-execution-userns-20260904-v2/
artifact manifest SHA-256: cfde18fece90f8a56e2d13170b2ea45dd4d4f85967be37f200e94f3b321351bf
review manifest SHA-256:   685855096da1c203431788b655c4d824b284903ee6e8578ff72f5962c12f2fbe
root disk SHA-256:         e142c244dd5b6de83da4cdf9121fd128504bedfa8c9b873b94f7311f308a7e5d
kernel config SHA-256:     0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
kernel Image SHA-256:      f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223
initrd SHA-256:            e70035a3f0eb16f08e062519163ab6fb344f0703cb476f2c9f1a15683d71d42c
extlinux SHA-256:          9c37225ddc174288dfc01686f70457bc16d4ca50763e42c909edee4273b4a0b4
```

`build/baseline-review-manifest-v2.txt` records all full source, artifact, log,
and prior-evidence hashes. Non-mounting inspection, immutable mode/link checks,
read-only `e2fsck`, unchanged pre-partition/MBR comparison, and overwrite
refusal pass. The new non-executable `set -eu` recipe is
`build/first-boot-after-guest-review-v2.command`, SHA-256 `8df7875c…`; it reports
explicit run/checker status and has not been executed. This exact corrected
snapshot awaits focused re-review. It is not a QEMU, ARM64 runtime, isolation,
release, hardware, or deployment result.
