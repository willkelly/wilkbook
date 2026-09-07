# Book State host contract — storage schema 1

Status: first host-only durability slice. This is a contract for the trusted
Guile authority and the next Book Protocol join, not a sandbox API, daemon, or
shipping service.

## Boundary

The backend owns **private durable state for one installed `BookInstance`**. It
does not edit a `Workspace`, produce a `BookRevision`, store reader settings, or
interpret text. The first value is one optional plain UTF-8 string.

The trusted host chooses the persistent root, book revision identity, and user
instance identity. `open-book-instance!` turns those trusted identities into an
opaque `<book-state-namespace>` record. There is no public namespace identifier
or database-path accessor. A sandbox must never provide a book identity,
instance identity, namespace row, SQLite path, or filesystem path.

The host issues a short-lived `<book-state-grant>` for a supervised endpoint.
The grant binds:

- the exact in-memory owner object by `eq?` identity;
- one opaque random handle and generation;
- one trusted namespace record;
- `read-only` or `read-write` access; and
- an `active` or `revoked` state.

`OWNER` is the trusted endpoint's private owner/scope object. It must be a fresh
host record or object retained by that endpoint, never a peer-supplied value or
an interned symbol/string that another endpoint could reproduce.

The handle is the only one of those values suitable for a JSON grant envelope.
The trusted endpoint keeps the grant record and supplies it directly to the
backend. Receiving the same handle string from another endpoint does not create
authority. No SQLite file or socket is exposed to a sandbox.

## Public Guile interface

The module is `(book-state)`.

```scheme
(open-book-state-store ROOT)              => <book-state-store>
(close-book-state-store! STORE)           => unspecified
(book-state-store-phase STORE)            => open | closing | closed | failed

(open-book-instance! STORE BOOK-REVISION INSTANCE-ID)
    => <book-state-namespace> | <book-state-rejection>

(issue-book-state-grant! STORE NAMESPACE OWNER ACCESS)
    => <book-state-grant> | <book-state-rejection>

(revoke-book-state-grant! STORE OWNER GRANT)
    => revoked | already-revoked | <book-state-rejection>

(read-book-state STORE OWNER GRANT GENERATION)
    => <book-state-absent> | <book-state-value> | <book-state-rejection>

(commit-book-state! STORE OWNER GRANT GENERATION
                    OPERATION-ID EXPECTED-STATE-VERSION TEXT)
    => <book-state-receipt> | <book-state-rejection>
```

Constructors for stores, namespaces, grants, values, receipts, and rejections
are private. Predicates and field accessors are exported only for typed dispatch:

- `<book-state-absent>` carries `state-version`, initially `0`;
- `<book-state-value>` carries `state-version` and `text`;
- `<book-state-receipt>` carries `operation-id`, `expected-state-version`,
  resulting `state-version`, and UTF-8 `text-bytes`;
- `<book-state-rejection>` carries a symbolic `code` and the current state
  version when it is safely available.

The public API returns fresh copies of text, operation IDs, and handles. Typed
records, not loose alists, represent authority and state internally.

## Commit semantics

Each new commit contains:

```text
operation ID
expected state version
plain UTF-8 text, at most 4096 bytes
```

`operation ID` is an opaque machine-generated retry identity, not user text.
The adapter and backend use the exported `book-state-operation-id?` predicate
and `book-state-max-operation-id-bytes` constant. Storage schema 1 fixes the
grammar to exactly `[A-Za-z0-9_-]{1,128}`: one through 128 ASCII letters,
digits, underscores, or hyphens. Dots, colons, whitespace, controls, and Unicode
are rejected. The intentionally small alphabet is sufficient for UUID/base64url
style host IDs and removes locale, normalization, escaping, and log-boundary
ambiguity from a value whose content has no human meaning.

The state version is `0` while the value is absent. A successful first commit,
including a commit of the empty string, creates a present value at version `1`.
Thus absent state and present empty text are distinct.

The trusted worker serializes grant checks, revocation, reads, and the complete
SQLite transaction with one backend mutex. The linearization rules are:

1. Revocation that obtains the mutex before a commit starts makes that commit
   return `revoked` without opening a transaction.
2. A commit that obtains the mutex first either durably commits and returns (or
   loses) its receipt before revocation can complete, or fails and rolls back.
3. The Book Session transition mutex must **not** be held while calling this
   backend. The backend does not borrow an earlier authorization check across
   file I/O; it rechecks owner, generation, access, and grant state under its own
   mutex at operation start.

Within one `BEGIN IMMEDIATE` transaction, operation lookup precedes compare and
swap:

- the same operation ID, expected version, and exact text returns the original
  receipt, even after process restart and even if the namespace has advanced;
- the same operation ID with different expected version or text returns
  `operation-conflict` and writes nothing;
- a new operation whose expected version differs from current state returns
  `stale-version` and writes nothing;
- a new matching operation atomically writes the value and its retry receipt,
  increments state version by one, and returns only after `COMMIT` succeeds.

Because schema 1 retains at most 64 receipts and never evicts one, its state
version is bounded to `0..64`; expected versions outside that range are rejected
before SQLite. For a new operation, a stale version is reported before receipt
capacity, while an exact retry continues to precede both checks.

If the process dies before `COMMIT`, SQLite recovery leaves no acknowledged
write. If it dies after `COMMIT` but before acknowledgement, an exact retry
returns the persisted original receipt. Receipt loss at the caller is therefore
recoverable without silently repeating the write.

