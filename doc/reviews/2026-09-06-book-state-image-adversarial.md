# Book State v6 image and two-boot payload — independent adversarial review

Date: 2026-09-06

## Verdict

**The exact realized image is accepted as a finite, inspected image artifact,
and its four boot-payload files are fixed below.  A production two-boot bundle
is not accepted and cannot yet be produced for the accepted v3 consumer.**

The image is the exact output of the previously accepted MODE-ONLY v6 source:

```text
image drv     /gnu/store/p6iwha5axl4s5yi2qb9l76x00cw9vqzg-disk-image.drv
image output  /gnu/store/9yx1xmhf2hnsp6vdwnvvxzqv3i9i9fkz-disk-image
SHA-256       53bee9f09d7b3a12ad5e9bf77f1dd91a1e2416be8ba205f06889becfd00de9d4
size          2063540224
```

Read-only/non-mounting inspection found no image defect.  The exact image,
actual image initrd, kernel, v6 source records, AArch64 language executables,
source-built gVisor release, mandatory state-volume service, and private
label-only QEMU baseline are internally consistent.

The stop is at the next gate, before `BUNDLE.scm`: accepted two-boot v3 has two
source-level ingestion blockers.

1. Its closed metadata schema can name only provisional `guest-v4-*` fields and
   cannot truthfully carry the distinct v6 packet, mode, accepted-review, image,
   and image-embedded-system identities.
2. Its shared fixed-file validator requires `nlink == 1` for source-pinned Guix
   store executables.  Every exact required executable on this host is a Guix
   store hard link, so the exact accepted module rejects QEMU before opening a
   VM.

I therefore did not invent a v6-under-v4 alias, issue a self-asserted review
field, or create a `BUNDLE.scm`/`MANIFEST.sha256` pair that the current consumer
cannot authenticate.  This report reviews an immutable four-file **payload**,
not a complete or runnable production bundle.  No QEMU, runsc, ARM, or KOReader
process was executed.

## Authorities and parent build record

The source and runner authorities remain:

```text
4c1df07a0dd1db655f5668975636bdf7aecc8fee3b755d26823be7b4c89cc4e5  accepted guest-v6 review
672c6c7d50e99e8d886b7ae93b94d803d2fc5922d702297770b4947924668b83  accepted two-boot-v3 review
5b801df014ccae882f410bf9deeefdbf8973c77f6c7932955108a9b2007e360b  guest-v6 packet manifest
deaca60eec261d7060120e44ba100443e720f71605ea9dac7e4b18539678f007  two-boot-v3 packet manifest
```

I authenticated both packets and the v6 author-evidence manifest before
inspecting the output.  The review packet retains complete byte copies of the
parent's `COMMAND.json`, `derive.stdout`, `derive.stderr`, `build.stdout`,
`build.stderr`, and `STATUS.json`.

The command record has the exact v6 capsule package/module views and channels,
private HOME/XDG/tmp/load/compiled-load/extension paths, empty `PATH`, target
`aarch64-linux-gnu`, `raw-with-offset`, `--no-grafts`, two occurrences of
`--no-substitutes` across time-machine and system image, `--max-jobs=1`, and
`--cores=2`.  It returned 0 after 24.937711464 seconds.  The log names 34
generated system/image derivations to be built and records each build,
including the actual image system and final image derivation.  I do not relabel
those 34 builds as cache hits; the expensive kernel and gVisor outputs were
already present and were not among them.

The reviewer ran no realization or package/image/system/kernel/gVisor build.
Private-environment Guix use was limited to references, requisites, derivers,
and recursive hashes.

## Raw image and filesystem

The image is **DOS/MBR, not GPT**.  This is the literal result and also the
shape expected by the accepted runner's baseline validator:

| Property | Value |
|---|---|
| partition count | one |
| bootable/type | yes / `0x83` Linux |
| start sector | 2048 |
| sector count | 4028304 |
| byte offset | 1048576 |
| partition bytes | 2062491648 |
| filesystem | ext4, 4096-byte blocks |
| source label | `Guix_image` |
| UUID | `35dc8ca2-ddfe-9918-e34a-02e035dc8ca2` |
| source partition SHA-256 | `fa27df3adefbb1bbcc7f7ad3b3fd015e1b9ee442925917729968c79e402a9c1f` |

The partition consumes every sector after the initial 1 MiB.  `e2fsck -fn`
returned 0 and reported a clean filesystem.  No mount, loop device, block
device, or privileged extraction was used.

An unprivileged `debugfs rdump` copied regular content but emitted expected
ownership-restoration warnings.  I retained all warnings and did not rely on
that copy for ownership claims.  Targeted `debugfs`, `blkid`, `dumpe2fs`, exact
file hashes, and host-store byte comparisons establish the accepted facts.

## The actual image system, initrd, config, and DTB

The source-review system derivation and the system actually generated inside
the image are distinct roles:

