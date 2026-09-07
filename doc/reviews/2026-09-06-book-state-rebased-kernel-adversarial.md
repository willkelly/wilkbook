# Rebased Book State test kernel — adversarial static review — 2026-09-06

## Verdict

**Not accepted for the separate QEMU boot yet.** The retained kernel output is
source-attributed and its claimed static binary/configuration properties check
out, but the required final-source preflight is red. The build proceeded after
that failure and the preflight was not rerun against the built test kernel's
exact `.config`.

The first failure is a real repository checker defect, not an incorrectly
staged invocation and not evidence that the kernel source itself is wrong. A
private, non-repository correction exposed three inconsistent source-mode pins
and then passed the exact retained 15-patch source. That diagnostic result does
not waive the repository gate. The checked-in checker and its negative tests
must be corrected separately and the real gate must pass before any QEMU run.

No kernel rebuild is required if that correction changes only the host checker
and its tests. The exact already-realized kernel may be reconsidered after a
passing preflight against its target `.config`, provided every kernel/package,
derivation, output, source, Image, DTB, and module identity below is unchanged.

## Scope and evidence boundary

This was a static review only. It did not execute target code and makes no boot,
QEMU, ARM-runtime, runsc, KOReader, image, device, display, suspend, or hardware
claim.

Reviewed packet:

```text
/tmp/opencode/book-state-rebased-kernel-20260906-CRE501
```

Packet identities independently computed:

```text
REPORT.md
ace58a937364b7b3b003dea0e323e01f086dec35d8c19942cbd1d03bc90eba52

ARTIFACT-MANIFEST.sha256
511c695e2b5fa7674af22e8aa6f772d3feae484dd2f433df02555066a1eeab66

target-files.sha256
6695ea1383fc7175364036b2e39f691ed6cdc19a944fd356d9a27d6c5aa30e30

command-index.json
3f4d5d475a95d60f83897786bcec932efb17a886acf5a8405ec772c5b8ab28a8

validation-summary.json
98c896ce7382bdfa0a0856ffe982827d5bbe7095f3b343e89ed406f73d7437dc
```

All 182 entries in `ARTIFACT-MANIFEST.sha256` matched. They cover 166
physical regular files and 16 explicitly inventoried source-view symlinks; the
manifest itself is the sole excluded regular file. All nine absolute store-file
records in `target-files.sha256` matched.

The source-view symlinks are not immutable copies. In particular,
`pinenote/systems/pinenote-book-execution-spike.scm` is absent from commit
`549dded…` and was an untracked input. Its exact reviewed hash is
`b56fafc9c64cf3ba816de85d6766b562fe1e62aac9956bfc2506af49c8336c09`.
The build wrapper checked it before every pinned Guix command, the artifact
manifest currently authenticates the dereferenced bytes, and the resulting
derivation/builder is retained in the Guix store. Nevertheless, commit
`549dded…` alone is not the complete source identity. If the live untracked file
or any source-view target disappears or changes, the packet cannot be replayed
from its symlinks; a successor should freeze those inputs rather than relying on
the working tree.

Two other absent-at-commit files were hash-checked by the source-view verifier:

```text
74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa  pinenote/tools/book-execution-spike/guest-smoke.scm
a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c  pinenote/tools/book-execution-spike/oci-bundle.scm
```

They do not enter this kernel output's runtime closure. They are recorded here
only to make the packet's broader source-view boundary explicit.

## Independently confirmed static artifact facts

### Source and derivation

The repository HEAD was exactly:

```text
549dded816e5f73d2c11557ffcd3130a018b82a8
```

The test derivation and current patched source matched the packet:

```text
/gnu/store/61ls988abhyi7lzvm19plffyv580nxc1-linux-pinenote-book-execution-test-7.1.8-pinenote.drv
sha256 82cc9c8f2786f785af27e3739d04bb9534d70e75a226cc326dbee398a83d06cb

/gnu/store/9g90lkd7s7dj52y3px7lqpg942py4pnz-linux-7.1.8.tar.zst
sha256 9394e1218362235d6b059b41eace74dad0ced7fbf7b0e189bd6b1355d41af871
```

