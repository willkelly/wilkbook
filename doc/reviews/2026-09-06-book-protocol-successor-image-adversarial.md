# Book Protocol successor image-to-source binding review — 2026-09-06

## Verdict

**Accept the exact successor image packet below as fit for exactly one parent-
authorized Book Protocol QEMU run through the reviewed launcher.** No image-to-
source, staged-baseline, runtime-input, or semantic-checker binding blocker was
found.

This review supplies image acceptance, not the separate run authorization. The
one-run parent interface is exactly:

```sh
WILKBOOK_PROTOCOL_CONTROL_QEMU_RUN_AUTHORIZATION=PROTOCOL_CONTROL_IMAGE_ACCEPTED_AND_RUN_SEPARATELY_AUTHORIZED \
  sh pinenote/tools/book-execution-spike/build/first-protocol-control-root-mount-after-image-review-v2.command
```

The command file is mode `0400`, SHA-256
`4c733150de56009f19a47d7c2467c208ad440d7f4105e633d6d56e06c4475b11`.
With the variable absent, invocation through `sh` independently refused as its
first effective operation with status 125 and sole diagnostic:

```text
refusing: protocol-control QEMU run is not separately authorized
```

Acceptance is finite: the fixed Guile and Python books, their two nonce-
dependent presentations per language, the accepted Guile authority, the
accepted unpatched six-file CONTROL runtime, and the root-mount-rejecting
`null-netns` cleanup adapter under one 600-second TCG QEMU invocation. It is not
a hostile-book security qualification, generic execution framework, output-
import or persistence result, cancellation/timer result, reader integration,
hardware result, or release acceptance.

The historical first protocol image remains a failed runtime: Guile proved two
nonce-dependent FD-3 presentations, cleanup failed before Python started, and
the exact historical residual entry was not observed. Nothing here converts
that partial run into a PASS. Successor ARM64/gVisor behavior remains unproven
until the separately authorized run itself succeeds.

## Scope and review boundary

This was only an immutable image-to-source and one-run-launcher binding review.
The corrected source had already been independently accepted in
`doc/reviews/2026-09-05-book-protocol-fd-adversarial.md`, SHA-256
`b1bc43e15f94ebc2969693895661b78877ca42d6ac58446fdc818ebea602def1`.
I did not repeat its adapter, OCI, gVisor, protocol/session, lifecycle, or Guix
source audit. In particular, the source review remains authority for the exact-
owned namespace-pin checks, state-root mount rejection, non-lazy unmount,
identity-checked placeholder removal, fail-preserve residue rules, and success-
after-cleanup ordering.

This review instead checked that those accepted bytes are the bytes represented
in the realized image and private run input, that unchanged dependencies remain
unchanged, and that the prepared launcher selects the intended outer runner and
protocol checker. It did not build or realize an image or package, invoke
runsc/Sentry, start QEMU, execute ARM code, run Bazel, mount a filesystem, access
hardware, stage, commit, or push.

Repository baseline was
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The packet and implementation are
untracked, so hashes—not that commit—identify the review object.

## Exact accepted packet

| Object | Identity |
|---|---|
| Image-review manifest | `722384c4167678023457148a742eaaab132d66011633fd70f0b36de93e8c109d` |
| Image binding | `af93742477a262d9db8e8d2f37497d9d34dd7211528c684b8d28c32122b9ce02` |
| Accepted source packet | `99050e5a55e0cba59df93ca2ae75cfd414a6be53c950237fd324ea481103d635` |
| Accepted source review | `b1bc43e15f94ebc2969693895661b78877ca42d6ac58446fdc818ebea602def1` |
| Source system | `/gnu/store/la8r16jpjzxgw5diqx333myc7nx62s38-system` |
| Source-system recursive Guix hash | `166rny8gsp6w1mfaarw41qw59q64sahf86sv7iv2hng1lbdxf17s` |
| Source image | `/gnu/store/90hinx7dwwlc8kz1ajg8ajpi7h1pcr24-disk-image` |
| Source-image SHA-256 | `09a0e849f3a7f0fecbd8e444405a44db38359fa6dda251dc3399aed21bfe9090` |
| Source-image recursive Guix hash | `0dabw54amryxnrm8g1121aam341lmvxnlcqymwafsvpgb4lrbl8k` |
| Accepted adapter | `eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d` |
| Runtime launcher | `4c733150de56009f19a47d7c2467c208ad440d7f4105e633d6d56e06c4475b11` |

The manifest declares 95 path-hash records. I parsed it independently, required
exactly 95 unique paths, and streamed SHA-256 over every named worktree,
artifact, and store object. All 95 matched. This included the accepted review,
source packet, image/binding/build/inspection records, private baseline and boot
bundle, protocol sources and realized outputs, kernel/initrd, complete CONTROL
runtime, historical evidence, outer runner, checker chain, and launcher.

The binding file itself matched its packet hash and consistently names the
system, image, derivations, closure sizes, adapter, generated service, private
inputs, kernel, initrd, and runtime recipe above.

## Actual image contents

### Image and closure identity

Read-only Guix store inspection independently established:

- the source image has the exact SHA-256 and recursive Guix hash above;
- it references `/gnu/store/la8r16...-system` exactly once;
- the system has recursive Guix hash
  `166rny8gsp6w1mfaarw41qw59q64sahf86sv7iv2hng1lbdxf17s`;
