# Book State QEMU volume helper adversarial review — 2026-09-06

## Disposition

**Do not accept this snapshot as the stateful-image join seam yet.** The normal
path is disciplined: the advertised 56 host assertions pass, the filesystem is
created through an already-open exclusive file descriptor with pinned
`e2fsprogs` 1.47.2 tools, process-level lease exclusion works, conservative
non-concurrent mutation cases preserve evidence, and the generated six-argument
QEMU delta has the intended file/raw/virtio shape with `locking=on`.

Independent testing nevertheless found concrete contract violations:

1. after a writer window begins, replacing `book-state.ext4` with another inode
   does not stop graph generation or the exact checker;
2. the process-local writer-window flag is not synchronized, and two threads
   can enter writer callbacks concurrently;
3. file modes depend on the caller's `umask`; and
4. accepted path and base-vector spellings bypass the promised control-character
   and reserved-node checks.

The first finding breaks the connection between the retained image identity and
the pathname a future QEMU would open. No QEMU was run, so no foreign file was
actually written, but this unit cannot currently support the stronger claim.
Correct these points and rerun the finite host probes before wiring a real
two-boot supervisor.

## Reviewed snapshot

| Input | SHA-256 |
|---|---|
| `pinenote/tools/book-state-qemu/CONTRACT.md` | `366f6a9b26881cda3cb5884126d323f73c0e6dbd98166ab0fbe6132f1151f6f6` |
| `pinenote/tools/book-state-qemu/book-state-qemu/state-volume.scm` | `2e396ab8e43b2476e5494b2e8e75f38ca2581f351f3bbbf9b99fe94b64e64a48` |
| `pinenote/tools/book-state-qemu/book-state-qemu/qemu-graph.scm` | `d426cdc7836b890405c12fcc478f0acbf4c7ecd279b5a4aba19c40a616285487` |
| `pinenote/tools/book-state-qemu/test-book-state-qemu.scm` | `8ceee708a84b2a040e516ee6aaf9d6f066bc829d0cb05e0b909e3b74d2a8903b` |
| seam design | `e55454c1a66e8177655e05cb876c2da0b2a4a32884f716913f15a51ae0db731a` |

The separately reviewed protocol, adapter, backend, Book Session, and optional
delegate candidates were not modified for this review.

## Reproduction environment and evidence

The checks used Guile 3.0.11 at:

```text
/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile
```

Filesystem tools were passed as exact absolute operands; no `PATH` lookup,
network access, substitution, or build was used:

```text
/gnu/store/2hg18b4ifvq5d6rp6fpmyxppx5q82zgq-e2fsprogs-1.47.2/sbin/mke2fs
  c0c9fc4b1e4a236fcaa299f1e620783906480d5d0028ae7da7144d81a2f3972f
/gnu/store/2hg18b4ifvq5d6rp6fpmyxppx5q82zgq-e2fsprogs-1.47.2/sbin/e2fsck
  3b5db06b3a7966fda5cac55e959651569fc715dc4ec5dc9765011c46c0f05a3c
```

Private review evidence:

| Evidence | SHA-256 |
|---|---|
| `/tmp/opencode/book-state-qemu-review-provided.log` | `3facbcd2fc56423c1b073eee8595d5f00b0bae28549e7d76cfd2177208dc51a5` |
| `/tmp/opencode/book-state-qemu-independent-review.scm` | `cc803866489b8c78d3c5a9831965fea5a08ddf0953fe567ee50bcc586adcb545` |
| `/tmp/opencode/book-state-qemu-independent-review.log` | `1f3bf76fb90dd0d95041ae9763effc2b818a48cfa569e701b570d54580712745` |
| `/tmp/opencode/book-state-qemu-umask-probe.scm` | `ff6c5ac84ba250c1d37db615cf4335911e1cf7b8765a697f0b79d41d03ed33ad` |
| `/tmp/opencode/book-state-qemu-umask-probe.log` | `79e536881386423bf69eb593f896477c278ea0b7c515707cc8f1a526de51e6f1` |

The supplied suite passed **56/56** assertions. All three Scheme files also
compiled with `-Warity-mismatch -Wformat` and no warnings. The independent
probe completed **20/20** checks; its “COUNTEREXAMPLE” passes mean that the
undesired behavior was successfully reproduced. It returned from seven to
seven open descriptors and removed its exact owned root. Two earlier aborted
probe roots and the deliberately retained strict-`umask` failure root were
inspected and removed by exact names; no `book-state-qemu-*` test directory
remained.

No filesystem was mounted. No QEMU, runsc, ARM code, KOReader, image/system
build, hardware, network, deployment, staging, commit, or push occurred.

## What the normal-path evidence proves

### Creation and validation

