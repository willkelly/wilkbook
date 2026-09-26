# Workspace Protocol 1 — integration API

This directory implements the transport-independent authoring authority. It uses
`(book-workspace)` for source storage and `(book-protocol)` for framing. It does
not launch an interpreter, create threads, or implement a reader surface.

## Host API (module `(workspace-delegate)`)

```scheme
(make-workspace-delegate owner store handle generation access preview)
;; OWNER: host-private identity, STORE: already opened fresh editor workspace.
;; HANDLE: trusted fresh opaque string; GENERATION: positive bounded integer.
;; ACCESS: 'author or 'preview. PREVIEW: (source snapshot cancelled?) -> result.
(workspace-delegate-announce! delegate) ; -> ready wire object, once only
(workspace-delegate-receive! delegate owner typed-request) ; -> 'queued
(workspace-delegate-take-task! delegate) ; -> opaque task or #f
(workspace-delegate-run-task! delegate task) ; -> opaque completion
(workspace-delegate-complete! delegate completion) ; -> wire reply or #f (stale)
(workspace-delegate-proposal delegate) ; -> host-private proposal or #f
(workspace-delegate-confirm! delegate owner proposal) ; -> 'queued
(workspace-delegate-cancel! delegate owner proposal) ; -> cancelled wire reply
(workspace-delegate-retire-view! delegate) ; cancel pending work/tickets, remain open
(workspace-delegate-close! delegate) ; idempotently revoke local lifetime
(workspace-delegate-phase delegate) ; ready/pending/running/confirming/retiring/closed
```

The caller supplies the retained owner object, never a wire actor identifier.
Use `eq?` identity, not a label, PID, or reconstructed value. One delegate owns
one retained store; no request selects a store, path, revision, or environment.
Construct fresh stores with an environment identity binding the distinct
`workbench-editor-v1` entry/runtime contract. Store ownership and final closing
remain with the composition root.

The session integration serializes receive/take/complete and output publication
with its endpoint lifetime. It runs `run-task!` outside its endpoint mutex. Only
one task may run; run each taken task exactly once and complete its result once.
The delegate also protects its transitions with its own mutex. No storage or
preview callback runs while that mutex is held. Announcement must be queued
successfully before admitting input; failure to publish it closes the endpoint.
An install proposal keeps the operation pending: its first completion returns
`#f` and publishes the private proposal. Only trusted UI code confirms/cancels.
Confirmation queues a second task; successful completion returns the installation
receipt. No sandbox message confirms installation.

Sealing and activation are **two transactions**, not one atomic operation.
Confirmation first commits an immutable revision with `workspace-seal!`, then
uses `workspace-activate-draft!` to compare the draft version/digest and activation
epoch in the pointer-update transaction. If that second transaction fails, the
sealed but uninstalled revision can remain and consume a retained quota slot.
The failed activation leaves the current draft and installation pointers/epoch
unchanged, including a competing draft committed after sealing. Reopening may
therefore recover both an unchanged installation and a new catalog entry.

Retire/close invalidate outstanding proposals, preview tickets, queued tasks,
and late completions. A backend transaction already in progress can commit;
retirement cannot undo a durable write. Inspect actual state on reconnect; never
blindly retry. Preview callbacks must observe cancellation and prove execution
cleanup before returning `((status . ok) (diagnostic . "..."))`. A successful
callback authorizes only the exact still-current draft/version/activation epoch.
The callback must use a disposable preview workspace with `access='preview`;
the live store/endpoint must not be donated to the candidate.

An executing/taken task stays in the slot after view retirement (`retiring`)
until its completion is consumed, preventing overlap with a replacement write.
Queued, untaken tasks are discarded immediately. A taken task run after
retirement returns a stale completion without doing backend work. The host
must still consume it to release the slot. Closing never waits for a callback;
the supervisor owns bounded callback cancellation/join and runtime cleanup.
Do not close the retained store while a task still uses it.

`workspace-proposal-snapshot` returns a defensive copy of the backend snapshot
(symbol keys, including source format, environment and seed revision);
`workspace-proposal-sequence` names the still-pending request. Keep the proposal
object itself host-private and use it for confirmation identity, not a decoded
copy. Cancel consumes the preview ticket and reports the proposal's captured
snapshot; it is not a fresh durable read. A fresh read is needed before another
CAS if another endpoint could have written in the meantime.

## Wire

Use ordinary Book Protocol frames (four-byte length + UTF-8 JSON object). The
ordinary hello/initialize contract is unchanged. After initialization queue the
object returned by `announce!`. Raw inbound bytes MUST go through
`decode-workspace-payload` or `decode-workspace-frame` from
`(workspace-protocol)`; they return an opaque typed request with copied fields.
`workspace-request-type`, `workspace-request-sequence`, and
`workspace-request-field` inspect it. `encode-workspace-request` is the sandbox
helper for a typed request; trusted fixture callers may construct one with
`make-workspace-request` from an exact request object.

