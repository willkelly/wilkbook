# Generic editor surface v1

This directory's surface module and renderer implement forms, not workspace
operations. Authored action IDs such as `save`, `preview`, `install`, and
`host_close` have no special renderer behavior. Only the reserved initial action
`open` has a protocol meaning. The workspace delegate and native process join
are separate components. No existing Workbench or BookSession module is changed.

## Public Book Protocol

All messages use the existing `(book-protocol)` four-byte big-endian length +
JSON frame (64 KiB payload maximum). JSON objects are closed: all listed keys
are required, extra and duplicate keys fail, including escaped duplicates.
Arrays must be JSON arrays, not objects. All numeric fields must have **raw
lexical integer** spelling; `1.0`, `1e0`, and underflowing exponents fail even
when a JSON decoder would round them to integers. Positive counters are bounded
by `9007199254740991`. Text limits count UTF-8 bytes; NUL is forbidden in every
string. JSON escaping may make a maximum-sized field exceed the aggregate frame
limit; both the field limits and the frame limit apply.

Host → book, when the host starts a new view:

```json
{"type":"editor-ready","protocol_version":1,"surface_handle":"opaque-host-value","surface_generation":1,"max_text_bytes":8192,"max_actions":8}
```

The handle is host-generated, nonempty, at most 128 UTF-8 bytes, and opaque to
the book. The book cannot select or renew it. Every new view increments the
generation, clears the accepted form and invalidates its outstanding action.

Host → book, from a trusted UI event:

```json
{"type":"editor-action","protocol_version":1,"request_id":1,"action_id":"open","surface_handle":"opaque-host-value","surface_generation":1,"sequence":1,"text":""}
```

`request_id` and `sequence` are host-owned, positive, strictly increasing across
views for the endpoint's lifetime. This implementation allocates both from one
counter. Text is 0–8192 bytes. Initial `open` is the only action allowed before
a presentation; subsequently only IDs enabled in the **last accepted** form
are allowed. Exactly one action is pending. A failed initial open may be retried.

Book → host:

```json
{"type":"editor-present","protocol_version":1,"request_id":1,"action_id":"open","surface_handle":"opaque-host-value","surface_generation":1,"sequence":1,"title":"My editor","text":"","status":"Ready","actions":[{"id":"commit-draft","label":"Keep this draft","enabled":true}]}
```

All six identity fields (`protocol_version`, `request_id`, `action_id`,
`surface_handle`, `surface_generation`, `sequence`) must exactly echo the pending
action. `title` is 0–128 bytes, `text` 0–8192, `status` 0–2048. `actions` contains
0–8 exact `{id,label,enabled}` objects. IDs match `[A-Za-z0-9_-]{1,64}`, are unique,
and cannot be `open`. Labels are 1–128 bytes. `enabled` is a JSON boolean. An empty
action vector is valid. Malformed or mismatched responses make no state change;
the authority decides whether to terminate the book after a protocol violation.

### Scheme API: `(editor-surface)`

Add this directory and `../book-protocol` to Guile's module path, with guile-json.

* `(make-editor-message alist)` validates and returns an opaque typed message.
  Object keys are strings, arrays Scheme vectors. Constructors and accessors
  defensively copy strings, alists and vectors.
* `editor-message?`, `(editor-message-type message)`,
  `(editor-message-ref message "key")`, `(editor-message->object message)`.
* `(encode-editor-message message)` → framed bytevector.
* `(decode-editor-frame bytes direction)` and
  `(decode-editor-payload bytes direction)` → typed message. Direction is
  `authority-to-book` or `book-to-authority`. The latter admits only presentations.
  Always use these raw-byte decoders at the book boundary; constructing from an
  already-decoded JSON object cannot prove numeric token spelling.
