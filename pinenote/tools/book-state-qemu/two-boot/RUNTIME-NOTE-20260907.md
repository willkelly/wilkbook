# Author runtime note — 2026-09-07

This is the author ledger for the launcher and V9 mount-flags successor. It does
not supply the pending focused final-binding acceptance or extend the separate
independent acceptances of the parent V8 guest/checker and image/payload inputs.

## Changes exercised

1. `modules/disposable-qemu.scm` accepts either the exact legacy PineNote root
   and console pair (and converts its consoles once) or the exact prepared V8
   `root=LABEL=PNGuixRoot` plus one `console=ttyAMA0`; only the prepared root is
   translated to Guix-native `root=PNGuixRoot` in emitted argv. Mixed,
   duplicate, unknown, and secondary root/console forms reject.
2. `one-boot.scm` stages `disposable-qemu.scm` and
   `guest-console-assertions.scm`, the transitive modules imported by the staged
   reader graph.
3. The process guardian now waits for an owner acknowledgement after the direct
   child's stable identity is recorded and only then releases that child to
   exec. EOF still causes exact owned-child cleanup.

The accepted V8 guest, image/payload bundle, kernel, graph structure, evidence
semantics, and timeout contract were not changed. The successor checker root
assertion is intentionally corrected from the previously accepted graph
spelling; this is author-tested successor work, not a retroactive review claim.

## Preserved attempts

### Original final-binding attempt

- Evidence:
  `/tmp/opencode/book-state-v8-evidence-base.zdqeQY/book-state-two-boot-evidence.kYJBbj`
- Failure: inherited downstream parser rejected the prepared V8 `APPEND` before
  QEMU.
- State hash stayed `45be558efd2f3a824972c48f9e34fdcb1f61df32b1cd162d0b97ff859339f5b2`.

### Successor attempt 2 — parser fixed

- Source packet:
  `/tmp/opencode/book-state-qemu-two-boot-v8-launcher-successor-20260907-v2`
- Listed-source/runtime manifest hashes: `879a3850b4288e0a2b45d7fd2dcc866f1fada58d45e4052d192cbc61c263e9b7` /
  `7021a1f6eccf5c56bc200b171249c2e3d5926fa4c44a28c939d3e0e14d24aa62`
- Evidence:
  `/tmp/opencode/book-state-v8-attempt2-evidence-base.w1fk_ws0/book-state-two-boot-evidence.T4LMLk`
- Campaign:
  `/tmp/opencode/book-state-v8-attempt2-campaign-base.5ijf5mbc/book-state-campaign.7I6TaZ`
- Failure: staged coordinator omitted `(disposable-qemu)`.
- State hash stayed `6a72780a9c46fd1a80371115434fcce70429e166d470c553a4b7e9ab4dbd367a`.

### Successor attempt 3 — staging fixed

- Source packet:
  `/tmp/opencode/book-state-qemu-two-boot-v8-launcher-successor-20260907-v3`
- Listed-source/runtime manifest hashes: `05eed056762847cbd4128523535ef4b9d2e75d06e932f2704f7f86946ec7b6cd` /
  `6771283c72e7689d30984ebcbc5370b27378e07c6002282dbbf8d2687c5c795b`
- Evidence:
  `/tmp/opencode/book-state-v8-attempt3-evidence-base.amwvwy7p/book-state-two-boot-evidence.arydE8`
- Campaign:
  `/tmp/opencode/book-state-v8-attempt3-campaign-base.3hl6lq8z/book-state-campaign.KmDmZV`
- Failure: first fast `cp` child exited before its parent-side PID/start-time
  observer ran.
- State hash stayed `610aeb1a9a539051acd9d955369d7acdcbc2d82130840870b0290eed9d2ba3ff`.

### Successor attempt 4 — real ARM boot

- Source packet:
  `/tmp/opencode/book-state-qemu-two-boot-v8-launcher-successor-20260907-v4`
- Listed-source/runtime manifest hashes: `a6ade1bc923d8d6164091346b88402fce1b5a592f5b1a6b705c32bb17d018d16` /
  `fd46029f95bc2d7a077e8e9fc8946f117426c53c118d4e9c80a80d6e1d9a8a27`
