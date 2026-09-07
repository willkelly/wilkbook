# Book State actual-QEMU guardian integration adversarial review — 2026-09-06

## Disposition

**Do not accept the complete frozen integration packet yet.** One finite,
reproducible blocker remains in its offline evidence checker: the checker treats
any line beginning with its one allowed `FAIL:` prefix as the expected
conservative run-root refusal. It accepts both an unrelated path and arbitrary
extra failure text on that line.

This is a checker defect, not a counterexample to the actual process or disk
lifecycle. No implementation-source blocker was found in the reviewed seam.
The supplied run and two independent source-exact runs establish the intended
paused-QEMU boundary on this host:

- the v3 handoff FD is the only descriptor above stderr made inheritable;
- the same open file description survives the real QEMU `exec`;
- actual QMP identifies the expected writable file/raw state nodes and virtio
  device while QEMU remains at `prelaunch` under `-S`;
- a separate actual QEMU receives the expected `locking=on` write-lock refusal,
  including after the owner has died while the first QEMU remains alive;
- normal close, owner `TERM`, and owner `SIGKILL` all join/reap the exact owned
  QEMU/process guardian before a later writer can acquire the image; and
- replacement of the watched run-root pathname is refused and the foreign root
  is preserved rather than traversed or deleted.

Those results may be banked. Correct and independently recheck only the frozen
checker/evidence boundary; another QEMU run is not necessary if the integration
sources and runtime evidence remain byte-identical. Until that recheck closes,
do not promote this packet as accepted integration.

Even after that correction, this is **conditional host integration only**. QEMU
was paused before guest execution. Two fresh guest supervisors must still prove
save, clean shutdown, reopen, and paint before semantic Book State persistence
is accepted.

## Frozen authority

The review used this packet as source authority, not the mutable checkout:

```text
/tmp/opencode/book-state-qemu-guardian-integration-review-complete.KuzKWi
```

| Frozen input | SHA-256 |
|---|---|
| `SOURCE-HASHES.sha256` | `a351d143e507f6e803ef582d37a3abe604ad50b58989b9dbb14ebe7bf4dd8e40` |
| source snapshot manifest | `19f78119ebd704f7f5e54cebff387c6430f22598d04129c3972c07b363bcfe27` |
| accepted volume-v3 nested manifest | `653b47b5a167e3fcfa35f8631cd5bcba32d717a45f40f769b9630c2eb65294ec` |
| accepted `disposable-qemu.scm` | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| accepted `reader-qemu-graph.scm` | `16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002` |
| accepted v3 `state-volume.scm` | `79324bbb80ba8eb9e57c4d8285b0d6f4f76020bfb1016d0e8c22fe8526b42d29` |
| accepted v3 `qemu-graph.scm` | `708ccca8fe367a20ef886168bed524704a5cdd0a97acf5f0609eecd822ad977c` |
| candidate `disposable-qemu.scm` | `902fe23f17dddace67f40b9cb7ae0d7ccbdbc81f0ae4779683cbca8db8dd4c62` |
| candidate patch | `2539b34ee34953941c514bb9a797dc1f952551faee59c476a3004749902f5c4a` |
| `successor-state-guardian.scm` | `efbc6c156ddc582b5d0225b527874958b91745a7272fcfd78725314cb0860306` |
| `successor-reader-graph.scm` | `bcb3464f5b1f7e1b714b0f8da9e1d918445cc24d23cb9a571ee0646d5d064741` |
| `qmp-probe.scm` | `abe74938fcbe528dffd8ddd3def1e7960ceddeeb637feb5ee7e1185c9c20587b` |
| `run-guardian-integration.scm` | `d9366905bc24c02113d771ae15db0d55c04f150ca20c9c511193bca8756a462c` |
| `verify-evidence.scm` | `a267f0a06ad2494b3858cb45c1d036fc58d97c908bc5f2ff89b576de8b14ae0a` |

All 28 entries in the source hash inventory verified. The packet records
working-tree commit `549dded816e5f73d2c11557ffcd3130a018b82a8` as context only.
No finding or runtime result depends on that checkout.