All requests have exactly `type`, `protocol_version=1`, `grant_handle`,
`grant_generation`, `operation_sequence`, plus:

| Type | Extra fields |
| --- | --- |
| `workspace-read` | none |
| `workspace-save` | `expected_version`, `source` |
| `workspace-preview` | `expected_version` |
| `workspace-install-propose` | `expected_version`, `expected_activation` |
| `workspace-export` | none |

Sequences start at 1 and advance for each accepted request, including an
operation that later fails. Rejected schema/owner/grant/sequence/busy requests
do not consume one. Only one operation is pending. Sequence exhaustion requires
a new endpoint. Sequence 2147483647 is accepted once and completes normally.
After it completes, another otherwise valid authorized request reports
`sequence-exhausted` before sequence equality is checked, including a repeat of
2147483647 or an older sequence. No durable operation-ID/retry protocol is supplied.

Version/CAS/sequence/grant numbers require lexical JSON integers, excluding
decimal/exponent aliases even when the generic decoder rounds them to an exact
integer. Counters are 0..2147483647, sequence/grant generation 1..2147483647.
Handles are 1..128 UTF-8 bytes without NUL. Source is 0..8192 UTF-8 bytes without
NUL; an empty draft is savable even though it need not execute.

Ready has exactly `type="workspace-ready"`, `protocol_version=1`,
`grant_handle`, `grant_generation`, `access="author"|"preview"`,
`max_source_bytes=8192`, `max_pending_operations=1`.

Every response has `type`, `protocol_version=1`, `operation_sequence`, plus:

| Type | Extra fields |
| --- | --- |
| `workspace-snapshot` / `workspace-saved` | `snapshot` |
| `workspace-previewed` | `workspace_version`, `source_digest`, `activation_generation`, `diagnostic` |
| `workspace-install-result` | `outcome="installed"|"cancelled"`, `snapshot` |
| `workspace-exported` | `workspace_version`, `source_digest`, `activation_generation`, `exported_revision`, `artifact` |
| `workspace-failed` | `operation`, `code`, `diagnostic` |

Snapshot has exactly `workspace_version`, `source`, `source_digest`,
`active_revision`, `previous_revision` (digest or false), `activation_generation`.
In an export response, `workspace_version` and `source_digest` describe the
captured **draft**. `exported_revision` is the captured **active revision**, the
immutable source actually exported; the decoded artifact's `revision` must
equal it. These digests can differ when the draft is uninstalled or broken.
Export neither seals the draft nor consumes a revision slot. The captured
`activation_generation` identifies the installation snapshot used to select the
export, not a guarantee that another endpoint has not since changed activation.
Diagnostics are bounded to 512 Unicode scalars, without NUL (at most 2048 bytes).
Do not repeat source snapshots alongside export. Reserve one full maximum frame
(65540 bytes including header) before accepting work; a source snapshot can
exceed the state extension's smaller response reservation.

Preview access allows read/save only. Recursive preview, installation proposal,
and export return `workspace-failed` with code `access-denied`. Malformed or
unauthorized requests throw `workspace-protocol-error` or
`workspace-delegate-error`; the transport owner decides its connection policy.
Operational failures return correlated responses and leave the delegate usable.

Trusted rollback and seed recovery use existing `workspace-rollback!` and
`workspace-activate!` with the retained store's `seed-revision` and epoch CAS.
They must retire the editor view first. Neither operation depends on executing
the draft or rewinds the independent note state. No sandbox rollback API exists.
Wait for a retired worker's cleanup/completion before starting recovery.

## Tests (cached native profile; no dependency builds)

The two suites use real Book Protocol bytes and SQLite, with explicit
take/run/complete schedules and a cancellation-aware injected preview fixture.
They do not execute source or establish sandbox cleanup. The preferred cached
native supervisor profile for the review rerun is
`/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor`
(Guile, JSON, gcrypt, SQLite).
From the repository root:

```sh
profile=/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor
export GUILE_AUTO_COMPILE=0
export GUILE_LOAD_PATH="$profile/share/guile/site/3.0"
export GUILE_LOAD_COMPILED_PATH="$profile/lib/guile/3.0/site-ccache"
for test in test-workspace-protocol.scm test-workspace-delegate.scm; do
    "$profile/bin/guile" --no-auto-compile \
      -L pinenote/tools/book-workbench-editor \
      -L pinenote/tools/book-workbench -L pinenote/tools/book-protocol \
      "pinenote/tools/book-workbench-editor/$test"
done
```

Each test exits nonzero on an assertion failure. SQLite fixtures live in newly
created private directories under `/tmp/opencode`; no reader or note store is
opened. The profile is an explicit reusable test input, not an ambient/runtime
fallback or a new Guix derivation claim.