- Evidence:
  `/tmp/opencode/book-state-v8-attempt4-evidence-base.mmx2w3h1/book-state-two-boot-evidence.8fMQyg`
- Campaign/state image:
  `/tmp/opencode/book-state-v8-attempt4-campaign-base.5zsvycs0/book-state-campaign.iaKN0x`
- Exact console diagnostic: `boot1/one-boot.stderr` in that evidence tree.
- Outcome: AArch64 Linux 7.1.8 booted; `/dev/vda1` and its `PNGuixRoot` label
  were visible; Guix then searched for the literal label `LABEL=PNGuixRoot` for
  21 trials and entered its debug REPL. QEMU was terminated by the bounded owner.
- State hash stayed `67a301a2d1d0dfe230e8287dde4ad8eafbc336586dba95171c3b5be6174696e8`.

All three successor run bases are empty after cleanup. No attempt reached
runsc, KOReader, the A→B write, boot 2, or final evidence acceptance.

The V2–V4 source snapshots also contain three immutable Python bytecode cache
files copied from the mutable working tree. They are absent from both source
manifests and were never loaded: the bootstrap copied only the authenticated
23-file runtime roster into a clean retained capsule. The caches were removed
from the working tree after discovery, and the host gate now rejects any future
complete-source inventory addition or omission.

A clean intermediate snapshot with the same runtime closure as executed V4 is
`/tmp/opencode/book-state-qemu-two-boot-v8-launcher-successor-20260907-v5`.
After V4, its diagnostic tail also exposed a host archive defect: Guile rejects
`open-file` mode `"wbx"`. The working successor now uses an explicit
`O_EXCL|O_NOFOLLOW|O_CLOEXEC` descriptor and `fdopen` mode `"wb"`. The final
clean handoff snapshot is
`/tmp/opencode/book-state-qemu-two-boot-v8-launcher-successor-20260907-v6`.
Neither V5 nor V6 was given a fourth successor runtime attempt.

### Successor attempt 5 — root handoff fixed; guest state mount blocked

- Source packet:
  `/tmp/opencode/book-state-qemu-two-boot-v8-root-handoff-successor-20260907-v7`
- Listed-source/runtime manifest hashes: `9fd3133a45bf02e8f806bdf258c565ca21889097533a8ccd4f03c9e379cb6a61` /
  `8ca1f97efea6c85d30eafff2239bceb8759ea8f2346eca3adfa68ba6721cb2d4`
- Complete launcher stdout/stderr/status ledger:
  `/tmp/opencode/book-state-v8-attempt5-launch.l9EiYU`
  (`RETAINED.sha256` =
  `7be5fd157982344fe9a67f35dfffdfceb4b6e2566de8ee22d1992ccf52301e05`,
  51 retained files).
- Evidence:
  `/tmp/opencode/book-state-v8-attempt5-evidence-base.bMkfXc/book-state-two-boot-evidence.qGkYzd`
- Campaign/state image:
  `/tmp/opencode/book-state-v8-attempt5-campaign-base.3mwmBM/book-state-campaign.FD4HX7`
- Run base (empty after cleanup):
  `/tmp/opencode/book-state-v8-attempt5-run-base.eGQ55G`
- Root correction proved: the emitted command line contains exactly
  `root=PNGuixRoot`; Guix found the label, mounted `/dev/vda1`, and started
  Shepherd (`boot1/run/console.log`, lines 33 and 251–267).
- KOReader opened the fixed fixture and registered the private source
  (`boot1/run/reader-ui/reader.log`, lines 113–125).
- New failure: every state-volume mount attempt passed
  `noatime,nodev,nosuid,noexec` as ext4 filesystem data. ext4 rejected
  `noatime` repeatedly (`boot1/run/console.log`, lines 301–420), so the guest
  never emitted a `BOOK-STATE-GUEST` operation and boot 1 reached its exact
  360-second hard VM deadline.
- State hash stayed
  `c189be53ecf2dafbfff5ae72ddea44bddb3684b14f796ee5d694e8e888744f66`.
- Cleanup checked all 26 identity records (24 unique PID/start-time pairs):
  zero exact identities remain live.

The second newly authorized runtime attempt was not used. This is not another
host-integration defect that can be repaired while retaining the immutable V8
image; the task's stop condition therefore applies.

## Superseded root blocker