```text
source-gate system drv     /gnu/store/kjiz9wzqbdr9p1y3w0ni6qh8hzhqrkp0-system.drv
source-gate system output  /gnu/store/l1f4jxp3vvr253gdfrq0fy5h6xyb52j1-system (not realized)

image system drv           /gnu/store/bci0wwk51f6b3ib02l4fbal3bbkhvf9j-system.drv
image system output        /gnu/store/nbsyhyxj5qxarilr5qksa2gjk1hpbjrf-system
```

The parent build log names `bci0…` explicitly, the image extlinux file names
`nbsy…`, and Guix reports `bci0…` as its deriver.  This is the expected
image-specific UUID lowering, not evidence that the accepted `kjiz…` source
gate realized.  A future binding must name both roles rather than calling
`kjiz…` the image-embedded system.

The actual image members are:

| Role | SHA-256 |
|---|---|
| image `/boot/extlinux/extlinux.conf` | `626908bf82e9a0c0bef6b330079653581d2615275f98716e5ed3b7f5f40b9bdd` |
| actual image initrd | `e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad` |
| kernel `Image` | `5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9` |
| kernel `.config` | `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` |
| PineNote v1.2 DTB | `e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229` |

The extlinux hash and kernel-config hash are deliberately separate.  The boot
binding's config is extlinux configuration, not `.config`.

The actual initrd is
`/gnu/store/gs72…-raw-initrd/initrd.cpio.gz`, selected by the image extlinux
file and embedded system.  Its extracted init program contains the exact root
UUID bytevector decoding to `35dc8ca2-ddfe-9918-e34a-02e035dc8ca2`, matching
the filesystem.  The standalone source-gate initrd output is not realized and
was neither substituted nor used as a shortcut.  The DTB decodes as `Pine64
PineNote v1.2` with the expected PineNote/RK3566 compatibles.

The selected kernel retains `CONFIG_USER_NS=y`, `CONFIG_NAMESPACES=y`, all
PID/IPC/UTS/network namespaces, `CONFIG_SECCOMP=y`, and
`CONFIG_SECCOMP_FILTER=y`.  This only retains the accepted kernel source gate;
it is not ARM runtime evidence.

## Exact immutable boot payload

The reviewed payload is:

```text
/tmp/opencode/book-state-image-v6-independent-review-20260906/
  review-packet-v1/reviewed-boot-payload-v1/
```

It contains exactly four single-link, owner-read-only regular files under
non-writable directories, with no links or special entries:

```text
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  boot-bundle/extlinux/Image
f7ade895ca2b7f970d1532051ed55b72b7d9c8fe271629521d1181c9570951ed  boot-bundle/extlinux/extlinux.conf
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  boot-bundle/extlinux/initrd.cpio.gz
20c28d8d4a336308862c1a95d93aba7703115d5be71b640aa05138dcf65249db  rootfs.raw
```

`rootfs.raw` is the full MBR disk baseline despite its consumer-defined name.
It is a private copy of the exact image with only the ext4 label changed from
`Guix_image` to `PNGuixRoot`.  It retains the same size, MBR, partition table,
partition bounds, filesystem UUID, and content.  Independent byte comparison
found 97 changed bytes in 27 ranges, all in the primary and five backup ext4
superblocks.  The transformed partition hashes to `2807ebf8…`; its explicit
`e2fsck -fn` returned 0.

The payload config is the exact source APPEND token set with only the bounded
QEMU transforms: the root token is `root=LABEL=PNGuixRoot`, `console=tty0` is
removed, and the PineNote hardware console is replaced by
`console=ttyAMA0`.  It selects `nbsy…` for both `gnu.system` and `gnu.load`, has
no phase/oracle/user-data argument, and is accepted by v3's exact
`read-append-line` helper.  The accepted QEMU graph itself fixes `-nic none`.
The same four immutable payload files are intended for both fresh boots; only
the separately owned 64 MiB `WBBookStateV1` state image persists.

## Embedded guest provenance and runtime paths

The image embeds and authenticates the v5-byte/v6-mode source generation
without worktree fallback:

```text
8a86fa2a1e7b8b388ab2858580d279fae9afc42dcd166f64fce4c1030f52d221  v6 source manifest
2b99fcca343823eca6f5f665bfb7a5e053fed7eede1ce99501c99a9747d7a7e8  v6 snapshot manifest
9e5f4edc0b2c6babea1a576aa8f7c270136a2ceda6f650d64bde18a0d4308f3d  v6 capsule roster
c670be1bd7daf3cf468b67ac989485fa6929b630decee7e7d667a917bbb9c814  v5-to-v6 mode diff
c550804a12701d511f2a66afebe3415d67d8f918697ac04b8db38d42f4f2b91a  v6 author evidence manifest
```

The image's generated source manifest hashes to `62389f49…`.  I parsed its 34
source records and hashed every named file from the extracted image: all 34
match both the declared hash and exact host-store object.  This includes:

- authority `e1bc1c87…`, OCI successor `2585371b…`, and FD3 adapter
  `15f8ec5c…`;
- Guile/Python denial probes `0ff742d7…` / `2381b92d…`;
- unchanged Guile/Python books `b4d9fd9b…` / `e9b0cebd…`; and
- the embedded candidate source manifest `8a86fa2a…` itself.