- `guix gc --requisites` exactly matches the submitted sorted rosters: 341
  unique system paths and 343 unique image paths; and
- the two image-only requisites are the matched extlinux object and image.

The image is a 2,055,102,464-byte DOS-partitioned raw image with exactly one
bootable Linux partition at start sector 2048, length 4,011,824 sectors. A
non-mounting `blkid` probe at byte offset 1,048,576 found ext4, block size 4096,
filesystem size 2,054,053,888 bytes, label `Guix_image`, and UUID
`a454a7b0-be49-f492-ea20-70d9a454a7b0`.

I extracted that partition into a private temporary regular file solely for
read-only `tune2fs`/`debugfs` inspection; it was never mounted and was deleted.
The superblock reports state `clean`, 501,478 blocks, 4096-byte blocks, and the
same UUID. `debugfs` confirmed the exact selected system directory and dumped
15 source/runtime files directly from the image bytes. Every dump matched its
accepted hash:

| Image-contained store object | SHA-256 |
|---|---|
| Accepted `guest-smoke.scm` | `74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa` |
| Accepted `oci-bundle.scm` | `a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c` |
| Accepted `book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |
| Accepted Guile `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| Accepted blocking adapter | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| Accepted Python codec | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| Protocol OCI source | `c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7` |
| **Corrected guest adapter** | **`eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d`** |
| Fixed Guile book | `9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a` |
| Fixed Python book | `b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0` |
| Realized protocol source manifest | `f6f5891e8ee967e9e6a80e854d3c858b1ed60471b993ba73bdd50a0b181feae1` |
| Realized build manifest | `6e77bd47a6bde19b6a96afcf153621fa778afc3c95eebf652a12983707a6193e` |
| Guest entrypoint | `757eec6bb8dfc7a4d8fe582cc87f0c3cf05e8c19db53761fed06e54410993a36` |
| Generated Shepherd service source | `3b591c0856670eac1190b7171568e2be0b16b918b762ebfde1e8247a2c376c5d` |
| Generated Shepherd compiled service | `4f93bfde23834ae87b3809ba090a9b2dc649b5c57c4f0be8cbdc46130cc25f4f` |

The image-contained realized source manifest independently enumerates the same
ten source hashes and names
`/gnu/store/fj0p...-wilkbook-guest-book-protocol.scm` as the adapter. The guest
entrypoint primitive-loads that exact object. The realized build manifest names
the fixed FD 3, Systrap, no-network, `null-netns`, forbidden state-root mounts,
non-lazy identity-checked cleanup, and fail-preserve policy accepted by the
source review. These checks bind accepted source bytes into the actual image;
they do not repeat or expand the source review's semantic conclusions.

### Successor delta

The historical failed image and successor requisite sets were recomputed from
the store rather than accepted from the submitted delta text:

```text
system: old=341 new=341 removed=12 added=12
image:  old=343 new=343 removed=14 added=14
```

Those four exact set differences matched every path recorded in
`protocol-control-root-mount-closure-delta-v2.txt`. The changed paths are the
adapter-dependent source manifest, adapter entry, service/activation/etc/boot
chain, system, extlinux, and image outputs. The kernel, initrd, 45-path sandbox
language closure, supervisor profile, and CONTROL artifact are not substitutions
in the delta.

The successor image is exactly 24,576 bytes larger than the historical image;
its root grew by 48 sectors/six 4096-byte blocks. The historical and successor
root UUID is the same
`a454a7b0-be49-f492-ea20-70d9a454a7b0`. These values agree with the realized
image, not only the packet prose.

## Private run input

The launcher does not boot the writable store image directly. It consumes the
private mode-0400 baseline
`build/artifacts/pinenote-book-execution-protocol-control-20260905-v2/baseline.raw`,
SHA-256
`f7aefd35653efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047`.
Its one partition has the same `2048 + 4011824` geometry, clean ext4 state, and
unchanged UUID; its label is the required `PNGuixRoot`.

Independent read-only extraction from this exact baseline again produced the
accepted adapter, realized source manifest, build manifest, guest entrypoint,
and generated Shepherd service source hashes. The run input is therefore not a
stale copy of the failed adapter.

A complete byte comparison between source image and private baseline found
exactly 91 differing bytes in six 4096-byte blocks: the main ext4 superblock and
the sparse-super backups for groups 1, 3, 5, 7, and 9. No filesystem data block,
partition-table byte, source object, or other image block differed. This is the
expected scope of the private `e2label PNGuixRoot` operation; it is stronger
evidence than trusting the staging script's label-only description.

The private artifact inspector also requires regular non-symlink inputs, link
count one, no write bit, exact hashes, ARM64 kernel identity, one unambiguous
root/system/load/console command line, no host share, and no QEMU network. The
launcher hashes that inspector and executes it before preparing a run.

### Non-mounting filesystem evidence

The preserved first inspection command expected the superseded historical
sector count 4,011,776. The actual baseline reports 4,011,824, so `set -e`
deterministically exits at that comparison before its subsequent `dd` and sole
`e2fsck` command. Its status is 1 and its two-line log contains only the
successful immutable-input probe. Thus that failed wrapper did not run fsck.

The final inspection command changes only the expected count to 4,011,824,
extracts the one partition without mounting it, and contains one
`e2fsck -fn` invocation. Its status is zero and its bound log records all five
read-only passes and:

