# Book computer: KOReader integration spike

Status: independently accepted replayable desktop/offscreen KOReader seam,
2026-09-04. This is an offline feasibility record for the exact trusted fixture,
not a shipping interface, Book Protocol, durable-state result, or hardware
validation. The final appended disposition in
`reviews/2026-09-04-book-reader-adversarial.md` closes BR-1 through BR-5 and
accepts that narrow gate; earlier blocked dispositions remain historical.

Architecture context:
[self-hosting book computer](wilkbook-self-hosting-book-computer.md),
especially sections 3, 4, 7, and 9. The purpose of this note is to replace
the architecture draft's “recheck the pinned implementation” caveat with
facts about the KOReader release this tree actually packages. It does not
choose the Book Protocol schema, broker transport, launcher, sandbox, or
durable-state schema.

Current cross-cutting protocol, acknowledgement, and candidate status:
[Book computer protocol and state reference](book-computer-protocols.md).
The later fixed sandbox-to-KOReader result is recorded separately in the
[Book computer demonstration](book-computer-demo.md).

## Result

The first reader slice does not need a KOReader fork or a new native API.
The pinned bundle has enough existing Lua seams for one narrow, trusted
bridge to:

1. add one action to the text-selection dialog;
2. open a host-rendered editor or form;
3. receive bounded asynchronous broker work on KOReader's UI loop; and
4. optionally paint through one reader view module when the first attached
   interaction actually needs persistent page decoration.

Start with **attached interaction**: selecting text opens an
`InputDialog`/`MultiInputDialog`. Do not make live insertion into crengine
layout, arbitrary custom surfaces, or one plugin per tool-book prerequisites
for the first end-to-end value edit.

The bridge should be one immutable plugin grafted into the packaged bundle,
following the repository's `idlewasher.koplugin` precedent. KOReader also
loads writable plugins from its data directory; that is useful for an
explicit developer experiment, but it is not a trust boundary and must not
be the production home of a bridge with broker authority.

No plugin was grafted into the package or PineNote device overlay in this
spike. The replayable probe uses a clearly labeled fixture under
`pinenote/tools/book-reader/` and copies it into a temporary KO_HOME.

### Later fixtures are separate layers

This note's `book-reader` fixture proves the generic KOReader action, widget,
polling, generation, and teardown seams. The later accepted
`pinenote/tools/book-interaction/` fixture connects those seams to the ordinary
Book Session and uses a private lowercase-hex UI channel for transient results.
The accepted QEMU demonstration then carries that same private channel over
virtio serial while sandboxed books use Book Protocol on separate sockets.

The newer `pinenote/tools/book-state-reader/` fixture is an **independently
accepted persistent-note native-UI successor**, not a revision of Book Protocol
and not a shipping plugin. Its exact packet-manifest SHA-256 is
`a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab`;
the accepting review is
[`reviews/2026-09-06-book-state-reader-adversarial.md`](reviews/2026-09-06-book-state-reader-adversarial.md),
SHA-256
`56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301`.
It has a different closed private vocabulary for load, edit, save,
conflict/failure, `commit-ok`, presentation, paint, navigation, and close. Its
scripted Guile authority is in memory: five UI generations in one Guile process
and one real packaged KOReader process prove widget state, inherited offscreen
paint, generation, and cleanup behavior—not fresh processes, SQLite durability,
QEMU/runsc/ARM, operator interaction, or physical rendering. The durable join
must receive a trusted typed backend completion before it sends private
`commit-ok`; a later book `present` or Lua `applied` cannot serve as that receipt
observer. That observer is an active separate candidate, not part of either
accepted reader fixture.

## Exact packaged/runtime baseline

- `pinenote/packages/koreader.scm` pins `%koreader-version` to `2026.03`.
  It selects and hashes separate upstream `linux-x86_64` and `linux-arm64`
  release tarballs. This is a prebuilt upstream bundle, not a source-built
  KOReader.
- The package copies `pinenote/packages/koreader-device/` into
  `$out/lib/koreader` and inserts the PineNote probe before upstream's SDL
  fallback. The same graft already supplies the trusted
  `plugins/idlewasher.koplugin`.