Pinned Guix's `device-string->file-system-device` in
`gnu/build/linux-boot.scm` wraps every non-path/non-UUID root string directly in
`file-system-label`; it does not strip Linux's `LABEL=` prefix. Therefore the
accepted graph's `root=LABEL=PNGuixRoot` becomes a lookup for a label literally
named `LABEL=PNGuixRoot`. The partition is correctly named `PNGuixRoot`.

The earlier recommendation to change the image/initrd is superseded. The
`LABEL=` spelling was an incorrect host/checker assumption, not a security or
user invariant. The immutable payload remains `root=LABEL=PNGuixRoot`, while
the exact prepared-config branch now emits `root=PNGuixRoot`. The checker
requires exactly that one bare root and rejects the `LABEL=` form, duplicates,
and wrong roots. No guest, image, kernel, or gVisor rebuild is required.

## V8 blocker and V9 successor

The accepted V8 system source declares the mandatory state filesystem with
`(options "noatime,nodev,nosuid,noexec")`. Pinned Guix keeps generic mount
flags separate: `<file-system>.flags` accepts `no-atime`, `no-dev`, `no-suid`,
and `no-exec`, converts them to `MS_*`, and passes `options` unchanged as
filesystem-specific data. The observed `ext4: Unknown parameter 'noatime'` is
the direct result.

V9 makes exactly that change: `%state-file-system` now uses
`(flags '(no-atime no-dev no-suid no-exec))` and has no `options` value.
`check-system.scm` checks `file-system-flags` plus false options, while
`test_source.py` requires the exact source form and rejects the V8 options form.
The guest authority, protocol, OCI bundle, probes, kernel, and gVisor are
unchanged.

The final source packet is
`pinenote/tools/book-state-guest/source-packets/book-state-guest-sources-20260907-v9-r5`
(`PACKET-CONTENTS.sha256` `fed017aa…`). Its networkless private replay passed the
full source gate and derived `/gnu/store/5n0zp5vs…-system.drv`; author evidence is
`/tmp/opencode/book-state-guest-sources-20260907-v9-r5-author-evidence-v2`
(`9705fd07…`). Two earlier command-wrapper preflights are preserved separately:
one selected non-store Python and one used the wrong user-namespace UID map;
neither reached the relevant project import/lowering.

One authorized raw-image realization produced
`/gnu/store/cm20vv4a7fbh3g3gbkmhyvg7iwwlbk1p-disk-image` (`c0bac7c4…`) in
20 seconds. Its dry run scheduled neither kernel nor gVisor. Read-only
partition extraction and `debugfs` inspection found embedded system
`/gnu/store/3b7n30ir…-system` and the generated filesystem service containing
`(no-atime no-dev no-suid no-exec)` with false options. The four-file prepared
payload has manifest `f2d13509…`; the exact production outer manifest is
`d61f6a26…`. Full image/build/payload author evidence is retained at
`/tmp/opencode/book-state-image-v9-author-20260907-v1` (`27830a75…`). No host
mount, network, hardware, SSH, or UART was used.

## V9 runtime attempt 1 — state mount fixed; post-mount startup blocked

- Frozen campaign source:
  `/tmp/opencode/book-state-qemu-two-boot-v9-mount-flags-successor-20260907-v1/source`
  (`SOURCE-MANIFEST.sha256` `ed0e5dc4…`, runtime manifest `5c917a62…`).
- Pre-runtime host gate: `/tmp/opencode/book-state-v9-pre-runtime-host-check.log`
  (`6d4c7931…`, 296 lines, status 0).
- Launch ledger:
  `/tmp/opencode/book-state-v9-attempt1-launch.10wO00`
  (`RETAINED.sha256` `cf114d00…`, 59 records).
- Evidence:
  `/tmp/opencode/book-state-v9-attempt1-evidence-base.kQMYax/book-state-two-boot-evidence.Do8Iqi`.
- Campaign/state:
  `/tmp/opencode/book-state-v9-attempt1-campaign-base.iIAnVU/book-state-campaign.dWqcnD`.
- Run base: `/tmp/opencode/book-state-v9-attempt1-run-base.loSXTi` (empty).