The successful path creates a sparse 64 MiB regular file, formats ext4 with the
exact `WBBookStateV1` label, and passes `e2fsck -f -n`. The image is opened with
`O_CREAT|O_EXCL|O_NOFOLLOW`; both `mke2fs` and `e2fsck` receive
`/proc/self/fd/N`, not an attacker-selected image pathname. Their argument
vectors are fixed and executed with `execl`, not a shell. Thus the reviewed
normal path contains no shell-injection route and does not redirect the
destructive formatter operand to a pre-existing pathname or block device.

The module validates device, inode, owner, mode, link count, size, type, exact
inventory, and directory identities when opening or explicitly validating a
reference. Existing same-name replacements, symlinks, hard links, replacement
roots, and unknown entries were all refused and preserved in the supplied
suite.

Executable identity is still a trusted-launcher responsibility. The module
accepts any canonical executable regular file; it does not itself require a
Guix-store path, version, or hash. The eventual launcher must retain the exact
store-path binding used above.

### Lease and fake writer lifetimes

The owner lease is a whole-file POSIX `F_SETLK` write lock on `owner.lock`.
Another process was refused while the owner lived, and the kernel released the
lock after the lease owner died by `SIGKILL`. The lock file remained empty; no
PID-file authority was involved.

The supplied suite ran two sequential fake writer processes against the same
image inode, removed two distinct fake run roots, retained the state disk
between those lifetimes, and then validated and cleaned it. The independent
probe repeated two sequential open/close windows. This proves resource and
identity behavior only. The fake writers did not modify ext4, run a backend, or
reopen application state, so this is **not semantic persistence evidence**.

Likewise, the owner-crash test had no surviving QEMU child. It proves kernel
lease release after one helper process dies, not generic process-group cleanup,
QEMU crash recovery, or physical-power-loss behavior.

### Graph and static guest prerequisites

For the clean test base, the constructor appends exactly:

```text
-blockdev
{"driver":"file","filename":"…/book-state.ext4","node-name":"book-state-file","read-only":false,"locking":"on"}
-blockdev
{"driver":"raw","file":"book-state-file","node-name":"book-state","read-only":false}
-device
virtio-blk-pci,drive=book-state,id=book-state-disk,serial=WBBOOKSTATEV1
```

Deleting an element, changing `locking` to `off`, or appending a host share to
the completed vector while retaining the original base makes the exact checker
fail. The trusted mount/database constants are also exact and expose no guest
choice of label, mount point, database path, or namespace.

The accepted reader boot-bundle config, SHA-256
`0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309`,
contains built-in `CONFIG_VIRTIO_BLK=y`, `CONFIG_VIRTIO_PCI=y`,
`CONFIG_EXT4_FS=y`, `CONFIG_EXT4_FS_POSIX_ACL=y`, and
`CONFIG_EXT4_FS_SECURITY=y`. No kernel rebuild is needed for the proposed
device.

## Findings

### 1. Blocking: graph generation is not bound to the retained image inode

`call-with-state-volume-writer-window` validates the reference at
`state-volume.scm:568`, then marks a mutable flag active and calls arbitrary
trusted code at lines 569–572. `leased-state-volume-qemu-arguments` subsequently
checks only the record type and that flag (`qemu-graph.scm:85–92`).
`state-volume-image-path` returns the stored pathname without revalidation.

The independent source-exact counterexample did this within one legitimate
writer callback:

1. rename the retained ext4 inode to a private saved name;
2. create a different mode-0600, 64 MiB regular inode at the original path;
3. call `leased-state-volume-qemu-arguments`; and
4. pass its result to `assert-leased-state-volume-qemu-arguments`.

Both graph calls succeeded while `lstat` proved that the pathname's inode was
not the retained inode. The original was restored and passed `e2fsck` afterward.
This directly contradicts `CONTRACT.md:23–26`, which says graph generation fails
when identity changes. A future QEMU would open the replacement pathname and
apply `locking=on` to that replacement, not to the retained image.

**Required correction:** bind each writer window to an already-open
`O_RDWR|O_NOFOLLOW|O_CLOEXEC` descriptor whose `fstat` exactly matches the
reference, and make graph/guardian handoff use an opaque window token rather
than only the lease Boolean and pathname. The reviewed outer must either pass
that exact descriptor safely through the QEMU file-node mechanism or perform an
equivalent identity-bound open immediately before `exec`, retain it through
QEMU acquisition, and revalidate after the guardian joins. Merely adding one
more pathname `lstat` in the constructor narrows but does not close the
open-after-check race.

### 2. Blocking: concurrent writer windows are admitted

The writer-active check at `state-volume.scm:566–567` and the state change at
line 570 are separated by a full reference validation and have no mutex or
owner token. Two threads were released from one barrier into the same lease.
Both callbacks entered concurrently; the recorded result was:

```text
(entered-count 2, maximum-concurrent 2, results (entered entered))
```

The existing nested-window test is single-threaded and does not cover this
check/set race.