- `pinenote/services/reader-session.scm` runs the bundle's own `luajit`
  directly on `reader.lua`, with the bundle as its working directory,
  `HOME=/root`, and `KO_HOME=/root/.config/koreader`. On the PineNote this
  selects the repository's native fbdev/evdev device path, not SDL.
- Source inspection and the replayable run used the native output
  `/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`.
  The relevant paths below are relative to its `lib/koreader/`; they are
  upstream v2026.03 files except for the explicitly named repository graft.

This packaging distinction is important: adding a Lua plugin to
`pinenote/packages/koreader-device/plugins/` follows an existing build path.
Changing crengine or another bundled native library would be a different
packaging commitment.

## Verified reader seams

### Selection action

`frontend/apps/reader/modules/readerhighlight.lua` provides:

```lua
ReaderHighlight:addToHighlightDialog(idx, fn_button)
ReaderHighlight:removeFromHighlightDialog(idx)
```

`fn_button` receives the `ReaderHighlight` instance and the current
highlight index, and returns an ordinary KOReader button description. The
menu is assembled with `ffiUtil.orderedPairs`, so the registration key gives
deterministic placement. The matching removal method returns the prior
callback.

This is the smallest verified entry point for “run an action on this
selection.” Register one generic Wilkbook action after `ReaderReady`, and
remove it during teardown. Do not add exercise-specific actions or schemas
to the trusted plugin.

### Host-rendered editor and form

`frontend/ui/widget/inputdialog.lua` already supports:

- editable or read-only text;
- multiline and full-screen modes;
- save, reset, close, and edited callbacks;
- visible validation/save failure messages; and
- the existing KOReader keyboard and focus path.

`frontend/ui/widget/multiinputdialog.lua` supplies the corresponding generic
multi-field form. Upstream's
`plugins/perceptionexpander.koplugin/main.lua` is a concrete reader plugin
that combines `onReaderReady`, `MultiInputDialog`, `UIManager:show`,
`ReaderView:registerViewModule`, `resetLayout`, and `paintTo`.

The upstream `texteditor.koplugin` is useful widget/lifecycle evidence, not
the storage design to copy: its save path ultimately calls
`util.writeToFile` on a selected host path. A book-computer editor should
submit a broker/workspace transaction instead. It must not turn a sandbox
filename into a host path or block the UI thread waiting on broker I/O.

### Optional page painting

`frontend/apps/reader/modules/readerview.lua` provides:

```lua
ReaderView:registerViewModule(name, widget)
```

The widget must have `paintTo`; KOReader assigns its `view` and `ui` fields.
Registered modules are painted after the document, saved and temporary
highlights, dogear, footer, and flipping indicator.

There are three constraints:

1. Registered modules are iterated with `pairs`, so their relative order is
   not a public stacking contract. Register one Wilk layer manager and order
   its internal layers explicitly.
2. This method establishes painting only. It does not grant a clipped input
   region, focus ownership, hit testing, or layout-generation invalidation.
   The one Wilk manager must own those policies.
3. No public unregister method was found in v2026.03. Register once per
   `ReaderUI`/document lifetime rather than repeatedly mutating the table.

The first attached dialog does not require this module. Add it only when a
marker or attached panel has a demonstrated need to remain on the page.

### Plugin lifecycle

`frontend/pluginloader.lua` discovers bundled `plugins/*.koplugin` and
configured `extra_plugin_paths` (defaulting to the KOReader data directory's
`plugins/`). It executes plugin `main.lua` and metadata with `dofile`.
`frontend/apps/reader/readerui.lua` constructs reader plugins with:

```text
dialog, view, ui, document
```

and registers each instance as a `ReaderUI` module before emitting
`ReaderReady`. Ordinary module event handlers therefore remain the right
lifecycle mechanism for page/position updates and `CloseDocument`.

PluginLoader's `HandlerSandbox` catches errors and improves stack traces; it
is explicitly not an execution-security sandbox. Never add book-supplied Lua
or a book resource directory to the trusted plugin search path.

## Asynchronous service integration

### What `insertZMQ` actually guarantees

`frontend/ui/uimanager.lua` exposes:

```lua
UIManager:insertZMQ(source)
UIManager:removeZMQ(source)
```

The name is more specific than the implementation. `processZMQs()` calls
each registered object's `waitEvent` as a Lua iterator. Upstream's
`StreamMessageQueue:waitEvent()` uses that call to poll a ZeroMQ socket with
zero timeout, process a bounded batch, invoke its receive callback, and
return. A bridge adapter can follow that structural pattern without exposing
the queue object to book code.