The immutable input still carried `root=LABEL=PNGuixRoot`, and actual argv
contained exactly one `root=PNGuixRoot`. The root mounted and selected embedded
system `3b7n30ir…`. Most importantly, `WBBookStateV1` passed fsck and mounted at
console line 302 with no ext4 unknown-option rejection. This closes the V8
filesystem-declaration bug on real AArch64 QEMU.

No volume-ready sentinel, SQLite database, `BOOK-STATE-GUEST` operation, or
sandbox-boundary record followed. After the exact 360 s VM deadline, the failure
path retained evidence and checked 28 process records representing 24 unique
PID/start-time identities; zero exact identities remained live. A read-only
`e2fsck -n` of the preserved state was clean. Replaying its journal only on a
private copy and inspecting with `debugfs` still found no sentinel or database,
so this is not merely an unreplayed-journal observation.

The console-only evidence did not identify the post-mount barrier. The bounded
diagnostic successor below does. `gpio-keys: failed to get gpio`, the eudev
credential warning, and `waiting for udevd...` were not causal.

## Diagnostic successor — exact post-mount failure identified

One separately named diagnostic image was built from
`/tmp/opencode/book-state-v9-startup-diagnostic-sources-20260907-v1`; it is not
a production successor and cannot establish semantic `PASS`:

- image: `/gnu/store/s2v1kn549vs4mvs29fk40mb5ia12rsjx-disk-image`
  (`2a30f58e…`), embedded system `/gnu/store/c71g91cd…-system`;
- evidence/work root:
  `/tmp/opencode/book-state-v9-startup-diagnostic-20260907-v1`;
- private source roster: `94aeaba3…` (134 inputs, 19 modules, exactly nine
  executable local-file assets);
- the dry run scheduled neither kernel nor gVisor; the 18-second realization
  reused exact outputs `334ljs8q…` and `djgy782a…`;
- the sole QEMU invocation used the asserted existing 48-argument graph, no
  NIC/share/monitor, one single-link 64 MiB `WBBookStateV1` image, and a
  60-second outer bound. It ended with expected timeout status 124; no QEMU
  process remains.

The independent observer's direct `/dev/ttyAMA0` write later failed with `EIO`,
but the volume gate's Shepherd-log bracket and normal service logs were retained
in the root journal. Read-only conversion/extraction followed by journal replay
on a private copy found, in order, in
`evidence/var-log-messages.txt`:

1. `Service udev started.` (line 55);
2. `Service file-system-/var/lib/wilkbook-book-state-demo started.` (line 99),
   with running value `#t` (line 103);
3. `Starting service book-state-volume-ready...` and
   `BOOKSTATE-STARTUP-DIAG volume-ready=entered` (lines 173–175);
4. immediate failure:
   `Unbound variable: get-string-all` (lines 176–177).

Thus there was no udev, filesystem, kernel, GPIO, or global Shepherd/Fibers
stall. The state mount completed and the exact next service failed before its
mount-options check or first sentinel write. The original V9 generated service
put `(use-modules (ice-9 textual-ports) (srfi srfi-1) (srfi srfi-13))` inside
the compiled start lambda. That runtime call did not establish the lexical
bindings required by the compiled g-expression; its first such reference,
`get-string-all`, was unbound. The state filesystem still contained only
`lost+found` after journal replay on a private copy.

The minimal source fix is now prepared, but deliberately neither image-realized
nor runtime-claimed: the volume service declares those three interfaces in its
`modules` field, appended to `%default-modules`, and removes the inner
`use-modules`. It changes no service requirement, mount flag, authority,
protocol, kernel, gVisor, DT, graph, or timeout. Connected static checks require
the generated-module contract. The private source capsule is
`/tmp/opencode/book-state-guest-sources-20260907-post-v9-volume-ready-fix-r1`:

- source manifest: `4945b12f…`;
- capsule roster: `284906aa…` (134 inputs, 19 modules, nine executables);
- final private host gate: `da2e6212…`, status 0;
- system derivation: `/gnu/store/52g81b12…-system.drv`, retaining exact kernel
  and gVisor outputs;
- separately lowered generated service source:
  `/gnu/store/gjhckmrh…-shepherd-book-state-volume-ready.scm` (`5efbd03d…`).
  It imports all three interfaces before constructing the service. Executing
  its real mountinfo parser with immutable host Guile/Shepherd inputs and an
  intentionally absent guest mount reached the expected
  `mandatory WBBookStateV1 ext4 mount is not exact` rejection, not an unbound
  variable (`evidence/invoke-volume-service-parser-v6.stdout`).