The candidate outer differs from accepted `disposable-qemu.scm` only by three
optional hooks and their plumbing: an exec-child extension after the deny-all
`FD_CLOEXEC` sweep, an exact process-guardian observer, and an exact direct-child
observer. Its existing subreaper, process-group, owner-liveness, TERM-to-KILL,
reap, and run-root guardian logic is unchanged. The default hook values retain
the accepted no-inherited-protocol-FD behavior.

The accepted volume helper, accepted outer/reader graph, immutable reader
assets, backend, protocol, Book Session, guest, and 45-path sandbox closure were
not edited.

## Supplied evidence

The supplied evidence packet was verified in place:

```text
/tmp/opencode/book-state-qemu-guardian-integration-evidence.YEEaZk
```

| Supplied evidence input | SHA-256 |
|---|---|
| `EVIDENCE-HASHES.sha256` | `565616df394eb9ff74bac009dc02e8e32d19060fa44f3eed0aee755b42381fcb` |
| evidence manifest | `2ef80eafc07295e4bc318bd40006bccb73b3577beaf849984d404cb0a1401ae8` |

Every enumerated evidence file verified. The implementation-authored runtime
reported **38/38**, and the frozen offline checker reported **24/24**. Six
integration modules compiled without warnings. The unchanged 87-assertion v3
host suite was intentionally not rerun because this candidate changes no volume
or graph unit behavior; its accepted result remains bound through the nested v3
packet.

The supplied run used exact QEMU 10.2.1, `qemu-img`, `e2fsprogs` 1.47.2, and the
recorded historical PineNote test-kernel and accepted read-only root assets. The
kernel and boot-bundle `Image` both hash to
`f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223`.
That is a fixed historical artifact identity, not an assertion that the mutable
tree would rebuild the same kernel today. QEMU was passed `-S`, so the kernel was
not executed.

Positive QEMUs were limited to 2 vCPU and 512 MiB; contenders to 1 vCPU and
128 MiB. The exact vectors retained `-nic none`, contained no host share, used a
fresh qcow2 root overlay over the accepted read-only baseline, and appended only
the descriptor-bound state file/raw/virtio graph plus a private Unix QMP socket.

The one runtime line below is expected evidence of conservative preservation,
not a test failure:

```text
FAIL: root guardian refuses replaced run directory: <exact owner-sigkill root>
```

The defect is that the offline checker does not require the exact suffix shown
by the structured evidence, as detailed below.

## Independent evidence

The independently frozen evidence packet is:

```text
/tmp/opencode/book-state-qemu-guardian-independent-review-evidence.nd9YPt
```

| Independent evidence | SHA-256 |
|---|---|
| `EVIDENCE.txt` | `328c8b37840435f1e474018a1bf9001a75bce902f0ddf4f7a6f9f71fd6ffc632` |
| `EVIDENCE-HASHES.sha256` | `f0b3aaaa5e915804be8a9d06f48982c1b65b86d5e758b040104d0163a91be629` |
| evidence manifest | `768e85961b998a9da1e7ffd8aa86f48b8db09de33b6e54a4206bcf6b777f8dd4` |
| `independent-actual-run.log` | `450d16da0a634846baaf5a723f53ba3f5e6a25608e5899488c393cd13f6c2a42` |
| `independent-actual-offline.log` | `252a32dba0680e176c35ab3562ddf3fcabe16d1faf961e95db1579f4f653b0ce` |
| `postexec-ofd-observer.py` | `27711b1b12d2fb08fd722a22aba2d6790bdf838fe808b71695f280839274a2b5` |
| `postexec-ofd-result.json` | `fc3d714e29d620373749246be2ab5607b0e0b4b5150df93dfd8fc52f0d18147a` |
| `mutation-probe.py` | `f22e40ead46b7478cc1ba71129102c9bf2e8a5614aa73d22e7055d844f022b48` |
| `mutation-probe.log` | `1f16ec4f29d4b4c321168cf87255ba6d03a66c76a235ecc4da8d2e74e76f9cfa` |
| `cleanup-check.log` | `a776663d71cf3962d7626c2843f0ad651ea15c90e6f1eb30f15c375cf047376f` |