**Required correction:** add a lease-private mutex and atomically claim/release
one writer owner before validation/callback execution. The mutex need not be
held while QEMU runs; it protects the ownership transition. Test two concurrent
threads and require exactly one callback entry plus one bounded
`writer-active` rejection.

This correction still cannot prove that arbitrary descendants have exited.
The contract is right to assign that fact to the accepted blocking process
guardian. Final integration must prove that the guardian has joined the whole
QEMU process group before the callback returns and the next window begins.

### 3. Blocking contract mismatch: exact modes depend on caller `umask`

The root is explicitly `chmod`ed to 0700, but `owner.lock`, `book-state.ext4`,
and temporary `mke2fs.conf` rely only on the mode passed to `open` at
`state-volume.scm:359–374` and 507–517. `open` applies the process `umask`.

With `umask 0777`, the independent probe created all three files as mode 000 and
then failed opening `mke2fs.conf` with a raw `system-error`/`EACCES`. The
contract promises exact mode 0600 files without declaring an ambient-`umask`
precondition. The failed private campaign was preserved, inspected, and then
removed by exact review-owned names.

**Required correction:** use `fchmod` on each newly and exclusively opened file
descriptor before any pathname reopen or child execution, then verify exact
mode. Convert creation failures to the unit's typed error while preserving the
diagnostic campaign. Add a strict-`umask` regression test.

### 4. Graph validation does not cover its declared input language

`safe-absolute-path?` and `safe-image-path?` reject NUL, newline, and carriage
return only. `json-quote` escapes only quote and backslash. A real canonical
mode-0700 campaign base containing TAB was accepted; its generated blockdev JSON
contained a literal TAB, which is forbidden unescaped by JSON.

The reserved raw-node check is spelling-dependent. This base fragment bypassed
it and was accepted by both constructor and checker:

```text
{"driver":"null-co","node-name": "book-state"}
```

The space after the colon evades the exact
`"node-name":"book-state"` substring. The helper then appends another raw node
with the same ID.

**Required correction:** reject all JSON control characters U+0000–U+001F in
accepted paths or use a complete JSON encoder, and validate reserved node/device
identifiers structurally rather than through formatting-specific substrings.
Regression cases should include TAB and alternate legal JSON whitespace.

### 5. Cleanup's final path operations have a remaining same-owner TOCTOU

The non-concurrent conservative cases pass. However,
`cleanup-state-volume-campaign!` completes `validate-reference!` and then calls
three pathname operations at `state-volume.scm:607–610`. There is no atomic
“unlink this recorded inode” primitive joining the validation to each delete.
A same-UID process can replace a name after validation but before `delete-file`,
causing deletion of the newly named object before a later operation reports
failure.

This review did not schedule a destructive race against an unrelated file. The
source ordering is enough to withhold the unconditional “replacement always
preserved” claim. Either narrow the threat model explicitly to no concurrent
same-UID mutation while the kernel lease is held, and prove the one outer owner
enforces it, or replace the cleanup protocol with a reviewed directory-FD/
quarantine sequence that detects substitution before irreversible deletion.
The conservative abnormal path may simply retain the campaign.

### 6. The reader base must remain an independent oracle

The exact checker is strong only relative to the `reader-arguments` value passed
to it. Independent probes supplied `-nic user` or `-virtfs` in that base, then
gave the same base to constructor and checker; both accepted it. This is
consistent with `CONTRACT.md:70–73`, which assigns no-network/no-share authority
to the accepted reader graph, but it means this unit alone does not prove those
properties.

Final integration must reconstruct the accepted base vector independently and
must not let one mutable value serve as both candidate and oracle. The current
accepted coordinator does exact reconstruction; preserve that pattern when the
state delta is added.

## Owner lease versus QEMU image locking

These are intentionally not one shared lock:

- the helper uses Guix's whole-file POSIX `F_SETLK` on `owner.lock` (a separate
  inode); and
- `locking=on` is requested on the QEMU file block node naming
  `book-state.ext4`.

Therefore parent death releases the helper lease even if an independently
living QEMU still has the data image open. A later helper can reacquire
`owner.lock`; only the existing process guardian and QEMU's actual lock on the
data image can prevent a second writer at that point. The generated argument is
the appropriate request, but no QEMU was executed here, so actual lock
acquisition, lock namespace, refusal latency, and old-child/new-QEMU conflict
remain unproved.

Before a persistence run, add an integration test using the accepted guardian:
hold boot 1's QEMU/image open, attempt boot 2, require a bounded lock failure,
then terminate and reap the exact boot-1 process group and prove boot 2 can
start. Also prove the normal synchronous path joins QEMU before returning from
the writer callback. Do not describe the helper's owner-crash test as that
proof.

## Acceptance checklist after correction

1. Make graph minting fail after image/root/lock identity replacement at every
   point before QEMU acquires the disk, with the original and replacement both
   preserved.
