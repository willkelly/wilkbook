# Book State backend — adversarial review — 2026-09-06

## Disposition

**Blocked for Book Protocol integration.** The trusted Guile/SQLite backend has
the intended narrow authority boundary, transaction ordering, bounded retry
model, and demonstrated process-crash behavior. However, an existing database
marked as storage schema 1 is not bound to the actual schema-1 definitions.
Open validates only the three table names and two integer version markers, so an
additional trigger or altered table definition is accepted as schema 1.

This is not merely an open-time diagnostic omission. A valid SQLite trigger can
delete the receipt inserted by the backend in the same transaction. In an
independent reproduction, the backend returned a successful receipt and advanced
the value, but no receipt persisted; the exact retry then returned
`stale-version`. That contradicts the core durable-idempotency contract.

No implementation file was changed. No protocol, QEMU disk helper, QEMU, runsc,
ARM code, image, Bazel, mount, network, deployment, or hardware path was used.
All reviewer-created databases, scripts, processes, and temporary directories
were removed.

## Frozen review boundary

The supplied packet and immutable snapshot matched:

```text
pinenote/tools/book-state/build/book-state-backend-review-packet-v1.txt
b873e5fe0039e9ce9d01383bb83b76c202517607390b47418fbd8b6d558ff946

pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v1/MANIFEST.sha256
ca11cfb39f5f1974aa4d67c5109344ce88503c43585e46ce16d63a95f5f7162c

pinenote/tools/book-state/build/book-state-backend-host-check-v1.log
553865a0094056353a15a1656e0e1993d7671f170d9474ac9d9083e03e7e7b9b
```

The manifest had 11 unique entries. All 11 snapshot files matched their hashes,
were regular, single-link, mode 0400 files, and the snapshot root was mode 0500.
Principal reviewed source identities were:

```text
book-state.scm             eeb572ef8c97873fd7d2b3295ac20552bcc72bf2916d8c1bdca8004ba5fbd3d4
CONTRACT.md                 c25622ef491cedc919be4ea1ffede666cea83241dd0b9066c03f769e5f96b677
schema-v1.sql               70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb
test-book-state.scm         a3de37b302d0b11636a1ac3e73fd238a15a50e917995d3749cdcc3a90ebbacee
test_book_state_crash.py    caf39be259ad949dbbe0a36e66bc0effb2e92f8b9bba76e37eaba4cd6c6c39bb
```

The separate active `pinenote/tools/book-state-protocol/` and
`pinenote/tools/book-state-qemu/` work was neither read nor modified.

## Accepted properties within the blocked packet

### Authority and capability shape

- The trusted factory alone supplies the private mode-0700 root, book revision,
  and instance identity. A namespace exposes neither its row ID nor database
  path.
- Namespace and grant constructors and their store/row/owner fields are private.
  Public operations require the grant record, the endpoint-private owner object
  by `eq?` identity, and the exact generation. The copied random handle string
  alone is not authority.
- Grants bind one namespace and read-only/read-write access. Wrong owner,
  wrong generation, read-only write, revocation, old-store grant, closed store,
  and failed store paths are distinguished by typed rejections.
- Text, operation-ID, and handle accessors return copies. Commit copies mutable
  operation-ID and text inputs before entering the backend critical section.
- The API accepts no peer pathname, namespace row, SQL, or SQLite socket. The
  OWNER freshness/type rule remains a trusted adapter obligation: the backend
  intentionally compares an out-of-band host object rather than deriving owner
  authority from peer data.

The operation-ID predicate first requires a Scheme string, then one through 128
UTF-8 bytes, and finally checks every character against literal ASCII `a-z`,
`A-Z`, `0-9`, `_`, or `-`. Non-strings cannot reach byte conversion; Unicode,
dots, colons, whitespace, and controls do not satisfy the character predicate.
The SQL constraint independently uses the same closed alphabet and byte bound.

### Serialization, CAS, and retry ordering

One store mutex covers grant validation, revocation, reads, and each whole
SQLite transaction. No Book Session mutex appears in this module. Therefore a
revocation that owns this mutex first rejects a later commit; a commit that owns
it first reaches commit/failure before revocation returns. The deterministic
pre-COMMIT test correctly establishes the commit-first ordering without claiming
that SQLite I/O is nonblocking.

`BEGIN IMMEDIATE` occurs before reading current state. Existing-operation lookup
then precedes stale-version and receipt-capacity checks. An exact operation ID,
expected version, text, and byte count returns its original receipt even after
later commits; changed expected version or payload is `operation-conflict`; a
new stale operation is `stale-version`; and only a new current-version operation
can update state and insert a receipt.