The source derivation has exactly the 15 PineNote patch inputs in package order.
Patch 15 is last and is exact probe-lifetime v2:

```text
1e9c9faa248a3ddf7cd2a30c56cb3267181543ef413891e3d3313eb5a42572b2
```

The retained source log records all 15 applications in that same order. A fresh
selective extraction from the exact source archive reproduced all 23 fixture
files byte-for-byte; all four forbidden retired paths were absent from the full
archive member inventory.

The base and test derivations have identical direct dependency sets except for
their generated builders. Removing the exact
`enable-user-namespaces-for-gvisor` phase wrapper makes the test builder
byte-identical to the base builder. Both builders name the same current patched
source. The private package therefore changes the inherited kernel recipe only
by:

1. enabling `USER_NS` after `configure`;
2. running `make olddefconfig`; and
3. requiring exact `CONFIG_USER_NS=y`.

The derivation prerequisite inventory has 914 unique paths and no gVisor,
Bazel, KOReader, OS-image, or system derivation selected. The installed output
has no direct store references; its runtime-requisite query returns only itself.

Pinned channel records matched:

```text
Guix    f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c
nonguix 653504e6551198c9b2b998c143d7cf2675b22547
saayix  a6ac453939f69ccee0cd699ddf55ef1e25d7913e
```

The 16-module positive `GUILE_LOAD_PATH` view and separate zero-Scheme `-L`
package-discovery view were checked at the start of the local build log. This is
an exact hash-pinned source view, not a claim that commit identity alone supplied
the untracked test package.

### Build record

Command 17 built the exact test derivation locally for
`aarch64-linux-gnu`, with `--no-grafts`, two cores, one job, and a 7,200-second
outer timeout. It exited 0 after 830.699704 seconds. Its 5,790,581-byte stderr
and 94-byte stdout records are untruncated.

The complete log has **27**, not 24, phase starts. The 27 success records are
identical and in the same order, including configure, the USER_NS phase, build,
check, install, strip, and runpath validation. The final successful-derivation
marker is present.

`REPORT.md` line 54 incorrectly says 24 phases. `build-phases.txt`,
`validation-summary.json`, command 21, and direct review of the complete build
log all establish 27. A successor packet must correct the report rather than
propagate the smaller count.

The warning census is complete and reproducible: 95 total, consisting of 74
Kconfig reassignment warnings, 19 missing-interpreter patch-shebang warnings,
one Guile imported-binding warning, and one inherited EBC `frame_counter`
compiler warning. No warning was unclassified. This is static warning
accounting, not a runtime-safety conclusion.

### Configuration and target files

The current 15-patch base config oracle is:

```text
/gnu/store/5csba72088511masili3mdvvv824vg33-linux-pinenote-7.1.8-pinenote/.config
sha256 211f8ffe2c8c53b31f848f9f68b8699ae40d84c09bb158d6dc93727ef8a7f582
```

The test config is:

```text
/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote/.config
sha256 0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
```

Independent semantic and full-text comparisons found exactly one changed
configuration line:

```diff
-# CONFIG_USER_NS is not set
+CONFIG_USER_NS=y
```

All recorded namespace, checkpoint/restore, seccomp, cgroup, ARM64, MMU,
PREEMPT_RT, and kexec requirements are `y`.

The output Image SHA-256 is
`5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9`.
It is 20,533,760 bytes, carries ARM64 magic `41524d64` at offset 56, and contains
the `Linux version 7.1.8` banner. No ARM instruction was executed.

Both PineNote DTBs are 63,768-byte FDTs with magic `d00dfeed` and matching
header total sizes. Their exact hashes are `6003bcf7…` (v1.1) and `e0530087…`
(v1.2). `rockchip_ebc.ko`, `rockchip_ebc_blit_neon.ko`, and `ws8100-pen.ko`
are ELF64 little-endian AArch64 relocatables with `7.1.8 ... aarch64` vermagic;
their exact SHA-256 records all passed.