The packet includes every raw record from both independent actual-QEMU runs,
the review scripts, source and supplied-evidence verification logs, the supplied
packet's offline-check result, and the independent replay's offline-check
result. Every enumerated file reverified after freezing.

The first independent replay loaded only frozen source paths ahead of any
mutable path, ran interpreted under Guile 3.0.11 with `--no-auto-compile`, and
reproduced **38/38**. Its newly generated raw evidence then passed the frozen
checker **24/24**.

The second replay used the same frozen runner and sources. An independent parent
observer stopped only its top-level runner after the normal QEMU had completed
`exec` and published actual QMP evidence. It checked the exact recorded QEMU
PID/start-time and process ancestry, then invoked Linux x86-64 syscall 312 with
`KCMP_FILE=0` across processes:

```text
QEMU FD 13 vs owner FD 11 => 0
QEMU FD 13 vs owner FD 13 => 0
QEMU FD 13 vs fresh reviewer O_RDWR open of the same inode => 1
```

Only zero means the same open file description. Thus the QEMU process retained
the v3 handoff OFD across real `exec`; this result does not infer authority from
matching device/inode alone. The fresh same-inode control compared different.
The observer resumed the runner, which completed **38/38**.

All recorded owner, QEMU, process-guardian, and run-root-guardian process
instances were gone afterward. All three exact temporary work roots from the
supplied and independent runs were absent. No broad PID/name scan was used to
signal a process, and no unrelated root was removed.

## What the actual-QEMU evidence proves

### Exact descriptor inheritance and graph

The exec-child hook runs only after the accepted outer marks every descriptor
above stderr `FD_CLOEXEC`. It rechecks retained state identity, compares the
handoff FD to the private writer anchor with `KCMP_FILE`, confirms both were
close-on-exec, clears `FD_CLOEXEC` only on the handoff duplicate, and then
requires the complete inheritable set above stderr to equal that one FD. The
anchor remains `CLOEXEC`.

The actual QEMU command line names `/proc/self/fd/N`. QMP `query-status`
reported `prelaunch`, while `query-named-block-nodes` and `query-block` showed:

- writable `book-state-file`, format `file`, at that inherited proc-FD;
- writable `book-state`, format `raw`, whose child is `book-state-file`; and
- `/machine/peripheral/book-state-disk/virtio-backend` attached to that raw
  node.

The independent post-exec `KCMP_FILE` result completes the open-file-description
identity proof that QMP's inode-bearing proc path alone could not provide.

This handoff is only host disk authority. It does not donate a Book Protocol FD,
Book Session binding, namespace choice, expected value, or book capability. No
state token was exposed to a sandbox or carried in a book message.

### Real `locking=on` exclusion

While the normal paused reader QEMU held the state image, a separate actual QEMU
opened the same retained inode through a fresh pathname open. It exited 1 with
the exact QEMU diagnostic `Failed to get "write" lock`; its graph had passed
construction and it reached QEMU's image-file lock acquisition.

The owner-death case separates QEMU locking from `owner.lock`. The test stopped
the exact first QEMU, killed its owner with `SIGKILL`, and demonstrated that
`owner.lock` was already reacquirable while that QEMU remained alive. A new
lease, writer window, and handoff then launched a separate actual QEMU against
the same inode through a fresh inherited OFD. It also exited 1 with the exact
write-lock diagnostic, this time naming `/proc/self/fd/N`.

Therefore the second writer stayed blocked until the first QEMU was reaped; the
result does not assume the dead owner's advisory lease protected the inode.
After the old guardian reaped the stopped QEMU, a fresh owner and actual QEMU
opened the same retained state inode and exited normally through QMP `quit`.

### Guardian ordering and conservative cleanup

The normal event records order process-guardian join and exact QEMU disappearance
before handoff return, writer-window return, lease return, and run-root cleanup.
The catchable `TERM` case returned signal-derived status 143 and likewise joined
the process and run-root guardians before owner completion.