2. Admit exactly one of two simultaneous writer-window callers.
3. Create exact modes under a deliberately hostile `umask`.
4. Reject every JSON control and alternate spelling of each reserved ID.
5. State and test the cleanup concurrency threat model.
6. Re-run the existing 56 assertions plus the independent finite probes with
   exact store-pinned tools and no QEMU.
7. At integration time only, prove guardian join and real QEMU image-lock
   exclusion, then run two fresh guest supervisors.

Even after these host corrections, two fake writer lifetimes prove neither
Book State save/reopen semantics nor a fresh guest's recovery. Those claims
remain reserved for the later joined backend/session/native-UI two-boot run.

## Corrected-snapshot recheck — 2026-09-06

### Disposition

**Do not accept the corrected unit for integration yet.** The corrections close
all six original counterexamples at their original boundaries, including the
cleanup race; the supplied suite passes **87/87**, and a separate six-check
rollback probe confirms that `RENAME_EXCHANGE` preserves a second foreign inode
introduced immediately before rollback. Three smaller but finite contract
counterexamples remain:

1. a child forked while another thread owns the process-registry mutex blocks
   before it can perform the promised PID-change reset;
2. the public `/proc/self/fd/N` result permits `N` to be closed and rebound to a
   fresh open-file description of the same retained inode, after which the old
   handoff token still mints and validates a graph; and
3. the purported flat-JSON parser accepts the invalid object
   `{"node-name":"safe",}`.

These findings require no QEMU claim. They are host-only failures of the
corrected source's own fork, descriptor-lifetime, and parser contracts. The
actual QEMU descriptor inheritance, `locking=on` behavior, and guardian join
remain separate later integration gates and were not used to decide this unit
verdict.

### Frozen corrected inputs

The four requested inputs and the pre-append review were verified against their
advertised hashes before testing. Because `qemu-graph.scm` imports the accepted
reader graph, that module and its two custom Scheme dependencies were also
copied before execution rather than loaded from the mutable working tree.

Private complete source snapshot:

```text
/tmp/opencode/book-state-qemu-corrected-review-complete.XjiSb2
```

| Frozen input | SHA-256 |
|---|---|
| `CONTRACT.md` | `5d42bf4936b7c2c8fe2a919c6c45e8d42cc6795e64cf65bd91a12342d52d2efd` |
| `book-state-qemu/state-volume.scm` | `f21c5a184aa1dc7c890da198fba887d733f54704275609a344048925a0c957c9` |
| `book-state-qemu/qemu-graph.scm` | `aa19942d3286e1dfc6df7ca71d80293b0152a335a8f7532fe1c8a0410aee5b8b` |
| `test-book-state-qemu.scm` | `ca22626449c2146af1b12c4688076b470a8fdd64df3b6bec1948c4418c9683b6` |
| accepted `reader-qemu-graph.scm` dependency | `16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002` |
| accepted `disposable-qemu.scm` dependency | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| accepted `guest-console-assertions.scm` dependency | `fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908` |
| original review copied before this append | `519a3fc7f1116388de93d87eb4df2b16468ea51414d098c83b63bbc6e5cf6227` |
| snapshot `SOURCE-HASHES.sha256` | `a0a473d18f57dc5d4e738583e71aa4dccbc89cac0e640da7edf4d93502ba8aeb` |
| snapshot manifest | `c210bef5ddaa78f901f9bf91f2bec42ac1747c9a69ebb8e27458b79f2b901b17` |

Working-tree commit `50572d7796abdb0928969f4db8836fc5e30aeb58` is
context only and was not treated as an input oracle.

### Recheck evidence

The snapshot was loaded ahead of every mutable load path. Guile was the same
3.0.11 store executable recorded above. The only external tools were the same
store-pinned `e2fsprogs` 1.47.2 `mke2fs` and `e2fsck` binaries and hashes in the
original review. Compiling all six source/test modules with
`-Warity-mismatch -Wformat` emitted no warnings.

Private evidence packet:

```text
/tmp/opencode/book-state-qemu-corrected-review-evidence.4mscWB
```

| Evidence | SHA-256 |
|---|---|
| `compile.log` | `1c726c7bdcb2f5b09f1b7bdc4c377e1daf4577b6388a984957e6d567210e3f4a` |
| `provided-87.log` | `44b2729bbb0fc7a3cca34e508f017a47c5bb7984b6541ec1941fa259a4c576a3` |
| `independent-recheck.scm` | `3966111d6b40c77d00c45611de1e9eed351ff4f49dbbc0a8323814c5790e3873` |
| `independent-recheck.log` | `01578c84620d7ffe26153212e91b91265130c115dd83c94c3fb69d3228dc6ac8` |
| `rollback-recheck.scm` | `f9b9e173461abfc44dc409207f5b9c52be5b86e6192cd161d4d3c399332955a7` |
| `rollback-recheck.log` | `546c2c4886109ebe18b4fbed27b941c6954859fe207a2de9d08fe8d5bcfb9203` |
| evidence `EVIDENCE-HASHES.sha256` | `fcfcbd15d27a042ca6cf671f6eb958422ce8297f885992d8f317f5acbb36e827` |
| evidence manifest | `25d836788345dfa6dbba407fe41aa904be0d396bf3643f45807ca234e952c02b` |

