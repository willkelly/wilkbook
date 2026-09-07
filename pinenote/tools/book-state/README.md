# Book State: first durable host backend

This directory implements one narrow trusted-host persistence result: a bounded
plain-text value for a stable `BookInstance` survives store close, a fresh Guile
process, a process killed before commit, and a process killed after commit but
before its acknowledgement. See `CONTRACT.md` for the authority and transaction
contract.

This is not wired into the Book Protocol or KOReader yet. It creates no daemon,
socket, JSON codec, sandbox mount, workspace, or shipping service. The next
protocol slice should map its existing bounded JSON messages into these typed
Guile records without accepting book identities or paths from a peer.

## Storage choice

The backend uses SQLite rather than inventing a journal:

- one `book-state-v1.sqlite` file stores namespaces, current values, and bounded
  idempotency receipts in the same transaction;
- `BEGIN IMMEDIATE` serializes compare-and-swap after the backend's own grant
  and revocation check;
- an operation receipt is inserted atomically with the new value;
- SQLite recovery rolls back a process killed before `COMMIT`; and
- an exact retry after commit/ack loss reads the original durable receipt.

A bounded atomic-file implementation was considered. Temp-file write, file
`fsync`, rename, and parent-directory `fsync` are sufficient for replacing one
value, but this contract must atomically replace the value **and** preserve a
bounded operation-ID receipt history. Putting both into one custom file would
require a new parser, schema and migration representation, whole-file rewrite,
checksums, duplicate-operation indexing, and crash-recovery reasoning. Splitting
them across files would reintroduce a transaction problem. SQLite already
provides the smaller and better-tested implementation, so the atomic-file path
is not used.

### Why rollback journal, not WAL

There is one synchronous trusted worker and no read-concurrency requirement.
The database therefore fixes:

```text
PRAGMA journal_mode = DELETE
PRAGMA synchronous = FULL
PRAGMA foreign_keys = ON
PRAGMA trusted_schema = OFF
PRAGMA temp_store = MEMORY
PRAGMA page_size = 4096
PRAGMA max_page_count = 4096
busy timeout = 5000 ms
```

In rollback-journal mode, a successful `COMMIT` under `synchronous=FULL` is the
receipt durability boundary. WAL would add a separate persistent `-wal` file
and checkpoint lifecycle without benefiting this serialized workload. The test
suite queries every PRAGMA above from the real open connection. No successful
commit result is constructed until SQLite's `COMMIT` call returns.

### Exact schema-1 binding

`schema-v1.sql` is also the machine-owned DDL input. At open, the backend applies
it to a private in-memory database using the same pinned SQLite and captures the
complete canonical `sqlite_schema` inventory plus table, column, index,
autoindex, foreign-key, `STRICT`, and exact metadata-row information. The real
database must match. All persistent schema objects are inventoried; the three
fixed-DDL autoindexes are admitted by exact name/metadata rather than a broad
`sqlite_*` exception.

Initialization/open validation runs in one `BEGIN IMMEDIATE` snapshot. Every
write transaction repeats the exact manifest check after `BEGIN IMMEDIATE` and
before reading or changing state, so an external connection cannot add a trigger
between the check and receipt commit. A midlife mismatch rolls back, fails the
worker, and revokes grants. Nothing silently removes, recreates, or migrates an
invalid database.

This is intentionally byte-strict known DDL, not a SQL parser: even a
whitespace-only change to canonical `sqlite_schema.sql` is unsupported schema 1.
Legitimate databases initialized from this version's fixed DDL reopen normally.

The result proves process-death recovery on the current host filesystem. It is
not a physical-power-loss or ext4/write-cache qualification; that requires a
later crashable QEMU filesystem test and eventually a device-specific result.

## Pinned dependencies

`runtime-manifest.scm` and `test-manifest.scm` resolve under `channels.scm`'s Guix commit
`f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c`:

| Role | Package | Realized output |
|---|---|---|
| trusted implementation | `guile@3.0.9` | `/gnu/store/aqpggy9i24nnx39d8ysxsms6zv4icnm5-guile-3.0.9` |
| SQLite binding | `guile-sqlite3@0.1.3` | `/gnu/store/wsg7chjw2cg6xnp4il5caff5w0w69ikc-guile-sqlite3-0.1.3` |
| SQLite library selected by the binding | `sqlite@3.53.1` | `/gnu/store/vi2anm0x47773lg48rh77dz9myhcbgmh-sqlite-3.53.1` |
| opaque grant randomness | `guile-gcrypt@0.5.0` | `/gnu/store/33f7w4fr1cljrzq8czffngcnvrbpf02w-guile-gcrypt-0.5.0` |
| independent crash-process orchestrator, tests only | `python@3.12.12` | `/gnu/store/lrl6shxa3gnlzy1mfa149vmgidnh60lw-python-3.12.12` |