All of this runs synchronously on the UI thread. Therefore a bridge source's
`waitEvent` must:

- never block;
- cap messages, bytes, decoding depth, and work per call;
- enqueue or dispatch only validated messages;
- reject work for closed views and stale generations; and
- be removed and stopped idempotently when its document/session closes.

Any callback it invokes has the same no-blocking requirement. Slow broker or
program work stays outside KOReader; replies return through the bounded
queue. `nextTick`, `scheduleIn`, and `tickAfterNext` can defer UI work but do
not provide an external-fd wake mechanism.

There is a power/latency caveat. While any source is registered, UIManager
caps its input wait at `ZMQ_TIMEOUT = 50 * 1000` microseconds: up to 20 poll
passes per second even when no message arrives. This is acceptable for an
offline first proof, not a free idle-power property. Measure wakeups and
awake/idle power before leaving a source registered for the whole reader
session; otherwise register it only for an active interaction.

The release contains `libzmq.so.5` and `libczmq.so.4`, but that does not
select ZeroMQ as the Book Protocol transport. In particular:

- `frontend/ui/message/streammessagequeue.lua` hardcodes a TCP endpoint;
- its server counterpart is shaped around existing KOReader uses; and
- `frontend/ui/message/simpletcpserver.lua` is HTTP-specific and can block
  for 10 ms in `accept` and 100 ms reading a client.

Reuse the **UIManager polling seam**, behind a small adapter. Do not reuse an
HTTP inspector/server as the private broker channel, and do not describe
`insertZMQ` as generic arbitrary-fd readiness registration.

## Persistent-storage boundary

The current image has two different lifetimes:

- `/data` is the mounted p7 data partition and survives os2 reflashes.
  `pinenote/services/library.scm` creates `/data/books` only after
  `file-system-/data`, and existing persistent system state already uses
  dedicated paths under `/data/wilkbook/`.
- `/root`, including `KO_HOME=/root/.config/koreader`, is on os2 and is
  replaced by a reflash. `pinenote/services/koreader-profile.scm` explicitly
  warns not to make KO_HOME durable before sparse overrides and migration
  exist.

Book-computer packages, instances, workspaces, authority records, and
environment-retention records therefore belong in a dedicated subtree of
the mounted `/data/wilkbook/...` hierarchy. The parent design must still
choose the exact root and transaction/schema rules. Creation must follow the
library service's pattern: a one-shot ordered after `file-system-/data`, with
a fail-closed/no-op path when p7 is not genuinely mounted. Do not create the
directory during activation underneath a later mount.

Neither KOReader storage mechanism is an authority store for authored tool
state:

- global profile/history/statistics under the current KO_HOME do not survive
  a reflash; and
- `frontend/docsettings.lua` normally writes `metadata.<suffix>.lua` in a
  `.sdr` directory next to the book. Those sidecars preserve useful reading
  position across reflashes, but are path/renderer metadata and already have
  asymmetric os1/os2 ownership behavior.

There is also a parser boundary: both `LuaSettings` and `DocSettings` load
their files with `dofile`. Portable or book-supplied durable state must be
parsed as bounded data, not executed as Lua. Keep KOReader's reading-position
integration, but send authoritative edits and state through broker-owned
transactions on `/data`.

## Replayable offscreen proof

`pinenote/tools/book-reader/` now turns the initial one-off probe into a
checked-in host gate. The run recorded for this note was:

```sh
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
  make -C pinenote/tools/book-reader check
```

KOReader reported `Version: v2026.03`, logged `Tearing down UIManager with
exit code: 0`, and exited 0. The runner asserted the exact marker sequence
and printed:

```text
PASS: pinned KOReader offscreen reader integration probe
```

The local adversarial control run also passed:

```sh
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
  make -C pinenote/tools/book-reader mutation-check
```

It killed all fifteen behavior mutations: recursive polling, non-integral
queue bounds, retained queue payloads, synthetic document close, retained
highlight registration, private highlight registration, private highlight
removal, private source insertion, omitted source removal, omitted dialog
close, off-by-one capacity, omitted generation rejection, a duplicate forged
version line, the review's bracket-spelled writer control, and a changed
package version plus forged fixture output. This is the implementer's run;
the final appended independent recheck later repeated the relevant cases and
accepted the narrow desktop/offscreen gate. This paragraph retains the ordering
of the original implementation evidence rather than pretending that the first
run was already independently accepted.