* `(make-editor-surface host-generated-handle)` → closed surface at generation 0.
* `(editor-surface-new-view! surface)` → ready message; invalidates pending/form.
* `(editor-surface-action! surface authored-id text)` → pending action message.
* `(editor-surface-present! surface decoded-message)` → accepted message.
* `(editor-surface-fail! surface exact-pending-record)` retires only that action,
  restoring `idle` with the previous form, or `initial` without a form.
* `(editor-surface-close! surface)` invalidates pending and form; reopening must
  call `new-view!`. Counters do not reset.
* `editor-surface?`, `editor-surface-phase` (`closed`, `initial`, `pending`, `idle`),
  `editor-surface-generation`, `editor-surface-pending`, `editor-surface-form`.
* Constants: `editor-protocol-version`, `max-editor-text-bytes`, `max-editor-actions`.

Schema/FSM errors throw `editor-surface-error`; underlying framing/JSON errors
retain `book-protocol-error`. The FSM performs no I/O, UI calls or workspace work.

## Private UI join v1

The launcher donates **one connected AF_UNIX/SOCK_STREAM descriptor** through
`BOOK_WORKBENCH_EDITOR_UI_FD`. It is not a pathname, listener or authored
capability. The plugin validates/protects it with nonblocking and CLOEXEC flags
before loading widgets and adopts it once. Only the trusted authority may write
replies; the book never receives this descriptor. The join must validate UI
commands as strictly as the documented schema and apply its own endpoint/view
and confirmation-token checks.

Framing intentionally follows the native Workbench transport shape, with an
independent schema:

```text
command|UI_SEQUENCE|LOWERCASE_HEX_UTF8_JSON\n
reply|UI_SEQUENCE|LOWERCASE_HEX_UTF8_JSON\n
```

`UI_SEQUENCE` is canonical decimal 1–2147483647, strictly increasing for **every**
UI command, including fire-and-forget `close`. It is a transport request ID,
distinct from the book's host sequence. Replies echo it exactly. JSON payloads
are at most 65536 bytes; lines at most 131104 bytes excluding newline. The Lua
codec rejects duplicate keys, noninteger scalar tokens, extra fields, invalid
UTF-8, unsupported arrays, and nesting beyond five containers. Arrays occur
only in `form.actions`. No `loadstring`, evaluation, or source loading is used
to decode messages.

### UI → authority payloads

| `op` | Exact additional fields | Meaning |
|---|---|---|
| `hello` | `protocol_version: 1` | Negotiate; idempotent on this donated connection. |
| `open` | `view`, `text` | Create fresh host surface generation and dispatch initial `open`; text is current visible draft. |
| `action` | `view`, `surface_handle`, `surface_generation`, `action_id`, `text` | Dispatch one enabled authored action with the visible text. |
| `close` | `view` | Retire that view, pending work and confirmation token. **No reply.** Keep the donated endpoint available for later opens. |
| `decision` | `view`, `token`, `accept` | Trusted confirmation response; `accept` is a JSON boolean. |
| `preview-action` | `view`, `token`, `surface_handle`, `surface_generation`, `action_id`, `text` | Dispatch an enabled candidate action, with its candidate view/token and visible candidate draft. |
| `preview-finish` | `view`, `token`, `accept` | Trusted Finish/Cancel preview. Cancel can supersede a pending candidate action; Finish requires an idle accepted form. |

`view` is a UI-owned positive integer ≤2147483647, increasing on every open or
rotation. `text` is 0–8192 bytes. Handle/action constraints match the public
schema; UI `action` cannot use reserved `open`. `token` is host-generated,
nonempty, at most 128 bytes, bound to the pending action, view and workspace
proposal by the authority. `hello` is allowed again if an earlier handshake was
retired by Close/rotation. `open` supersedes earlier view work; transport work
may still finish, but cannot supply the new view's presentation. The join must
retire old UI callbacks even if workspace effects already completed.

### Authority → UI payloads