For uncatchable owner `SIGKILL`, owner-liveness EOF—not a PID file or lease—made
the existing process guardian terminate/reap its exact QEMU process group. The
test renamed the original watched root and installed a different mode-0700 root
plus unknown marker at the old pathname. The run-root guardian compared the
recorded directory identity, refused cleanup, and left both the renamed original
and foreign replacement untouched. The test owner removed them only after
recording and verifying both identities and the marker.

The guardian records bind PID and `/proc/PID/stat` start time. Teardown uses the
known child/guardian identities and one established process group; it does not
kill arbitrary same-PID replacements or search processes by name.

## Finding 1 — blocking: the expected `FAIL:` exemption is prefix-only

`verify-evidence.scm:117–122` performs only these two tests:

```scheme
(= (count-substring runtime
                    "FAIL: root guardian refuses replaced run directory:")
   1)
(= (count-substring runtime "FAIL:") 1)
```

It never binds that line to `owner-sigkill.foreign-root.scm` or requires the
line to end after the exact recorded replacement path.

The independent mutation probe copied the complete independently generated
evidence and changed one input at a time:

| Mutation | Frozen checker result |
|---|---|
| unchanged evidence | accepted 24/24 |
| add a separate unrelated `FAIL:` line | rejected at check 6 |
| change expected line's path to `/unrelated/not-the-recorded-root` | **accepted 24/24** |
| append ` ARBITRARY-FAILURE-TEXT` to the expected line | **accepted 24/24** |
| replace the actual QEMU write-lock diagnostic | rejected at check 15 |

The two bold rows are counterexamples, not desired behavior. They show that one
allowed substring currently acts as a generic hiding place for arbitrary
failure content. This violates the review requirement that no arbitrary
`FAIL:` be green merely because it shares the allowed prefix.

### Required correction

Parse `runtime.log` by complete lines. Require exactly one line beginning
`FAIL:`, and require that line to be byte-equal to:

```text
FAIL: root guardian refuses replaced run directory: <replacement-path>
```

where `<replacement-path>` is the exact `replacement-path` in
`owner-sigkill.foreign-root.scm`, itself equal to the `run-root` in the
`owner-sigkill` root record. Reject leading/trailing bytes, a different path,
multiple matches, embedded newlines, and every other `FAIL:` line. A structured
guardian refusal record checked independently of presentation text would be
stronger still.

Freeze a successor checker with a new source manifest and run at least the five
mutation cases above against both the supplied and independent immutable
evidence. If integration and runtime evidence hashes remain unchanged, that
finite correction does not require another actual-QEMU execution.

## Remaining boundary

Once the checker finding closes, the accepted claim should be exactly:

> On this reviewed Linux host, the accepted volume-v3 handoff can pass one exact
> OFD through the successor guardian into an actual paused QEMU; actual QEMU
> enforces `locking=on`; and normal, TERM, and SIGKILL ownership paths join the
> exact process group before reopening the retained image.

It must not be restated as guest execution, backend durability, Book Session
integration, or semantic persistence. The next stateful milestone remains the
separately frozen two-boot campaign: boot 1 must run the real guest supervisor,
save through the reviewed backend, and shut down cleanly; boot 2 must use a
fresh root overlay and fresh processes, reopen the retained state, and paint it
through the real reader path.

No guest instruction, runsc, ARM book, KOReader, host mount, root block device,
network, kernel/OS/image build, hardware, deployment, staging, commit, push, or
merge occurred in this review. No implementation or frozen packet was edited;
this review document and private independent evidence are the only outputs.

## Checker-successor finite recheck — 2026-09-06

### Disposition

**Accept the checker-only successor and close Finding 1.** Combined with the
already banked source-exact actual-QEMU results above, the paused-QEMU guardian
integration is accepted at its exact conditional host boundary.

This does not retroactively strengthen or alter the original checker. Its
prefix-only `FAIL:` exemption remains a historical rejected artifact. The
accepted composition is the unchanged parent integration and runtime sources,
the unchanged supplied and independent runtime evidence, and the separately
frozen successor checker reviewed here.