```text
PNGuixRoot: 47672/125440 files (0.1% non-contiguous), 375840/501478 blocks
```

The separate realized inspection contains no `e2fsck` invocation and binds the
image, system, closures, source outputs, profiles, CONTROL, and private inputs.
I did not rerun `e2fsck`; my independent filesystem work used only non-mounting
metadata reads and `debugfs` extraction.

## Unchanged runtime inputs

The selected system links to the accepted kernel and initrd. Direct hashes are:

| Runtime input | SHA-256 |
|---|---|
| Kernel `Image` | `f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223` |
| Kernel `.config` | `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` |
| PineNote v1.2 DTB | `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` |
| Initrd | `06d641e95e712f1b0c94a660baf66c68f3eebd26743c69837da31f53b7ac3175` |
| Private extlinux | `76b6e2f77ef150655a13a5139cb596631d40ae00c44ac63932958415ede79827` |

The extlinux command line selects exactly
`gnu.system=/gnu/store/la8r16...-system`, its `/boot`, and `root=PNGuixRoot`.
No kernel or initrd derivation appears in the successor closure delta.

The sandbox language closure is still SHA-256
`48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc`,
with exactly 45 unique paths and zero `guile-gcrypt` names. The system closure
contains exactly one gVisor-named output: the previously accepted unpatched
source-built CONTROL artifact
`/gnu/store/b9a3...-gvisor-v12-control-local-test-artifact-20260831.0`.
Its complete six-file set independently matched:

| CONTROL member | SHA-256 |
|---|---|
| `containerd-shim-runsc-v1` | `7fbaf0e090b1bb10ecf35a25ff2d22c6c9ccdc0d3ada6a1ab548a7ece259c548` |
| `gvisor-bin/checkpointgofer` | `19451cc0b04ce9d2baaa7a8e2a5abeb0b06c9c0f43bc7c182bc9954b97514846` |
| `gvisor-bin/gvisor-sentry-prewarmer` | `1e0d994e39f3f8d7746890a0df09cb7b88de79f90da8489c274e2fa9b0e3a81a` |
| `gvisor-bin/gvisor_sentry` | `b586873e1f32fc4bde4c1535780a0dae4bc4ad873a8a3858588430153878437f` |
| `gvisor-bin/runsc-metric-server` | `080fde2370aa27f176ef1af02c8a89c73644fc2970b5fbe2d30072d86cb180dc` |
| `runsc` | `a5aca591653e0f504d75093b1d37d301dca23e14b18f1140c406d68732b16ed3` |

No diagnostic or generic prebuilt gVisor package replaced CONTROL.

## Launcher and checker binding

### Fixed launcher inputs and discovery boundary

The mode-0400 launcher contains 48 pre-copy `require_sha256` checks and three
post-copy checker-module rechecks. The 48-item retained input-check log names the
same inputs; all were also independently covered by the 95-path packet hash
recalculation. The three private copies reproduced exactly:

| Private checker module role | SHA-256 |
|---|---|
| Accepted outer `disposable-qemu.scm` | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| Protocol semantic checker | `3c456df71d8630c2c6c992cdf637f796312d34e01b9f4803d63e9513d72e3c68` |
| Legacy-hook-to-protocol bridge | `b691c19d8e151c0afcf76468c1f902479c2fc9ed68f80847e941a04c3da89b1b` |
| Fixed protocol entrypoint | `769f4f2ff0a805d4dfa52621821acee348ff438026d23f9cb8b7cfeb93fbf30a` |

After the authorization guard, both the image builder and runtime launcher
explicitly clear `GUIX_PACKAGE_PATH` and `GUIX_BUILD_OPTIONS`; the runtime also
clears ambient Guile load paths. The accepted v8 assembly view remains exactly
19 `.scm` symlinks with roster hash
`406509bd6e75702de8e3d6c891253432b8b918e6f4bb4f4f6b4218af8a82f749`;
the package view contains zero Scheme files and marker hash
`eb6412b8d31a23c092c9fe712f130c3bf72ef0620aec7757b2864c212419a636`.
These were already source-reviewed; this check only confirmed that the view
identities used for the accepted assembly remain present.

Neither v8 assembly nor the runtime launcher names a path below `doc/reviews`.
The current append-only review file is not a mutable machine dependency. The
source packet's historical report-hash field is evidence text inside an
immutable packet; no launcher compares it to the current report.

### Correct protocol oracle

The accepted outer imports `(guest-console-assertions)`. The launcher does not
expose the repository's legacy checker under that hook. It creates a private
three-file module view and maps the reviewed bridge to
`guest-console-assertions.scm`; that bridge first invokes the protocol semantic
checker and then requires clean kernel power-down.

I recreated that isolated view and invoked only the checker—never QEMU. The
exact positive protocol/diagnostic/cleanup/power-down chain passed. Five focused
mutations each failed before a ten-second watchdog:

1. missing Guile protocol PASS;
2. missing Python protocol PASS;
3. both language PASS lines replaced by legacy `BOOKEXEC-SMOKE-PASS`;
4. missing protocol cgroup-teardown PASS; and
5. missing `reboot: Power down`.

The checker also requires the markers exactly once and in order, with each
language PASS after its bounded debug/panic summaries, and rejects frozen-smoke,
host-test, failure, overflow, panic, BUG, and Oops fragments. It therefore
cannot accept the historical Guile-only transcript or legacy smoke output.