## Direct disposable-V9 troubleshooting

The operator next authorized direct work on a disposable writable copy of the
existing V9 image, with at most three bounded diagnostic QEMU cycles before a
blocker report. This did not authorize mutation of the immutable V9 image or
failed campaigns, a host mount, another diagnostic image build, or use of the
reserved one normal image build before the direct path worked.

The work root is
`/tmp/opencode/book-state-v9-direct-fix-20260907-v1`. Starting from the original
mode-0400, single-link prepared V9 image (`4b5d741b…`), read-only `debugfs`
extraction first verified the installed generated service bytes. A private
partition copy then replaced only these two paths with the separately lowered
fixed outputs before being written into a private full-disk copy:

- `/gnu/store/w7i1f649…-shepherd-book-state-volume-ready.scm` received
  `/gnu/store/gjhckmrh…-shepherd-book-state-volume-ready.scm`
  (`5efbd03d…`);
- `/gnu/store/cyazvngf…-shepherd-book-state-volume-ready.go` received
  `/gnu/store/1c7n9pjn…-shepherd-book-state-volume-ready.go`
  (`bbefc4e3…`).

Post-write extraction matched both fixed inputs byte-for-byte, read-only fsck
was clean, and the disposable full-disk image is `72364b61…`. The original V9
image remained `4b5d741b…`, mode 0400, and single-linked. This disposable image
is explicitly not a normal Guix realization, production payload, or acceptance
artifact.

### Cycles 1 and 2 — volume gate and authority startup crossed

Cycles 1 and 2 each used the asserted existing 48-argument QEMU graph, exact
kernel/initrd, no NIC/share/monitor, a fresh single-link 64 MiB
`WBBookStateV1` image, private Unix console/UI sockets, and a 365-second bounded
owner. Both ended much earlier with status 1 because KOReader's inherited
startup-overlay assertion failed; exact QEMU and reader PID/start-time records
were absent afterwards.

Before that independent host failure, both boots produced the same decisive
guest sequence in `run/console.log`:

1. `WBBookStateV1` passed fsck and mounted as ext4 on `vdb`;
2. the volume-ready sentinel was created;
3. `BOOK-STATE-GUEST source-provenance=pass` was emitted;
4. kernel identity, network absence, and forbidden-mount checks passed;
5. all fixed gVisor executables were identified and
   `BOOKEXEC-RUNSC-VERSION-PASS` was emitted.

Thus the in-place two-file fix crossed the exact failure point and entered the
real Book State authority. Read-only evidence from cycle 2 is under
`evidence/cycle2/`: journal replay was performed only on a private copy;
`debugfs` found the mode-0600 sentinel and database; immutable-store `sqlite3
-readonly` returned `integrity_check=ok`, `user_version=1`, the exact three
tables, and metadata `storage_schema_version=1`. It also found one Guile
namespace at state version 0 and no commit receipt. That is startup evidence,
not a successful note save.

### Host UI blocker exposed by the direct runs

The inherited fixture expects and closes exactly two clean-profile KOReader
startup notices when the first persistent-note dialog opens. Native host runs
answer `channel-ready` quickly enough that both remain present. With the
AArch64 TCG authority on the other side of the private UI proxy, the timed
BookInfo notice's three-second deadline expires before the guest's `open`
command arrives. Cycles 1 and 2 therefore logged
`FAIL:clean profile did not show both pinned startup overlays`; retrying after
`open` cannot restore an expired notice.

Cycle 3 tested the right synchronization point—consume the same exact two known
notices in `onReaderReady`, before emitting `channel-ready`, while delaying the
existing marker until after `dialog-shown`—but added one unjustified assertion:
that `self.ui` must already be the top visible widget after the notices close.
KOReader removed both notices and immediately reported
`FAIL:could not expose the expected startup target`; `onReaderReady` precedes
that underlying widget becoming visible. The coordinator terminated QEMU before
it produced guest console output. This is a diagnostic-fixture defect, not
evidence against the image fix. Cycle 3's exact QEMU and reader identities are
also absent.