The actual OCI source in the image still places each fixed probe immediately
before its unchanged book in one interpreter/process context.  Its mount list
has no state root/database/private-UI path, its network namespace is fixed, and
runsc receives only `--pass-fd=3:3`.  The actual generated service starts the
trusted Guile authority only after the mandatory state mount.  The generated
fstab requires label `WBBookStateV1`, ext4, and
`noatime,nodev,nosuid,noexec`; the trusted readiness service enforces root mode
0700 and sentinel mode 0600.  The authority database is not present in the
root image and is created per boot on the separate state volume.

The 45-path language-closure manifest is byte-exact at `48728ed9…`; all 45
unique paths are present in the image.  The exact Guile and Python guest
executables, Python `_sqlite3`, SQLite libraries, and five Go-built gVisor
members are ELF machine 183/AArch64.  Python `_sqlite3` has an explicit runpath
to permitted SQLite 3.39.3.  Trusted `guile-sqlite3` names the exact SQLite
3.53.1 library path.  This keeps book-visible SQLite software separate from
persistent-state authority.

The source-built gVisor output has recursive Guix hash
`06znixdbp8ak4g3psy058wfr1rdmpv42fb0yd3hah4fki8v5bdm8`.  All six exact
release members are present, executable, AArch64, and statically linked.  The
four versioned files carry `release-20260831.0`, the two deliberately
unversioned files do not, and all five Go-built members carry `go1.26.3`.
Their hashes are in `BINDING-PINS.txt`.  No old prebuilt/control/diagnostic
gVisor output is selected.  This accepts package/image identity only; source-
built runsc remains unexecuted.

I make no claim that every executable reference in the broader image closure
is AArch64: generated manifests intentionally retain native build references.
The executables the guest actually uses were checked individually.

The root image contains only GNU Unifont as a font output.  It contains
waveform installer/service code but no `ebc.wbf`, VCOM value, waveform blob,
preseeded Book State database, sentinel, Wi-Fi credential file, home data, or
root user profile.  `/var/guix/db/db.sqlite` is Guix's package database, not the
Book State authority database.

## Consumer blockers and exact minimum correction

### 1. The v3 schema cannot express this review

Exact v3 `bundle.scm` is `2ca5ae4c…`.  Its closed `metadata-fields` list and
record accessors require `guest-v4-*`; `image-binding.scm` is `9ca5a42a…` and
contains the same provisional vocabulary.  Updating only the latter would fail
the exact-alist gate.

The minimal metadata successor must version the schema once, rename the
provisional guest fields truthfully, and add distinct fields for the v6 packet
manifest, v6 accepted review, mode diff, image derivation/output/hash, and
image-embedded system derivation/output.  `BUNDLE.scm` and the source-pinned
binding must carry the same closed field set.  `binding-review-evidence-sha256`
must remain external to `BUNDLE.scm`; the reviewed evidence-manifest hash below
is the later binding input, avoiding a self-hash cycle.

### 2. Exact store executables fail the single-link check

The exact current module's `authenticated-executable` delegates to
`require-fixed-file`, which rejects links other than one.  Actual counts are:

- 2: QEMU, qemu-img, mke2fs, e2fsck, cp, sha256sum, Guile, Python, and runsc;
- 10: KOReader LuaJIT.

With private Guile load and cache paths, I called the exact private validator on
the exact pinned QEMU/hash.  It returned the expected
`book-state-two-boot-bundle-error`, status 17:

```text
QEMU is not an immutable single-link regular file
```

This is deterministic pre-QEMU rejection.  The minimal correction is to keep
the `nlink == 1` rule for caller-owned bundle files while giving source-pinned
canonical Guix-store executables a separate validator that retains exact path,
store-output, regular/non-writable/executable, and SHA-256 checks but permits
Guix store deduplication hard links.  This is a source change and needs its own
finite review.

Until both corrections pass review, production must remain unavailable.

## Sealed evidence

The independent packet is:

```text
/tmp/opencode/book-state-image-v6-independent-review-20260906/review-packet-v1
```

It has five directories, 98 regular files, no links or special entries, no
write bits, and no multi-link regular file.  Its 97-record external manifest
verifies in full:

```text
eef2ebd3d483d7204b0d663a7f569368327551a439ae2dc9dbe630870e53a7df  REVIEW-EVIDENCE.sha256
47395a7609930418f2ef40be8577e5daee811a01264bf7363ceb540b5dbaaa90  BINDING-PINS.txt
f68166e7952f33c2ce25295b1847b671ed77cd2b10ee8335d01778eba1c41b05  CONSUMER-BLOCKERS.txt
```

The manifest deliberately does not include this review document and the pins
deliberately do not claim the manifest's own hash.  This document can name the
already sealed external manifest without a cycle.  A later source-pinned
binding may use `eef2ebd3…` as independent image-review evidence, subject to
review of that binding successor.