| `op` | Exact additional fields | Correlation |
|---|---|---|
| `ready` | `protocol_version:1`, `max_text_bytes:8192`, `max_actions:8` | Reply to `hello`. |
| `present` | `view`, `form` | `form` is the complete, already FSM-accepted `editor-present` object. Reply to `open`, `action`, or the corresponding `decision`. |
| `failure` | `view`, `error` | Correlated terminal failure; error is 0–2048 bytes. Visible draft is retained. |
| `confirmation` | `view`, `token`, `kind`, `summary` | Reply to `action` only; `kind` is exactly `install` or `recovery`, summary 0–2048 bytes. |
| `preview` | `view`, `preview_view`, `token`, `form` | Initial reply to the author's action, then replies to candidate actions. The initial `view` is the author view; later replies use the distinct `preview_view`. |
| `preview-failure` | `view`, `token`, `error` | Candidate action failed; its execution and disposable store have been cleaned up. Retain the visible candidate draft until Cancel. |

A `confirmation` consumes the UI action's transport pending slot, but the
authority retains the original book action while awaiting `decision`. The
terminal `present` after a decision echoes that **original book action**;
its outer UI sequence echoes the decision command. No second book action is
invented. Cancel may produce `failure`, or the original action's presentation
after the delegate handles the rejection. Confirmation tokens are single-use,
and cannot survive new views, Close, EOF, or changes to the underlying proposal.
Do not forward an authored `editor-present` as `confirmation` based on an action
ID or label. The workspace authority triggers trusted confirmation explicitly.

### Interactive disposable preview

An initial `preview` consumes the author action's private transport request,
while the authority retains that original action and its workspace operation.
The host assigns a fresh candidate `preview_view` and opaque single-use token.
Every candidate command must match both. Its surface handle, generation and
action correlations belong to a separate authority and a separate temporary
SQLite workspace with **preview access**. Candidate Read/Save operate there;
recursive preview, installation and export receive `access-denied`, regardless
of authored labels or enabled buttons. No live author store is donated.

The candidate uses a separate editable InputDialog and separate `edit_serial`,
form counters and draft retention. Its measured title begins with the trusted
**Disposable preview — changes are discarded** heading, above the authored
title. Its final button row contains trusted **Finish preview** and **Cancel
preview** controls. Authored buttons retain positional `authored_N` IDs. The
author widget remains retained underneath with its actions disabled. Native
Back cancels the candidate. A stale candidate widget, Finish/Cancel callback,
action token or view cannot act on a later candidate or close the author.
Retired preview-token/view commands and stale Close commands are ignored without
a reply, preserving the current request slot and execution lifetime.

Finish/Cancel first revokes and cleans the candidate execution and authority,
then deletes its disposable filesystem, **before** reporting a preview result
to the live workspace delegate. A cleanup failure propagates `CleanupError`,
retains the runtime root and issues no preview ticket. Success authorizes only
the original saved source, not any disposable candidate edits. A failed/cancelled
preview authorizes no installation. The eventual `present` uses the **author
view and original author action's surface/action identity**, and the private
sequence of `preview-finish`. The plugin retains the original author action's
edit serial across this continuation, so neither candidate replies nor Finish
can overwrite later author edits. Cancel retires a candidate's pending private
request; any late reply to that request is ignored.

One authored action may perform several sequential workspace operations: for
example preview, installation proposal, then another preview before its final
presentation. Every continuation retains the original author action and edit
serial. These are author operations; candidate grants still deny recursive
preview and installation.

Candidate errors after opening clean up immediately. If no private request is
pending, the plugin learns the error on the next action (idle does not poll);
Finish in that state returns a failed preview rather than a successful ticket.
An error before the initial preview is displayed resumes the author directly.
Closing/reopening the author or EOF retires both candidate and author work.

