# Workbench authoring contract, prototype 1

This contract describes the source/revision prototype in this directory. The
trusted KOReader-to-authority channel is separate from ordinary Book Protocol,
which the fixed execution runner uses on its own FD 3.

## Identities

- A store is opened by trusted construction for one private workspace directory.
- A UI endpoint retains that store and its explicit preview runner. Messages
  cannot select a path, database, workspace, interpreter or environment.
- `workspace_version` identifies the saved draft. A compare-and-swap write
  rejects stale versions rather than silently overwriting a newer draft.
- `source_digest` identifies source bytes under the store's format/environment
  contract. A digest is not authority to another workspace.
- `active_revision` identifies immutable installed source.
- `activation_generation` is a monotonically advancing epoch; rollback advances
  it too. It prevents stale requests across an R1 → R2 → R1 cycle.
- A successful preview creates an in-memory authorization retained only by that
  endpoint, bound to draft version, source digest and activation epoch. There
  is no wire field that lets the caller manufacture this authorization.

## Private UI framing

```text
command|SEQUENCE|LOWERCASE_HEX_OF_JSON\n
reply|SEQUENCE|LOWERCASE_HEX_OF_JSON\n
```

`SEQUENCE` is canonical decimal, 1 through 2,147,483,647. An endpoint starts
at 1 and advances by exactly one per command. The UI permits one pending
command. JSON uses the existing strict Book Protocol object codec: at most
65,536 payload bytes, no duplicate keys, depth at most 16, strict Unicode and
exact integer validation for versions. A line is at most 131,104 bytes before
its newline. A malformed, truncated, oversized or out-of-sequence line closes
the connection; there is no stream resynchronization.

Each request has exactly these fields:

| `op` | Other fields | Effect |
| --- | --- | --- |
| `open` | none | Read the durable snapshot and invalidate the prior editor view's preview authorization |
| `save` | `expected_version`, `source` | Commit the new draft through CAS; invalidate preview authorization |
| `preview` | `expected_version`, `text` | Run the exact saved draft; retain matching authorization only on success |
| `run` | `text` | Run immutable installed source, independently of the draft |
| `activate` | `expected_version`, `expected_activation` | Require the endpoint's matching preview, seal, and activate through epoch CAS |
| `rollback` | `expected_activation` | Select the retained predecessor through epoch CAS, keeping the draft |
| `export` | none | Return the deterministic installed-source artifact |
| `close` | none | Discard endpoint preview authorization and close the session |

Source is at most 8,192 UTF-8 bytes and contains no NUL. Input text is
1–2,048 bytes without NUL. Successful result text is nonempty, at most 4,096
bytes, and contains no NUL. Versions are exact, nonnegative integers no greater
than 2,147,483,647.

Every reply has `ok` and `op`. Successful `open`, `save`, `activate`, `rollback`
and `close` include:

```json
{"snapshot": {
  "workspace_version": 1,
  "source": "...",
  "source_digest": "...",
  "active_revision": "...",
  "previous_revision": false,
  "activation_generation": 1
}}
```

Successful `preview`, `run` and `export` instead include `workspace_version`,
`source_digest` and `activation_generation` directly. They preserve the
client's source snapshot. `preview` and `run` add `text` and `diagnostic`;
`export` adds `artifact`. Omitting a repeated source snapshot keeps worst-case
escaped source plus export/result within the existing JSON budget.

Failure replies contain `error`; preview failures also contain a bounded
`diagnostic`. They do not claim a new saved baseline or active revision.
Storage conflicts leave the connection usable so the caller can `open` the
current snapshot. The implementation does not automatically retry a write
after a lost acknowledgement. A reconnect must read actual durable state.

## Execution and installation

The current runner loads one Guile resource defining `(workbench text)` and
expects a plain-text result. The authoring authority never evaluates it.
Preview has no live note-state or authoring-store grant. Native test composition
is explicitly named `--trusted-native-fixture`; it is not selected as a
fallback if sandbox execution fails.

A preview result is useful only after the runner has observed the correlated
Book Session reply and completed process cleanup. Output written to stdout,
stderr or a diagnostic PASS marker is not a result or an installation receipt.
A concurrent draft/activation change invalidates a completed preview for
activation purposes.

Sealing does not activate. Installation's transaction compares both the draft
version/source digest and activation epoch, including a competing save after
sealing. If activation conflicts, an immutable unactivated revision may remain
in the catalog. The active pointer is unchanged.
Export reads installed source, not the mutable draft or the SQLite files.
Rollback is independent of the draft's syntax and executability.

The catalog holds 128 revisions including the seed and sealed-but-unactivated
source. New-source activation at capacity returns `revision-quota-exhausted`.
Saving drafts, running/exporting installed source, rollback and activation of
already-sealed source remain available. There is no automatic pruning.

The installed revision is source selection for `run`, not a Guix system
generation. This prototype supplies no program-owned durable-state grant or
state migration: the note's existing database and grants remain separate.