Preserved reviewer setup records include the initial derivation-basename/output
confusion (`bci0…` is a derivation, `nbsy…` its output), unprivileged rdump
ownership warnings, one Python Scheme-list parsing mistake, two overly literal
generated-source checks, one f-string syntax error, and the first attempted
rename of an already read-only payload directory.  Each correction is bounded
and the accepted results are separate.

No source/frozen packet/implementation/observer/UI/protocol/architecture/image/
kernel patch was edited.  No staging, commit, push, fetch, merge, rebase,
networking, device access, mount, QEMU, runsc, ARM, or KOReader execution
occurred.

## Required next gate

1. Prepare a small two-boot source successor implementing only the closed v6
   metadata update and store-executable hard-link correction above.
2. Independently review that source before creating `BUNDLE.scm` and its exact
   five-record production manifest from the four payload bytes fixed here.
3. Pin `eef2ebd3…`, the resulting bundle-manifest hash, and every exact field in
   the new source binding; first prove host-only authentication.
4. Only after separate runtime authorization, run the two fresh ARM/gVisor
   boots and assess actual-child denial markers jointly with typed persistence,
   trusted UI, cleanup, termination, and A-to-B recovery evidence.

The image review does not close runtime BSG evidence or BTQ runtime acceptance.

---

# Book State V7 image and immutable two-boot payload — 2026-09-07 continuation

## V7 verdict

The complete V6 report above remains an unchanged 330-line prefix with SHA-256
`02a4d7adecf9dc36dbd696ea488d00500999cd95d8304a6e76472403281ffa4b`.

**Accept the exact V7 image and four-file payload as finite,
read-only-inspected immutable artifacts.  They are historical V7/reference
artifacts, not final-campaign binding inputs.  Do not infer runtime acceptance,
production availability, or fitness for the eventual two-boot campaign.**

The realized source image is:

```text
image drv     /gnu/store/z714ddhf80rndbx4iz3qs1ys3wwryy5i-disk-image.drv
drv SHA-256   e10b712203330c0b9699508661c266107dfad76ed5300ae404e812e30a5c8593
image output  /gnu/store/lsk489hgzszvym56m5pnsbrvf5malhiy-disk-image
SHA-256       7f38261ec047d5db9c0917ea73e42bfbe2d8475cfb90f276ceef799882770350
nar hash      09xl7cbcp171ssfk478fnqmivlflilbrl1ncmz1q8ggjx88gvjak
size          2063552512
mode/owner    0444 root:root (Guix-store nlink 2)
```

The parent build record names the accepted V7 capsule paths and exact flags
`--target=aarch64-linux-gnu --no-grafts --no-substitutes --max-jobs=1
--cores=2`.  `STATUS.json` records return code 0 and 18.83350063895341 seconds.
Its raw stderr is retained, including the `nonguix` and `saayix` untrusted-channel
warnings.  That is successful construction, not a claim of zero runtime errors
before a boot.

The accepted source identities remain:

```text
8d9eb000cdd51754a6983ea69d5d561eedf9f039473d41779725c9d43dfbb206  V7 packet
cb86ceec72ed59353e4ec75f88c292594b210de26074a98a35293c9ccef5e7ce  source manifest
dc068b4c04a9168c9d6f34f9dc1486ad2b0788f53d4906602de6dc9a99aa8c4e  source snapshot
c26f69012d1069bfbb9f5df8dbd610aa63a288e74fabfd325c9842b3d532de07  capsule roster
473142078efb0ec678edbec8b308ca95a75603d5e905ff50b754b1b49b6dd86f  V6-to-V7 delta
ee06d8be01eba8e970c9da59a273daae48d16c23cf0f26a75f8436cd54bc4065  source review
49bf1e84aeda168c97395a64cd754e796d1fc32eee1199957ee90f7da9af31cc  source-review evidence
ebcf06a909398a120c3be50f4f4c0040e91a181ad3e6ff665a0185a08e8e33b7  system source
d852a183608dacf5758e0424f1494522f93c57646b7b396ba80902ffbb240fdd  authority source
```

I did not repeat the complete V7 source review, kernel/package audit, or 77-case
host matrices.  This continuation authenticates their accepted identities and
examines the newly realized image delta.

## Actual image layout and image-generated system

The image remains one bootable DOS/MBR `0x83` partition at sector 2048.  V7 has
4,028,328 sectors, so its exact partition byte offset and size are 1,048,576 and
2,062,503,936.  The image ends at the partition end.  The source partition is
clean ext4:

```text
label                  Guix_image
UUID                   35dc8ca2-ddfe-9918-e34a-02e035dc8ca2
source partition hash  8e8f03b3d8c3c8457cbbf54907840af044116f7acdec914c30edccf530877d67
e2fsck -fn             0
```

Image lowering generated a distinct system from the accepted standalone source
gate.  These roles must not be aliased:

```text
source gate drv     /gnu/store/3s4gz8f6i8dkclwbknp2x4ww786wv19p-system.drv
source gate output  /gnu/store/i1ws95jfmvmkjcli5731i1h0ql0k1qn7-system (unrealized)
image system drv    /gnu/store/hz8364zq1rqwwnyqmvb10lyvgjq94rgn-system.drv
drv SHA-256          0a3d7e1e800567a595cb527412e6e9c3b4b40868ed02e6d236d066bcc8ddfc25
image system output /gnu/store/1kdfj3idqvvyshy8fyriv716hzd405cz-system
nar hash             05j4v05nc327vp2gkj85lbd7dkpfhgk2qqdiisyb5i2rh46x97hp
```

The actual source-image boot members are:

```text
d00914b9252adc129fd788046a2a028ee3215ac828e72ca3ac73cf9fc265aeab  /boot/extlinux/extlinux.conf
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  actual image initrd
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  kernel Image
0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309  kernel .config
e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229  PineNote v1.2 DTB
```

The initrd is the image-selected
`/gnu/store/gs72wkdw4x7f6hzfm2h2cqvmgqygsg67-raw-initrd/initrd.cpio.gz`, not the
unrealized standalone system's initrd.  Kernel `.config`, image extlinux config,
and prepared payload extlinux config are three separate identities.

## Finite V6-to-V7 filesystem delta

I extracted both exact partitions with `debugfs rdump`, without mounting or
using a block device, and inventoried regular-file hashes, symlink targets, and
modes without following links.  Directory size was deliberately normalized out
because the host filesystem, not ext4 source bytes, chooses an rdump directory's
`st_size`.

Both trees have 47,743 records: 6,614 directories, 34,497 regular files, 6,632
links, and no special entries.  Of 47,693 common paths, 47,690 records are
identical.  The three common-path changes are exactly the generated extlinux
config, Guix's own `/var/guix/db/db.sqlite`, and the system profile link.  There
are 50 V6-only and 50 V7-only records.  The replacement set is bounded to the
new system and `/etc` trees plus the generated authority/guest, manifests,
activation, Shepherd gate/config, boot, and extlinux outputs.  The unchanged
common records include the exact kernel, initrd, source-built gVisor package,
45-path language closure, native book/SQLite sources, and all other retained
image files.  This is a finite file identity comparison, not a new broad ELF or
runtime-closure claim.

The image contains the accepted V7 authority at hash `d852a183…`.  Its generated
guest program hashes to `ec826160…`; replacing only the V6 authority store path
and expected hash in the V6 generated program reproduces the V7 program exactly.
The in-image compiled Shepherd gate selects that V7 generated program and does
not contain the V6 guest path; the root Shepherd configuration selects the V7
gate.  Thus this is the functional finalized-capture image, not the old guest
with new descriptive metadata.

Focused source inspection confirms that the installed authority reads the
finalized owned `runsc.stdout` through the reviewed stable-FD path, validates
the captured marker, and emits the attribution followed by `captured-marker`.
The publisher does not emit the expected comparison constant.  These are static
image facts already accepted at source; actual gVisor denial and publication
remain runtime claims.

## Mandatory state profile and SQLite roles

The installed fstab requires `LABEL=WBBookStateV1` at
`/var/lib/wilkbook-book-state-demo` as ext4 with
`noatime,nodev,nosuid,noexec`.  The accepted system source sets
`mount-may-fail? #f`, filesystem checking, the volume-ready dependency, private
mode `0700`, sentinel mode `0600`, no respawn, private `HOME`, and fixed Guile
paths.  Installed profile links select the V7 build/source manifests, the exact
45-path language profile, and the trusted supervisor profile.

No `book-state-v1.sqlite` or `.sandbox-boundary-sentinel-v1` is preseeded in the
root image.  That absence is an image-content fact only; it is not the native
book's gVisor visibility/denial test.  Trusted Guile remains the persistence
authority using SQLite 3.53.1.  SQLite 3.39.3 remains present in the exact
45-path book closure as a permitted non-authority component.

## New immutable four-file payload

The reviewed payload is:

```text
/tmp/opencode/book-state-image-v7-independent-review-20260907/
  review-packet-v2/reviewed-boot-payload-v2/
```

Its exact manifest is the file `evidence/PAYLOAD.sha256`, not `STATUS.json`:

```text
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  boot-bundle/extlinux/Image
fc3d2a3352f25985065fadae56e86a62218a66a7f608cb6f0ad31f32e161254f  boot-bundle/extlinux/extlinux.conf
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  boot-bundle/extlinux/initrd.cpio.gz
3bdf7513f40fcf3c37fc3647cedf9fc6f70722960cb4a962ea2086a62b8b117b  rootfs.raw
```

```text
ce98c3c0bf70c4f1a2fbdd001648d19f35896eed425d36029eac9578b34a150f  evidence/PAYLOAD.sha256
86213ee383b538a98a1f2aef07fba4c1294b3563ce42f2849d4ed1495ab22851  evidence/STATUS.json
```

All four payload members are single-link regular files at mode `0400`; their
three directories are mode `0500`; no link, special entry, multi-link file, or
write bit exists.  `rootfs.raw` remains a full MBR disk despite its historical
consumer-defined name.  The source Guix-store raw image remains unchanged and
immutable; the payload is a separate owned copy.