The serial checker does not parse Book Protocol payloads or nonces directly.
That semantic authority remains in the exact image-contained accepted adapter:
its language markers follow the two authority-accepted nonce-dependent results
and language cleanup. Binding those adapter bytes, both language markers, the
cleanup chain, and clean power-down is the intended division of responsibility;
no console marker is being reclassified as a Book Protocol result.

### One bounded QEMU recipe

The launcher contains one `guix time-machine` invocation of the fixed protocol
entrypoint, supplies `--dedicated-baseline`, and supplies exactly
`--timeout-seconds 600`. The accepted outer creates a fresh identity-checked
private run root, rehashes private kernel/initrd/config/baseline snapshots,
creates a fresh qcow2 overlay over the private raw baseline, and invokes one
QEMU process through its owned-process deadline/cleanup path.

The hash-bound non-executed graph, SHA-256
`47b3ac7c25939722b10faa17739c74eeb3e1f2f74bc9edabd01af9f466dc5fc7`,
matches the accepted outer source and records:

```text
-accel tcg,thread=multi
-cpu max
-nic none
private qcow2 overlay over the hash-checked raw baseline
virtio-blk only; no host share
```

There is no `-virtfs`, `-fsdev`, 9p, host forwarding, tap, or host-directory
argument. The graph and private baseline agree on the one-partition geometry.
The outer bounds retained console/failure evidence, reaps QEMU before invoking
the checker, and identity-checks run-root cleanup. The launcher accepts only
outer status zero plus one and only one exact status line:

```text
OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS
```

Any nonzero outer status, missing/extra status line, semantic-checker failure,
or incomplete launcher path remains non-PASS evidence. The accepted adapter's
own final language and overall markers remain after endpoint release, runsc
group reaping, bounded capture drain, cgroup absence, exact `null-netns` pin
cleanup, empty state-root removal, bounded store summaries, and verified store
unmount as established by the already accepted source review.

## Evidence accounting and hygiene

Independent checks completed in this review:

- 95/95 unique packet path hashes;
- exact image/system recursive Guix hashes and 341/343 requisite rosters;
- exact historical-to-successor 12/12 system and 14/14 image set deltas;
- non-mounting actual-image extraction of 15 accepted source/runtime files;
- non-mounting private-baseline extraction of adapter, manifests, entrypoint,
  and service;
- full source-image/private-baseline byte comparison;
- kernel/config/DTB/initrd and six CONTROL member hashes;
- 45/45 unique sandbox language paths with no gcrypt;
- launcher `48 + 3` hash topology and independent status-125 refusal;
- exact private checker view, one positive semantic chain, and five negative
  transcript mutations; and
- static one-invocation QEMU recipe/graph checks.

Three reviewer-probe assumptions were corrected and are not counted as
failures of the packet:

1. launcher hash calls total 51 because the claimed 48 fixed inputs exclude the
   three post-copy rechecks;
2. mode `0400` requires the documented `sh COMMAND` interface, so direct exec
   returns a permission error rather than reaching the status-125 guard; and
3. `e2label` updates bounded ext4 superblock bookkeeping in addition to volume-
   name/checksum bytes, so the valid label-only staging proof is six changed
   superblock blocks and zero changed data blocks—not a claim that only the
   16-byte label field differs.

All accepted results above came from corrected probes. Every temporary image
partition, checker view, transcript, and helper lived under a private exact-
prefix directory in `/tmp/opencode` and was deleted. No reviewer-owned process
or temporary directory remained. The concurrent runtime/Guix-source reviewer
was not inspected, interrupted, or cleaned up. This report is the only
repository file written.

## Authorization boundary after this review

The image-binding gate is closed at the exact hashes above. A parent may now
separately authorize **one** invocation of the mode-0400 launcher with the exact
token recorded in the verdict. Any change to the image, private baseline,
accepted adapter, system, kernel/initrd, CONTROL files, language closure, outer
runner, checker/bridge/entrypoint, binding, source packet, launcher, or token
requires refusal or a fresh review.

Only the resulting bounded run can establish the successor ARM64 gVisor result:
both fixed Guile and Python Book Protocol exchanges plus the complete cleanup
chain and clean QEMU shutdown. A runtime failure remains evidence to diagnose,
not permission to weaken the checker, reuse historical partial success, or
expand this functional fixture into a general security claim.

## Authorized successor runtime attribution — checker correction pending

The one authorized run above has now been consumed. **Do not invoke the
launcher again under this image acceptance.** This section supersedes only the
pre-run authorization state in the preceding section; it does not rewrite the
original host result as a PASS.

The original wrapper record is
`/tmp/opencode/wilkbook-qemu-protocol-successor-wrapper.pR3ZER.log`, SHA-256
`3688e58f9efd4d2ba3b4fa9c139ef0923f535aace60eae0577e5cc2c630d4002`.
It binds the retained evidence named below and records exactly:

```text
RUN-STATUS=1 CHECKER-STATUS=1
```

The run used the still-exact launcher
`4c733150de56009f19a47d7c2467c208ad440d7f4105e633d6d56e06c4475b11`
and accepted outer runner
`0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca`.
No outer success line exists and no status zero is inferred. The immutable
original outcome is **guest functional chain observed; original host checker
FAIL**.

### Full-console recovery is exact, not marker grep

The retained complete failure output is:

```text
pinenote/tools/book-execution-spike/build/protocol-control-root-mount-runtime-evidence-v2.OMSobe.log
SHA-256 5bfcd98425f0d3e554a343e89775d2ba2f56212ac21753bc15a6542c5818e378
```

I independently derived the inverse of the accepted outer's
`write-escaped-bytevector`; I did not treat the printed host failure output as
guest serial text. The accepted encoder prefixes each rendered line with
`| `, represents LF/CR/TAB/backslash as `\\n`, `\\r`, `\\t`, and `\\\\`,
represents every other control/non-ASCII byte as lowercase `\\xHH`, and copies
only printable non-backslash ASCII literally. This grammar is prefix-free: a
raw backslash is never copied literally, `x` always consumes exactly two
lowercase hex digits, and every physical continuation before the final renderer
newline must follow an encoded source LF. Therefore there is no double-unescape
choice.

The evidence has exactly one unprefixed full-retention begin record, one content
record, and one stable end record:

```text
source-bytes=25120 retention=full
CONTENT bytes=25120
END label=console.log retention=full
```

There is no `ELIDED` or `INCOMPLETE` record in that frame. I removed only the
outer-owned `| ` prefixes, concatenated the 341 physical encoded lines, decoded
the accepted grammar once, and recovered exactly 25,120 bytes. Re-encoding
those bytes with an independent implementation reproduced the entire framed
content region byte for byte. The recovered raw console identity is:

```text
SHA-256 171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3
```

This distinguishes three domains: unprefixed outer diagnostics are framing,
decoded bytes are the guest console, and any guest-rendered diagnostic payload
inside that console remains visibly prefixed by the guest's own `| `. Only
exact unprefixed lines in the reconstructed guest console count as protocol
markers.

### Guest functional chain proved at the accepted source bytes

The reconstructed console contains, exactly once and in order:

1. Guile's exact owned `null-netns` evidence and non-lazy cleanup marker;
2. Guile `runsc-debug` and `runsc-panic` bounded-store summaries;
3. `BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS`;
4. Python's exact owned `null-netns` evidence and non-lazy cleanup marker;
5. Python `runsc-debug` and `runsc-panic` bounded-store summaries;
6. `BOOKEXEC-PROTOCOL-PYTHON-SYSTRAP-PASS`;
7. `BOOKEXEC-PROTOCOL-CGROUP-TEARDOWN-PASS`;
8. `BOOKEXEC-PROTOCOL-PASS`; and
9. the timestamped kernel `reboot: Power down` line.

For both languages the state root reports `root-mounts=0`, exactly one emitted
entry, a mode-0444 regular `null-netns`, one `nsfs` network-namespace mount with
the same inode `4026532133`, and
`action=nonlazy-unmount`. Guile's debug/panic summaries report capacities
4,194,304/1,048,576 bytes, file limits 10/2, and `overflow=#f`; Python reports
the same bounds and no overflow. No protocol FAIL, legacy smoke PASS/FAIL,
diagnostic overflow, kernel panic, BUG, or Oops fragment occurs in the recovered
console.

Those markers are causal evidence for this exact trusted fixed fixture, not
self-authenticating statements from an arbitrary book. The image-bound adapter
is still SHA-256
`eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d`.
Its Guile and Python marker literals each occur at one success emission site.
For each language that site is reachable only after the authority has generated
two fresh strong-random nonce-bearing actions; received two committed
`presented-text` values; matched action ID, generation 1, sequence 1 then 2, and
the exact nonce-dependent computed text; observed EOF; released the authority
endpoint; reaped zero-exit runsc; finalized bounded captures without overflow;
verified and removed the exact owned runtime state; emitted non-overflowing
store evidence; and verified store unmount. The pair runs sequentially, and the
overall marker follows final cgroup absence for both containers.

A fixed book's captured output cannot satisfy these exact-line checks through
the diagnostic channel: captured payload is escaped and prefixed, whereas the
accepted markers above are unprefixed lines emitted by the adapter after the
authority/cleanup chain. This closes a forged-marker bypass only for the exact
trusted Guile/Python fixtures and accepted process path. It is not a claim about
hostile books or a generic sandbox boundary.

Accordingly, the first complete ARM64 gVisor functional evidence is present for
both accepted nonce-dependent Book Protocol exchanges and their accepted
cleanup path. It does not need an expensive guest rerun merely to rename the
host checker's expected store labels.

### Original checker failure is the four-label mismatch

The immutable checker used by the run is SHA-256
`3c456df71d8630c2c6c992cdf637f796312d34e01b9f4803d63e9513d72e3c68`.
Its lines 99 and 101 collect prefixes `label=debug` and `label=panic`; lines 112
and 116 validate the same two shortened labels. The accepted FINAL2 guest
emitter instead always emits `label=runsc-debug` and `label=runsc-panic`, as the
actual reconstructed console does twice each.

I replayed the exact reconstructed raw console through the immutable original
checker and bridge under a ten-second watchdog. It failed with status 1 and the
same sole semantic cause retained at evidence line 349:

```text
each language PASS must follow its bounded debug/panic store summaries
```

In a private temporary copy only, changing exactly those four checker string
literals to `runsc-debug`/`runsc-panic` made the unchanged 25,120-byte console
pass the protocol checker and clean-power-down bridge. The temporary diagnostic
copy is not an accepted source object and was deleted; its result establishes
that no second transcript defect is hidden behind the label mismatch.