The three-cycle diagnostic allowance is now exhausted. The concrete source
correction retains cycle 3's pre-`channel-ready` exact two-notice count but drops
only the requirement that an underlying widget already be visible; the
historical marker remains after first `dialog-shown`, and the guest-driven
selection action, UI protocol, state authority, graph, and timeout semantics
remain unchanged. The canonical and two-boot fixture copies are byte-identical
at `837a0934…`; KOReader's LuaJIT compiled those bytes successfully. A fresh
native reader-join run then passed all 22 lifecycles, with exactly one startup
marker in every reader log, strict
`selection-action:registered` → `dialog-shown:generation=1` →
`startup-overlays-dismissed:2` → `dialog-ready:generation=1` order, and no
`BOOK_STATE_READER: FAIL:` marker. Its four-line terminal output is `84bdb1ae…`
and stderr is empty (`e3b0c442…`) under
`/tmp/opencode/book-state-v9-direct-fix-20260907-v1/evidence/`.

No fourth diagnostic QEMU cycle was run.

## Clean post-V9 successor build and binding

The exact 134-input source capsule is frozen at
`/tmp/opencode/book-state-guest-sources-20260907-post-v9-volume-ui-fix-r2`:
source manifest `03b07080…`, roster `253cf3a5…`, snapshot `6011e2eb…`, packet
manifest `02dc64f1…`, and V9→successor delta `dadb7d9d…`. Its private replay
passed and is sealed at
`/tmp/opencode/book-state-guest-sources-20260907-post-v9-volume-ui-fix-r2-author-evidence-r1`
(`05404ef1…`). The roster remains 19 modules, 91 assets, 24 checks, and exactly
nine executable local-file inputs.

The first derivation-only prebuild check correctly stopped before realization:
a packet-sealing `chmod` had removed those nine executable bits, changing only
the recursive gVisor package-tools input mode and therefore its derivation. The
roster modes were restored, the capsule checker passed, and the corrected dry
run resolved the exact cached kernel `334ljs8q…` and gVisor `djgy782a…`,
scheduling neither for rebuild.

The single authorized clean build then completed in 20 seconds with one job and
two cores. Image `/gnu/store/cbnpv8rxy7i7h5m58a5vkn929dq4yvvb-disk-image`
is `2839f9fc…`, 2,063,552,512 bytes, with embedded system
`/gnu/store/a4qgl0y3k0c265mwx9wx0v8g24jla6bs-system`. Read-only `debugfs`
inspection proved both the generic mount flags and the compiled volume gate's
textual-ports/SRFI imports. No image or state filesystem was host-mounted.

The label-only private payload remains a 97-byte/27-range transform. Its root is
`6336c1ee…`; `PAYLOAD.sha256` is `0336260c…`. The complete image packet is
`/tmp/opencode/book-state-image-post-v9-volume-ui-fix-author-20260907-v1`
(`AUTHOR-EVIDENCE.sha256` `6b294d09…`). The version-neutral table remains
exactly 88 fields across eight roles (`17eabf6f…`). The production bundle's
`BUNDLE.scm` is `60d7ed70…` and its outer manifest is `22cc91b2…`.

## Production campaign result: boot 1 stale-cgroup rejection

The exact frozen launcher source (`SOURCE-MANIFEST.sha256` `6e44b908…`, runtime
manifest `31e298bf…`) passed its complete host gate against outer bundle
`22cc91b2…`, then ran once through the sole production entrypoint. This was the
authorized production retry, not a fourth diagnostic cycle. It failed after 33
seconds in boot 1 without a timeout; boot 2 did not start and the checker did
not reach `PASS`.

The run proves both source fixes reached their intended runtime seams. The
volume gate completed, the authority started, and source, kernel,
network-absence, forbidden-mount, and runsc-version checks passed. KOReader
logged exactly `dialog-shown:generation=1` →
`startup-overlays-dismissed:2` → `dialog-ready:generation=1`. Guile then read
absent/version 0, committed A/version 1 under operation
`note_surface_7wMvVTmRpK1QwnlWg6smLD9S_s1_q1`, and completed the UI
`commit-ok`/`present`/`close` exchange.