No actual QEMU rerun was needed or performed. The runtime runner remains
`d9366905bc24c02113d771ae15db0d55c04f150ca20c9c511193bca8756a462c`,
and both prior 38/38 source-exact executions remain the functional evidence.
This recheck changes only how those immutable artifacts are checked offline.

The accepted claim remains:

> On this reviewed Linux host, the accepted volume-v3 handoff can pass one exact
> OFD through the successor guardian into an actual paused QEMU; actual QEMU
> enforces `locking=on`; and normal, TERM, and SIGKILL ownership paths join the
> exact process group before reopening the retained image.

Guest execution and semantic persistence remain unproven. The next integration
gate is still two fresh real guest supervisors proving save, clean shutdown,
reopen, and paint.

### Preserved review and frozen authority

Before this append, this document was byte-identical to the first review at:

```text
0ddcdf73d13c427633f0872d99070956f770698fae47d9082f70e5c60734ad58
```

That complete prefix—including the original blocker and its counterexamples—was
preserved. The successor packet binds that hash rather than replacing the
review history.

Checker-successor source authority:

```text
/tmp/opencode/book-state-qemu-guardian-checker-successor.3awbKu
```

| Successor input | SHA-256 |
|---|---|
| `PACKET-HASHES.sha256` | `a29712dc8a6d4d24e927fa8665410b56cf9679dd9a2f3363133f28709a7a8a07` |
| packet manifest | `f1c5e7ec0c5a63fea33a23a0009ad42df1e333a020f962ec3f52f6849a610393` |
| parent v1 `verify-evidence.scm` | `a267f0a06ad2494b3858cb45c1d036fc58d97c908bc5f2ff89b576de8b14ae0a` |
| successor `verify-evidence.scm` | `2619f166764f416b683268652a486a687227657086097156fea4513bab27f136` |
| `test-verify-evidence.scm` | `790d81c8afe3a2ab2f0de4d996ac444c6104854113b482adea401164de27b33a` |
| exact v1-to-successor patch | `f83f3affc224c53a4989626acb6bc3d2e9bb54e2bc1f9c795ee52274dc9455ed` |

Every packet hash verified. The packet's parent checker is byte-identical to the
checker in source manifest
`19f78119ebd704f7f5e54cebff387c6430f22598d04129c3972c07b363bcfe27`.
Applying the frozen patch to that exact parent produced the successor checker
byte-for-byte.

The following authorities also reverified without modification:

| Preserved authority | Manifest SHA-256 |
|---|---|
| parent integration source | `19f78119ebd704f7f5e54cebff387c6430f22598d04129c3972c07b363bcfe27` |
| supplied runtime evidence | `2ef80eafc07295e4bc318bd40006bccb73b3577beaf849984d404cb0a1401ae8` |
| prior independent evidence | `768e85961b998a9da1e7ffd8aa86f48b8db09de33b6e54a4206bcf6b777f8dd4` |

The integration runner, handoff/guardian source, graph source, QMP probe, actual
runtime logs, and structured evidence records were unchanged. No mutable
checkout file was used as source authority.

### Exact correction

The successor replaces the two permissive prefix/count checks with a finite
line and identity protocol:

1. `runtime.log` must contain LF-only records, exactly one final LF, no empty
   lines, and no control characters other than horizontal tab;
2. exactly one `FAIL:` occurrence and exactly one complete `FAIL:` line may
   exist;
3. that line must be byte-equal to the fixed refusal prefix plus the exact
   owner-SIGKILL `run-root`—no trim, regular expression, prefix-only match, or
   suffix is accepted;
4. it must occur immediately after exact runtime check 23 and immediately
   before exact runtime check 24;
5. the root must have the exact private randomized
   `/tmp/opencode/book-state-guardian-run.XXXXXX/runs/`
   `book-state-guardian.owner-sigkill.XXXXXX` shape; and
6. the same root path/device/inode is cross-bound through the owner-SIGKILL root
   record, exec record, and QMP socket record. The foreign record must identify
   that same replacement pathname/device with a different replacement inode,
   and its held-original path/device/inode and exact marker must identify the
   renamed original.

