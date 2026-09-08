# Book interaction realized QEMU image/binding adversarial review — 2026-09-06

## Disposition

**Accept the realized image and its actual image-generated initrd for one later,
separately authorized QEMU demonstration.** The `raw-with-offset` lowering is
internally consistent: the image system and initrd use Guix's deterministic
root UUID, the private baseline retains that UUID while changing only the ext4
label to `PNGuixRoot`, and the private QEMU command line deliberately overrides
the initrd's embedded root device with `root=PNGuixRoot`.

**Accept launcher v4's image/source/outer binding, conditional on independent
acceptance of its exact replacement harvester.** The only change from the
already inspected v1 launcher is the private harvester snapshot and its related
manifest/hash, evidence path, and authorization literal. The image, boot
bundle, baseline, KOReader, accepted guest/outer/coordinator/Lua sources,
production invocation, QEMU graph, and deadlines are unchanged.

Review results:

```text
READER_INTERACTION_QEMU_IMAGE_BINDING_VERDICT=ACCEPTED_FOR_ONE_SEPARATELY_AUTHORIZED_QEMU_DEMONSTRATION
READER_INTERACTION_QEMU_LAUNCHER_V4_BINDING_VERDICT=ACCEPTED_CONDITIONAL_ON_INDEPENDENT_HARVESTER_V4_ACCEPTANCE
```

This is **not** runtime authorization. In particular, it does not set or grant
the launcher's environment token. The actual QEMU/ARM/runsc behavior remains
unproven until the independent harvester verdict is accepted and the parent
separately authorizes exactly one invocation.

The superseded v1 launcher remains unfit because it pins blocked harvester
`410fc4bb…`. No image finding needs to be revisited for that host-helper defect.

No image or Guix build, dry-run, mount, QEMU, runsc/gVisor, ARM execution,
hardware, VM, SSH, UART, network, deployment, staging, commit, push, or merge
was performed in this review. I used read-only store/source inspection,
bounded host metadata/hash checks, the immutable inventory checker, and the
launcher's pre-runtime refusal branch only.

## Frozen boundaries

The original image/runtime packet matched its claimed identity:

```text
2233c6f4f0a69fe2d1c00e590e029cba1ed651709f4466a8f6a61a6c549c7c89
  pinenote/tools/book-execution-spike/build/reader-interaction-image-runtime-binding-review-packet-v1.txt
```

Its accepted joined-source parent remains:

```text
632ee95ca513293a3fefbff686748c9b70874ca3e0b9bdac0694345038fbc8e5
  doc/reviews/2026-09-06-book-interaction-qemu-guest-outer-adversarial.md
READER_INTERACTION_JOINED_SOURCE_VERDICT=ACCEPTED_FOR_SEPARATELY_AUTHORIZED_IMAGE_ASSEMBLY
```

The focused replacement-helper packet and proposed launcher matched:

```text
53f281e3efc00027f0f18debd4ece4631a76c951870d7d62c3cdfe0b4304a4b6
  pinenote/tools/book-execution-spike/build/reader-interaction-harvester-lifetime-review-packet-v2.txt
42f90a468ab5447ab9565abcbf7feb8849756784ef94f19c49f59a0c52fcbbdb
  pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v4.command
b9f7936095d8363d25c6cdc5f754f4883e6ef2a0af9f3c9a4358d6670e691457
  pinenote/tools/book-execution-spike/harvest_reader_qemu_logs_v4.py
```

Harvester process ownership, late-writer exclusion, bounded descendant-pipe
handling, and the H1/H2 regressions remain the separately assigned review. This
review accepts their launcher integration only if that review accepts exact
helper `b9f79360…`; it does not independently relabel the helper as correct.

## Guarded image assembly

The v2 and v3 guarded recipes failed closed before any derivation, dry-run, or
image operation. V2 could not load `(gcrypt base16)` from ambient Guile; v3's
added load path was immediately cleared. The successful v4 recipe hashes to
`3e5abf7021e7e2603e1a6ffdb1638261c528648e62e8111d012b2867cbc3a039`.

The preserved v2→v4 diff hashes to `d65ab8a3…` and makes only two changes:

1. it versions the dry-run log path from v2 to v4; and
2. it executes the production five-source roster assertion in a pinned, pure
   `guile@3.0.9`/`guile-json@4.7.3`/`guile-gcrypt@0.5.0` shell.

The derivation and image commands are byte-identical. The authorized v4 log
hashes to `548baa1e…`, records the exact 46-path inventory and production roster
checks before lowering, and ends in the one realized image output below. Its
dry-run log hashes to `f49cee11…`; it plans only the expected 19 generated
reader-system/image derivations and no kernel or CONTROL rebuild.

I accept this as a host-environment repair, not a change to the image recipe or
accepted source semantics.

## Raw image and private label-only baseline

The realized Guix image is:

```text
/gnu/store/apblsmdj5i4spl2ya8bm7zxb9vw1c1xd-disk-image
SHA-256 725ebcaf5783554a2b01c113733f8cb858d4307bf9b58ad90ae8314bf0f5afb6
size    2055192576
```

Independent non-mount parsing of that output and the private baseline found the
same disk and filesystem shape:

| Property | Store image | Private baseline |
|---|---|---|
| MBR partitions | one, type `0x83` | one, type `0x83` |
| Start sector | `2048` | `2048` |
| Sector count | `4012000` | `4012000` |
| Root byte offset | `1048576` | `1048576` |
| ext4 UUID | `a454a7b0-be49-f492-2be5-51d8a454a7b0` | same |
| ext4 label | `Guix_image` | `PNGuixRoot` |
| Whole-file SHA-256 | `725ebcaf…` | `34eef74f…` |

A byte-for-byte comparison found 97 changed bytes in 27 ranges. Every range is
inside the primary or five backup ext4 superblocks; the changes are the label
and resulting superblock checksum/metadata bytes. No filesystem data or inode
region differs. The baseline is a mode-0400, single-link file beneath a
mode-0500 private directory. The packet's bounded read-only `e2fsck -fn`
inspection passed.

This is adequate evidence that the QEMU baseline is the realized image with
only the requested private partition-label transformation, not a second image
assembly.

## Actual image initrd and root selection