The corrected supplied suite passed **87/87**. The independent probe made 43
checks: 40 passed and the three failures below were retained verbatim as
findings. It returned from seven to seven descriptors. The separate rollback
probe passed **6/6**. All exact review-owned run roots were removed.

No filesystem was mounted. No QEMU, runsc, ARM code, guest, KOReader,
image/system/kernel build, block device, hardware, network, deployment,
staging, commit, push, or merge was used.

### Status of the original findings

1. **Retained-inode graph binding: closed at the original boundary.** During a
   live handoff, replacing the image, owner lock, or campaign root makes both
   graph minting and checking fail. The exact original image-replacement replay
   returned `identity-changed` for a new graph and a graph minted before the
   replacement. The graph names only the live `/proc/self/fd/N` anchor.
2. **Concurrent writers: closed.** Eight independent simultaneous two-thread
   replays each admitted exactly one callback with maximum concurrency one; the
   loser returned `writer-active`. A nested writer also returned immediately
   without deadlock.
3. **Hostile `umask`: closed.** Under `umask 0777`, root, lock, and image were
   exactly 0700/0600/0600 and the image passed `e2fsck`.
4. **Path controls and structural collision checks: closed at the original
   cases.** All U+0000–U+001F path controls are rejected before campaign
   creation. Alternate whitespace, Unicode key/value aliases, duplicate decoded
   keys, duplicate node IDs, duplicate device properties, reserved IDs, raw
   controls, and malformed escapes were rejected. An appended unknown QEMU
   option and a NIC mutation failed the independently reconstructed exact
   oracle. The trailing-comma parser defect below is a new narrower case.
5. **Cleanup validation-to-unlink race: closed within the stated owner model.**
   Replacing the image or whole campaign root at the deterministic
   post-validation/pre-exchange boundary returned `cleanup-race`; both the
   retained objects and exact foreign inode/bytes survived. A second
   instrumented race replaced the sentinel with another foreign root
   immediately before rollback. The restore exchange overwrote nothing: that
   exact foreign root and marker moved intact to quarantine, while the first
   replacement and retained image also survived. The restored campaign passed
   `e2fsck` and normal cleanup.

   This does not silently broaden the threat model. As `CONTRACT.md:158–166`
   says, hostile same-UID mutation *inside the randomized mode-0700 quarantine
   after a successful exchange and validation* remains excluded. There is no
   pathname conditional-unlink primitive, so accepting that stronger threat
   would require a different isolated cleanup owner. The original concrete race
   occurred before quarantine capture and is now covered.
6. **Independent reader oracle: closed.** The API no longer accepts a mutable
   caller base. It reconstructs the accepted reader vector itself and compares
   the complete candidate. Added host state and network changes were rejected.

The fake writer callbacks still prove only bounded ownership and identity
lifetime. They did not alter ext4 or run/reopen Book State, so they remain no
evidence of semantic persistence.

### New finding 7 — blocking: fork can inherit the registry mutex locked

`claim-process-lease!` locks `process-lease-registry-mutex` at
`state-volume.scm:467` before checking the PID at lines 473–475. The stated
fork recovery therefore executes too late if another thread owned that mutex at
the instant of `primitive-fork`.

The deterministic probe let one thread hold that exact mutex, forked, and had
the child call the public `call-with-state-volume-lease`. The child produced no
result within 500 ms and had to be killed (`(#f #f 137)`). When the mutex was
not held at fork, the existing child test correctly cleared the inherited
registry and reached the parent's real `F_SETLK`, returning `already-leased`.

Guile warns that `primitive-fork` while multiple threads run has unspecified
further behavior. That warning reinforces rather than repairs the mismatch:
the current contract unconditionally says a fork detects its PID and clears the
copy, while this unit also advertises thread-safe process-local registration.

**Required correction:** either reset/recreate child-local registry state before
attempting to lock an inherited mutex, with a reviewed fork-safe mechanism, or
narrow and enforce the contract so the process cannot fork while any sibling
can be in this API. Add a bounded child regression in which the pre-fork mutex
state is locked. Do not rely on PID comparison located behind that lock.

### New finding 8 — blocking: a live handoff token does not identify its open file description

The handoff initially uses `dup`, and the probe confirmed that its descriptor
shares the writer's open-file-description offset. It also confirmed that an
ordinary open of `/proc/self/fd/N` resolves the same inode with an independent
offset, and that a forked child resolves that string in the child's own FD
table. Closed descriptors and descriptors retargeted to `/dev/null` were
correctly rejected.