The root copy applies only `tune2fs -L PNGuixRoot` to an extracted owned
partition and writes that partition back at byte 1,048,576.  The measured
full-disk delta is 97 bytes in 27 ranges, all inside the primary/backup ext4
superblock label/checksum metadata.  `dumpe2fs` differs in volume label and the
expected last-write timestamp; file content and the UUID are unchanged.  The
prepared partition is clean and hashes to:

```text
5df01dfa568f5ea9748d0b35f4cbcfadf44dcb407ea32bc37b768a26e53bb138
```

The prepared extlinux entry selects the actual image-generated system, changes
the hardware consoles to `console=ttyAMA0`, and uses
`root=LABEL=PNGuixRoot`.  It carries no phase, oracle, expected-user-data, or
mutable-input argument.  The same immutable four-file baseline is intended for
both fresh boots.

## Consumer handoff and remaining stop

No `BUNDLE.scm` or five-record production `MANIFEST.sha256` is issued here.  The
V5 checker review closed the missing-marker and `PAYLOAD.sha256`-role defects,
but rejected the final join because a balanced cross-boot swap of one language's
attribution-plus-marker pair still passed fully sealed evidence.  That later
finding is outside this image inspection and does not change any V7 artifact
hash; it does mean V7 must not be promoted into an available final-campaign
binding.

The assigned narrow successor adds the actual book-owned operation ID and
result version to trusted capture attribution, then binds them to the preceding
same-language saved record and phase in the checker.  Those future V8
producer/checker bytes and artifacts do not exist in this review and must be
jointly reviewed before a new image realization.  The currently visible bundle
validator also still hard-codes V6's 2,063,540,224-byte image,
4,028,304-sector partition, and 2,062,491,648-byte partition size, so it cannot
truthfully accept V7 either.

This packet records `evidence/PAYLOAD.sha256` / `ce98c3c0…` and the distinct
`STATUS.json` / `86213ee3…` only to authenticate the V7 historical artifact and
prevent future role confusion.  A V8 review may use V7 as its immutable delta
baseline, but must issue new image, payload, external-review, checker, binding,
and production-bundle identities rather than relabel these values.

The image and payload establish no actual ARM, QEMU, runsc, KOReader, boundary
denial, typed persistence, private UI, cleanup, QEMU termination, shutdown,
unmount, or power-loss durability result.  Source-built gVisor remains an exact
image/package input whose runtime is unproven.

One direct `debugfs -o` setup attempt comprised four commands; this installed
`debugfs` lacks that offset option, so all four stopped at option parsing before
opening a filesystem.  The review retained that failure and used the accepted
owned-partition extraction procedure.  A focused Python audit draft later
stopped on one over-literal accessor spelling; its output is retained separately
and the corrected static audit passed.  Unprivileged `debugfs dump -p` emitted
ownership-preservation warnings while producing correct selected bytes; exact
in-image ownership/modes were checked separately with `debugfs stat`.

No guest, kernel, image, protocol, observer, UI, architecture, frozen packet,
outer checker, binding, or two-boot implementation was edited.  No reviewer
build or realization, mount, block device, QEMU, runsc, ARM, KOReader, network,
device, SSH, staging, commit, or publication action occurred.

---

# Book State V8 image and immutable two-boot payload — 2026-09-07 continuation

## V8 verdict

The complete V6/V7 report above remains an unchanged 563-line prefix with
SHA-256 `e6e8f415d5925e7d6b6a03be783f1d0afdb1dc0b0dc3283264d10d2c22b756bb`.

**Accept the exact V8 image and new four-file prepared payload as finite,
read-only-inspected immutable artifacts for a separately reviewed exact final
binding successor and, after that binding is accepted and runtime is separately
authorized, the future two-fresh-boot campaign.  This is artifact acceptance,
not runtime acceptance or current production availability.**

The realized source image is:

```text
image drv     /gnu/store/iaw5idj7sbwcvv74fcal8i5nx7x3vvhq-disk-image.drv
drv SHA-256   b01e21a93b1826276754b2a762fc482ed9ec3555fc9eddfac9b4f7f4c1b5ff16
image output  /gnu/store/rj1a6k042gcchcmcsb8pli426b83w34g-disk-image
SHA-256       2a492559aece65eb92832bf836b6b90751f5475101db3642a174c058e5ffa366
nar hash      0gllmz389jg99bxws1g3ch5pkxl34z2nydjhy9zf5dlkbkf1nb3h
size          2063556608
mode/owner    0444 root:root (Guix-store nlink 2)
```

The six-file parent record authenticates the frozen V8 capsule system and exact
`--target=aarch64-linux-gnu --no-grafts --no-substitutes --max-jobs=1
--cores=2` build.  `STATUS.json` records return code 0 and
18.8807849669829 seconds.  Its two untrusted-channel warnings are retained.
That is a successful construction record, not evidence from a boot.

The independently accepted joint source identities are:

```text
e223e4232376795416beca9d598c771307515a34f068e93026f31fd02891f5a2  V8 packet
3cef458b490637ab03d0abb2bc1e7fa22e292e6f68a7961a91c3bff19bf71444  source manifest
95d9b5878a9232c586e59d7f6887ff9c1216543692c1c6f1d818e6057551a56c  source snapshot
fe12fb85efff2dd3be0d820f43a39287dc100270592b67cb7a6c07f60e5daac8  capsule roster
b2695e27c844e93da121f90f1346a645b913b24d976e3ea7f0cb8348f8263696  V7-to-V8 delta
f8a30641076d5e10fe4e49d5ee0f2fecf0da82450f5ac90d7137fcbdbb7037fb  authority source
10578fb0ea715416b3d23640c7d6046fe8dc03fd7e7d09cc3ba942f34fa25098  system source
a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19  joint source review
b93e51dafb17cc4792c77b7c1317b4dad6fffa9c54db93d7e873603f8130dd02  joint-review evidence
```

The frozen V6 consumer packet remains exact at source manifest `4bac69a4…`,
runtime manifest `998c1bc4…`, checker `6cd97897…`, bundle consumer `664407a0…`,
and unavailable image binding `63d96c26…`.  I verified its sealed packet and
joint-review evidence but did not repeat the accepted producer/checker matrices.

## Actual V8 image, partition, and boot identities

The image is one bootable DOS/MBR `0x83` partition at sector 2,048.  Its exact
layout is:

```text
partition sectors      4028336
partition byte offset  1048576
partition byte size    2062508032
source label           Guix_image
filesystem UUID        35dc8ca2-ddfe-9918-e34a-02e035dc8ca2
partition SHA-256      7b8df74b15ffc02e41c7ef790cca6758cb85fd930c22720748019bc88ada5684
e2fsck -fn             0
```

V8 is exactly one 4,096-byte ext4 block/eight sectors larger than V7; the full
image is also 4,096 bytes larger.  The source image remained immutable.

Image lowering again generated a distinct system from the standalone source
gate.  Their identities and roles are:

```text
source gate drv       /gnu/store/35bsagzm09wjrn18my3jh61am624phlq-system.drv
drv SHA-256           10c639fdd9bd9cb863a68327fea994e66dac5b65f8d8e3c442ebabea5a816558
source gate output    /gnu/store/v536sbh5v4gfngx5yv5k4w3fv6ihh5vc-system (unrealized)
image system drv      /gnu/store/911rbkh4ba70jfbsp443mx1slncarqpx-system.drv
drv SHA-256           693357ca5b8ca43ffc6a2d5e562066c11a32eb18efcc11b162a7a9395e50979a
image system output   /gnu/store/9rkms12jnb68h83la5w9j4w77mxl4i3y-system
nar hash              0wazbkdn5wkx9mf20vn2indhg76ccc7zqjajciwv74sk1b8j45mq
```

Actual source-image boot members, selected by the image's own extlinux and
image-generated system, are:

```text
be37cd21328659ca2f04759f8b1bff40f01b4cffa7dce717a7d3671f13018c96  image extlinux
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  image initrd
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  kernel Image
0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309  kernel .config
e0530087f39abdfa771a0b94a08547fcfe6aebe692fe619848d41fb84d862229  PineNote v1.2 DTB
```

The initrd is still the exact image-selected
`/gnu/store/gs72wkdw4x7f6hzfm2h2cqvmgqygsg67-raw-initrd/initrd.cpio.gz`.
Image extlinux, payload extlinux, kernel `.config`, standalone source-gate
system, and image-generated system remain distinct identities.

## Finite V7-to-V8 image delta and functional selection

I used the accepted non-mounting owned-partition plus `debugfs rdump` procedure
and compared regular-file hashes, symlink targets, and modes without following
links.  V7 and V8 each have 47,743 records: 6,614 directories, 34,497 regular
files, 6,632 links, and no special entries.  Of 47,693 common paths, 47,690 are
identical.  The three changed common records are `/boot/extlinux/extlinux.conf`,
Guix's own `/var/guix/db/db.sqlite`, and `/var/guix/profiles/system-1-link`.
There are exactly 50 V7-only and 50 V8-only records.

The 50-for-50 set is confined to generated authority/guest, source/build
manifests, Shepherd source/compiled gate/config, `/etc`, activation, boot,
extlinux, and image-system outputs.  Kernel Image/config/DTB, actual initrd,
source-built runsc (`c6f9a31f…`), 45-path language closure (`48728ed9…`), and
all other common records are unchanged.  This is a finite artifact comparison,
not another broad kernel/package or foreign-ELF audit.

The image installs the accepted V8 authority byte-for-byte at `f8a30641…`, its
complete frozen source manifest at `3cef458b…`, and a generated guest at
`f6a7cba1…`.  Replacing only the V7 authority store path and expected digest in
the V7 generated guest reproduces the V8 guest exactly.  Replacing only that
guest path and the generated gate-source path reproduces the V8 compiled gate
`4f1850fb…`; replacing only the compiled-gate path reproduces root Shepherd
config `5844ec00…`.  Thus the selected service is V8, not V7 behind new metadata.