The next fail-closed boundary found
`/sys/fs/cgroup/wilkbook-execution-wilkbook-guile-book-state` still present
after runsc exited zero and its exact process group was reaped:
`runtime left stale cgroup: wilkbook-guile-book-state`. Python never started.
KOReader's later `private control host closed unexpectedly` is downstream of
the guest authority closing its transport after this failure, not the cause.

The guest unmounted `WBBookStateV1` cleanly. Read-only `e2fsck`, `debugfs`, and
immutable SQLite inspection of a private copy found one Guile namespace and one
version-1 receipt, `quick_check=ok`, no foreign-key rows or sidecars, and no
Python namespace. The campaign state hash is `8e62f74b…`. All 30 recorded host
PID/start-time records are absent, no live argv names any owned run path, the
run base is empty, and the campaign owner lock is released.

Observed evidence does not say whether the remaining cgroup was empty or busy
and did not retain the runsc debug file that would identify the failed teardown
operation. Static inspection supplies only a bounded inference: this gVisor's
`container.Run` deliberately ignores errors from its deferred `Destroy`, while
`Destroy` calls cgroup-v2 `Uninstall`; therefore runsc exit zero can coexist
with the observed stale node, but the exact uninstall error is unknown.

No additional QEMU cycle or build was run. The sealed launch manifest is
`6c3ab034…`; read-only failure inspection is
`/tmp/opencode/book-state-successor-production-failure-inspection-20260907-v1`
(`aa0962b4…`). Before another cycle or clean build, obtain authorization and add
bounded exact-path cgroup metadata plus guaranteed runsc-debug emission at this
failure boundary. Do not choose cleanup semantics until that evidence
distinguishes an empty orphan from a busy cgroup. The full acceptance obligation
remains A/version 1 for both languages, boot-2 recovery of A, B/version 2, four
attributed boundary records, clean shutdown, read-only final evidence, and
checker `PASS`.

## Natural-grace clean successor and strict two-boot result

The bounded-grace diagnosis was ported without changing the Book State
protocol: an owned `runsc run` first receives the existing five-second natural
exit/drain interval, then retains the previous TERM → grace → KILL → grace
escalation. The focused guest suite passed 99 module checks and 18 liveness
checks (`487ff7ab…`). The frozen 134-input capsule is
`/tmp/opencode/book-state-guest-sources-20260907-natural-grace-successor-v1`:

- source manifest `920bacf1…`, capsule roster `8506c901…`, snapshot
  `0858d36d…`, packet manifest `082d0784…`;
- 19 modules, 91 assets, 24 checks, and exactly nine executable local-file
  inputs;
- author replay
  `/tmp/opencode/book-state-guest-sources-20260907-natural-grace-successor-v1-author-evidence-v1`
  (`65bff26e…`), with no independent-successor review claim.

The network-isolated dry run scheduled neither the exact cached kernel
`/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote`
nor gVisor
`/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`.
The one authorized `--no-grafts --no-substitutes --max-jobs=1 --cores=2`
realization took 19 seconds and built 15 small derivations:

- derivation `/gnu/store/ynds2p541hz4krjna26rj78dismm7gzf-disk-image.drv`;
- image `/gnu/store/j6i1p44vabm88dxa79f1dyzljzjgzyzc-disk-image`, SHA-256
  `fd4f2ffffcb401fd0adb8dbb9d614517d967032c3d008a690fdcfbbb2ee8ae73`;
- embedded system `/gnu/store/b1i3hjgdpqvvy6wbny23gnb9wmr0mj6n-system`;
- image/payload packet
  `/tmp/opencode/book-state-image-natural-grace-successor-author-20260907-v1`,
  `AUTHOR-EVIDENCE.sha256` digest `9c6b5582…`;
- four-file boot `PAYLOAD.sha256` digest `dacfad2a…`, separate from
  `BUILD-STATUS.json`; schema-3 binding remains exactly 88 fields/eight roles;
- production bundle outer-manifest digest
  `bd7151f0c4e729d40c4ed6ef65fe381ad07c30e4e3912089a83bfe0d1849245b`.

Read-only image extraction proved the actual partition, extlinux, initrd,
embedded system, generic state mount flags, and compiled volume-gate imports.
The private root preparation changed only the ext4 label (97 bytes across 27
ranges). No filesystem was host-mounted.

### Exact production attempts