The runner:

- evaluates the repository's native `koreader-bin` derivation once, without
  building or realising it, and takes the canonical expected version and
  output from that derivation;
- labels only that exact output with its matching deriver as package-pinned;
  an alternate v2026.03 override is a compatibility run;
- verifies the bundle's one-line `git-rev` **before** copying or executing the
  writable fixture, then requires one anchored official startup version line
  before the first fixture marker;
- creates a mode-0700 run directory below `/tmp/opencode`;
- scopes `HOME`, `KO_HOME`, XDG data/config/cache, and `TMPDIR` below it;
- starts with an otherwise empty environment apart from the explicit paths,
  locale, SDL drivers, and PATH;
- copies the trusted fixture to that temporary KO_HOME rather than changing
  the shipping package/device tree;
- launches the bundle's own LuaJIT and `reader.lua` with
  `SDL_VIDEODRIVER=offscreen` on a temporary text document;
- puts the reader below a supervised GNU `timeout --foreground` owner with a
  20-second deadline and bounded two-second TERM-to-KILL escalation; and
- records each owned PID plus Linux start time, so deadline-owner loss,
  runner signals, and ordinary exits clean only those exact processes. It
  removes the profile, book, and logs by default; `KEEP_ARTIFACTS=1` preserves
  only that scoped run directory for diagnosis.

`test-timeout-owner.sh` reproducibly covers three failure paths with a
single-process helper that ignores TERM: deadline expiry, a signal sent to the
supervisor, and deliberate loss of the timeout process. Every case must fail
closed and leave neither recorded identity alive. No shared process name or
broad kill is used.

Inside the real `ReaderUI`, the fixture proves:

1. `ReaderReady` registers one action through
   `ReaderHighlight:addToHighlightDialog()` and `CloseDocument` removes the
   same callback through `removeFromHighlightDialog()`.
2. The action opens an actual editable `InputDialog` through
   `UIManager:show()`.
3. A callback-style source is registered through `UIManager:insertZMQ()`
   only while each dialog interaction is active. `processZMQs()` drives its
   nonblocking `waitEvent`. Independent instrumentation wraps the public
   insert/remove methods and verifies one call to each in addition to checking
   the real UIManager registry.
4. `max_queued` must be a finite positive integer. A reentrancy guard makes
   recursive `waitEvent()` from `receive` inert, so one outer poll invokes at
   most one callback. The pure test verifies the guard, malformed limits, and
   guard/queue cleanup after a callback error.
5. The source enforces its configured queue cap. A stale generation is
   rejected before it can edit the dialog.
6. Programmatic edits traverse the Save button generated by InputDialog and
   therefore its real Trapper-wrapped `save_callback` path. One local fake
   broker response takes the accepted branch and one takes the rejected
   branch; the resulting disabled/enabled Save-button states are asserted.
   “Accepted” explicitly means **fixture accepted, not durable**.
7. Normal close removes/stops the source exactly once and a second close is
   inert. One message queued behind close is actually absent afterward, a
   stale direct `waitEvent` cannot invoke a callback, and the stopped source
   rejects a later enqueue.
8. A deliberately throwing source callback clears the reentrancy guard, then
   takes the same remove/stop path idempotently. Its queue is empty, its stale
   poll is inert, and its successor never runs.
9. A third interaction closes ReaderUI while its dialog, source, and queued
   message are still active. `CloseDocument` cleans them, the public remove
   seam is observed exactly once, the action key is absent from the actual
   ReaderHighlight registry, and stale poll/enqueue attempts remain inert.
10. After ReaderUI's real close path returns, `ui.document == nil`; a direct
    synthetic call to the plugin's handler cannot satisfy this postcondition.
11. A separate observer wraps `ReaderHighlight:addToHighlightDialog()` and
    `removeFromHighlightDialog()` before the action is registered. Counts for
    the observed key must transition from add/remove `1/0` to `1/1`, while the
    actual registry independently transitions from the exact factory to nil.
