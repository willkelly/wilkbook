# Book State QEMU volume helper contract

This host-only unit implements the ownership and exact QEMU graph seam from
`doc/reviews/2026-09-06-book-state-qemu-seam-design.md`. It does not implement a
reader, state backend, protocol adapter, operating system, image, or QEMU run.

## Ownership

`call-with-new-state-volume-lease` accepts two existing caller-owned mode-0700
directories below `/tmp/opencode`: a campaign base and a non-overlapping
ephemeral-run base. It creates exactly one mode-0700 campaign directory, one
mode-0600 empty `owner.lock`, and one mode-0600 64 MiB
`book-state.ext4`. The filesystem label is exactly `WBBookStateV1`.
Every U+0000–U+001F control is rejected in a supplied path before a campaign
root is created. Newly exclusive regular-file descriptors are explicitly
`fchmod`ed and verified, so these modes do not depend on the caller's `umask`.
The fresh randomized campaign directory is captured as a caller-owned inode,
then changed to and verified as mode 0700 before use.

The caller supplies absolute, canonical executable paths for `mke2fs` and
`e2fsck`; an eventual Guix launcher must supply the paths from one pinned
`e2fsprogs` package. Creation uses a unit-owned fixed `mke2fs.conf`. The image
operand is `/proc/self/fd/N` for the already-created `O_EXCL|O_NOFOLLOW` regular
file, so neither tool can be redirected to a block device or foreign pathname.
The filesystem gets a random ext4 UUID; this helper does not invent a generic
device identity.

The reference records device/inode, owner, mode, link count, size, and type for
both files and all three directories. Reopening, graph generation, validation,
and cleanup fail if those identities or the exact two-entry campaign inventory
change. There is no PID file and no stale-PID authority.

The supervisor holds a nonblocking kernel `fcntl` write lock on `owner.lock`
for the complete two-boot campaign. A second process is refused. Kernel process
death releases the lock; reopening still requires every recorded identity, so
lock release cannot bless a replaced root or image.

Because POSIX `F_SETLK` ownership is process-wide rather than descriptor- or
thread-wide, a synchronized process registry rejects a second lease handle for
the same lock inode before another `F_SETLK`/close sequence can disturb the
first. This registry complements rather than replaces the kernel lock: the
registry handles threads/handles in one process; `F_SETLK` handles other
processes, and both are released on owner-process death. A fork detects its new
PID and clears the inherited memory copy before acquisition, so a child still
tests the parent's real kernel lock rather than a stale process-local entry.

## Writer lifetime

Each QEMU boot starts in a synchronous callback of
`call-with-state-volume-writer-window`, nested inside the one campaign lease.
A lease-private mutex atomically admits one writer token; a nested or concurrent
caller gets an immediate `writer-active` error rather than waiting for the
QEMU-length callback. The writer owns an exact
`O_RDWR|O_NOFOLLOW|O_CLOEXEC` descriptor whose `fstat` matches the retained
image identity.

The writer callback must then enter `call-with-state-volume-qemu-handoff`.
That scope duplicates only the image descriptor, verifies the copy, and makes
the copy inheritable. Only its opaque handoff token can mint the QEMU graph.
The callback must invoke the existing accepted blocking process guardian,
preserve that explicit descriptor through QEMU exec, and return only after its
QEMU process group has closed and been reaped. The helper revalidates the
descriptor and owned pathname before closing the handoff. Boot 2 starts in a
second writer/handoff scope after boot 1 returns.

This unit deliberately does not duplicate the accepted process guardian. It
has not executed QEMU and therefore cannot prove that the future outer preserves
the handoff descriptor, that QEMU opens it, or that the caller obeys the join
rule. Those remain integration-review obligations.
If the parent dies, its existing guardian must terminate/reap the owned QEMU
group before any later campaign reopen. QEMU additionally receives
`locking=on` on the image file node and must independently refuse concurrent
image writers.

## Exact graph delta

The accepted reader graph must end with exactly one:

```text
virtio-blk-pci,drive=rootfs-overlay
```

Inside a QEMU handoff scope, `leased-state-volume-qemu-arguments` independently
reconstructs the accepted reader graph and appends only:

```text
-blockdev
{"driver":"file","filename":"/proc/self/fd/N","node-name":"book-state-file","read-only":false,"locking":"on"}
-blockdev
{"driver":"raw","file":"book-state-file","node-name":"book-state","read-only":false}
-device
virtio-blk-pci,drive=book-state,id=book-state-disk,serial=WBBOOKSTATEV1
```

`N` is the scoped inheritable descriptor for the already-open retained inode;
the mutable campaign pathname never enters JSON. The checker independently
reconstructs and compares the entire resulting vector. It does not accept a
caller-provided base as both candidate and oracle. The accepted base's flat
blockdev objects are parsed with complete JSON string escape handling,
duplicate-key rejection, and structural node/device collision checks. The raw
node suppresses format probing; the writable device is not a snapshot.

## Guest constants and boundary

The future non-shipping system must translate `state-volume-mount-contract`
literally:

- label `WBBookStateV1`;
- mandatory ext4 mount at `/var/lib/wilkbook-book-state-demo`;
- options `noatime,nodev,nosuid,noexec`;
- database path
  `/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite`;
- trusted guest Guile owns the path; sandboxes never see it;
- the backend service requires the exact mount service before opening state.