### NAR encoding correction

Both recorded NAR strings have 52 characters, which is the expected
`ceil(256/5)` width for a SHA-256 base32 representation. They are not truncated.
However, command records 25 and 26 used Guix `--format=base32`, while
`nar-hashes.txt` says `format=nix-base32` and `REPORT.md` labels the values
“Nix base32.” Guix distinguishes those encodings.

The packet's actual `--format=base32` values reproduce as:

```text
4sp6qpkefircjt7iwshprenyrepmabd6dufiydjd4nqjgcqcjrwa  test output
gviiccfgxs5igisni6upl27h6gilcr7em5uv3beqaxxpnjomhfpa  patched source
```

The true `--format=nix-base32` values are:

```text
0v2c08596q734c6qq2hxgq2c07l9p28zi3mlx37j88ia8hyyi7z4  test output
0pirrjjzdvh5j225ssb7wi3v347iwzmzba279li87fmwlq482l1m  patched source
```

The algorithm and NAR serializer are correct; the metadata names the wrong
base32 encoding. This does not change the independently checked SHA-256 file
identities, but successor evidence must correct the format label and values as
a pair.

## Blocking finding RKQ-1: final-source preflight is internally impossible

Command 15 invoked the documented API exactly as written:

```text
pinenote/scripts/preflight/inspect-kernel-source.sh \
  current-15-patch-source-fixture-v1 \
  /gnu/store/5csba72088511masili3mdvvv824vg33-linux-pinenote-7.1.8-pinenote/.config
```

`inspect-kernel-source.sh` calls
`validate-rockchip-pm-source.sh CHECKER CANONICAL_PATCH APPLIED_SOURCE_TREE`.
That wrapper first validates the canonical BSP patch and then invokes
`check.py --source-tree` on the supplied fully applied source. Project docs also
describe this as inspection of the final kernel source. It is therefore not a
stage-specific validator accidentally called on the wrong patch stage.

The canonical BSP patch check passed. Final-source validation then exited 1 at
its first diagnostic:

```text
FAIL: PineNote DT stays baseline-deep only contains forbidden token:
      rockchip,suspend-state-override
```

This is contradictory because:

- `check.py` lines 316–324 say the prohibition concerns **this BSP patch's DT
  hunk**, not the final tree;
- `%linux-pinenote-patches` deliberately applies
  `linux-pinenote-7.0-ultra-rails.patch` after the BSP patch;
- that later patch must add exact `rockchip,suspend-state-override = <5>;` as
  one half of the hardware-proven matched pair;
- the final source contains exactly that value; and
- the same checker requires parser support for the standing override.

The independent `ultra-coupling-check` passed and established that the override,
three rail-off flips, and card-power flip remain together in the later patch.
That check complements final-source validation; it cannot turn a red preflight
green.

### Two additional failures masked by the first

A private checker copy was changed only enough to move the BSP-only prohibition
out of final-source policy and require one exact final `<5>` override. The next
failure showed that line 442 requires `dt_state_override` in
`rockchip_suspend_of.c`. The actual reviewed state snapshot and `.prepare`
restore correctly live in `rockchip_suspend_activate.c`, where the source has
all expected references. The checker names the wrong source object.

After privately correcting that origin, the source mutation suite failed before
running because lines 707–708 demand
`# CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE is not set`. Production validation at
lines 294–298 requires the same final defconfig to contain exactly
`CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y`. The mutation anchor is stale.

With all three contradictions corrected only in `/tmp`, both canonical-patch
validation and full final-source validation—including the existing source
mutation suite—passed. Additional private mutations removing the final override,
changing it to `<3>`, or duplicating it were all rejected. The canonical BSP DT
hunk was independently confirmed not to add the standing assignment. No
repository file was edited by this experiment.