`raw-with-offset` does not preserve the standalone label-root system object. It
lowers a new image system whose root is the deterministic image UUID:

```text
standalone system: /gnu/store/7wmkz16hckklh7wc0if06sl8446028f6-system
  root:   file-system-label PNGuixRoot
  initrd: /gnu/store/dpv1jnkl4298wmqrkhbh03g3sv466l1w-raw-initrd/initrd.cpio.gz
  initrd SHA-256: d3eb4deeb10ee6430cb2e2392143a9327f7227ac0bd145d6d1474abfb9fe37fe

image system: /gnu/store/lnssfrn2p2g0pzdw1ffnd0mndax6jyk0-system
  root:   UUID a454a7b0-be49-f492-2be5-51d8a454a7b0
  initrd: /gnu/store/g1dm8064yj6fxd116p6dgd5swxk08wi7-raw-initrd/initrd.cpio.gz
  initrd SHA-256: d28c4c95ad1a234895e2556524971538aa0dfc10f237fa018917252ae89a2507
```

Both system-derivation closures contain 2,558 paths: 2,541 are shared and the
17-for-17 replacement is confined to generated system, parameters, fstab,
activation, boot, init, and initrd wrappers. Both initrd derivation closures
contain 1,024 paths: 1,020 are shared and only the four generated init/initrd
paths differ. The kernel and all substantive reader sources remain shared.

The actual image initrd archive contains 702 entries. Its `./init` points to
`/gnu/store/5ha9lxd019vsmim0kiji4q4jszq6c61y-init`; the archived file matches
that store object at SHA-256
`72e120e4a1e41fff1a2cb1256d7e517b374da2c69750730658db5808786ed7b3`
and embeds the deterministic image UUID.

The private extlinux command line supplies, in relevant part:

```text
gnu.system=/gnu/store/lnssfrn2p2g0pzdw1ffnd0mndax6jyk0-system
gnu.load=/gnu/store/lnssfrn2p2g0pzdw1ffnd0mndax6jyk0-system/boot
root=PNGuixRoot
```

Pinned Guix `f250e74d…`, `gnu/build/linux-boot.scm`, explicitly gives the
kernel's `root=` option precedence over the root filesystem record embedded in
the initrd. The private baseline has that exact label and retains the UUID the
image initrd expects elsewhere.

Therefore the correct boot-bundle input is the **actual image initrd**
`c7xi…`/`g1dm…` with SHA-256 `d28c4c95…`. Requiring standalone
`89md…`/`dpv1…` bytes would misdescribe what Guix put in this raw image and is
not necessary for the label-selected private baseline.

The private boot bundle's kernel, config, DTB, and initrd independently match
their realized store outputs:

```text
Image  f3da1a2291a8b2a6c02a8512350a64196a01906a979a8ae17743cb924ce7f223
config 0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
DTB    e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229
initrd d28c4c95ad1a234895e2556524971538aa0dfc10f237fa018917252ae89a2507
```

The config includes the reviewed user-namespace, virtio console, virtio PCI,
virtio block, and devtmpfs prerequisites.

## Realized source and execution binding

The image-lowered realized system has 347 output requisites. The image has 348
direct references and 349 output requisites including itself; every recorded
path exists. The system embeds the expected reader source manifest
`5f259c48…` and build manifest `87400e07…`.

The realized Shepherd source:

- requires `user-processes` and `udev`;
- launches the exact trusted supervisor profile under `env -i`;
- passes the exact 45-path language closure, fixed Guile and Python books,
  accepted codec/session/OCI sources, and the three reader-interaction sources;
- supplies the accepted guest adapter and reader-source hashes; and
- replaces itself with the system's `halt` after the finite gate returns.

The source manifest pins reader authority `6dc0dfc9…`, virtio UI adapter
`3b6e8eb1…`, private control `1304b21d…`, and accepted guest protocol adapter
`eb6a1af3…`. The installed eudev rule creates
`/dev/virtio-ports/$attr{name}`; the guest requires the exact character-device
symlink `/dev/virtio-ports/org.wilkbook.book-interaction`.

The selected fixed execution paths resolve to AArch64: trusted and sandbox
Guile, sandbox Python, CONTROL `runsc`, system `env`, and the directly bound
libgcrypt library. The system `halt` script's shebang also selects the same
AArch64 Guile. The two fixed OCI process vectors name only
`/profile/bin/guile` and `/profile/bin/python3`, and the immutable profile maps
those to the inspected AArch64 outputs. Read-only ELF inspection shows the
selected Guile, Python, and `env` request the AArch64 dynamic loader and carry
runpaths to target libraries; CONTROL `runsc` is static AArch64.

### Architecture qualification

A literal claim that the complete realized closure contains **no** x86-64 ELF
is false, and this review does not make that claim. A complete static ELF scan
of the 347-path system closure found:

```text
1859 AArch64 ELF files
 571 x86-64 ELF files
1108 ELF-container Guile .go files with e_machine=0
```

Of the inherited, already accepted 45-path language closure, 455 ELFs in 17
store outputs are x86-64. Those outputs are consequently present in the guest
store and mounted read-only into the fixed OCI roots along with the complete
accepted language closure. They are inherited references of the cross-built
Guix profiles; they are not selected by the fixed Shepherd, runsc, Guile, or
Python command paths reviewed here.

For this finite trusted-book demonstration, the relevant condition is that no
foreign binary is selected for execution, and that condition passes. A future
requirement that no foreign ELF may be present or mounted at all is a different
closure-hygiene gate and this exact image would fail it. I do not reinterpret
the present acceptance as satisfying that stronger statement.

## Immutable v5 runtime snapshot and helper-only delta

The proposed v5 private source manifest hashes to:

```text
3a343d9f99dc6cf37f0575d9a5fb1ed7cb7a5a9f1a505eea880480c7a0084f1c
  pinenote/tools/book-execution-spike/build/artifacts/
  reader-interaction-runtime-sources-20260906-v5/RUNTIME-SOURCES.txt
```

I independently found 63 regular files, 15 directories including the root,
and zero symlinks. The root/directories are mode 0500; every file is mode 0400
with one link. The private inventory checker passed all 46 accepted joined
paths against this snapshot.

An independent recursive v2→v5 comparison found exactly:

```text
removed: harvest_reader_qemu_logs.py
removed: test_harvest_reader_qemu_logs.py
added:   harvest_reader_qemu_logs_v4.py
added:   test_harvest_reader_qemu_logs_v4.py
changed: RUNTIME-SOURCES.txt
unchanged common files: 60
```

All 46 joined-source files and all seven runtime-module-view files are among
the byte-identical common files. The copied v4 helper matches the proposed
source at `b9f79360…`; its copied test matches `84e93273…`. Thus the helper
replacement does not alter the accepted outer, coordinator, Lua, guest,
checker, or QEMU graph source.

## Launcher v4, KOReader, and QEMU graph

The preserved v1→v4 launcher diff hashes to `3b520f66…`. Direct comparison
shows only these six binding changes:

1. authorization literal;
2. runtime snapshot path v2→v5;
3. future evidence path v1→v4;
4. private helper path;
5. runtime snapshot manifest hash; and
6. helper hash.

No line containing the image directory, baseline, kernel/config/DTB/initrd,
KOReader, host tools, production outer command or its arguments changed.
Launcher v4 passes shell syntax checking.

The exact KOReader output remains:

```text
/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
git-rev: v2026.03
git-rev SHA-256:   846aed94948bfa1c155325770bf4df8673850a14395ec585c3d594c859d5b2d5
reader.lua SHA-256: a189ca83623153f2a1b048c7bc04eba1fca76068bd9705dc71296d26292613cc
luajit SHA-256:     d6fdee87218f50e36b44b4c19f18de944f87b465cd24227dacf5b9cb83774a88
```

`bin/koreader` resolves only to `../lib/koreader/koreader.sh`. The accepted
outer requires the canonical exact store path, and launcher v4 verifies the
revision before the production call. The coordinator and four Lua files come
from the immutable v5 snapshot; the normal production outer pins coordinator
`ca0c552f…` and the same four accepted Lua hashes with no roster override.

The unchanged production graph is exactly:

- `-no-user-config`, `-nodefaults`, machine `virt`;
- TCG multi-thread, CPU `max`, four vCPUs, 2 GiB;
- no display, reboot, NIC, or monitor;
- a private qcow2 overlay over the private raw baseline;
- one private console socket/log;
- the three reader additions immediately before `-kernel`: one private Unix
  socket chardev, one `virtio-serial-pci` controller, and one named
  `virtserialport` for `org.wilkbook.book-interaction`;
- no 9p/virtfs/fsdev or other host filesystem share; and
- no UI-chardev logfile.

The v4 harvester receives the production command after `--` and launches that
argument vector unchanged. It validates the exact run base, 600-second outer
deadline, and five-second outer TERM grace; it has no QEMU graph, boot-image,
KOReader, or semantic-book input of its own. Its subreaper/private-session
layer is additional host observation and cleanup ownership, not a replacement
or source edit to the accepted process and run-root guardians. Whether that
extra ownership layer is correct remains the independent harvester condition.

There is exactly one production invocation, still bounded by a 600-second
outer deadline and five-second TERM grace. The host wrapper deadline is 630
seconds (hard configurable maximum 660 seconds).

## Inert authorization guard

The exact proposed launcher is:

```text
pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v4.command
SHA-256 42f90a468ab5447ab9565abcbf7feb8849756784ef94f19c49f59a0c52fcbbdb
```

Its guarded branch requires:

```text
variable: WILKBOOK_READER_INTERACTION_QEMU_AUTHORIZATION
literal:  READER_INTERACTION_HARVESTER_V4_PACKET_ACCEPTED_AND_REAL_QEMU_SEPARATELY_AUTHORIZED
```

I invoked v4 once **without** that variable. It returned status 125, produced
no stdout, and produced exactly:

```text
refusing: reader-interaction real QEMU run is not separately authorized
```

Before and after that refusal,
`/tmp/opencode/reader-interaction-v1-runs` was mode 0700 and empty, and the
future evidence directory was absent. The guard therefore remains before hash
checks, evidence creation, or process launch.

The future evidence path bound by this launcher is:

```text
pinenote/tools/book-execution-spike/build/artifacts/
reader-interaction-real-qemu-20260906-v4-harvest
```

Recording the variable and literal here describes the reviewed interface; it
does not authorize setting it.

## Obligations after any separately authorized run

A later run may be called successful only if all of these hold:

1. the independent harvester review has accepted exact helper `b9f79360…` and
   exact packet `53f281e3…` before authorization;
2. launcher v4 itself exits zero and the harvester publishes only
   `harvest-status=complete`;
3. all six retained logs are complete and stable: guest console, coordinator
   stdout/stderr, reader log, and QEMU stdout/stderr;
4. production stdout is exactly the one payload-free joined success line, with
   coordinator and QEMU status zero and clean power-down;
5. the strict reader console checker is rerun against retained `console.log`;
6. four ordered guest `present` observations match four actual
   `InputDialog:paintTo` observations and four topmost `ui_audit` paint
   observations by their runtime-generated suffixes;
7. the values have the fixed shape: two Guile uppercase/length results followed
   by two Python reverse/length results—there is no host literal-result oracle;
8. exactly one native KOReader UI lifecycle completes and cleans up; and
9. the accepted identity-safe guardians leave the run base empty.

No PNG is expected or required. The accepted native evidence is the existing
`InputDialog:paintTo` plus topmost `ui_audit` observation pair.

Until those facts are produced by the separately authorized one-use run, this
review proves only image and launcher binding—not boot, virtio enumeration,
runsc execution, native paint, shutdown, or runtime cleanup.

## Focused v5 launcher-binding recheck — final fit disposition

### Superseding launcher verdict

**Accept exact launcher v5 as fit for at most one separately parent-authorized
run.** The independent harvester review has accepted the exact v5 helper tuple,
closing this review's former host-helper condition. V5 changes no accepted
image, boot, guest, native-reader, outer, coordinator, Lua, KOReader, or QEMU
graph input.

```text
READER_INTERACTION_QEMU_LAUNCHER_V5_BINDING_VERDICT=ACCEPTED_FOR_AT_MOST_ONE_SEPARATELY_PARENT_AUTHORIZED_RUN
```