Attempt 1 is preserved at
`/tmp/opencode/book-state-natural-grace-production-launch-20260907-v1` and its
evidence at
`/tmp/opencode/book-state-natural-grace-evidence-base.jtb3jI/book-state-two-boot-evidence.JRz6L3`.
Its 44-second boot was semantically clean—both languages saved A/version 1,
both boundary records were published, and all runtime processes were reaped—but
the checker expected a semantic status confirmation between two audit callbacks
that the real UI emits during the same paint. The corrected checker preserves
all required markers and requires their actual order. Replay also proved that
Shepherd captures the service-exit status line instead of sending it to UART;
the checker now rejects that phantom console line and orders canonical
power-down after guest success. The same preserved boot then passed strict
single-boot replay.

The second and final production command was exactly:

```sh
/tmp/opencode/book-state-qemu-two-boot-natural-grace-successor-20260907-v1/source-r2/run-two-boot.sh --bundle /tmp/opencode/book-state-qemu-two-boot-natural-grace-successor-20260907-v1/production-bundle --campaign-base /tmp/opencode/book-state-natural-grace-r2-campaign-base.A5lEm5 --run-base /tmp/opencode/book-state-natural-grace-r2-run-base.rVvJXa --evidence-base /tmp/opencode/book-state-natural-grace-r2-evidence-base.MfE1mX
```

`source-r2` has complete-source manifest `5cdd3310…`, 23-file runtime manifest
`6f9c0fb6…`, and snapshot `bf5ba5d4…`. The entrypoint ran 86 seconds. Both fresh
boots passed their strict per-boot checks and the pre-cleanup cross-boot check:

- boot IDs `1a89de1d0552df2bc2c3cd568fcd310a` and
  `679125b44b0ab29b0708fe4e2d0f3fc1`;
- boot 1: Guile and Python absent/version 0 → A/version 1;
- boot 2: both read/repainted A/version 1 → B/version 2;
- state hash chain `502782aa…` → `651d4b49…` → `ffb49189…` on the same
  device/inode and single-link 64 MiB image;
- four distinct operation IDs and four attributed sandbox boundary records;
- canonical power-down at 38.190522 s and 32.789169 s; both QEMU and KOReader
  statuses zero, all owned process identities gone.

The first attempt-2 host exit occurred only after those checks: the final-copy
guard compared two six-field identity alists with different field order. The
fields themselves all matched. A focused live regression now requires exact
`device,inode,uid,mode,links,size` structural equality. Offline continuation of
the already quiescent attempt then reached one final producer typo: Scheme
numeric `0400` serialized as `400`, while the checker correctly required the
textual evidence value `0400`. Both failed host-finalization records and an exact
single-link mode-0400 copy of the post-boot-2 state remain under
`/tmp/opencode/book-state-natural-grace-production-launch-20260907-v2`.

No third QEMU boot was run. After those narrow producer/join corrections, the
already-complete attempt-2 evidence was finalized offline using the same strict
checker from `source-r2`. Identity-safe campaign cleanup removed the original
campaign root; the run base is empty. Final immutable evidence is:

- root:
  `/tmp/opencode/book-state-natural-grace-r2-final-evidence-base-v2.IOI2LD/book-state-two-boot-evidence.qPQNl4`;
- `EVIDENCE.sha256` digest:
  `b9d08b88295df2feaa49b60ec9ca923e57aa964a54523682326fb8554d6da06b`;
- final-evidence `PAYLOAD.sha256` digest: `317934de…` (not the boot payload or
  build-status evidence);
- read-only, single-link 64 MiB state artifact SHA-256:
  `ffb491892db5c2824f57d65bda9084210db2d7483d2f1a0cd3875f20c54e9d9b`.

An independent read-only final checker replay prints
`PASS: exact two-fresh-boot Book State evidence and cleanup join`; `e2fsck -fn`
also returns clean. The exact campaign result is:

```text
BOOK_STATE_TWO_BOOT: status=pass; evidence=/tmp/opencode/book-state-natural-grace-r2-final-evidence-base-v2.IOI2LD/book-state-two-boot-evidence.qPQNl4; manifest-sha256=b9d08b88295df2feaa49b60ec9ca923e57aa964a54523682326fb8554d6da06b; state-artifact=read-only
```

This is strict opt-in ARM QEMU evidence, not PineNote hardware validation and
not default-reader activation.
