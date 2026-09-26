# Workbench device composition: bounded investigation

The composition contract, migration inventory, work packages and device
qualification matrix are in
[`doc/workbench-device-integration.md`](../../../doc/workbench-device-integration.md).
There is no device launcher or service in this directory yet.

`owner-control.scm` is a pure Guile consumer of the existing sandbox owner's
private `ready\n` / `clean\n` receipts. Its caller supplies bytevector fragments,
records trusted stop intent, and reports the actual waited process result with
`owner-control-exited!` (`'exit` and exit code, or `'signal` and signal number;
**not** the raw wait status). Invalid receipts throw `owner-control-error` and
permanently retire that instance.

- `owner-control-can-deliver?` gates authored frames on readiness and lifetime.
- `owner-control-cleanup-complete?` requires clean plus a terminal process result.
  It reports disposal evidence, not a final verdict on the receipt stream; later
  malformed bytes poison it.
- `owner-control-preview-eligible?` additionally requires requested stop,
  readiness, no observed premature termination, exit zero and observed socket
  EOF. Clean plus exit zero alone cannot authorize success while trailing bytes
  may remain unread. This is necessary
  execution evidence only: it does not grant a preview ticket or prove authority,
  SQLite, disposable-store or aggregate service cleanup.

Feed every received byte through `owner-control-feed!` before reporting actual
socket EOF with `owner-control-eof!`. Process exit, EAGAIN, timeout and local
socket closure do not prove terminal drain. Exit and EOF may be observed in
either order; both are required for successful preview eligibility. Keep the
future caller's drain within its existing cleanup observation deadline.

The module performs no I/O, launch, timing or source evaluation. A future
coordinator owns those operations and cannot recover a failed cleanup by
allocating a fresh receipt record. Observe each process through its retained
ownership handle; receipt bytes and process status must belong to the same owner.

With a cached Guile, from the repository root:

```sh
guile --no-auto-compile -L pinenote/tools/book-workbench-device \
  pinenote/tools/book-workbench-device/test-owner-control.scm
```

The SRFI-64 suite tests fragmentation/coalescing, premature termination, terminal
result/EOF ordering, delayed trailing bytes, malformed/duplicate receipts and
permanent failure. It needs
only Guile's standard modules. It neither executes a sandbox nor builds anything.