This supersedes only the conditional launcher-v4 disposition above. The image
verdict, actual-initrd decision, architecture qualification, and post-run
evidence obligations remain unchanged. Launcher v4 and its token are prohibited
because the independent review found its P-1 false-complete publication window.

Before this appendix, this image review matched the accepted parent identity
recorded in the publication packet:

```text
805f1abdb77ea48632fe2c9fe0f1fd7e4b228b2bdd09edaad1539aa52e63a43
```

The independent harvester report now hashes to
`487a178371e2d4c173c70df3d4fef3187ef43ca62d5fa8cca65a41d3eac50921`
and accepts this exact tuple:

```text
publication packet  db1800568bfbb95cd06b4320011b26e9216e950e480801bdb69019cfcd
helper              462a20ad7eb8c9ce908645aa10a6da8cd6bdd054f852c90e51294dde73e27e51
test                2101be2f51f7846778d44c15c39fa59c8c4367de6adfef8440bc287a3bf61e48
v6 manifest         506605cfec38f32fe2a1bad426529d4e4816174df8a1a3c3ebf9407c66d389a6
launcher            f1289ecbb4f5363d56deba3437cf12b22f8d7163997f291f1d86c056691ea151
```

### Immutable snapshot and launcher delta

I independently walked private snapshot
`reader-interaction-runtime-sources-20260906-v6`: it contains 63 regular files,
15 directories including the root, and zero symlinks. Every directory is mode
0500; every file is mode 0400 and single-link. Its private joined-inventory
checker passes all 46 paths.

The v5→v6 snapshot delta is exactly:

```text
removed: harvest_reader_qemu_logs_v4.py
removed: test_harvest_reader_qemu_logs_v4.py
added:   harvest_reader_qemu_logs_v5.py
added:   test_harvest_reader_qemu_logs_v5.py
changed: RUNTIME-SOURCES.txt
unchanged common files: 60
```

All 46 joined-source files and all seven runtime-module-view files remain
byte-identical. The private helper and test copies match `462a20ad…` and
`2101be2f…`; the production outer and graph remain `8ae1ec1a…` and
`16f11331…`.

Direct v4→v5 launcher comparison found only the same six helper-binding fields:

1. authorization literal;
2. runtime snapshot v5→v6;
3. future evidence path v4→v5;
4. private helper filename;
5. runtime-manifest hash; and
6. helper hash.

The image directory, baseline and its hash, kernel/config/DTB/initrd paths and
hashes, KOReader, host tools, source roster, production entry, complete
production argument vector, one-invocation cardinality, 600-second outer
deadline, and five-second outer TERM grace are byte-unchanged. Launcher v5 also
passes shell syntax checking.

The exact final launcher is:

```text
pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v5.command
SHA-256 f1289ecbb4f5363d56deba3437cf12b22f8d7163997f291f1d86c056691ea151
```

Its future evidence directory is:

```text
pinenote/tools/book-execution-spike/build/artifacts/
reader-interaction-real-qemu-20260906-v5-harvest
```

### Authorization guard

Supplying the obsolete v4 literal to launcher v5 returned status 125, no
stdout, and exactly the refusal line. Before and after, the private run base was
empty and the v5 evidence directory was absent. Thus the old literal cannot
reach hash checks, evidence creation, or process creation.

The sole eligible launcher interface is:

```text
WILKBOOK_READER_INTERACTION_QEMU_AUTHORIZATION=READER_INTERACTION_HARVESTER_V5_PACKET_ACCEPTED_AND_REAL_QEMU_SEPARATELY_AUTHORIZED
```

It was not set, exercised, or consumed here. This review establishes fit; only
the parent may separately supply that exact literal, for at most one invocation
of the exact launcher hash above. Actual QEMU/ARM/runsc behavior and every
post-run result remain unproven until that run and its retained evidence are
checked.

No actual runtime, image or Guix build, dry-run, mount, hardware, deployment,
network, staging, commit, push, or merge occurred in this focused recheck.

## Authorized v5 attempt — pre-QEMU config-hash binding failure

### Corrected disposition and attribution

**Retract the launcher-v5 fit verdict above.** The approved v5 attempt exposed
an argument-semantic error in the launcher: `--config-sha256` was given the
kernel `.config` hash, but the accepted outer defines “config” as the private
copy of `boot-bundle/extlinux/extlinux.conf`.

```text
READER_INTERACTION_QEMU_LAUNCHER_V5_BINDING_VERDICT=RETRACTED_CONFIG_SHA256_ARGUMENT_MISBOUND
```

The realized image, actual image-generated initrd, private baseline, kernel,
kernel config, extlinux file, KOReader, guest/outer/coordinator/Lua sources,
QEMU graph, and accepted v5 harvester remain valid at their reviewed scopes.
Only the launcher call integration is rejected.

This was a miss in this image-binding review. I verified both files and both
hashes, and verified that helper-version launcher deltas preserved the
production argument vector, but I did not trace the semantic meaning of the
outer's `--config-sha256` option. Treating the unchanged argument as accepted
therefore propagated the original misbinding through launchers v1–v5. The
separate preflight hash of `extlinux.conf` did not make the later wrong option
argument correct.

Before this appendix, this review hashed to:

```text
5136e0ebb77d77b255929f2ec99046687d4bf958c1e1567a1fb6ae52f422bd9c
```

### Exact root cause

Both immutable boot files are correct and retain their previously reviewed
hashes:

```text
boot-bundle/extlinux/config
  0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309

boot-bundle/extlinux/extlinux.conf
  aeea33940e8c1ba9d6cf97aa41f19d02a9eb7a1faa162efeecd079e4b8a5f284
```

Launcher v5 correctly checks both at lines 97–104. Its production call then
incorrectly supplies:

```text
--config-sha256 0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
```

The immutable accepted outer's call chain is unambiguous:

1. `validate-boot-bundle` assigns its `config` value to
   `BOOT-BUNDLE/extlinux/extlinux.conf`;
2. `run` parses `--config-sha256` into `config-sha256`; and
3. `private-snapshot` copies that extlinux file to private
   `boot/extlinux.conf` and verifies it against the supplied hash.

The kernel `.config` is not the object governed by this outer option. The
correct argument for these unchanged inputs is therefore `aeea3394…`, while
the separate preflight check of kernel `.config` should remain `0a885ef8…`.