The live author action clock is paused throughout preview. Candidate startup
and actions keep independent clocks; human idle has no action deadline. The
authority worker blocked on preview completion does not trigger the 10 ms work
poll. Native startup defaults to 3 seconds; sandbox startup to 20 seconds;
actions default to 10 seconds and may be explicitly configured by trusted tests.
Synchronous authority send/receive and child-output waits are capped by the
remaining active clock. A timed-out or interrupted authority exchange retires
that channel permanently so a late reply cannot satisfy a later RPC. A fresh
`EditorSession` is required to reopen it. Transactions already committed remain
committed; retiring the channel does not claim to undo them.
The UI bridge handles this terminal backend state locally: later actions/Open
fail without another authority RPC, Close retires the view, and the reader keeps
the editable local draft. A UI Close/Open does not resurrect the backend.
The coordinator's idle socket wait remains bounded by the reader-exit observation
interval. This is scheduling behavior, not a device power measurement.

`EditorSession(..., preview_mode="interactive", sandbox_command=None)` defaults
to interactive preview. Trusted direct coordinators inspect `session.preview`,
invoke its `action(id, text)`, and call `session.finish_preview(True/False)`.
Legacy startup-smoke tests explicitly select `preview_mode="smoke"`; neither
native nor sandbox UI launch selects smoke mode.

### Trusted sandbox owner launch

`native-editor.py` accepts exactly one of `--trusted-native-fixture` or
`--sandbox-command PATH`. The latter requires an immutable, executable, canonical
regular file under `/gnu/store`, with no native fallback. Its exact selection is
inherited by every candidate; a prefixed SHA-256 of its canonical command path
forms the workspace ABI identity (92 ASCII characters), distinct from a
trusted-native workspace. The immutable command captures the execution closure.

Owner argv is `[sandbox_command, control_fd, source_file]`; stdin is the donated
book socket. Only the control descriptor is passed besides standard descriptors;
stdout/stderr go to `/dev/null`. The owner runs in its own session and supplies
`ready\n` after validating launch controls. No child hello or source frame reaches
the authority before that record. Control framing is bounded to 32 bytes and
retains an early/coalesced `ready\nclean\n`. The parent sends `stop\n`; control EOF
also requests owner cleanup. Exact `clean\n` proves complete domain/filesystem
cleanup and precedes owner reaping. Sandbox cleanup observation allows 12 seconds
(owner cleanup may take 10); the native owner retains its 3-second bound. A
missing/invalid acknowledgement is a cleanup failure, not a source rejection.
The sandbox authority uses the private `--workspace-authority` entrypoint.

After `clean`, the coordinator also consumes the owner's exit status. Zero means
execution succeeded and cleanup completed; nonzero is a contained execution
failure when cleanup is proved. Finish checks this terminal verdict after close,
including a failure first observed during shutdown, before authorizing preview
success. A bounded, private `SOURCE_FILE.sandbox-error` sidecar is read only
after owner exit, as diagnostic data. Its absence is not proof of success.

The UI additionally checks current view, fresh generation on open, matching
surface/action on action and decision responses, and monotonic accepted book
request/sequence values. Full six-field book correlation is the Scheme FSM's
responsibility, before a private reply is constructed.

## Renderer behavior and integration seams

`main.lua` is a KOReader `WidgetContainer` plugin named `bookworkbencheditor`.
It registers **Book editor (experimental)** in the main menu. It uses native
`InputDialog` with authored buttons in rows of two, a trusted Close button, and
native navigation/rotation. No native `save_callback` is installed. Native
widget IDs are positional (`authored_1` … `authored_8`), so authored IDs cannot
collide with trusted chrome. Text is never run as Lua.