### Minimum non-weakening repair

A separately assigned fix should, at minimum:

1. retain the baseline-only prohibition on the canonical BSP patch's **DTS
   section**, where the checker comments say it belongs;
2. make final-source validation require exactly one
   `rockchip,suspend-state-override = <5>;` rather than forbidding it;
3. check `dt_state_override` restore provenance in
   `rockchip_suspend_activate.c`, not the parser source;
4. mutate the real final activation line `CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y`;
5. add negative source cases for missing, wrong, and duplicate final overrides;
6. retain `validate-ultra-coupling.sh` as the separate one-patch/order guard; and
7. pass the actual canonical patch check, source-wrapper tests,
   `make rockchip-pm-check`, `make ultra-coupling-check`, and the final
   `inspect-kernel-source.sh` invocation.

No production requirement should be removed or waived. This is a checker-scope
and mutation-fixture repair.

## Gate-order deviation and exact unblock condition

The packet preserves all four nonzero commands:

```text
07  pinned Guix lacks attempted `guix derivation` subcommand       exit 1
10  artifact-local derivation checker false negative               exit 1
15  real repository final-source preflight                         exit 1
20  artifact-local config-diff counter false negative              exit 1
```

Commands 11 and 21 correct the artifact-local errors from 10 and 20; direct
reference inspection replaces unavailable command 07. Those three have
successful, reviewable successor evidence. Command 15 does not: it is still the
checked-in production gate and remains red.

Despite command 15, command 16 ran and command 17 performed the 830.7-second
kernel build. This violates the project's “stop at the first failed ladder
gate” discipline. The later successful build establishes artifact properties;
it does not retroactively satisfy the earlier source gate.

Command 15 also supplied the current **base** `.config`, not the eventual test
output `.config`. The exact one-line comparison proves every PM symbol checked
by the script is identical, so this does not create a hidden binary delta.
Nevertheless, the qualification command for this candidate must use exact
target config
`0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309`.

The QEMU block closes only when a reviewed checker successor passes against:

```text
source sha256  9394e1218362235d6b059b41eace74dad0ced7fbf7b0e189bd6b1355d41af871
target config  0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
```

and the target derivation/output/Image/DTB/module hashes remain exactly those in
this review. If any executable checker, package, patch, derivation, source,
configuration, or output identity changes, perform fresh review at the affected
boundary. Do not run QEMU under this verdict.

## Review conduct

No implementation, frozen packet, observer, UI, architecture/protocol, image,
kernel, or patch source was edited. No kernel/Guix/Bazel/image build, QEMU, ARM,
runsc, KOReader, mount, network investigation, deployment, hardware operation,
staging, commit, push, fetch, merge, rebase, or reboot occurred. Reviewer-created
temporary source extracts, checker copies, and comparison files were removed.

## Successor re-review — checker packet v2

### Verdict

**The three original RKQ-1 contradictions are closed, but the checker
successor is not accepted and the separate QEMU boot remains blocked.** Two
realistic structural counterexamples are accepted by the complete final-source
gate: the sole exact ultra override can be moved out of the `rockchip-suspend`
node, and the DT-policy restore can be moved until after policy construction and
execution. The exact retained source does neither; this is a fail-closed
checker defect, not evidence of a defect in the retained kernel output.

This verdict does not make a GitHub PR merge a prerequisite for local offline
QEMU validation. The repository's PR-only rule governs what reaches GitHub
`main`. The actual prerequisite here is a further checker-only successor that
rejects the counterexamples, passes the exact source/config preflight, and is
independently reviewed. No kernel rebuild is needed if all kernel and output
identities remain unchanged.

Reviewed successor packet:

```text
/tmp/opencode/book-state-rebased-kernel-20260906-CRE501-v2

b5856fca9bc7b53e3d7869d3730f540b83866542f2687907e45c00439f401f37  evidence/SUCCESSOR-REPORT.md
cca84fdfe303c1594884b8f044c34f5ea9ab0fd4d4a1da0d1078344ef2a1f49e  evidence/SUCCESSOR-MANIFEST.sha256
```