### Failure evidence and execution boundary

The parent wrapper log is:

```text
/tmp/opencode/wilkbook-reader-demo-wrapper.nLysNu.log
SHA-256 5f59de54054db65fc6dfae159b83c2fc393a94d5066c994ec26c3a4f52bf15ef
```

It contains only the joined-inventory PASS, normal-production-roster PASS, and
the exact rejection:

```text
FAIL: private config SHA-256 mismatch: expected 0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309, got aeea33940e8c1ba9d6cf97aa41f19d02a9eb7a1faa162efeecd079e4b8a5f284
```

The v5 evidence directory contains only mode-0400 `HARVEST.txt`,
`launcher.stdout`, and `launcher.stderr` beneath a mode-0500 directory.
`HARVEST.txt` says:

```text
harvest-status=failed
launcher-status=1
writer-completion=true
adopted-owned-children-observed=0
launcher-pipes-eof=true
run-root-removed=true
```

All six QEMU/reader log entries are `missing-or-unstable`, as expected because
their producers never started. `launcher.stdout` is empty and
`launcher.stderr` contains only the hash mismatch. The mode-0700 run base is
empty.

The outer failed during private boot-input snapshotting. It had not yet copied
the baseline, invoked `qemu-img`, constructed or launched the coordinator,
invoked QEMU, started KOReader, or executed ARM/runsc/guest code. Consequently
this consumed an authorization attempt but produced **no actual demonstration
run and no partial guest assertion**. The v5 literal must not be reused.

### Finite successor requirement

A successor needs only a fresh versioned launcher/evidence path/token that:

1. retains the kernel `.config` preflight hash `0a885ef8…`;
2. retains the extlinux preflight hash `aeea3394…`;
3. changes only the production `--config-sha256` argument to `aeea3394…`;
4. proves the corrected semantic mapping through the immutable accepted
   outer's real offline input-validation function, while stopping before any
   QEMU or other runtime operation; and
5. otherwise preserves the accepted image, v6 source snapshot/helper,
   KOReader, QEMU graph, one 600-second invocation, and five-second grace.

That successor needs only a narrow exact-delta and offline-validator follow-up.
It does not require rebuilding or re-reviewing the image, initrd, harvester,
guest, native reader, outer, coordinator, or Lua sources.

No QEMU, `qemu-img`, coordinator, KOReader, runsc, ARM/guest code, image or Guix
build, hardware, network, deployment, staging, implementation edit, commit,
push, or merge was performed in this attribution review.

## Focused launcher v6 config-argument correction — final fit

### Superseding verdict

**Accept exact launcher v6 as fit for at most one separately parent-authorized
run.** It corrects the sole v5 call-integration defect, uses a fresh evidence
path and authorization literal, and otherwise remains byte-identical to v5.

```text
READER_INTERACTION_QEMU_LAUNCHER_V6_BINDING_VERDICT=ACCEPTED_FOR_AT_MOST_ONE_SEPARATELY_PARENT_AUTHORIZED_RUN
```

This supersedes the retracted v5 launcher verdict only. The accepted image,
actual image initrd, baseline, source snapshot, harvester, KOReader, guest,
native reader, outer, coordinator, Lua, graph, architecture qualification, and
post-run obligations are unchanged. The stopped v5 failure and its evidence
remain preserved as history.

Before this appendix, this review hashed to:

```text
b74b2364befc5e0a54eca7a70c38bb6b5dfdcc3915b371aefa8906651d57b4c2
```

The focused inputs match:

```text
review packet
pinenote/tools/book-execution-spike/build/reader-interaction-launcher-v6-config-fix-review-packet-v1.txt
968cfa86042384279725e07957af7c67ec344ad772c653e4d557d2d777e62a88

launcher
pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v6.command
38e84085e21030f7b0929dc2280b23552b6b96f55c54831c11366ebfe4c6156e

v5-to-v6 diff
pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v5-to-v6-config-fix.diff
87dd2cdf2e4937718532da6d6cf55384bebc94236fe3c5a800f8309c70b634a1
```

### Exact three-value delta

Independent direct comparison found exactly three changed line pairs:

1. the authorization literal advances from launcher v5 to v6;
2. the future evidence path advances from the preserved v5 failure directory
   to a fresh v6 directory; and
3. the production `--config-sha256` value changes from kernel `.config` hash
   `0a885ef8…` to extlinux hash `aeea3394…`.

No other launcher byte changed. In particular, the private v6 source snapshot,
accepted v5 harvester, image/baseline paths and hashes, kernel, initrd, KOReader,
outer/coordinator/Lua sources, host tools, QEMU graph, one production
invocation, 600-second deadline, and five-second grace remain unchanged.

The independent guards still hash the two distinct immutable files correctly:

```text
boot-bundle/extlinux/config
  actual/guard: 0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309
  production --config-sha256 match: false

boot-bundle/extlinux/extlinux.conf
  actual/guard: aeea33940e8c1ba9d6cf97aa41f19d02a9eb7a1faa162efeecd079e4b8a5f284
  production --config-sha256 match: true
```

This now matches the accepted outer call chain: `validate-boot-bundle` returns
`extlinux/extlinux.conf` as `config`, and `private-snapshot` validates that file
using the supplied `config-sha256` option.

### Actual-input offline validation

The supplied clean proof is:

```text
command SHA-256 8ca131aeb1eb8e9aa2c2c414ce5420ef1a6d89b1dec74004dcf5825480cb9b92
log SHA-256     3393c71429deacd47617381b13c2c8956f17bb46d0e056a7087804939bad49f7
exit            0
```

I inspected the command before independently rerunning it. It imports the
immutable accepted outer and graph modules, uses the actual immutable boot
bundle and baseline, and calls their existing validators, private snapshotter,
APPEND parser, guarded-root helpers, and pure reader-QEMU argument constructor.
It contains no QEMU or `qemu-img` process invocation.

The independent run reproduced the former exact rejection for `0a885ef8…`,
then passed `aeea3394…` against the actual extlinux bytes. It also passed the
actual kernel, initrd, baseline, separate kernel `.config`, DTB and APPEND
checks, and assembled and self-asserted the accepted reader QEMU vector as pure
data. It produced no QEMU-side artifact and left its mode-0700 preflight run
base empty.