**Gate state at this append:** guest functional PASS evidence is accepted for
the exact fixed Guile/Python fixture; the original host result remains
`RUN-STATUS=1 CHECKER-STATUS=1`; corrected-checker and exact-extractor source
review is still pending. Final host-checker acceptance requires independently
reviewing the implementer's correction, replaying the immutable raw console,
and exercising realistic positive/negative transcripts. That offline review
may close this label defect without a new image, QEMU, runsc, ARM, or hardware
run, but it must not manufacture or relabel an original status-zero result.

## Final corrected-checker/extractor review — blocked by a canonical-frame counterexample

### Verdict

**Accept the corrected protocol checker itself at SHA-256
`4a8e9e554d98ba8f22d16dec36578bbd727853dbcca3ffa5ddb50a02b4ca6f43`,
but do not accept the combined checker/extractor packet and do not close the
offline host-checker gate.** The four-label checker defect is closed; the
extractor at SHA-256
`af6cb638025756e308414add83c66e2c260e4aada4aa8650b65d89843688ac44`
accepts a contradictory full-console framing record that the accepted outer can
emit only as incomplete evidence.

This does not retract the accepted guest-functional result. The exact fixed
Guile and Python ARM64/gVisor Book Protocol exchanges and complete accepted
guest cleanup chain remain proved by the immutable 25,120-byte console. It also
does not alter the original command result: it remains exactly
`RUN-STATUS=1 CHECKER-STATUS=1`, with no outer success line. No image, guest, or
runtime rerun is warranted by either host-only issue below.

### Packet identity and freshness

The submitted manifest itself matches SHA-256
`7cc2b57e7e67cde135b18b275970823a6124b8908c6a207aa6ae48d758629ddd`
and contains exactly 49 unique `path-sha256` records. At review time, 47 matched
and two did not:

| Path | Packet hash | Observed hash |
|---|---|---|
| `doc/book-computer-implementation.md` | `faaa16d54cdc083632d13da04572f6a7ecf36dca79dba078c20d49654bba22da` | `c9cfb2dfa768ebedd43b9244286625618fab0dfb215ab1c38e4350b4377d7e4b` |
| `pinenote/tools/book-execution-spike/protocol-guest/README.md` | `b654ed934bdb6edbb0365c3763a3767f85e4ea2724b5c25b5a0277cb93248aa2` | `00629e7dcc691e4388746a6047a8072cfd23848366a10ab56797b7865a99e734` |

Both observed files were modified after the mode-0400 manifest was written,
amid separate UI-transport work. I did not alter or treat that concurrent work
as part of this gate. The 47 matching records include every executable checker,
extractor, outer/emitter, immutable evidence/raw console, replay command, test,
diff, accepted protocol/session source, and retained result log relevant here.
Nevertheless, the claim that all 49 submitted paths are frozen is false at this
worktree state. Any successor packet must either bind the resulting intended
documentation versions or exclude unrelated mutable documentation explicitly;
it must not silently reuse the `7cc2…` all-path claim.

The report's pre-append hash
`2e60bd2fc0a792dcf03f18ee33b47525b299f885f86955a39c700715429f8e71`
did match its manifest record before this required review append. Its deliberate
append-only change is not counted as a third pre-review packet mismatch.

### Corrected checker: accepted

I reconstructed the corrected checker from the immutable rejected checker,
SHA-256
`3c456df71d8630c2c6c992cdf637f796312d34e01b9f4803d63e9513d72e3c68`,
by applying exactly these four substitutions:

1. prefix `label=debug` → `label=runsc-debug`;
2. prefix `label=panic` → `label=runsc-panic`;
3. validator label `debug` → `runsc-debug`; and
4. validator label `panic` → `runsc-panic`.

The reconstructed bytes equal the submitted corrected checker exactly. The v2
diff, SHA-256
`89c6174bafaea787a16599e6f7a60a9642ae5e3b7bb11ca52542062b0fb5e23b`,
contains only those four literal changes; the superseded v1 diff preserves its
incidental indentation change and is not the accepted delta. Marker
cardinality/order, store-summary cardinality/order, exact limits/capacities,
`overflow=#f`, forbidden fragments, input-size bound, and clean-power-down
bridge are byte-identical outside the four literals.

The positive fixture no longer invents the old labels. It reads the two
`make-diagnostic-store` symbols from the exact accepted emitter
`guest-smoke.scm`, SHA-256
`74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa`,
and requires the resulting list to be exactly
`runsc-debug,runsc-panic` before constructing the fixture.

One independent focused run passed all 15 checker/extractor test methods and
the immutable-console replay. Separately, I replayed the committed raw console
through both checker versions under ten-second watchdogs:

- the immutable historical checker failed status 1 with the exact retained
  store-summary-label diagnostic;
- the corrected checker plus unchanged clean-power-down bridge, SHA-256
  `b691c19d8e151c0afcf76468c1f902479c2fc9ed68f80847e941a04c3da89b1b`,
  passed; and
- the corrected checker rejected seven mutations made from the actual console:
  missing debug summary, debug overflow, historical short debug label, legacy
  smoke substitution, duplicate Python marker, duplicate panic summary, and a
  Guile PASS moved before its panic summary.

Passing the parent-rendered failure evidence directly to the corrected checker
also failed. Only the decoded raw guest console can satisfy the exact unprefixed
marker lines; parent `| ` rendering is not accepted as guest evidence.