Thus the allowed diagnostic is no longer a generic prefix exemption. A changed
path, arbitrary suffix, leading text, trailing whitespace, duplicate, deletion,
phase move, CRLF, or contradictory structured record fails before the final
24/24 result.

### Finite execution results

The successor checker ran interpreted under Guile 3.0.11 with
`--no-auto-compile` and frozen dependency load paths. It passed **24/24** against
both immutable evidence sets:

- the originally supplied actual-QEMU evidence; and
- the independently generated actual-QEMU evidence from the first review.

The frozen checker-only suite passed **16/16** against each evidence set. Its
count consists of one unchanged positive control and fifteen one-variable
negative mutations:

- extra unrelated `FAIL:` line;
- another path;
- arbitrary suffix;
- trailing space/tab;
- duplicate exact refusal;
- leading prefix;
- deleted refusal;
- wrong phase order;
- missing or extra final LF;
- CRLF at the refusal;
- changed QEMU lock diagnostic;
- contradictory foreign-record path;
- coordinated but non-owned path substitutions; and
- contradictory original-root inode.

A reviewer-authored independent probe separately replayed the two original
counterexamples against both immutable evidence sets. Results were **6/6**:
both unchanged controls passed, while both unrelated-path mutations and both
arbitrary-suffix mutations returned failure. This directly reverses the two
bold counterexample rows in Finding 1 without relying only on the candidate's
own test driver.

The successor checker and finite test source also compiled with
`-Warity-mismatch -Wformat` and no warnings. All checker-test temporary roots
were removed.

### Independent checker evidence

The independently frozen checker-only evidence packet is:

```text
/tmp/opencode/book-state-qemu-guardian-checker-independent-evidence.hMRBuH
```

| Independent evidence | SHA-256 |
|---|---|
| `EVIDENCE.txt` | `b1956aba8a816bf3eb5202ab4483a449f9aba27c52f01dc0b06868b75eb16754` |
| `EVIDENCE-HASHES.sha256` | `d52cd230c4b32e74bc4a66fed8f3de0b46fcf3a9f950d74fe8f09ba91ce35e98` |
| evidence manifest | `8fe9e265dc02ccb11643444e7bdff83339a34bfa98a93098902c80842961694b` |
| `authority-verification.log` | `ce96d58cfcec36e6a773321226d690571a59c18defd4211712b137e98e591d96` |
| `diff-verification.log` | `2d878fa181f0cb4612f61b073a9dd03015230a0cefad46062e003b733f025250` |
| `independent-counterexample-recheck.py` | `b38f137489ee7b4afb0438d073c911b2b9ef01f7d2d0fd7fc3410877d5fa5804` |
| `independent-counterexample-recheck.log` | `5eefb63a74b41694130087dbaa673db710bfa84cfd25df8899b3d6cd01096bbc` |
| `independent-compile.log` | `15baf9e64cc84a2a2ce924381d374d8186b63724cf8296dfaf9f18663ec02726` |

Every enumerated evidence file verified after freezing.

### Static artifact-authentication boundary

The checker establishes exact consistency within the already authenticated
evidence. It is not a signature verifier. A hypothetical adversary allowed to
replace every runtime and structured record with a wholly coordinated,
valid-looking alternative could make self-consistent assertions; no content
checker can recover the original path identity from those self-attestations
alone.

That is not an accepted bypass here. The source and both runtime evidence sets
were first authenticated against their external immutable manifests, and only
then passed to the successor checker. The coordinated mutation test deliberately
checks that merely changing the refusal line and selected untrusted path fields
does not pass; it does not claim to turn self-attested records into a signing
scheme.

### Final boundary

Finding 1 is closed, and there is no remaining paused-QEMU guardian integration
finding. The old checker remains rejected; use the successor checker identity
above for this evidence.

This acceptance does not include a guest boot, Book State backend execution,
Book Session join, native KOReader persistence, or a current-kernel rebuild.
The separately active native/two-boot work is untouched. No QEMU, runsc, ARM
code, compiler other than the two checker files, kernel/OS/image build, mount,
block device, network, hardware, deployment, staging, commit, push, or merge
occurred during this finite recheck.