SQLite failures return `storage-failure`. The backend attempts an explicit
rollback first. If the binding cannot confirm that rollback (including SQLite
having already auto-rolled back after `SQLITE_FULL`), the worker retires its
connection, revokes every live grant, and enters `failed`; a fresh worker must
reopen and recover the database before another operation. It never guesses that
an ambiguous live connection is reusable.

## Durability and schema

The implementation uses the pinned Guix `guile-sqlite3` binding and SQLite in
rollback-journal `DELETE` mode with `synchronous=FULL`. One synchronous trusted
worker is a better match for this small append-and-replace workload than WAL:
there is no read-concurrency requirement, no checkpoint durability boundary,
and every successful receipt follows SQLite's completed rollback-journal commit.
`foreign_keys=ON`, `trusted_schema=OFF`, `temp_store=MEMORY`, a finite busy
timeout, fixed page size, and fixed maximum page count are verified on open.

`storage_schema_version=1` is recorded both in `PRAGMA user_version` and a
metadata row. It is independent from Book Protocol JSON version, grant
generation, state version, and software revision. An empty database may be
initialized as schema 1. Version 1 defines no migration or repair.

The packaged `schema-v1.sql` is executable application schema, not merely human
documentation. On each store open, the backend applies those bytes to a private
in-memory database through the same pinned SQLite and captures a finite known
schema manifest. Validation requires exact equality for:

- every `(type, name, tbl_name, sql)` row in `main.sqlite_schema`, including the
  canonical table SQL and exactly the three expected `sqlite_autoindex_*` rows;
- the complete and only metadata row;
- `pragma_table_list`, including column counts and `STRICT` flags;
- every known table's `pragma_table_xinfo` and `pragma_index_list` rows;
- every known autoindex's `pragma_index_xinfo` rows; and
- every known table's `pragma_foreign_key_list` rows.

There is no broad `sqlite_*` exclusion. Any additional or altered table, index,
view, trigger, SQLite statistics object, column, default, key, constraint,
collation, strictness flag, or metadata row is inconsistent schema 1. Because
canonical `sqlite_schema.sql` bytes are compared, independently reconstructed
DDL with only whitespace or formatting changes is deliberately unsupported;
schema 1 is the exact known application DDL, not a semantic-SQL migration
framework.

Open performs initialization or validation and `quick_check` within one
`BEGIN IMMEDIATE` snapshot. Every later write transaction validates the same
complete manifest immediately after its own `BEGIN IMMEDIATE` and before state
or receipt lookup. The write reservation prevents another ordinary SQLite
connection from inserting DDL between validation and commit. A schema mismatch
throws `book-state-unsupported-schema` with `inconsistent` and supported version
`1`; a midlife mismatch first rolls back, then retires the connection and
revokes every grant. It never commits state, manufactures a receipt, deletes the
unexpected object, recreates tables, or migrates the database.

Stored text and identifiers are always bound SQL data. The backend never applies
Scheme `read`, `eval`, or code loading to stored content.

The demonstrated failure boundary is **process death and restart on the host
filesystem**. It is not yet physical power-loss qualification. Filesystem/device
write-cache behavior and ext4 crash recovery need a later bounded QEMU test and,
eventually, device evidence.

## Fixed prototype quotas

| Resource | Limit | Full behavior |
|---|---:|---|
| UTF-8 text per value | 4,096 bytes | `text-too-large` |
| UTF-8 operation ID | 128 bytes | `invalid-operation-id` |
| trusted book revision or instance ID | 256 bytes each | trusted factory rejection |
| namespaces per database | 32 | `namespace-quota-exhausted` |
| simultaneous live grants per worker | 32 | `grant-quota-exhausted` |
| grant generation | 1..1,000,000 | `grant-generation-exhausted` |
| durable retry receipts per namespace | 64 | `receipt-quota-exhausted` |
| SQLite page size | 4,096 bytes | open-time invariant |
| SQLite database pages | 4,096 (16 MiB) | storage failure, transaction rolled back |
| concurrent backend operations | 1 | serialized by the trusted worker mutex |
| detached workers or queued requests | 0 | caller performs one synchronous operation |

Receipt history is never silently evicted. Once its quota is full, an exact
retry of an existing operation still succeeds, stale compare-and-swap still
reports `stale-version`, and a new operation at the current version fails closed
until a future explicitly designed archival/migration operation exists.

## JSON Book Protocol projection

JSON remains the current wire encoding. This backend does not add or parse wire
messages. A protocol adapter may project already validated exact-shape messages
onto the typed API with these semantic fields:

```text
grant handle + grant generation
read

grant handle + grant generation
commit: operation_id + expected_state_version + text

reply: absent/value/receipt/rejection with state_version where applicable
```

The adapter derives the owner from its supervised endpoint and resolves the
opaque handle to the endpoint-retained grant record. Book identity, instance
identity, namespace identity, storage schema, and path are never peer fields.
Wire-version evolution and a future richer typed message model remain separate
from storage-schema migration.

## Explicit non-goals

- no workspace journal, immutable revision commit, undo, or export;
- no generic key/value database or arbitrary blobs;
- no sandbox-visible SQLite file, SQL operation, host path, or state socket;
- no Python production authority;
- no async worker framework, durable queue, or background checkpoint;
- no physical-power-loss, multi-process writer, network filesystem, or device
  durability claim; and
- no integration change to the accepted Book Session, QEMU, runsc, reader, or
  interaction demonstration.