The value update and receipt insert are in the same transaction. The receipt
record is not returned from `call-with-write-transaction` until SQLite `COMMIT`
returns. A failed decision explicitly rolls back. If rollback cannot be
confirmed, the connection is retired, all grants are revoked, and the store
enters `failed` rather than speculating about transaction state.

Absent state is `(absent 0)`, while committing the empty string produces a
present value at version 1. State versions are bounded to 0..64. Receipt lookup
continues ahead of quota checks at 64 receipts, no receipt is evicted, and stale
CAS remains distinguishable from full receipt capacity.

### Quotas and ordinary storage failures

The implementation and SQL agree on the 4096-byte UTF-8 value bound, 128-byte
operation ID, 256-byte trusted identities, 32 namespaces, 32 live grants,
1,000,000 grant generation ceiling, 64 receipts per namespace, 4096-byte page,
and 4096-page database maximum. Namespace, grant, receipt, stale, and text quota
decisions occur without a partial state advance.

The real `SQLITE_FULL` test lowers the live database page maximum to its current
page count, reaches SQLite's actual full error, observes `storage-failure`, and
confirms that an unconfirmable auto-rollback retires the worker. A fresh worker
reopens the database, sees only the last committed value, and can commit again.

### Filesystem and dependency posture

The root must be an absolute canonical caller-owned mode-0700 directory; aliases
and symlinked roots are rejected. An existing database must be a caller-owned,
single-link regular mode-0600 file. New database creation uses exclusive create
with `O_CLOEXEC`, and posture is checked again after SQLite opens it. These are
appropriate checks for the stated private trusted-host context; this review does
not turn the backend into a defense against another privileged or same-UID host
attacker racing path replacement.

The runtime manifest contains Guile 3.0.9, the already-used guile-gcrypt 0.5.0,
and the new guile-sqlite3 0.1.3 dependency. The realized binding module matched
SHA-256 `604201080df7502bddb39ca8df7ed4448e35e547b687ce380caf1222fd39d430`
and its direct Guix reference was exactly SQLite 3.53.1 at
`/gnu/store/vi2anm0x47773lg48rh77dz9myhcbgmh-sqlite-3.53.1`. Python appears
only in the test manifest and crash oracle.

## Independent host results

The packet's exact pinned Guix command was rerun with `--max-jobs=1 --cores=2`.
It completed successfully with 71 Guile expected passes and the one Python crash
test method passing.

The crash test uses fresh Guile processes and independent Python SQLite reads:

- acknowledged state reopens with its receipt;
- SIGKILL after transactional writes but before COMMIT leaves the preceding
  state and receipts unchanged after hot-journal recovery;
- SIGKILL after COMMIT but before output preserves both the new value and retry
  receipt;
- an exact retry after that lost acknowledgement returns the original receipt;
- retry remains exact after later state advancement; and
- changed retry and new stale operation are rejected without mutation.

This is good evidence for process-death recovery on the current host filesystem.
It is not evidence for physical power loss, ext4/device caches, QEMU, AArch64,
or PineNote durability.

Two additional concurrency controls passed using already-open backend handles:

- two fresh Guile processes opened separate stores/grants first, then raced
  distinct operation IDs at expected version 0; one committed version 1 and one
  returned `stale-version 1`, leaving exactly one value and one receipt; and
- while an independent SQLite connection held `BEGIN IMMEDIATE`, an already-open
  backend commit returned typed `storage-failure` after 5.009 seconds, kept its
  store open, and left absent state with no receipt.

An exploratory simultaneous launch of two whole workers caused one worker to
receive an unhandled `SQLITE_BUSY` during concurrent store opening while the
other committed. That does not contradict the explicitly single-worker contract
or establish multi-process-writer support. Protocol integration must preserve
the one trusted worker/connection-owner model; this packet does not qualify
concurrent store initialization.

## BS-1 — schema-1 markers do not authenticate schema-1 behavior

`validate-or-initialize-schema!` initializes only when `user_version` is zero
and no user tables exist. For an existing version-1 database, it checks:

1. `PRAGMA user_version = 1`;
2. the sorted user-table names are exactly `book_instances`,
   `commit_receipts`, and `metadata`; and
3. metadata key `storage_schema_version` has integer value 1.

It does not validate column definitions, `STRICT`, primary/unique indexes,
foreign keys, CHECK constraints, or the absence and definitions of triggers and
views. `PRAGMA quick_check` verifies SQLite structural consistency, not that
these application schema definitions match `schema-v1.sql`.

### Independent counterexample

Using only the pinned host test environment and a private temporary database:

1. A normal backend process initialized schema 1 and one namespace, then closed.
2. Python's independent SQLite connection added this ordinary schema object:

   ```sql
   CREATE TRIGGER discard_receipt
   AFTER INSERT ON commit_receipts
   BEGIN
     DELETE FROM commit_receipts
     WHERE namespace_id = NEW.namespace_id
       AND operation_id = NEW.operation_id;
   END;
   ```

3. The database retained `user_version=1`, metadata version 1, exactly the same
   three table names, and `PRAGMA quick_check = ok`.
4. A fresh backend process accepted it and returned:

   ```text
   (receipt "triggered-op" 0 1 25)
   ```

5. Independent inspection immediately showed state `(1, 1,
   "committed-without-receipt")`, the trigger present, and zero receipt rows.
6. A fresh exact retry returned:

   ```text
   (rejection stale-version 1)
   ```

The trigger runs inside the backend's transaction, so SQLite COMMIT really does
commit the state advance and receipt deletion atomically. The flaw is the
backend's acceptance of behavior not belonging to schema 1. Neither
`trusted_schema=OFF` nor `quick_check` disables or rejects a trigger composed of
built-in SQL operations.

This counterexample requires no sandbox access or live path race. It models an
existing, closed, internally consistent database whose definitions disagree
with the version the backend claims to understand—the exact inconsistent-schema
case the contract says must fail on open.

## Required finite correction

Before protocol integration:

1. Bind storage schema version 1 to the complete accepted SQLite schema, not
   only names and integer markers. Verify exact table columns/types/STRICT
   properties, keys/indexes, foreign keys, defaults and constraints, and reject
   every unrecognized trigger or view before issuing a store.
2. Prefer a deterministic schema fingerprint or a complete normalized
   `sqlite_schema`/PRAGMA inventory whose expected bytes are generated from the
   pinned schema. Also require the expected metadata row set, not merely one
   matching row.
3. Add the receipt-deleting trigger above as a negative regression: reopening
   must throw the documented inconsistent-schema error before namespace/grant
   creation or commit. Add at least one altered-table/constraint case so trigger
   absence alone is not mistaken for complete schema validation.
4. Preserve fresh initialization, explicit newer/unknown-version rejection, no
   implicit migration, and all existing authority, quota, transaction, crash,
   `SQLITE_FULL`, CAS, and busy-lock behavior.
5. Freeze new source/test/schema hashes and perform another focused host-only
   review. No QEMU, hardware, image, protocol, or physical-power test is needed
   to close BS-1.

Until then, source hash `eeb572ef…` is **not accepted for protocol integration**.
The separate protocol candidate should not bind this backend as its persistent
authority. No conclusion here blocks unrelated interaction-demo work or changes
the accepted Book Session/Book Protocol results.

---

## BS-1 correction recheck — accepted — 2026-09-06

### Disposition

**BS-1 is closed for the exact v2 snapshot below.** The corrected trusted Guile
backend is accepted for a later Book Protocol integration review. The rejected
v1 source and counterexample above remain historical facts; this acceptance does
not relabel or supersede them.

The correction binds storage schema 1 to the complete schema produced from the
packaged `schema-v1.sql` by the pinned SQLite, checks that schema at open and at
the start of every database-writing transaction, and retires a store whose
schema changes after open. The original receipt-deleting trigger can no longer
produce a success receipt or advance state.

### Frozen v2 boundary

```text
pinenote/tools/book-state/build/book-state-backend-review-packet-v2.txt
d4bc141b24020cf4df8316835a9d4aa1c7eb3c0c0d906ebd1143fee9e996a2f3

pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v2/MANIFEST.sha256
6520e5ed592cbec37be4605544b7606387d8032335a474ce596a485c022f5426

pinenote/tools/book-state/build/book-state-backend-host-check-v2.log
b0cb0fcf161419d68f8446d62eb806e37a240a8b2cba0fe7d5df8bedf8071fab
```

The immutable manifest had 11 unique entries. All 11 files matched their
declared hashes and were regular, single-link, mode-0400 files; the snapshot
directory was mode 0500. Principal accepted identities are:

```text
book-state.scm             7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9
CONTRACT.md                 f84bcd84eb894e43bc4e5a03ef7379dc563e44683aab053610c13279368ae6e6
schema-v1.sql               70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb
test-book-state.scm         d4599ee82003bcd64e96e814321eb0ca448558cab137f74169d2e8ff99e3f4c1
test_book_state_crash.py    caf39be259ad949dbbe0a36e66bc0effb2e92f8b9bba76e37eaba4cd6c6c39bb
```