Derivations resolved to:

```text
/gnu/store/jkai0jara4pnhbwr0m8z4fzf3641qg55-guile-3.0.9.drv
/gnu/store/qkbqrbdnj8wp01p3qxnc1rrjbzcbshri-guile-sqlite3-0.1.3.drv
/gnu/store/2p5qgk7wpmfwzmf2amc8cvlhc42l4n6f-sqlite-3.53.1.drv
/gnu/store/6n4abga6qz3z2ismznk27lgxzasaqn5w-guile-gcrypt-0.5.0.drv
/gnu/store/9l9sd0ji4gn06kqsv2lffyxmz7160hsl-python-3.12.12.drv
```

The realized binding's `(sqlite3)` module is SHA-256
`604201080df7502bddb39ca8df7ed4448e35e547b687ce380caf1222fd39d430`.
It directly binds SQLite 3.53.1 and exposes the APIs used here:
`sqlite-open`, `sqlite-close`, `sqlite-exec`, `sqlite-prepare`,
`sqlite-bind-arguments`, `sqlite-step`, `sqlite-map`, `sqlite-finalize`, and
`sqlite-busy-timeout`. The pinned Guix package reports `aarch64-linux` among its
supported systems; this slice nevertheless performs host-native tests only and
does not claim an AArch64 build or image integration.

The production dependency delta relative to the already accepted trusted Guile
authority profile is `guile-sqlite3` and its SQLite runtime reference.
`guile-gcrypt` was already present there for strong opaque IDs. Python belongs
only to the fault-oracle test profile and is not a production authority path.

## Files

- `book-state.scm` — trusted typed API, grants, serialized state machine, CAS,
  idempotency, SQLite transaction and schema checks.
- `schema-v1.sql` — fixed SQL schema parsed only by SQLite as trusted package
  data; stored values are bound parameters and are never Scheme input.
- `CONTRACT.md` — interface and protocol-join boundary.
- `runtime-manifest.scm` — exact trusted runtime profile; its only package added
  to the existing authority profile is `guile-sqlite3` (which references SQLite).
- `test-manifest.scm` — runtime profile plus test-only Python.
- `test-book-state.scm` — typed API, quota, real database-full, schema and
  concurrent revocation tests.
- `test-worker.scm` — test-only fresh-process and two-point `SIGKILL` driver.
- `test_book_state_crash.py` — independent process supervisor/fault oracle.
- `Makefile` — bounded host checks only.

## Test

From this directory:

```sh
make check
```

The Makefile uses the repository's pinned `channels.scm`, at most one Guix build
job and two build cores. It performs no kernel, Bazel, image, QEMU, runsc, ARM,
or hardware work.

The real-file matrix covers:

- absent state versus committed empty text;
- exact UTF-8 byte bounds and exported `[A-Za-z0-9_-]{1,128}` operation-ID
  grammar;
- compare-and-swap success and stale rejection without mutation;
- exact operation retry and changed-payload rejection;
- two stable instance namespaces with isolated values;
- read-only, wrong-owner, stale-generation and revoked grants;
- a commit/revoke race proving one backend-mutex linearization order;
- full namespace and durable-receipt quotas without silent eviction;
- a finite live-grant quota with revocation releasing one slot;
- actual SQLite page exhaustion, fail-closed worker retirement, rollback
  recovery, and subsequent use through a fresh worker;
- explicit rejection of a newer storage schema;
- exact rejection of the BS1 receipt-deleting trigger at open and when inserted
  after a store is already open, with no state or receipt write;
- rejection of a weakened receipt constraint, unexpected table/view/index,
  SQLite-generated `sqlite_stat1`, and an extra metadata row;
- two already-open valid handles racing CAS, leaving one receipt and one stale
  result under the unchanged exact schema;
- close/reopen in a fresh Guile process;
- `SIGKILL` after writes but before commit, followed by rollback recovery; and
- `SIGKILL` after durable commit but before acknowledgement, followed by exact
  receipt replay and changed-retry rejection.

The Python fault oracle also opens the real SQLite file after each kill and
checks the state/receipt rows independently. It does not implement authority or
modify production state semantics.

The crash tests leave only the mode-`0600`, single-linked database after every
recovery. Test roots are caller-owned mode `0700`; no generic recursive cleanup
or arbitrary-path interface is part of the backend.
