# book-reader — replayable KOReader offscreen integration probe

This host-only rung runs a trusted **test fixture** through the real pinned
KOReader desktop frontend. It turns the one-off investigation in
`doc/book-computer-reader-spike.md` into a replayable check without grafting a
plugin into the shipping package or device overlay.

```sh
KOREADER_BUNDLE=/gnu/store/...-koreader-bin-2026.03 \
  make -C pinenote/tools/book-reader check
```

With no override, `run-tests.sh` evaluates the native package derivation via
`guix repl` and `canonical-koreader-output.scm`. A fail-closed Guix build
handler rejects any attempted source or package realisation. The evaluated
output must already exist. An explicit `KOREADER_BUNDLE` that names that exact
output is package-pinned; any other v2026.03 bundle is clearly reported as a
compatibility run rather than package-pinned.

The ordinary gate also runs the TERM-resistant timeout-owner regression. The
review controls are separate because they replay multiple full UI sessions:

```sh
make -C pinenote/tools/book-reader mutation-check \
  KOREADER_BUNDLE=/gnu/store/...-koreader-bin-2026.03
```

## What executes

The runner creates a mode-0700 directory below `/tmp/opencode`, scopes `HOME`,
`KO_HOME`, XDG data/cache/config, and `TMPDIR` beneath it, copies
`fixture/bookreaderprobe.koplugin` into that temporary KO_HOME, and opens a
temporary text document. It launches the bundle's own LuaJIT and `reader.lua`
with `SDL_VIDEODRIVER=offscreen`. One supervised GNU `timeout --foreground`
owns the 20-second deadline and a two-second TERM-to-KILL escalation. The
supervisor and command are tracked by exact PID plus Linux start time; timeout
loss, runner signals, and every exit path use bounded exact-process cleanup.
No process-name match or shared path is used. The gate compares the fixture's
exact marker sequence, checks clean UIManager exit, asserts that the fixture
is absent from the packaged bundle, and removes the run directory. Set
`KEEP_ARTIFACTS=1` to retain that one scoped directory for diagnosis.

Before copying or executing the fixture, the runner evaluates the canonical
native output and derivation, verifies their relationship with
`guix gc --derivers`, and reads the bundle's one-line `git-rev`. Afterward it
requires exactly one anchored official startup version line before the first
fixture marker. A writable fixture therefore cannot forge package-pin
acceptance by printing another version line.

The fixture executes these real v2026.03 paths:

- PluginLoader discovery from temporary `KO_HOME/plugins`;
- `ReaderUI` and its `ReaderReady`/`CloseDocument` lifecycle;
- `ReaderHighlight:addToHighlightDialog()` and matching removal;
- an editable, displayed `InputDialog` and its generated, Trapper-wrapped
  Save button;
- accepted and rejected `save_callback` returns, including the resulting
  disabled/enabled Save-button state;
- `UIManager:insertZMQ()`/`processZMQs()`/`removeZMQ()` with a callback-style
  source;
- ReaderUI document teardown while a dialog and source are still active; and
- clean reader/UIManager teardown with `ui.document == nil`.

The small `interaction_source.lua` accepts only finite positive integral queue
limits. It processes at most one in-memory fixture message per UIManager poll,
and an explicit busy guard prevents `receive` from recursively re-entering
`waitEvent`. Error cleanup clears that guard before stopping and emptying the
queue. A pure test uses a recursive receive callback and malformed limits.

The full fixture independently instruments calls through both the public
UIManager insert/remove seams and the public ReaderHighlight add/remove seams.
For the observed action key, add/remove counts must be exactly one each; the
actual ReaderHighlight registry must also transition from the registered
factory to absence. It separately checks the real `_zeromqs` registry and
actual queue emptiness rather than trusting fixture markers or a drop counter.

Normal close, callback error, and active-document close each retain the closed
dialog reference and require `not UIManager:isWidgetShown(dialog)` against the
actual UIManager stack. Each path stops its source exactly once, and stale
`waitEvent` and enqueue attempts cannot invoke work. The active-document
scenario additionally proves ReaderUI clears its document and removes the
selection action.

## Evidence boundary

The “broker” is a local Lua callback with exactly two fixture outcomes. An
accepted callback means only that `InputDialog` followed its success branch;
it writes no durable state. Rejection means only that the dialog followed its
failure branch. The queued Lua tables are not a proposed wire schema.

The fixture is trusted test code loaded from a writable temporary KO_HOME.
That demonstrates upstream plugin loading; it is deliberately **not** the
production trust posture. `lint-fixture.sh` is only a lexical convenience
check for a short list of commonly spelled writer APIs. Alternate Lua
spellings can bypass it; it is not a parser, sandbox, runtime confinement, or
security proof. Source review found no arbitrary-path write in the fixture.
KOReader's expected profile/cache/sidecar writes are redirected below the run
directory, but this redirection does not constrain arbitrary trusted Lua.

Automation invokes the registered selection button factory directly; it does
not synthesize touch selection or prove highlight-menu layout. SDL/offscreen
does not exercise PineNote fbdev/evdev, e-ink refreshes or optics, suspend,
power, the future broker/framing/capability boundary, gVisor, durable `/data`
transactions, crash recovery, or QEMU service wiring.