12. Normal, callback-error, and active-document close retain their original
    dialog references and independently require
    `not UIManager:isWidgetShown(dialog)` against UIManager's actual window
    stack. Clearing the plugin's own dialog field cannot satisfy this check.

The fixture is trusted and source review found no arbitrary-path writer in it.
`lint-fixture.sh` is only a lexical convenience check for a short list of
common writer spellings. Alternate Lua spellings can bypass it; it is not a
parser, sandbox, write-confinement mechanism, or security claim. KOReader's
expected profile/cache/sidecar paths are redirected below the temporary run
root, but arbitrary trusted Lua is not constrained by that redirection.

The evidence boundary remains narrow:

- the “broker” is a local Lua callback with two fixed outcomes;
- queued values are in-memory Lua tables, not a proposed wire schema;
- no framing, byte/depth validation, caller identity, capabilities,
  backpressure across processes, or integrated broker exists here;
- automation invokes the registered action's button factory directly rather
  than synthesizing a touch selection or testing highlight-menu layout;
- the test shows and edits a real offscreen dialog but has no pixel golden;
- accepted save does not write or recover durable state; and
- SDL does not exercise the PineNote fbdev refresh path, evdev input, e-ink
  optics, suspend, or idle power. In particular, the 50 ms source polling
  cost remains unmeasured on the tablet.

## Historical minimum implementation and test recommendation

This was the recommendation at the end of the reader-only spike. Later
interaction and state candidates satisfy some host-fixture portions, as mapped
above, but no immutable shipping plugin or durable reader join exists.

### Integration slice

1. Package one generic `wilkbook` plugin through
   `pinenote/packages/koreader-device/plugins/`. Give it no exercise or
   language semantics.
2. On `ReaderReady`, register one selection action. It opens a KOReader
   `InputDialog` or `MultiInputDialog` populated from a granted selection and
   scoped state.
3. Connect one bounded nonblocking queue adapter to `UIManager:insertZMQ`
   only for the active interaction. Keep transport/framing and capability
   decisions in the protocol/broker work; the reader adapter only validates
   the host-facing presentation subset and lifecycle.
4. Submit saves to the broker/workspace transaction path. Keep the dialog
   responsive and report the eventual accepted/rejected result without
   treating presentation as a durability acknowledgement.
5. Close the interaction by removing its async source, rejecting late
   replies, and dropping transient view state. Remove the highlight action at
   document/plugin teardown. Reopening must read acknowledged state from the
   broker-owned `/data` store.
6. Defer `ReaderView` painting until the same slice needs a persistent marker.
   When it does, add exactly one internal Wilk layer manager.

This slice intentionally excludes a protocol schema, sandbox launcher,
language adapter, inline layout mutation, arbitrary raster protocol, package
export, and any shipping-flavor wiring.

### Current and remaining cheap gates

The SDL/offscreen gate above now covers the pinned reader contracts, queue
type/cap and per-poll reentrancy bound, stale generation,
accepted/rejected dialog callbacks, late-callback suppression, public seam
use (including public highlight add/remove), and
normal/error/active-document dialog disposal. `mutation-check` removes each
reviewed property in isolated copied trees and requires the gate to turn red;
markers remain ordering diagnostics rather than the sole oracle. It remains a
fixture, so the next gates belong with the components that make those
properties real:

1. **Protocol/adapter tests:** fragmented/coalesced input, frame byte/depth
   limits, malformed data, cross-process queue overflow, cancellation, late
   replies, and mutations proving each bound. These wait for the separately
   owned framing/broker contract rather than inventing a second schema here.
2. **Production packaging/storage structural gate:** once a real bridge is
   approved, prove it is in the immutable bundle, production does not depend
   on `KO_HOME/plugins`, and durable paths are below a verified `/data` mount
   rather than `/root`, `.sdr`, or an activation-created mountpoint stub.
3. **Full-system restart gate:** use QEMU when service wiring, mounted p7
   state, broker/worker restart, or packaged ARM64 execution enters the slice.

SDL/offscreen is the right next rung because it runs the real KOReader plugin
loader, widgets, and event loop in seconds. QEMU becomes useful when service
wiring, the mounted data partition, restart recovery, or the packaged ARM64
image enters the slice. Hardware remains unnecessary until a change needs
the PineNote input/display/power path or a claim about user experience on
glass.