There is nevertheless a same-inode reuse hole. Using only the public handoff
filename and state-image path, the callback can:

1. close `N`;
2. reopen the retained image, obtaining the same lowest free descriptor number
   `N` but a fresh open file description; and
3. call the graph constructor/checker with the still-live old handoff token.

Both graph operations succeed. `validate-state-volume-handoff!` checks the
integer descriptor's current `fstat` identity and `FD_CLOEXEC`, but not that it
is still the exact `dup` created for this handoff. The callback cannot mutate
the Scheme record, yet it can replace the OS resource to which the record's
integer now refers. This does not redirect QEMU to a foreign inode—the retained
inode checks remain effective—but it contradicts the promised duplicate-copy,
descriptor-bound lifetime and makes “retargeted FD rejects” true only for a
different inode.

**Required correction:** bind validation to the exact open file description,
not only `(fd number, file identity)`. On this Linux-only helper,
`kcmp(getpid(), getpid(), KCMP_FILE, writer-fd, handoff-fd)` can distinguish the
original `dup` from a fresh same-inode open; an equivalent reviewed mechanism is
acceptable. Test close/reuse with both a foreign inode and the same retained
inode. If the owner instead intends to trust the callback not to manipulate
`N`, that must be an explicit narrower contract, not an opaque descriptor-bound
claim.

Old-token generation itself works: after handoff return, while the writer is
still live, the old handoff returns `invalid-handoff`; after writer return, both
the old writer and old handoff reject. Cross-thread token use also rejects.

### New finding 9 — blocking parser mismatch: trailing commas are accepted

The structural parser correctly decodes JSON escapes before duplicate and
reserved-name checks. Its comma branch at `qemu-graph.scm:143–146`, however,
loops back to the same state used immediately after `{`; that state accepts `}`.
Consequently:

```scheme
(validate-no-state-collisions
 '("-blockdev" "{\"node-name\":\"safe\",}"))
;; => #t
```

That text is not JSON. It does not by itself bypass a reserved identifier, and
the independent exact-vector checks found no unknown-option, host-share, or NIC
bypass. It does show that the implementation does not parse exactly the fixed
flat-JSON language claimed at `qemu-graph.scm:33–37`; malformed accepted-base
syntax can pass this validator and be deferred to QEMU.

**Required correction:** after consuming a comma, require another member rather
than accepting the object terminator. Add trailing-comma and adjacent/double
comma cases alongside the existing escape, alias, whitespace, and duplicate-key
tests.

### Exact later QEMU/guardian proof still required

Host-unit acceptance after findings 7–9 are corrected must not be represented
as QEMU integration acceptance. The successor outer still has to prove all of
the following with actual QEMU later:

1. pass the handoff FD number explicitly to the blocking guardian; do not infer
   authority from a pathname string;
2. replace the current guardian child's “mark every FD above stderr CLOEXEC”
   rule with an exact allowlist, and prove immediately before `exec` that this
   one `N` is open, inheritable, and has the retained device/inode while every
   unapproved descriptor remains closed-on-exec or closed;
3. prove in the child/QEMU process—not by inspecting the parent's
   `/proc/self/fd`—that `/proc/self/fd/N` resolves the inherited retained inode;
4. keep boot 1 alive, attempt a separate writer/QEMU against the same image,
   and require a bounded `locking=on` refusal; then terminate and reap boot 1's
   exact process group and prove a later QEMU can acquire the image;
5. record ordering that the QEMU process group is closed and reaped before the
   synchronous guardian returns, before the handoff callback returns, and
   before writer window 2 can begin; and
6. exercise parent death so guardian liveness teardown completes before a later
   campaign reopen can become a writer.

Only after those gates pass should two fresh real guest supervisors establish
semantic persistence: boot 1 saves and shuts down cleanly; boot 2 reopens the
same state and paints it. None of those QEMU or guest steps is required to close
this host-unit review.

## v3 finite recheck — 2026-09-06

### Disposition

**Accept the frozen v3 host helper as fit to proceed to the conditional actual
QEMU/guardian integration review.** Findings 7–9 are closed on their exact
boundaries, the earlier findings remain closed, and no new finite blocking
counterexample was found.

This is not unconditional portability or QEMU acceptance. The reviewed runtime
requires Linux `KCMP_FILE` on one of the two explicitly supported ABIs and a
host policy that permits same-process comparison. Unsupported architecture,
`ENOSYS`, or `EPERM` fails closed with `ofd-comparison-unavailable` before the
handoff callback; there is no inode-only fallback. This private QEMU host meets
that precondition today. A different host must demonstrate it again rather than
loosening the check.

Actual descriptor preservation through the guardian's child setup and QEMU
`exec`, QEMU's `locking=on` exclusion, complete process-group join ordering, and
semantic two-boot persistence remain unproven. The six exact integration proofs
listed in the preceding section remain mandatory.