### Exact launcher and authorization interface

The final launcher path and identity are:

```text
pinenote/tools/book-execution-spike/build/reader-interaction-real-qemu-launch-v6.command
SHA-256 38e84085e21030f7b0929dc2280b23552b6b96f55c54831c11366ebfe4c6156e
```

Its fresh future evidence path is absent:

```text
pinenote/tools/book-execution-spike/build/artifacts/
reader-interaction-real-qemu-20260906-v6-harvest
```

The sole eligible interface is:

```text
WILKBOOK_READER_INTERACTION_QEMU_AUTHORIZATION=READER_INTERACTION_HARVESTER_V5_LAUNCHER_V6_PACKET_ACCEPTED_AND_REAL_QEMU_SEPARATELY_AUTHORIZED
```

Supplying the consumed v5 literal to launcher v6 returned status 125 with no
stdout and the exact refusal line. Before and after, both production and
preflight run bases were empty and the future v6 evidence path was absent.
Launcher v6 and the offline proof both pass shell syntax checking.

The v6 literal was not set, exercised, or consumed here. This review
establishes fit; only the parent may separately supply it for at most one
invocation of exact launcher `38e84085…`. Runtime success remains contingent on
the already recorded retained-evidence obligations.

No actual QEMU, `qemu-img`, coordinator, KOReader, runsc, ARM/guest execution,
image or Guix build, mount, hardware, network, deployment, staging,
implementation edit, commit, push, or merge occurred in this focused check.

## Authorized v6 attempt — functional proof with a host-checker false negative

### Evidence disposition

The one authorized invocation of exact launcher v6 performed a real QEMU/ARM/
runsc/native-KOReader run for approximately 31 seconds. Its retained evidence
supports the complete fixed-fixture functional claim. The launcher nevertheless
returned status 1 because the frozen host console checker mistakes Linux's
normal timestamp prefix on the final power-down line for a missing shutdown.

```text
READER_INTERACTION_QEMU_V6_FUNCTIONAL_RUNTIME_EVIDENCE_VERDICT=ACCEPTED
READER_INTERACTION_QEMU_V6_HOST_JOINED_DISPOSITION=FAILED_PENDING_NARROW_SHUTDOWN_CHECKER_FIX_REVIEW
```

The first verdict is deliberately scoped to this sandboxed, instrumented,
fixed-fixture reader demonstration. It is not a hostile-security result, a
durability or performance qualification, a physical-display observation, a
PineNote hardware result, or a shipping-product verdict. The second line
preserves the actual process disposition: no final joined PASS was emitted and
neither `HARVEST.txt` nor launcher status may be rewritten as success.

Before this appendix, this review hashed to:

```text
536b1421dfab4f61adfca7797dd0b18efec960c8edbed9c9b85ac5a3a3516def
```

The run retained the previously accepted tuple unchanged:

```text
launcher v6 SHA-256       38e84085e21030f7b0929dc2280b23552b6b96f55c54831c11366ebfe4c6156e
runtime manifest SHA-256  506605cfec38f32fe2a1bad426529d4e4816174df8a1a3c3ebf9407c66d389a6
harvester v5 SHA-256      462a20ad7eb8c9ce908645aa10a6da8cd6bdd054f852c90e51294dde73e27e51
```

This is distinct from the v5 attempt: v5 stopped at immutable-input preflight
before QEMU and ran no guest code; v6 crossed that gate, booted the accepted
image, ran both sandboxed books, completed the native reader lifecycle, and
powered QEMU down. The one-use v6 authorization is consumed and must not be
reused.

### Retained evidence integrity

The immutable evidence directory is mode 0500. All nine entries are regular,
mode-0400, single-link files:

```text
HARVEST.txt        2418  cc13872224a622d9e6fb2ededf3212cf7c7c58871f3d9f4d9c6a82ba22a6f77d
console.log       25849  6b67e290e473533446ee02582475b34c4021abd7629ef0f1922c47ef44605d56
coordinator.stderr    0  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
coordinator.stdout   72  d389cf6c983eb071374ad49a863285a3d5817e001d918c988511f512aad4f8a4
launcher.stderr   28117  fc94f3c8a7b419628a74fa8cfc28b81a19c901d323e308b49f482137ccdc80b8
launcher.stdout       0  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
qemu.stderr           0  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
qemu.stdout          61  fe1bf85f980f1eccc0ccd094cfab2cac34881adc00554f939c209118f187298c
reader.log        10419  e85264b8d9726ab83503d700e65b619d9f0c34d718f803e78231b5b6b465c8c2
```

`HARVEST.txt` accurately records `harvest-status=failed` and
`launcher-status=1`, plus `writer-completion=true`, zero adopted owned
children, zero unreaped children, launcher-pipe EOF, all six fixed runtime logs
retained with stable identities and exact hashes, and `run-root-removed=true`.
The production run base is empty. This closes publication and ownership for the
failed disposition; it does not convert the outer result to success.

### Actual execution and guest evidence

The console is an actual raw QEMU serial boot, not the earlier offline
preflight: Linux 7.1.8 reports AArch64, the reviewed image system and
`root=PNGuixRoot`; QEMU's private graph supplies the virtio-serial UI route;
and the guest reports the exact CONTROL `runsc` version and executable. QEMU's
captured stdout contains exactly one descriptor-hygiene execution marker and
its stderr is empty.

All thirteen required reader-protocol console markers occur exactly once and
in their prescribed order, from source provenance through Guile and Python
systrap completion, cgroup teardown, private-UI EOF, and final protocol PASS.
The four bounded `runsc-debug`/`runsc-panic` summaries have the required
language-relative ordering and are within their entry and byte limits. None of
the frozen checker's forbidden failure, host-test, replay/payload, overflow,
panic, BUG, or Oops fragments occurs.

The native process is the pinned packaged KOReader v2026.03 using its SDL
offscreen emulator backend at 600x800. Its log proves one fixture-plugin init,
one private-source registration, one public selection-action registration and
fixture invocation, one shown/topmost editable `InputDialog`, and four ordered
input/submit/scheduled-wait cycles. The four exact visible result strings are:

```text
GUILE[28]:ADA|NONCE=G-HJIZTUEJEO9GZJIF
GUILE[31]:ÉLAN Λ|NONCE=G-PXZEN3PVTJC9CTZI
PYTHON[30]:oycWqNaQevLuRssg-p=ecnon|ecarG
PYTHON[27]:JJclqSAZ8ME8O3Pk-p=ecnon|京東
```

Each appears first in one
`BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:` observation and then in one
matching `BOOK_INTERACTION_READER: present-painted-exact:` acknowledgement.
The four paint and acknowledgement lists are byte-for-byte equal and ordered.
For the Python results, reversing the visible values recovers the exact guest
inputs `Grace|nonce=p-gssRuLveQaNqWcyo` and
`東京|nonce=p-kP3O8EM8ZASqlcJJ`. The Guile values have the correct 28/31
character counts and exact Unicode uppercase transformations, including
`élan λ` to `ÉLAN Λ`; uppercase intentionally erases the original case of each
16-character random nonce token.

This is not a mock/replay acceptance. The frozen production authority creates
two nonce-bearing actions per language from libgcrypt's strong random source,
only after Lua submits the current dialog text. It donates a separate connected
Unix socket as FD 3 to each real runsc child. The fixed Guile and Python books
independently require the exact action identity, base text, sequence and nonce
shape and compute uppercase/reverse output. The guest authority then validates
the returned Book Session envelope and exact precomputed value, waits for the
native scheduled UI tick, and only then sends the presentation over the
separate private UI channel.

The production coordinator supplies no semantic/book input and no result
oracle. Its QEMU-mode KOReader environment omits
`BOOK_INTERACTION_EXPECTED_RESULT` and `BOOK_INTERACTION_UPDATE_INPUT`, and the
fixture rejects either variable if present. The audit wrapper calls the
inherited packaged `InputDialog:paintTo` first, then records the actual widget's
text and topmost identity. Thus these lines establish real packaged native-UI
paint semantics under the offscreen backend, not a substituted guest marker or
a host-computed replay.

After the fourth paint, the reader removed the selection action, removed its
one registered UI source, closed the donated control FD (verified as `EBADF`),
observed no stale callback, closed the dialog, reported exactly four painted
presentations and `result:ok`, and exited zero. The guest then observed private
UI EOF and emitted final protocol PASS. `coordinator.stdout` is exactly:

```text
BOOK_INTERACTION_QEMU_COORDINATOR: children=zero; reader-lifecycle=pass
```

Its stderr is empty. That line is emitted only after both QEMU and KOReader
have exited zero, both captures are finalized, the exact reader/QEMU logs pass
the coordinator's lifecycle checks, and both children are reaped.

### Sole host-checker failure

The console ends, after final guest PASS and orderly root remount/Shepherd
shutdown, with exactly one line:

```text
[   30.381268] reboot: Power down
```

The frozen host checker normalizes only a trailing carriage return and at line
141 calls its exact-whole-line matcher with bare `"reboot: Power down"`.
Consequently it observes zero matches and emits the sole final error:

```text
expected exactly one serial marker "reboot: Power down", observed 0
```

Independent read-only evaluation of the retained logs confirmed: the bare form
occurs zero times; the canonical timestamp-prefixed shutdown form occurs once;
it follows final protocol PASS; all required markers, ordering, bounded-store
predicates and forbidden-fragment checks otherwise pass. This is a host parser
defect, not evidence of failed guest shutdown.

Because the outer invokes the checker only after its guarded coordinator and
same-process-group descendants have exited zero, this late false negative made
the outer and launcher return 1. The joined success line is correctly absent,
launcher stdout is empty, and the harvester correctly published failure.

A permanent successor checker is not reviewed here. Once frozen, it should
change only shutdown recognition to one tightly anchored canonical
timestamp-prefixed form and regress both accepted and rejected console cases.
The retained immutable console is sufficient to validate that host-only
correction; this complete run provides no functional reason to consume another
QEMU authorization. Final joined acceptance remains conditional on that narrow
checker review.

No new QEMU, runsc, ARM/guest, KOReader/native-UI replay, image or Guix build,
mount, hardware, network, deployment, staging, implementation-source edit,
commit, push, or merge occurred in this evidence-attribution review.

## Frozen shutdown-checker correction — final offline closure

### Verdict

**Accept the frozen host-checker correction and its offline attribution of the
immutable v6 evidence.** The change recognizes the one canonical Linux printk
timestamp actually emitted before `reboot: Power down`, without relaxing any
guest protocol marker, bounded-store predicate, cardinality, or ordering rule.

```text
READER_INTERACTION_QEMU_V6_SHUTDOWN_CHECKER_VERDICT=ACCEPTED
READER_INTERACTION_QEMU_V6_FIXED_EVIDENCE_OFFLINE_GATE_VERDICT=ACCEPTED
READER_INTERACTION_QEMU_V6_DEMONSTRATION_SCOPE=FIXED_SANDBOXED_BOOKS_IN_REAL_PACKAGED_KOREADER_OFFSCREEN_UI
```

This closes the sole remaining functional-evidence gate. It does **not** alter
the historical run disposition: launcher v6 returned 1, `HARVEST.txt` remains
`failed`, launcher stdout contains no joined success line, and the one-use v6
authorization remains consumed. Acceptance here is a post-run semantic verdict
over immutable evidence, not a manufactured claim that the original outer
returned zero.

Before this appendix, this review hashed to:

```text
912cd3d960872afb050dcf37e7891d69f19c86a670b7845d7d12a782769d6bff
```

The final focused packet matches its stated identity:

```text
pinenote/tools/book-execution-spike/build/
reader-interaction-v6-shutdown-checker-review-packet-v1.txt
SHA-256 61777e51899373a4d9106cd057a46ac90deddfb414739c90d6cd487ec70990c6
```

### Exact source delta

The old checker remains preserved in runtime snapshot v6 at:

```text
reader-protocol-console-assertions.scm
SHA-256 d4de980e35a9385d6cdf1a0634b43f2ae3e84ef5a37cefcdbddd0d962b743927
```

The corrected active checker is:

```text
pinenote/tools/book-execution-spike/reader-protocol-console-assertions.scm
SHA-256 de1129e263a0be22b90086f93de2476880a3f61480383696f6bfedd857bea607
```

Their frozen diff hashes to:

```text
fe39995f39687da7038988355a99e8ffdaf8c5b5ddccc123590b1f1493a0679d
```

Direct inspection confirms that this is the only runtime-code change. It adds
one private timestamp regexp, one line predicate, and one shared cardinality
helper, then replaces the old exact-bare `one-line-index` call with that helper.
It does not change line normalization, required or forbidden markers, store
labels or limits, language ordering, final-PASS ordering, file bounds, or the
public checker interface.

The new accepted forms are exactly:

```text
reboot: Power down
[<canonical printk timestamp>] reboot: Power down
```

The anchored timestamp grammar requires:

- a literal opening and closing bracket;
- a seconds field containing either `0` or a non-zero-leading decimal;
- left-space padding such that seconds occupy width five until naturally wider;
- exactly one dot and exactly six fractional digits; and
- exactly one space followed by the exact payload `reboot: Power down`, with no
  prefix or suffix.

For the retained line, three spaces plus two seconds digits satisfy width five:

```text
[   30.381268] reboot: Power down
```

The helper collects both admitted forms into one index set and requires exactly
one total match. A bare plus timestamped duplicate therefore fails. The
existing `final-index < power-down-index` check remains unchanged, so an early
shutdown still fails. Arbitrary prefix stripping or global marker normalization
was not introduced.

### Focused adversarial tests

The test-only delta preserves all existing protocol, marker, bounded-store,
overflow and ordering cases and adds binding to immutable
`console.log` SHA-256 `6b67e290…`, a canonical synthetic positive, and shutdown
negatives. The corrected test source and diff are:

```text
test source  73df5ba0ea9f2b140e15f34200ceeac41228582d55ed57a53c4aac6adf6472aa
test diff    663b5817a073b27c42ec01f764db31b2b63e4db53190e9898dfab9f25d0e4a55
```

The supplied eight-test run exited zero:

```text
reader-interaction-v6-shutdown-checker-tests-v1.log
SHA-256 93a20f871aac7139b4dfcd92fcbfcfd2ce22ea62d15901522e6a987d656b50b3
```

It covers the actual immutable console, retained exact-bare compatibility, the
canonical timestamp, missing and duplicate shutdown, timestamped shutdown
before final PASS, wrong timestamp padding, a payload-like arbitrary prefix,
and suffixed garbage. Static inspection of the anchored regexp additionally
confirms rejection of leading-zero multi-digit seconds, missing or excess
padding, and fractional fields other than exactly six digits.

The original checker replay remains a useful control: it exited 1 with the
exact historical bare-line mismatch. Its log hashes to
`de0de6348a1190df6d729d716a4fd34b264abf01260e0a873a097f55419ef89f`.

### Offline replay and immutable run attribution

The fixed replay command hashes to:

```text
d5b87296aefe6733062fb21b34ee9ed4204a66430d4021be7168ec64735ad9c8
```

Inspection confirms that its checker entry imports the corrected module from
the same fixed tool directory. The command invokes only host Guile for the
console assertion and host Python for bounded evidence parsing. It contains no
QEMU, `qemu-img`, runsc, ARM/guest, or KOReader launch and writes nothing under
the evidence directory.

Before interpreting semantics, the replay binds the old and new checker, test,
wrapper, manifest and all retained logs to exact hashes; requires the evidence
directory/files to remain mode 0500/0400, regular and single-linked; requires
the six manifest records to be retained and stable across both harvest reads;
requires the original `harvest-status=failed`, `launcher-status=1`, complete
writer/pipe state, zero adopted/unreaped children and removed run root; and
requires the caller-owned mode-0700 production run base to remain empty.

It then verifies the exact coordinator and QEMU success lines, empty stderr,
the ordered native action/dialog lifecycle, all four matching
`InputDialog:paintTo`/presentation pairs and their guest-computed nonce
relations, cleanup, guest Guile/Python/cgroup/UI-EOF/final-PASS chain, and clean
power-down. It also requires the preserved wrapper to begin with both immutable
source preflight passes and end with the original launcher failure.

The supplied replay exited zero and produced:

```text
reader-interaction-v6-offline-semantic-replay-v1.log
SHA-256 687bb50e0dfebf52de9b4439eb61ced83f37e863c7f876b49c9e08dc83be4734

GUEST-READER-PROTOCOL-ASSERTIONS=PASS
READER-INTERACTION-V6-OFFLINE-SEMANTIC-REPLAY=PASS
```

The immutable evidence remains exactly as previously attributed:

```text
console.log        6b67e290e473533446ee02582475b34c4021abd7629ef0f1922c47ef44605d56
reader.log         e85264b8d9726ab83503d700e65b619d9f0c34d718f803e78231b5b6b465c8c2
coordinator.stdout d389cf6c983eb071374ad49a863285a3d5817e001d918c988511f512aad4f8a4
HARVEST.txt        cc13872224a622d9e6fb2ededf3212cf7c7c58871f3d9f4d9c6a82ba22a6f77d
wrapper            c72c6de4a016539247ef271ebf545decc6f57ed0dbec6abdd47c64c340c1e6fe
```

No image, guest, authority, coordinator, harvester, launcher, KOReader or Lua
re-review is needed: the accepted v6 functional evidence and four literal
painted results are reused unchanged. The machine replay does not consume the
human documentation. The separately updated `doc/book-computer-demo.md`
(SHA-256 `c56911df…`) accurately preserves the failed historical status, lists
the four actual values, identifies SDL offscreen operation, and explicitly
disclaims PNG/glass, arbitrary-book, hostile-book, durable-state, recovery and
shipping/hardware conclusions.

The resulting accepted claim is finite: two fixed books and four fixed actions
executed in real AArch64 QEMU/runsc and reached the real packaged KOReader
widget/paint path with the demonstrated cleanup chain. No broader product or
security claim follows.

No QEMU, runsc, ARM/guest, KOReader, checker/test/replay interpreter execution,
image or Guix build, mount, hardware, network, deployment, staging,
implementation-source or documentation edit outside this review appendix,
commit, push, or merge occurred in this final focused review.