The generated source manifest is exactly the V7 manifest after four declared
substitutions: successor role, candidate-manifest path, authority path, and
authority hash.  The generated build manifest is exactly V7 after selecting
that source manifest and adding only the accepted
`operation,resulting-state-version` save binding and
`read-version,no-new-commit` stable-B declaration.  Static inspection confirms
the installed V8 authority derives attribution from the same completed typed
book result, publishes it before the unchanged captured marker, and retains the
separate stable-B read-only grammar.  Actual publication and denial remain
runtime claims.

The exact mandatory `WBBookStateV1` fstab/profile/system wiring remains in the
image.  No `book-state-v1.sqlite` or `.sandbox-boundary-sentinel-v1` is
preseeded.  As before, absence is only an image-content fact, not sandbox-denial
evidence.

## Immutable V8 four-file payload

The new payload is:

```text
/tmp/opencode/book-state-image-v8-independent-review-20260907/
  review-packet-v1/reviewed-boot-payload-v1/
```

Its authority is `evidence/PAYLOAD.sha256`:

```text
5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9  boot-bundle/extlinux/Image
185b41ffcc4209ba517a58ebcc1f6e7f78095e7f7a18343f7163ca0d9f874e34  boot-bundle/extlinux/extlinux.conf
e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad  boot-bundle/extlinux/initrd.cpio.gz
14abe02a4aeb08bb2e0306b23ca2f326fd5b9893a53939a431137af93d877c46  rootfs.raw
```

```text
c26dfa9416c438a59a6fe697773d5325cca863a171e2a6537e9fa93bec2491bc  evidence/PAYLOAD.sha256
f1550fb51c481221fdd186b04fb2f12c4ee36eb611ce93d1b2074e398c5ac67d  evidence/STATUS.json
```

These roles are deliberately distinct: `PAYLOAD.sha256` authenticates the four
payload files; `STATUS.json` only records the parent's build exit and elapsed
time and must never be used as payload authority.

The source store image was copied to a separate single-link full-MBR regular
file.  On a separate owned partition copy, `tune2fs -L PNGuixRoot` produced the
current measured 97 changed bytes across 27 primary/backup ext4 metadata ranges;
the checked prepared partition hashes to
`88287db6b5056fea365733906ab6cd0aac6b3ad5ecbf38f5a11161dd68668d5a`.
Its UUID is unchanged and `e2fsck -fn` returns 0.  The prepared partition was
written back at byte 1,048,576, and an exact range comparison proves that the
full payload carries those same 2,062,508,032 checked partition bytes.

The payload extlinux changes only the two hardware consoles and UUID root token
to `console=ttyAMA0` and `root=LABEL=PNGuixRoot`, while retaining the actual V8
image-generated system and initrd.  It carries no phase, oracle, expected data,
book operation, result version, or other caller campaign argument.  The same
four immutable baseline files are for both fresh boots.

## Binding handoff and precise current blocker

No `BUNDLE.scm` or outer `MANIFEST.sha256` is issued by this review.  Frozen V6
consumer `modules/two-boot/bundle.scm` still hard-codes V6's 2,063,540,224-byte
image, 4,028,304-sector partition, and 2,062,491,648-byte partition.  Truthful
V8 values are 2,063,556,608, 4,028,336, and 2,062,508,032 respectively, so the
accepted authenticator must reject a truthful V8 data bundle before comparing
the remaining metadata.  Issuing an unaccepted or knowingly rejected bundle
would not create authority.

The sealed review packet therefore supplies a complete role-named V8 binding
parameter table, but not a self-declared binding review, caller-controlled hash,
production bundle, or bundle manifest.  A narrow metadata-only source successor
must update those three layout constants, replace the existing unavailable
sentinels with the exact values from this independent inspection, pin this
external image-review document, and be independently accepted before the final
bundle envelope is made.  The bundle-manifest digest can then be pinned by a
subsequent reviewed source binding without making a file authenticate itself.

The exact V8 artifacts are fit inputs to that successor.  They establish no
actual ARM, QEMU, runsc, KOReader, sandbox denial, typed persistence, trusted UI,
cleanup, termination, shutdown/unmount, A-to-B recovery, or power-loss result.
Source-built gVisor remains an exact unchanged image input whose runtime is
unproven.

Preserved setup failures are limited to two manifest checks started from the
wrong working directory, an attempted edit of an owned copy that had retained
mode `0400`, one absent `/run/current-system` probe, and the first write into an
owned full-image copy before changing its inherited `0444` mode.  Corrected
checks are retained separately; none changed a frozen packet or store input.
Unprivileged `debugfs dump -p`/`rdump` ownership-preservation warnings are also
retained, with exact image modes checked separately.

No guest, kernel, image, protocol, observer, UI, architecture, frozen packet,
outer checker, binding, or two-boot implementation was edited.  No reviewer
build or realization, mount, block device, QEMU, runsc, ARM, KOReader, network,
device, SSH, staging, commit, or publication action occurred.
