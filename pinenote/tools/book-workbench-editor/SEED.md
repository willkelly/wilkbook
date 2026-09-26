# Self-authoring editor child

## Runner contract (for integration)

From the checkout root, the sandbox argv is:

```sh
guile --no-auto-compile -L pinenote/tools/book-protocol \
  pinenote/tools/book-workbench-editor/workbench-editor-runner.scm --sandbox
```

The prepared sandbox supplies `/book/program.scm` as a read-only regular-file
snapshot and a connected Unix stream on FD 3, with `BOOK_SESSION_FD=3`.
Only the sandbox launcher supplies isolation; this interpreter is unrestricted
Scheme. There is no automatic native fallback.

Explicit trusted fixture argv (all paths absolute):

```text
GUILE --no-auto-compile -L BOOK_PROTOCOL_DIR RUNNER \
  --trusted-native-fixture SOURCE GUILE BOOK_PROTOCOL_DIR
```

Donate the connected socket on stdin. The adapter establishes its process group
and stops with SIGSTOP before source evaluation. The supervisor records the
group, continues it, and owns bounded observation/termination/reaping. The child
normalizes descriptors (socket becomes FD 3, stdin becomes `/dev/null`, descriptors
above 3 close) and execs the same interpreter with internal `--native-run SOURCE`.
This mode is for trusted test programs only. It offers no sandbox guarantees.

Dependencies: Guile 3, guile-json, `(book-protocol)` and its `(book-protocol
blocking-io)` helper; ordinary Guile standard modules. No workspace database,
delegate, surface, or old Workbench module is loaded by the adapter. The bounded
blocking helper's private `read-exactly` primitive is reused to retain raw JSON
for lexical integer checking before delivering decoded values.
Set `GUILE_LOAD_PATH=PROFILE/share/guile/site/3.0` and
`GUILE_LOAD_COMPILED_PATH=PROFILE/lib/guile/3.0/site-ccache` for the cached
supervisor profile below; its bare `bin/guile` does not discover guile-json
without those environment variables. The Python test supplies them by default.

`editor-seed.scm` is the entire authored program, bounded to 8192 UTF-8 bytes.
Entry: `(define (workbench-main receive! send! own-source) ...)`. The adapter
validates and reads the snapshot once, evaluates those bytes in the child, and
passes a separate string copy as `own-source`. Its fixed hello/initialize runs
first. `receive!` returns decoded bounded JSON objects (or EOF); `send!` validates
and frames JSON objects. Neither convenience grants host authority. All numeric
wire values in this contract use lexical JSON integers; decimal/exponent forms
are rejected before decoding can erase their spelling.

The host then supplies Workspace Protocol 1 ready, Editor Surface 1 ready (either
order), and the initial `editor-action` with reserved action id `open`. Workflow,
title, action list and meanings belong to source. Only one workspace operation
is pending. The source waits for its correlated reply before presenting again.
Editor `request_id`, `sequence`, and `surface_generation` are positive lexical
JSON integers (up to 2^53-1), matching `(editor-surface)`; workspace counters use
its separate 2^31-1 bound. The seed accepts increasing editor sequences, including
a fresh view whose host sequence did not reset, and echoes correlation exactly.

## Seed behavior and proof

Read loads the current draft. Save sends the text supplied by the editor action.
Preview and Request installation apply to the saved draft, with version and
activation CAS from the latest snapshot. Begin successor replaces the edit buffer
with `own-source`; Save then persists the complete program as a draft. Insert
header is a source-defined behavior seam. Export exports the installed immutable
revision, independently of the saved draft or unsaved edit buffer. Its bounded
status names the reply's `exported_revision` and leaves the editable source intact.
The export reply's `workspace_version` and `source_digest` describe the draft;
`exported_revision` identifies the artifact's installed source. Preview access enables only
read/save workspace operations; the broker separately enforces that restriction.
Installation is only proposed: host-owned confirmation remains outside source.
The seed's action IDs are `read`, `save`, `preview`, `install`, `successor`,
`insert-header`, and `export`; `open` is only the host's initial action. These
labels are source conventions, not adapter opcodes. The complete seed currently
remains below 8192 bytes, leaving room for the demonstrated successor edit.

Run the native socketpair tests with:

```sh
python3 pinenote/tools/book-workbench-editor/test-editor-runner.py
```

The default interpreter is the cached supervisor profile's `bin/guile` at
`/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor`;
override with `GUILE`. Tests use a fake host, actual child bytes and socketpairs.
They prove source-authored requests and successive executable programs, not
database durability, installation authority, sandbox isolation, or hardware.
The eight native tests also cover ready ordering, reduced preview access,
unsaved-edit refusal for preview/install, installed export with distinct saved
draft and unchanged edit buffer, cancellation and operation failures (including maximum
Unicode diagnostics), exact UTF-8 source boundaries, snapshot read-once behavior,
malformed/oversized/truncated frames, lexical integer aliases at nested and
top-level positions, outgoing frame budget, and clean EOF.