This helper proves private image creation, retention, identity, lease exclusion,
and conservative deletion. Reusing the same image identity through two fake
writer lifetimes is **not** semantic Book State persistence. That later claim
requires two fresh real guest supervisors: boot 1 must commit version/text via
the backend and native UI, and boot 2 must reopen the host-owned namespace and
paint the recovered version/text without argv, environment, or fixture-value
injection.

## Deferred integration hooks

After the backend and typed-JSON contracts are independently accepted, a new
successor runner—not this helper—should:

1. enter one `call-with-new-state-volume-lease` callback;
2. enter writer window 1 and its handoff scope, let this unit independently
   reconstruct the accepted reader vector and append the descriptor-bound
   graph, then synchronously invoke the existing one-boot guardian;
3. require that guardian's closed/reaped result and an empty ephemeral-run base;
4. repeat with writer window 2 and a fresh accepted run root/root overlay;
5. join backend version/text and real native-UI evidence; and
6. clean the campaign only after the joined checker succeeds.

The OS successor translates the mount constants and starts the trusted backend
after the exact file-system service. The backend receives only
`state-volume-database-path`; the accepted sandbox profile, donated descriptors,
CONTROL runtime, UI channel, kernel, and root graph remain unchanged. Wiring
those hooks will require new successor runner/system sources and review of the
actual QEMU image-lock behavior. It requires no modification to this ownership
module and no new generic disk, mount, or host-share input.

## Cleanup

`cleanup-state-volume-campaign!` atomically claims the same process-local
operation state as a writer, so cooperating API calls cannot overlap cleanup.
It validates the full inventory, creates one private sibling quarantine, and
uses Linux `renameat2(RENAME_EXCHANGE)` to swap the campaign root with a known
empty sentinel without overwriting either side. It validates the moved root and
every file identity before the first unlink. A substitution at that boundary is
exchanged back when the two directory identities still permit an unambiguous
rollback; foreign bytes, the retained object, and the diagnostic quarantine are
preserved.

The ownership guarantee covers this serialized API and the one cooperating
outer while it holds `owner.lock`. Linux has no “unlink this inode if still at
this name” operation. An uncooperative or privileged same-UID process that
continues mutating names *inside the randomized mode-0700 quarantine after the
successful exchange and validation* can still race the final path unlinks.
This unit does not claim hostile same-UID race safety. Such mutation is outside
the fixed test-owner model; if it is in scope later, cleanup must move to a
separately reviewed privileged/isolated owner rather than broadening this small
helper.

Any ordinary unknown entry, symlink, replaced identity, changed root/base, or
active writer causes refusal and preservation. A failed campaign is left for
diagnosis; production code never recursively removes it or follows a symlink.

## Host check

Pass all executable paths explicitly; the test never searches `PATH` for
filesystem tools:

```sh
guile --no-auto-compile \
  -L pinenote/tools/book-execution-spike \
  -L pinenote/tools/book-state-qemu \
  pinenote/tools/book-state-qemu/test-book-state-qemu.scm \
  /gnu/store/…-e2fsprogs-1.47.2/sbin/mke2fs \
  /gnu/store/…-e2fsprogs-1.47.2/sbin/e2fsck
```

The bounded suite creates three 64 MiB sparse images sequentially below a fresh
mode-0700 `/tmp/opencode/book-state-qemu-test.*` root. On success it removes
only the exact test-owned campaigns, run roots, bases, and top directory. It
does not mount an image or start QEMU, runsc, ARM code, KOReader, a network, or
a build.

## v3 finite host hardening

The corrected-v2 registry mutex is superseded by one PID-tagged atomic CAS
state. Registry authority acquires no process-local mutex, so a post-fork child
cannot wait on synchronization formerly owned by a vanished sibling thread.
The child atomically replaces only its private PID-mismatched registry snapshot
before considering any inherited key. This does not alter the parent's registry
or inherit lease authority: the child must still acquire `owner.lock`, so a
live parent is reported as `already-leased` by the kernel lock.

Every live handoff is compared with the private CLOEXEC writer anchor using
Linux `kcmp(getpid(), getpid(), KCMP_FILE, writer-fd, handoff-fd)`. Device/inode
equality is still required but is no longer sufficient. A `dup` of the anchor
is accepted as the same open file description; closing the public descriptor
and reopening even the same inode is rejected. This host helper has reviewed
syscall numbers only for x86-64 (312) and AArch64 (272), with `KCMP_FILE=0`.
Unknown architectures, unavailable syscalls, or policy-denied comparisons fail
with `ofd-comparison-unavailable`; there is no inode-only fallback. The private
anchor remains CLOEXEC and is not added to the future QEMU allowlist.

The finite flat-JSON grammar distinguishes the empty-object state from the
member-required state after a comma. Empty objects and valid escaped strings
remain accepted, while trailing, leading, and doubled commas are rejected.
Run `test-book-state-qemu-v3.scm` with the same load paths and explicit
`mke2fs`/`e2fsck` arguments shown above; it contains the bounded locked-mutex
fork, exact-open-file-description, token-revocation, and strict-JSON cases.
These are host-source guarantees only. Actual QEMU descriptor inheritance,
QEMU `locking=on`, guardian joining, guest storage, and semantic Book State
persistence remain unproven integration gates.