Each accepted form replaces the action vector and title, and displays nonempty
status through a native `InfoMessage`. With no intervening edit, its text may
replace the submitted text (authored transformations work). Any intervening
edit, including edit-away-and-back, prevents replacement. A retained draft is
also preserved through rotation and Close/reopen; only a subsequent accepted
action without intervening edits resolves it. Native `InputDialog:reinit()`
preserves text, cursor/scroll and keyboard state while rebuilding buttons;
initialization's repeated edit notifications are suppressed. Old view/button
and confirmation callbacks are retired by identity, not just button disabling.
The displayed title, including waiting/failure/disconnection text, is installed
**before** native `InputDialog:init()` measures its height. A changed title
reinitializes the whole layout; identical control updates do not rebuild it.
There is no post-layout `TitleBar:setTitle()` mutation that could leave stale
parent offsets. Both the trusted Close button and native Back/Escape close only
their originating widget and view. A Close callback retained from a loading or
closed editor cannot close a later editor.

The native join/real-widget runner can call `_open()`, `_action(id)`,
`_new_view()`, `_closed(dialog)`, and `onCloseDocument()` to exercise lifecycle;
these are plugin implementation hooks, not book capabilities. `editor_dialog`, `form`,
`pending`, `channel`, `view`, `sequence`, `retained_text` expose inspection state.
`editor_dialog` is the plugin's editable InputDialog. KOReader's injected `dialog`
field remains the native ReaderUI/FileManager owner throughout open, Close,
reopen, and teardown; the plugin must never replace or clear it.
`editor_channel.lua` exports `prepareFD(fd)` and
`Channel:new{fd,receive,on_error,on_progress}`;
instances support `send(ui_sequence,payload)`, `waitEvent()`, `stop()`. The channel
calls optional `on_progress()` after a successful poll so the owner can drop
its poll registration when queued output drains.
is a UIManager ZMQ poll-source adapter, not a ZMQ socket. `editor_codec.lua`
exports `encodeCommand`, `parseReply`, `validCommand`, `validReply`, `validForm`,
`validText`, `MAX_SEQUENCE`, `MAX_LINE`.

Optional trusted callback seam:

```lua
plugin.host_confirmation = function(kind, summary, accept, cancel)
    -- Present trusted native chrome, then invoke exactly one callback.
    -- Callback identities automatically expire on edit/view change/Close.
end
```

Without it, host messages create native Install/Cancel or Recover/Cancel boxes.
Editing during confirmation cancels it. Late confirmation arriving after an
edit is declined automatically. Decisions retain the original action's edit
serial, so a reply cannot overwrite edits made while confirmation was visible.

I/O work per poll is bounded to 16 KiB read/write and one reply. Output is bounded
to four frames; a pending request has a 60-second deadline (including sandbox
startup, disposal and author continuation). Polling is registered
only while a reply or queued output is pending. An idle editor, including one
waiting for human confirmation or interacting with an idle candidate, has no
poll registration or request deadline;
every new request/decision registers again. This avoids UIManager's otherwise
forced 20 Hz wakeup. The tradeoff is that EOF while idle is discovered on the
next operation, when sending or polling resumes. The local draft remains intact;
the UI cannot treat a pending confirmation as successful without a reply.
Close removes the
poll source and deadline immediately. Its small fire-and-forget close frame is
flushed once; if backpressure leaves bytes queued, the endpoint is closed and
EOF retires the host view. Local text remains available. No closed-dialog
polling is retained to wait for a response. Later open on a live endpoint drains
and ignores retired replies before accepting its own response. No reconnect or
donated numeric-FD reuse is attempted after disconnect.

## Offline checks

From the repository root, with guile-json on the load path:

```sh
guile --no-auto-compile -L pinenote/tools/book-protocol \
  -L pinenote/tools/book-workbench-editor \
  pinenote/tools/book-workbench-editor/test-editor-surface.scm

/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03/lib/koreader/luajit \
  pinenote/tools/book-workbench-editor/test-plugin.lua \
  pinenote/tools/book-workbench-editor/plugin/bookworkbencheditor.koplugin
```

The Lua suite uses the bundle's actual rapidjson and real Unix socketpairs;
widgets are mocks. Native process-join and real-widget integration are separate
parent-runner gates. These tests make no hardware, packaging, or backend claim.
