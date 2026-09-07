# Persistent-note KOReader fixture

This host-only slice is a usable editable `InputDialog` for one persistent text
value. Lua owns the widget and paint lifecycle. A trusted Guile authority owns
load and commit decisions. The fixture is copied into a temporary KOReader home;
it is not installed as a shipping plugin and it never speaks Book Protocol JSON.

## Run it offline

The default test runs the repository-pinned KOReader v2026.03 with SDL's
offscreen backend:

```sh
cd pinenote/tools/book-state-reader
./run-tests.sh /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

`make check KOREADER_BUNDLE=/gnu/store/...-koreader-bin-2026.03` is equivalent.
`SHA256SUMS` seals every source, fixture, runner, and contract file in this
review packet; `run-tests.sh` verifies it before evaluation or execution.
It evaluates the canonical derivation without realizing anything, then uses the
already-present bundle. It performs no QEMU, runsc, ARM, image, mount, network,
or device operation. The finite owner is the accepted
`../book-reader/timeout-owner.sh`; PID plus Linux start-time records cover both
the Guile host and KOReader child.

If an SDL display backend is available, an operator can edit arbitrary text:

```sh
./run-interactive.sh /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

No expected state is accepted on that command line or through the environment.
State is authority-owned and lasts for that interactive host process. After
closing the dialog, select text and use **Open persistent note fixture** to
exercise a fresh load. This optional mode is not part of `check`.

## Exact private UI contract

Transport is one connected full-duplex FD donated to KOReader as FD 3. Every
frame is exactly:

```text
kind|generation|lowercase-hex-of-UTF8\n
```

The successor codec in `private-control.scm` / `state_channel.lua` preserves the
accepted bounded framing: generation `1..1000000`, value at most 4096 UTF-8
bytes, line at most 8224 bytes excluding LF, eight queued frames, and bounded
nonblocking pumps. The command and event sets are closed:

```text
authority -> Lua:
  open load-absent load-value edit save commit-ok commit-failed present
  navigate close finish

Lua -> authority:
  channel-ready ready status submit applied ignored navigated closed done
```

`open`, `load-absent`, `save`, `navigate`, `close`, and `finish` carry empty
values. `load-value`, `edit`, `commit-ok`, `present`, `submit`, and `applied`
carry note text. `commit-failed` carries exactly one of
`receipt-quota-exhausted`, `read-only`, `storage-failure`, or `conflict`.
`status` carries exactly one of `loaded-absent`, `loaded-value`, `dirty`,
`pending`, `saved`, or `failed`. `ignored` carries the rejected command kind;
`ready`, `navigated`, and `closed` are empty; `done` is `ok`.

Generation is the interaction lifecycle, not a storage version. `open N` is
accepted only when no dialog is active and N is the exact successor. All other
commands except `finish` must match the active generation. Navigation or close
synchronously invalidates that generation and closes the exact widget. A late
old-generation command yields `ignored` and cannot alter a later dialog.

`edit` is test automation for `InputDialog:setInputText(..., true)`. `save`
invokes the Save button KOReader generated for the real `save_callback`; it is
not a second submission API. While `pending`, Save is disabled and duplicate
`save` yields `ignored`. An operator types and taps the same real widget instead.

### Authority mapping

The later native/QEMU join needs only this typed mapping on the trusted side:

| Guile/Book State fact | private UI command | Lua consequence |
|---|---|---|
| Absent `state-value` | `load-absent` | Empty editable widget; `loaded-absent` |
| Present `state-value` (including empty) | `load-value TEXT` | Exact editable text; `loaded-value` |
| Save callback | `submit TEXT` event | Guile issues the one Book Protocol `state-commit` |
| Durable `state-committed` receipt | `commit-ok TEXT` | Matching pending draft may become `saved` |
| Conflict/failure | `commit-failed CODE` | `failed`; exact draft stays editable |
| Optional surface presentation after receipt | `present TEXT` | Repaint same authority text |
| Inherited topmost `InputDialog:paintTo` observed | `applied TEXT` event | Paint fact only |

`commit-ok` is the **only** input that can produce `saved`. `load-*` can paint
without any Save. `present` and `applied` never imply a storage commit. Thus the
three facts remain ordered and distinct: durable Guile receipt, optional surface
presentation, and inherited Lua paint acknowledgement.

The private channel intentionally carries no operation ID, state version,
grant, namespace, path, JSON, or arbitrary method name. Those stay in the Guile
Book Protocol/state endpoint. One pending operation and the interaction
generation are sufficient at this UI boundary.

The durable backend accepts U+0000, but this ordinary text-widget fixture does
not claim arbitrary NUL rendering. Its private UI codec rejects U+0000 while
accepting ordinary multilingual UTF-8 through the exact 4096-byte limit.

## Automated evidence

The real pinned widget test covers:

- authority-loaded absent, explicitly present-empty, and multilingual nonempty
  state before any Save;
- actual widget editing and exact Save callback submission;
- visible dirty, pending, failed, and saved titles through inherited topmost
  `paintTo` observations;
- one storage failure with the draft retained and resubmitted unchanged;
- disabled duplicate Save with no duplicate submission;
- durable commit confirmation before a separate `present` / `applied` paint;
- navigation and close invalidation, late receipt/presentation/load rejection,
  and fresh-generation reopen from authority state;
- exact action removal, every dialog closed, private source removal, FD `EBADF`,
  and no stale callback after cleanup.

The scripted Guile host is intentionally an in-memory authority oracle for this
UI packet. It does not duplicate the real backend, protocol adapter, or native
Book Session join under development in `../book-state-integration/`. Loaded and
recovered values reach Lua only over FD 3—never via expected-result environment,
CLI arguments, fixture source constants, or direct filesystem reads. There is
no display-latency or physical-panel claim.