The hash-bound retained logs record 38 pinned-environment host tests, two pinned
gVisor source checks, and 18 static system checks with zero exits. I independently
reran the two review-drift tests, which passed. I did not count an ambient broad
host discovery: without the pinned Guile JSON environment it failed dependency
setup, and concurrent UI-transport tests had expanded that broad filename glob
beyond this packet. No Guix shell/build was authorized for this review. The
focused 15-test command and immutable replay require only the available host
Python/Guile environment and passed independently.

### Extractor: accepted result for the immutable file, rejected strict parser

The final extractor correctly decodes the one immutable retained file. My own
independent decoder again recovered exactly 25,120 bytes across 341 rendered
payload lines, reproduced the complete encoded content byte for byte, and
produced SHA-256
`171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3`.
The submitted extractor's output and the committed mode-0400 raw console were
byte-identical to that independent result. Exclusive output creation, one-link
mode-0400 output, and overwrite refusal also behaved as claimed.

Its source/content bounds match the accepted outer
`0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca`:
3,423,172 source bytes and a 20 MiB retained-evidence input bound. Its canonical
escape decoder and exact re-encoder correctly distinguish printable ASCII,
`\\n`, `\\r`, `\\t`, `\\\\`, and lowercase `\\xHH`; the all-byte round trip
and literal-backslash test show that it performs only one decoding pass. It
rejects wrong declared counts, duplicate complete frames, missing end framing,
bad line prefixes, noncanonical named/hex encodings, uppercase hex, raw control
bytes, oversized declarations, and output overwrite.

That is sufficient to reproduce this hash-pinned console, but not the submitted
claim of a strict canonical full-console frame parser.

#### EX-1 — a complete frame plus an exact `INCOMPLETE` record is accepted

The accepted outer's full-console exporter has two mutually exclusive endings:
after rendering it emits either stable
`END label=console.log retention=full`, or it emits
`INCOMPLETE label=console.log state=changed ...` when the source identity
changes. An evidence stream containing both for the same one export cannot be a
canonical image of that outer function.

I inserted this exact accepted-outer form immediately after the immutable
console frame's stable END, without changing any framed payload byte:

```text
BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE label=console.log state=changed exported-bytes=25120 limit-bytes=3423172
```

The extractor returned status zero, printed its PASS, created a 25,120-byte
mode-0400 output, and returned the same raw SHA-256 `171aedc3…`. The parser
counts only exact full BEGIN and END regex matches and ignores other unprefixed
console-specific framing records outside their indexes. Consequently it accepts
evidence that simultaneously asserts stable full retention and incomplete
retention. This is a concrete malformed acceptance under the requested
`strict inverse of accepted outer 0fe` criterion.

The immutable runtime file does not contain this contradiction, and the offline
replay hashes that file before decoding. EX-1 therefore does not undermine the
already attributed guest-functional result. It does block accepting the
extractor as the claimed canonical evidence validator. A narrow correction can
reject any additional unprefixed full-console BEGIN/END/INCOMPLETE control
record outside the one exact frame and add this exact mutation as a negative.
That is host-only work; no guest or image run is needed.

### Gate state after final packet review

- **Accepted:** both exact fixed ARM64/gVisor nonce-dependent Book Protocol
  exchanges and their complete accepted guest cleanup, from the immutable raw
  console and already accepted source chain.
- **Accepted:** the corrected four-literal host semantic checker at `4a8e…`.
- **Preserved failure:** the original invocation remains
  `RUN-STATUS=1 CHECKER-STATUS=1`; offline replay does not create a historical
  status-zero run.
- **Not accepted:** extractor `af6c…` as a strict canonical frame validator.
- **Not accepted:** manifest `7cc2…` as a currently matching 49-path frozen
  packet.
- **Protocol gate:** not fully closed by this packet. Only EX-1 plus packet
  freshness remains; no source, protocol, guest, image, kernel, gVisor binary,
  QEMU, runsc, ARM, hardware, reader/UI, cancellation, timer, persistence, or
  hostile-book rerun/review is requested or implied.

## Ancillary EX-1 recheck — accepted

### Verdict

**Accept the EX-1 correction at extractor SHA-256
`5e7aeca0d9add0a130fd87d58eb047cbfcb47dc0d78cc3aeb09d9087d570a183`
and close the remaining offline host-artifact defect for the exact fixed Book
Protocol fixture.** The prior contradictory full-plus-INCOMPLETE evidence is
now rejected with no output, while the immutable real evidence still recovers
the exact independently identified console and passes the already accepted
checker and clean-power-down bridge.

This ancillary acceptance supersedes only the EX-1 and stale-packet blockers in
the immediately preceding section. It does not manufacture an original outer
success: the historical invocation remains exactly
`RUN-STATUS=1 CHECKER-STATUS=1`, with no outer status-zero line. The accepted
result remains the source-bound, offline-attributed functional result for the
two exact fixed Guile/Python ARM64/gVisor Book Protocol exchanges and their
complete accepted cleanup chain.

No reader/UI behavior, cancellation, timers, persistence, output import,
arbitrary programs, hostile-book isolation, general sandboxing, or production
process boundary is accepted by implication. This host-only correction is not a
reason to rerun or block an independently reviewed reader-image join.

### Frozen ancillary packet

