# Book State paused-QEMU guardian integration

This directory is the finite successor-integration candidate for the accepted
Book State volume-helper v3. It owns no production runner or OS source. It does
not modify the accepted volume helper, state graph, reader graph, disposable
outer, immutable v6 packets, backend, protocol, reader, or system modules.

## Exact parent sources

The candidate depends on these unchanged source identities:

| Source | SHA-256 |
|---|---|
| `pinenote/tools/book-execution-spike/disposable-qemu.scm` | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| `pinenote/tools/book-execution-spike/reader-qemu-graph.scm` | `16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002` |
| `pinenote/tools/book-state-qemu/book-state-qemu/state-volume.scm` | `79324bbb80ba8eb9e57c4d8285b0d6f4f76020bfb1016d0e8c22fe8526b42d29` |
| `pinenote/tools/book-state-qemu/book-state-qemu/qemu-graph.scm` | `708ccca8fe367a20ef886168bed524704a5cdd0a97acf5f0609eecd822ad977c` |

`candidate/disposable-qemu.scm` is a private copy of the first source with only
three optional hooks added to its existing guardian path:

1. an exec-child callback after the deny-all `FD_CLOEXEC` sweep;
2. observation of the exact process-guardian PID; and
3. observation of the exact direct-child PID reported by that guardian.

The subreaper, owner-liveness pipes, PGID setup, TERM-to-KILL escalation,
reaping, and run-root guardian are otherwise the accepted implementation. The
candidate remains private here until independent review decides whether those
hooks are suitable for a later successor outer.

`successor-state-guardian.scm` constructs the one permitted exec callback from
an active opaque v3 handoff. The frozen helper first validates the handoff with
same-process `KCMP_FILE`. After the accepted deny-all sweep, the exec child again
requires the handoff FD and private writer anchor to be the same open file
description and the retained regular-file identity. It then clears `CLOEXEC` on
only the handoff duplicate and requires that it be the only descriptor above
stderr that will survive exec. The private anchor and campaign lease remain
`CLOEXEC`.

`successor-reader-graph.scm` starts with the complete frozen state-reader graph,
requires its independent exact-vector assertion, and appends only test controls:

```text
-S -qmp unix:<exact-run-root>/qmp.sock,server=on,wait=off
```

The QMP endpoint is a private Unix socket. There is no TCP listener, NIC,
host share, monitor, mount, or sandbox-visible state path.

## Bounded runtime gate

`run-guardian-integration.scm` refuses root, creates one private 64 MiB ext4
regular file with the explicit pinned `mke2fs`/`e2fsck`, and checks all immutable
runtime inputs before starting QEMU. It uses the historical accepted AArch64
book-execution test kernel and v6 read-only baseline; it makes no claim about the
newer package base. Each positive QEMU uses the accepted reader `virt` graph and
is stopped at QEMU's `prelaunch` state before any guest instruction. Each has a
30-second bound. Its private vector changes the accepted graph's resource values
from 4 vCPUs/2 GiB to the authorized maximum of 2 vCPUs/512 MiB; no accepted
source is changed. Contenders use a 128 MiB, 1-vCPU AArch64 `virt`
file/raw/virtio-blk graph and a four-second bound.

The finite cases are:

1. **normal close:** QMP proves `prelaunch`, the exact reader/state nodes and
   `book-state-disk`, and the exact command vector. `/proc/PID/fd/N` in QEMU is
   the retained state inode. A second actual QEMU opening the campaign pathname
   is refused by `locking=on`; QMP `quit` then lets the guardian join.
2. **owner TERM:** the accepted catchable-signal path terminates and reaps QEMU,
   unwinds the handoff/writer/lease, and removes only its exact run root.
3. **owner SIGKILL:** the exact QEMU is stopped so its image lock remains held,
   then the owner is killed. The kernel campaign lease becomes reacquirable, but
   a descriptor-handoff contender is still refused by QEMU's independent lock
   while the old QEMU remains alive. The existing guardian kills and reaps the
   stopped process boundedly. Replacing the watched run-root name proves the
   existing root guardian refuses that different inode and preserves its unknown
   marker; the test owner removes both verified test-owned roots only afterward.
4. **post-reap:** a fresh owner, handoff, root overlay, guardian, and actual QEMU
   open the same retained state inode after the old group is gone.

The root guardian deliberately emits `FAIL: root guardian refuses replaced run
directory` in case 3. In this fixture that exact line is expected evidence of
its conservative refusal, not the overall test verdict.

All QMP responses, exact PID/start-time identities, child-side allowlist facts,
QEMU `/proc` FD inventories, lock-refusal stderr, event ordering, bounded raw
console files, and foreign-root identity/marker facts are retained. On success,
the campaign passes explicit `e2fsck`, then its helper-owned inventory is
removed; all run/campaign bases are empty and every recorded process instance is
gone.

## Non-claims

This gate executes QEMU on the host, but it does **not** boot the guest, execute
ARM code, run runsc or KOReader, mount the state image, exercise the backend or
typed protocol, or prove state semantics. It proves neither two-boot Book State
persistence nor filesystem durability/recovery, hostile security, hardware,
PNG/glass behavior, shipping readiness, or the production per-book filesystem
decision. The retained image's unchanged identity across fresh paused QEMU
processes is ownership/integration evidence only.

Independent acceptance by someone other than the implementation author remains
required before these private successor hooks can be integrated.