The storage DDL, public operation-ID predicate and
`[A-Za-z0-9_-]{1,128}` contract, crash driver, worker, manifests, Makefile, and
dependencies are unchanged from v1. Storage schema remains version 1 because
the DDL remains byte-for-byte identical. The implementation and its schema
tests/documentation are the finite changed surface.

### Why the correction closes BS-1

For each store, the backend executes the trusted DDL in a private in-memory
database and captures an expected manifest. It compares the persistent database
against all of the following:

- every `(type, name, tbl_name, sql)` row in `main.sqlite_schema`, with no
  wildcard or `sqlite_*` exception;
- the exact complete metadata row set;
- `pragma_table_list`, including column counts and `STRICT` flags;
- `pragma_table_xinfo` and `pragma_index_list` for all three application tables;
- `pragma_index_xinfo` for all three DDL-generated autoindexes; and
- `pragma_foreign_key_list` for all three tables.

Exact canonical table SQL binds defaults, keys, CHECK clauses, and the rest of
the table definitions. The additional PRAGMA inventory binds column layout,
index origin/uniqueness/partial status, index columns and collations, strictness,
and foreign-key actions. Unexpected triggers, views, tables, explicit indexes,
SQLite statistics objects, autoindexes, or metadata rows therefore change the
manifest. An equivalent schema reconstructed with different SQL text is
deliberately not schema 1; there is no implicit migration or repair.

Open initializes or validates and runs `quick_check` within one
`BEGIN IMMEDIATE` transaction. Each later database write obtains
`BEGIN IMMEDIATE`, validates the complete expected manifest, and only then
performs namespace, state, receipt, CAS, or quota work. The write reservation
prevents an ordinary second connection from landing DDL between validation and
COMMIT. A midlife mismatch rolls back, marks the store `failed`, revokes all its
grants, closes the database connection, and propagates
`book-state-unsupported-schema`; it cannot return a typed receipt.

### Independent focused results

The exact pinned v2 Guix environment was used with `--max-jobs=1 --cores=2`.
The 92-assertion Guile suite passed. The separate-process Python crash/restart
scenario also passed. This rerun was warranted because schema validation now
sits inside the transaction containing the established pre-COMMIT and
post-COMMIT/pre-ack crash checkpoints.

Independent reviewer probes established:

1. **Original trigger before open.** A database initialized by v1 received the
   exact `discard_receipt` trigger from BS-1. V2 rejected open with
   `book-state-unsupported-schema`; state remained absent/version 0, no receipt
   existed, the trigger remained for diagnosis, and `quick_check` remained `ok`.
2. **Original trigger after open.** A v2 store, namespace, and grant were opened,
   then an independent SQLite connection installed the trigger. The next commit
   rejected the inconsistent schema before state or receipt work. State remained
   absent/version 0 with zero receipts; the store became `failed`, the grant
   became `revoked`, and a later use of that grant returned `store-failed`.
3. **Exact v1 compatibility.** A genuine database and receipt created by the
   rejected v1 implementation's unchanged DDL reopened under v2. V2 read the
   version-1 value and an exact operation retry returned the original receipt,
   with one state row and one receipt unchanged.
4. **Valid two-handle CAS.** Two separate Guile processes fully opened v2 stores
   and grants before racing distinct operation IDs at expected version 0. One
   returned a version-1 receipt and one returned `stale-version 1`; independent
   SQLite inspection found one winning value, one receipt, and `quick_check=ok`.

The passing 92-assertion suite additionally exercises a weakened receipt
constraint, an extra view, table, index, `sqlite_stat1`, and metadata row. Each
is rejected rather than trusted or repaired. It also preserves the valid
two-handle result and the prior authority, revocation, quota, exact-retry,
`SQLITE_FULL`, and transaction tests.

### Accepted scope and next join

Source hash `7c3a507d…` is accepted as the trusted persistent-text backend for
future protocol integration. This means process-crash durable state and receipt
semantics on the tested host filesystem; it does **not** claim physical-power
loss, ext4/device-cache, QEMU, AArch64, PineNote, sandbox, UI, lifecycle,
rendering, or shipping-service qualification.

The separate Book State Protocol v2 review remains independent. Existing
adapter tests that used rejected backend source `eeb572ef…` do not validate this
join. Once both components are separately accepted, the real adapter/SQLite
integration must be rerun against this exact v2 backend snapshot. Any change to
the accepted backend executable source, DDL, dependency, snapshot, or test
hashes requires fresh review.

No backend, protocol, UI, guest, runtime, or QEMU source was edited during this
recheck. No QEMU, runsc, ARM execution, image build, mount, deployment, hardware,
staging, commit, or push occurred. Reviewer-created scripts, databases,
processes, and temporary directories were removed.