All 121 manifest entries passed. They inventory all 121 physical regular files
other than the manifest itself; the successor packet has no symlinks, missing
records, or extra records. Its selective 23-file final-source fixture is frozen
as regular files and names source archive SHA-256 `9394e121…`. This corrects
the predecessor packet's mutable source-view boundary for this focused
re-review. `SOURCE-CHANGES.patch`, baseline commit `549dded…`, and the following
successor hashes pin the two implementation-side edits:

```text
e4f5c99f6f74c4971a03f6787f2caa3aab58ed56d8edad28c54c91440281f924  pinenote/tools/rockchip-pm/check.py
fdeb198ebfe94fc8cf3034f788f1bee281bbbed673b733080e98e08eaf8fa0bd  pinenote/tools/rockchip-pm/README.md
```

The live files matched those hashes. Their diff changes only the checker and
its README; the kernel package and patch diff is empty. These files remain
unstaged and uncommitted.

### What the successor demonstrably closes

The 19 complete command records contain exactly the three declared diagnostic
failures: the preserved original red preflight and two superseded host-tool
invocation errors. No stream is truncated. Independent finite replay confirmed:

1. canonical-patch mode still rejects an ultra override added to the BSP
   patch's PineNote DTS section;
2. final-source mode accepts the exact retained source and rejects missing,
   `<3>`, and duplicate override mutations;
3. the activation mutation has one real anchor and changes the production
   `CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y` line to the disabled form;
4. the restore literal is now required inside
   `rockchip_suspend_prepare()` in `rockchip_suspend_activate.c`; merely naming
   `dt_state_override` in the parser does not satisfy it;
5. the canonical patch mutation suite and the supplied focused regression
   controls pass;
6. the declared Guix host-tool run passes the compiled fake model/executor and
   DTB tests, patch mutations, and wrapper failure tests; and
7. the authoritative ultra-coupling gate passes.

The repository `inspect-kernel-source.sh` preflight also passes against the
frozen fixture extracted from source SHA-256 `9394e121…` and the **actual test
output** `.config` SHA-256 `0a885ef8…`. Its only diagnostics are the expected
warnings that a selective extracted source is not a Git checkout and that
static inspection does not prove a hardware boot.

### Blocking finding RKQ-2: final override validation is not node-scoped

Final-source validation counts `rockchip,suspend-state-override` over the whole
`rk3566-pinenote.dtsi` text and separately searches that whole file for the
exact `<5>` assignment. It does not establish that the property belongs to the
`rockchip-suspend` node consumed by the Rockchip parser.

An independent in-memory mutation removed the sole exact line from
`rockchip-suspend` and inserted the same line under `/chosen`, immediately
after `stdout-path`. There was still exactly one property name and one exact
`<5>` token in the file, but the Rockchip suspend node no longer carried the
standing override. Both `validate_production_sources()` **and the complete
built-in `run_source_mutations()` suite accepted this source**:

```text
sole-exact-override-moved-from-rockchip-suspend-to-chosen=ACCEPTED_BY_FULL_SOURCE_GATE
```

This is not a cosmetic nesting trick: a property attached to `/chosen` is not
the policy property parsed from the matched Rockchip suspend device node. The
separate ultra-coupling patch gate does not replace final-tree node ownership;
a later patch in the applied stack could move the property while leaving the
original coupling patch unchanged.

The next successor must scope the exact-one/exact-`<5>` requirement to the
actual top-level `rockchip-suspend` node and reject the same property outside
that node. It should retain the whole-file duplicate defense so a valid node
assignment plus a stray second assignment also fails.

### Blocking finding RKQ-3: the restore is function-scoped but not ordered

The wrong-file defect is repaired: the checker extracts
`rockchip_suspend_prepare()` from the activation source and requires the exact
two-line restore there. It does not, however, include that restore in the
already enforced prepare-phase ordering.