### Frozen v3 authority and preserved history

The v3 source packet was verified in place before review:

```text
/tmp/opencode/book-state-qemu-v3-review-complete.vzeav4x2
```

| Frozen input | SHA-256 |
|---|---|
| `CONTRACT.md` | `b7b2aa512dec59d2d28a482a482c7371ac2a51f5557f76a74484beefc38bf167` |
| `book-state-qemu/state-volume.scm` | `79324bbb80ba8eb9e57c4d8285b0d6f4f76020bfb1016d0e8c22fe8526b42d29` |
| `book-state-qemu/qemu-graph.scm` | `708ccca8fe367a20ef886168bed524704a5cdd0a97acf5f0609eecd822ad977c` |
| unchanged baseline `test-book-state-qemu.scm` | `ca22626449c2146af1b12c4688076b470a8fdd64df3b6bec1948c4418c9683b6` |
| focused `test-book-state-qemu-v3.scm` | `e49c97a8ccb3ed8a4a4de18c3040e009daaea48695e0388fa02e4251525b5455` |
| accepted `reader-qemu-graph.scm` | `16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002` |
| accepted `disposable-qemu.scm` | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| accepted `guest-console-assertions.scm` | `fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908` |
| this review before the v3 append (`input-review.md`) | `9ac34a3eb3ee18e0d1e15ac275d47b3c07cbf22db371db0c44f415eb767b4b07` |
| parent-v2 `SOURCE-HASHES.sha256` | `a0a473d18f57dc5d4e738583e71aa4dccbc89cac0e640da7edf4d93502ba8aeb` |
| parent-v2 snapshot manifest | `c210bef5ddaa78f901f9bf91f2bec42ac1747c9a69ebb8e27458b79f2b901b17` |
| v3 `SOURCE-HASHES.sha256` | `91f43ffa3e223eb1e068405535ad3efe1fbeb39c2ef5927fcbe51826782630eb` |
| v3 snapshot manifest | `653b47b5a167e3fcfa35b8631cd5bcba32d717a45f40f769b9630c2eb65294ec` |

`input-review.md` was byte-identical to this document before this append. The
parent-v2 manifests and the two prior independent probe sources are also bound
inside the v3 source manifest, so the earlier review history was not rewritten.
The packet records working-tree commit
`50572d7796abdb0928969f4db8836fc5e30aeb58` as context only. The mutable
checkout reported `549dded816e5f73d2c11557ffcd3130a018b82a8` during final
verification; neither commit was source authority, and the verdict does not
depend on the checkout.

The supplied v3 evidence packet also verified exactly:

```text
/tmp/opencode/book-state-qemu-v3-review-evidence.ze3sukmq
```

Its `EVIDENCE-HASHES.sha256` is
`bf4be13ee6c1c2d2950050e9fa9863cb5d3f72c7851a081182c0ea6e33d6645b`;
its manifest is
`c4c17e040bb2f2b916cae0c3ef69dabccb5083d24f37c73521c05e95559b944e`.
It records **87/87** unchanged baseline assertions, **35/35** focused v3
assertions, **43/43** from the byte-identical prior independent probe, **6/6**
from the byte-identical rollback probe, and seven compiled modules with no
`-Warity-mismatch` or `-Wformat` warnings.

The compiler result is the only no-warning claim. Both supplied and independent
runtime logs retain Guile's documented warning that behavior after
`primitive-fork` with multiple threads is unspecified. The finite reviewed-host
executions completed correctly; they are not described as warning-free or as a
generic Guile multithreaded-fork guarantee.

### Independent evidence

The independent finite probe was newly written for this recheck and loaded the
frozen source ahead of every mutable path. It ran interpreted under Guile 3.0.11
with `--no-auto-compile`. Its only external programs were the same exact
store-pinned `e2fsprogs` 1.47.2 `mke2fs` and `e2fsck`; they operated only on one
new review-owned sparse 64 MiB regular file.

Private evidence packet:

```text
/tmp/opencode/book-state-qemu-v3-independent-review-evidence.RlLyfv
```

| Evidence | SHA-256 |
|---|---|
| `EVIDENCE.txt` | `924d0136af068a6982efcb3ab52bb8a026aa829130143f420569d2a8a9753e57` |
| `independent-finite.scm` | `83c0f46886292e574779235f4cdc1c447514bfd5d0313ca9a6ae07eb0d19e1d9` |
| `independent-finite.log` | `a7caf666c612ff22d1483749fc44d4ce2234ac4aabf08d35a336ce8406dc6d15` |
| `source-verification.log` | `d923b35b7d146b61a6a927c60c4a8659c577419e340282dea17783047da3741f` |
| `EVIDENCE-HASHES.sha256` | `80061ac087a7c0c8a159971955f07b121a950ed9db28c608afc99f6d4d7366fe` |
| evidence manifest | `25e8a8125ee884ecbe9b79e1d21beab8ebbe5910de2391ffe02bf06b90ab059e` |