The correction record
`doc/reviews/2026-09-06-book-full-console-extractor-ex1-fix.md` matches SHA-256
`d45ec93d175ae7011d5f6a9eaeafdfa1ba4c78dc915dde92d65ac9cdfdb9b2e5`.
The private packet `/tmp/opencode/book-extractor-ex1-fix.10KAct` is mode 0700;
its manifest matches
`c87da4c6c68e773baafdb99c11f813d9505e1e99f95eade030a19b5c046f9848`.
Every manifest-bound private evidence file matched its hash.

The replacement machine gate is the relevant-subset packet:

```text
pinenote/tools/book-execution-spike/build/protocol-control-extractor-ex1-fix-review-packet-v1.txt
SHA-256 af05d9f802b617b03b7e47cf670f71a58e32c8cae864ff60d5f968afa5f22070
```

It contains exactly 11 unique machine path hashes; all 11 matched. They bind
only the extractor/test, frozen checker/test/entry/bridge, accepted outer,
immutable retained/raw evidence and wrapper, and the historical manifest. This
is correctly a new relevant-subset gate, not a claim that the old 49-path packet
became current again.

The old manifest remains untouched historical evidence at SHA-256
`7cc2b57e7e67cde135b18b275970823a6124b8908c6a207aa6ae48d758629ddd`.
Its two known concurrent documentation mismatches remain historical facts, not
members of the new machine gate. The mutable implementation document,
`protocol-guest/README.md`, and this append-only adversarial report are
explicitly excluded rather than repeatedly repinned. That exclusion is
appropriate for this executable two-file parser correction.

### Exact delta

The test source is accepted at SHA-256
`bd9ea882cf6ae3cc6dbce3effedfab5d662bf1f1591e8b51202ff19a08bc61c2`.
The combined old-to-new extractor/test delta matches
`8a431008a97a854f24fb65477fd3631f1a75263b59e095da5cb1832ddb5408fb`.
I reverse-applied that delta in a private temporary tree and recovered the prior
extractor and test bytes exactly at their accepted hashes `af6cb638…` and
`bdebe2b0…`. No checker, outer, guest, protocol/session, system, reader, image,
kernel, or gVisor binary source is part of the delta.

The source change adds one classifier for unprefixed accepted-outer
`BEGIN`, `END`, and `INCOMPLETE` controls whose label is exactly
`console.log`. Once the parser identifies the one exact stable frame, it permits
only that frame's exact BEGIN and END indexes. Any other recognized control is
fatal before decoding or output creation. The existing bounded read, canonical
one-pass escapes, source/content counts, exact re-encoder, and exclusive
mode-0400 output path are unchanged.

The classifier does not normalize the accepted outer's fixed internal syntax.
The main BEGIN and END still require exact full matches, so tab, doubled-space,
or other alternate whitespace in canonical headers cannot become the selected
frame. At the console-label boundary the classifier recognizes space, tab, CR,
LF, or end of line, so changing whitespace after the exact label cannot evade
the extra-control rejection. Arbitrary strings outside the accepted outer's
fixed prefix grammar are ordinary wrapper text, not alternate accepted framing.

### Independent focused results

One clean independent run passed exactly 11 extractor test methods. In addition
to the existing all-byte, single-unescape, canonical-escape, prefix, count,
bound, output-mode/link, and overwrite checks, these tests establish:

- the exact 109-byte EX-1 `state=changed` line after stable END is rejected;
- no output file is created on that rejection;
- exact and malformed extra BEGIN/END/INCOMPLETE controls before and after the
  frame are rejected;
- console-control text inside encoded guest payload remains valid because it is
  parent-prefixed; and
- complete `qemu.stderr` frames before and after the console frame remain valid.

I independently rebuilt the exact EX-1 evidence from the immutable retained
file, rather than using the packet's prebuilt counterexample. The corrected CLI
returned status 1, emitted the expected `EvidenceDecodeError`, and created no
raw output. Independent boundary probes also rejected space, tab, and CR forms
after the exact console label and rejected alternate whitespace in the main
canonical header.

The unchanged retained evidence, SHA-256
`5bfcd98425f0d3e554a343e89775d2ba2f56212ac21753bc15a6542c5818e378`,
still decoded successfully. The result was exactly 25,120 bytes, mode 0400,
single-link, byte-identical to the committed raw console, and SHA-256
`171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3`.
The accepted corrected checker `4a8e9e55…` and unchanged bridge
`b691c19d…` both passed that recovered console.

The original wrapper remains SHA-256
`3688e58f9efd4d2ba3b4fa9c139ef0923f535aace60eae0577e5cc2c630d4002`
and still contains exactly one `RUN-STATUS=1 CHECKER-STATUS=1`. Offline
acceptance changes the correctness disposition of the host artifacts, not those
historical bytes.

### Final finite gate state

- **Guest functional fixture:** accepted for both exact fixed language
  exchanges and complete accepted cleanup.
- **Corrected checker:** accepted at `4a8e9e55…`.
- **Canonical extractor:** accepted at `5e7aeca0…`.
- **Ancillary relevant-subset machine gate:** accepted at `af05d9f8…` with
  11/11 matching paths.
- **Historical command:** permanently preserved as status 1/1, not relabelled.
- **Offline fixed-fixture protocol artifact gate:** closed; no QEMU, runsc, ARM,
  image, Guix build, kernel, or hardware rerun is needed.

Any change to the accepted extractor, test, checker, bridge, outer, retained
evidence, raw console, or 11-path packet requires fresh focused review.