An independent in-memory mutation moved the exact restore assignment from its
correct position before one-shot-arm handling to immediately after the
`rockchip_suspend_execute(...)` statement. This leaves the required literal in
the right function but makes it too late to affect the policy built and
executed for that suspend. Again, both production validation and the complete
built-in source-mutation suite accepted it:

```text
restore-moved-after-policy-build-and-execute=ACCEPTED_BY_FULL_SOURCE_GATE
```

The next successor must require the DT snapshot restore before any one-shot
override handling and, at minimum, before `rockchip_suspend_model_build_probe`,
`rockchip_suspend_model_build_prepare`, and `rockchip_suspend_execute`. A
focused relocation negative should prove this is not merely another
presence-only token pin.

### Preserved artifact and chronology facts

The successor manifest, all nine target-file records, and direct finite hashes
confirm that the derivation, exact source, target config, Image, both DTBs, and
three modules remain unchanged. In particular:

```text
9394e1218362235d6b059b41eace74dad0ced7fbf7b0e189bd6b1355d41af871  exact 15-patch source
0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309  target .config
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  Image
```

The focused packet correctly records 27 successful build phases and the
unchanged 95-warning census. It correctly distinguishes Guix `base32` from
`nix-base32` and supplies the previously verified values for both encodings.
It also preserves rather than rewrites the original command-15 RED result, the
subsequent continued build, and the resulting rung-order violation. A new green
preflight cannot manufacture an original status-zero result.

No previously accepted static kernel property was reopened or needlessly
recomputed. No QEMU, target code, kernel/image/Guix build, mount, device,
network, staging, commit, push, fetch, merge, or rebase was performed in this
successor review. The only repository edit made by the reviewer is this review
append.

## Final successor re-review — checker packet v3

### Verdict

**Accepted: RKQ-2 and RKQ-3 are closed, and the retained test kernel is fit to
advance to a separately scoped PineNote QEMU boot.** The three earlier RKQ-1
repairs remain valid. The exact retained kernel source is unchanged and correct;
the v3 checker now rejects both counterexamples that v2 accepted. No concrete
counterexample survived the finite recheck within the checker's stated,
deliberately structural boundary.

This is source-gate clearance, not evidence of a boot and not acceptance of any
new guest integration layered above the kernel. A later QEMU run remains a
separate activity with its own exact inputs and evidence. Local QEMU validation
does not require the checker change to be merged through GitHub first; the
PR-only rule governs publication to GitHub `main`, not local ladder order.

Reviewed packet and independently computed identities:

```text
/tmp/opencode/book-state-rebased-kernel-20260906-CRE501-v3

246db7c01b1314dca954609c0d6f3f1789eb4a45dcfc775fe2d1829cd17247af  evidence/SUCCESSOR-REPORT.md
c3353a557037e60d06bd00b62422a3183a6691fe730a2030cb67f560b5cf8c80  evidence/SUCCESSOR-MANIFEST.sha256
c3ed3c9d14b14faaca28458b3be9c491778b3bc9f8d88c287496acc87b8c800d  pinenote/tools/rockchip-pm/check.py
fe127710a1c327b7627a3d0f0c806d03853577fcb963eae22286476d96fb7dae  pinenote/tools/rockchip-pm/README.md
```

All 113 successor-manifest entries passed and exactly inventory the 113 regular
files other than the manifest itself. There are no symlinks, omitted files, or
extra records. All 18 recorded commands exited zero, all streams are complete,
and none is truncated. The frozen 23-file fixture identifies exact source
archive SHA-256 `9394e121…`; the v2 checker snapshot and v2-to-v3 incremental
patch make the reviewed successor independently inspectable. The live checker
and README match the packet hashes. Their cumulative repository diff contains
only those two files, with an empty tracked kernel package/patch diff; both
remain unstaged and uncommitted.

The predecessor identities also remain exact:

```text
ace58a937364b7b3b003dea0e323e01f086dec35d8c19942cbd1d03bc90eba52  v1 REPORT.md
511c695e2b5fa7674af22e8aa6f772d3feae484dd2f433df02555066a1eeab66  v1 ARTIFACT-MANIFEST.sha256
b5856fca9bc7b53e3d7869d3730f540b83866542f2687907e45c00439f401f37  v2 SUCCESSOR-REPORT.md
cca84fdfe303c1594884b8f044c34f5ea9ab0fd4d4a1da0d1078344ef2a1f49e  v2 SUCCESSOR-MANIFEST.sha256
7fa50214771f10bc068daef51eaee0fc1acb053d51d4bf0f2c79ce32f4e13473  pre-v3 review text
```

### Finite independent checker recheck

The review replayed the exact v2 RKQ-2 and RKQ-3 mutations against the live v3
checker. Both are now rejected by initial production-source validation, so they
cannot reach a successful complete source gate:

1. moving the sole exact `<5>` assignment from `rockchip-suspend` to `/chosen`
   fails because the direct suspend-node body no longer has the property; and
2. moving the exact DT snapshot restore after `rockchip_suspend_execute()`
   fails because policy is used before the restore.

An additional bounded matrix checked the new structural boundary rather than
demanding a general DTS or C parser:

- exact retained source plus the complete built-in mutation suite: accepted;
- override moved to `/chosen`, into a nested suspend child, or only into a
  comment: rejected;
- wrong direct `rockchip,pm-rk3568` compatible: rejected;
- balanced counterfeit node/property text in a comment: ignored and accepted;
- an unrelated nested child containing quoted braces: accepted without
  counterfeit scope;
- restore moved late, preceded by a real policy use, placed in a braced or bare
  condition, placed behind `#if 0`, or retained only in a comment: rejected;
- policy-like text only in a comment before the correct direct restore: ignored
  and accepted.

The supplied focused controls additionally reject missing, `<3>`, duplicate,
labeled-node, whole-node-under-`/chosen`, changed-compatible, and unterminated-
comment DTS cases. They retain the real unique production
`CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y` to disabled mutation, canonical BSP
patch isolation, existing patch/source mutations, direct-function restore
scope, and restore-before-arm/build/build/execute ordering. These properties
close RKQ-1 through RKQ-3 for the known reviewed source shape; they do not claim
semantic coverage of arbitrary C programs or DTS syntax.

The checker changes affect only Python source placement and ordering checks.
The compiled fake-model/DTB suite was therefore not repeated; its accepted v2
result is not invalidated by this incremental boundary. Both the supplied and
independently rerun authoritative ultra-coupling checks pass.

### Exact preflight and unchanged target

The full repository source preflight was independently rerun and passed against
the frozen fixture from:

```text
9394e1218362235d6b059b41eace74dad0ced7fbf7b0e189bd6b1355d41af871  exact 15-patch source archive
0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309  actual test-output .config
```

The config is the retained test output at
`/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote/.config`,
not the base-kernel config. The only preflight diagnostics are the expected
warnings that the selective frozen fixture is not a Git checkout and that
static inspection does not prove a hardware boot.

All nine target records passed again. The derivation, source, config, Image,
both DTBs, and all three modules are unchanged; the Image remains:

```text
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9
```

No recompilation was performed or required. The retained 27 successful phases,
95-warning census, and corrected Guix/Nix base32 labels remain predecessor
facts. Most importantly, the original command-15 RED result, the build that
continued afterward, and the rung-order violation remain historical truth.
V3 supplies a later accepted green gate; it does not relabel or overwrite that
failed command as an original pass.

This acceptance is pinned to the checker, source, actual target config,
derivation, and nine target identities recorded above. Any change at those
boundaries requires fresh review. No QEMU, ARM/native target code, kernel/image/
Guix build, device, mount, network operation, staging, commit, push, fetch,
merge, or rebase occurred during this final source-gate review.