The probe passed **29/29** checks, returned from seven to seven descriptors, and
removed its exact owned root. No test run root remains.

No source or frozen packet was edited. No QEMU, runsc, ARM code, mount, block
device, guest, KOReader, network, image/system/kernel build, hardware,
deployment, staging, commit, push, or merge was used.

### Finding 7 closure — PID-tagged atomic registry

The process registry now consists of one PID-tagged atomic-box value. Claim,
release, and child reset use compare-and-swap loops at
`state-volume.scm:501–539`; registry authority no longer locks the retained
test-baton mutex.

An independent absent-key race released two threads simultaneously against one
reference. Exactly one callback entered, exactly one caller received
`already-leased`, maximum concurrent ownership was one, and the resulting
registry was empty under the current PID. This tests the CAS claim race rather
than merely observing an already-populated registry.

For the exact old deadlock, another thread held the inherited retired mutex
while the process forked. The child returned within 500 ms as
`(#t #\A 0)`: it installed its own PID-tagged empty snapshot, reached the
parent's real kernel lock, received `already-leased`, and released its child
claim. The parent's atomic snapshot retained exact object identity and a second
parent handle remained refused. Thus child reset neither waits on vanished
thread ownership nor clears parent authority.

The runtime warning noted above remains visible. This closure is the concrete
reviewed-host result and the removal of the inherited-mutex dependency, not a
claim that arbitrary Guile work after every multithreaded fork is portable.

### Finding 8 closure — exact open-file-description comparison

Every handoff is now checked against the private writer anchor with
`KCMP_FILE` at `state-volume.scm:369–405`, once before exposing the callback and
again after it returns. The private anchor remains `CLOEXEC`; neither its FD nor
the handoff FD accessor is exported.

On the reviewed x86-64 host, direct syscall results were `(0 0)` for a real
`dup` and `(2 0)` for a fresh same-inode open. The positive ordering value is
not treated as stable; only zero means the same open file description. The
legitimate dup-backed token and exact graph passed. Closing the public handoff
slot and reopening the same retained inode in that slot now returned
`invalid-handoff`; restoring a dup of the exact original open file description
restored authority. A `/dev/null` rebound remained rejected.

Fail-closed behavior was independently forced for all relevant branches:

- `EPERM` → `ofd-comparison-unavailable`, no callback, descriptor count 9→9;
- `ENOSYS` → `ofd-comparison-unavailable`, no callback, descriptor count 9→9;
- unknown architecture/no syscall number → `ofd-comparison-unavailable`, no
  callback or descriptor growth; and
- a positive/different comparison → `invalid-handoff`, no callback, descriptor
  count 9→9.

After each failed attempt the private writer anchor was still live, and a later
legitimate handoff succeeded. At handoff return its public descriptor was closed
and its token revoked while the private writer anchor remained live; at writer
return the writer token revoked and descriptor accounting returned to its
pre-window value.

A finite fork check also showed that `/proc/self/fd/N` resolved in the child to
the child's inherited descriptor with the retained device/inode and
`FD_CLOEXEC=0`. That is only the pre-`exec` inheritance fact. The current
accepted guardian still marks all descriptors above stderr close-on-exec, so
the required successor allowlist and actual QEMU proof remain integration work.

The runtime requirement is now exact: the helper reviews syscall numbers 312
for x86-64 and 272 for AArch64, both with `KCMP_FILE=0`. This host returned both
the required zero and positive cases under its current privilege policy. Future
execution must fail closed if architecture, kernel, seccomp, ptrace policy, or
other host policy prevents that comparison; it must not weaken exact OFD
identity to inode identity.

### Finding 9 closure — finite strict flat-JSON grammar

The parser's post-comma state at `qemu-graph.scm:143–151` now requires another
member and cannot reuse the initial empty-object terminator. Independent
positive cases retained `{}`, a whitespace-only empty object, multiple fields,
booleans, and standard escaped characters including `\u002d`.

Finite negative cases rejected a leading comma, a comma before the first
member, doubled commas, an ordinary trailing comma, a whitespace-separated
trailing comma, and end-of-input immediately after a comma. Escaped reserved
aliases and duplicate decoded keys remained rejected. This is acceptance of the
declared small flat-object grammar used by the fixed reader graph, not a claim
to have implemented or needed a speculative general JSON parser.

### Remaining gate

The volume helper's host-unit review is now closed. The next permissible step
is the separately reviewed successor outer that preserves exactly the handoff
FD through child setup and QEMU `exec`, synchronously joins the complete QEMU
process group, and performs the real `locking=on` exclusion test. Passing that
gate still would not itself prove Book State persistence; the later two fresh
guest supervisors must establish save, clean shutdown, reopen, and paint.
