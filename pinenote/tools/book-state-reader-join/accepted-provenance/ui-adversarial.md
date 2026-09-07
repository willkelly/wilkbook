# Book State reader UI slice — independent adversarial review

Date: 2026-09-06

## Disposition

**Accept the exact `pinenote/tools/book-state-reader/` packet identified below
at the offline native-UI fixture gate.** I found no concrete blocker in the
source-exact slice.

This acceptance means that one trusted Guile fixture can drive a real editable
KOReader `InputDialog` over one private FD, while preserving the distinctions
between loaded state, an editable draft, a pending save, a durable-authority
receipt, a later presentation, and an observed inherited widget paint. It also
accepts the finite generation and cleanup behavior exercised here.

It does **not** accept SQLite durability, the Book Session delegate, the active
`book-state-integration` join, process-death recovery, QEMU, runsc, ARM, an
image, a device, physical pixels, or release behavior. The five interactions in
the accepted run are five UI generations in one Guile process and one KOReader
process, not five process starts or storage recoveries.

## Frozen packet and accepted hashes

`README.md` defines `SHA256SUMS` as the packet manifest. I copied every packet
file and every external source pinned by `run-tests.sh` into a mode-private
read-only snapshot **before** running the provided or independent tests:

```text
/tmp/opencode/book-state-reader-independent-review-20260906/source-snapshot
fed9ea416fed671581bb487374a4976fd8ad30614c45d24780497b3225a6026c  source-freeze-manifest.json
```

The supplied manifest identity was reproduced exactly:

```text
a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab  pinenote/tools/book-state-reader/SHA256SUMS
```

All 12 entries in that manifest verified before execution and remained
byte-identical to the frozen snapshot after execution. The accepted source
inputs are:

| Packet input | SHA-256 |
|---|---|
| `Makefile` | `de361c5e2529c634d759df0bd9c09d4241b7975f43ad910c9749670235d524a8` |
| `README.md` | `db1b7b7feac700732c25805c2bc6a497fad74c34d6b50fcdafaee4946becf2f4` |
| `fixture/bookstatereader.koplugin/_meta.lua` | `64b2d8ad62e34854a8d4673b7b7aba01918f7aaa736497265449d31fa269e451` |
| `fixture/bookstatereader.koplugin/main.lua` | `17ac60feecff8b0b67a32845338f8969c8d6cdc4141ed346947389c94fe16fc3` |
| `fixture/bookstatereader.koplugin/state_channel.lua` | `aa3c2cf9bbc025208e5ebdfe6745ac83d2e2d2572ceba7845b7b14c20bd6fc5c` |
| `fixture/bookstatereader.koplugin/ui_audit.lua` | `1765dcb1bf907002eae66457c2bc00bf66409c341a5bcf844f3fae3a37232130` |
| `integration-host.scm` | `632e5283b2e894cb3ae8d81ddeade6d051adcb3ddc19dc6e3a27cc994072e821` |
| `private-control.scm` | `4cf7702704cae8db2eff4cc48b13cf139cfb616b0809f69f141e9c684325f5d3` |
| `run-interactive.sh` | `bb9be53d5f93a0aa31e00d9b8dc01458dc542ee9b122d291651f09e8682a2778` |
| `run-tests.sh` | `694dcdd2861dc129512e36efed334ebca5d91b2385ae273f1cfb25e25e1f3b59` |
| `test-private-control.scm` | `2ffac6a116cb10289f32da2a98bfc0c1d567ebed456520fb8254b7aac8daeefb` |
| `test-state-channel.lua` | `609f0d0ea0984fe753c9c8ad464f976b1f2a0418054fcf3024ebf0ee0733c9b7` |

No alternative or corrected reader candidate was presented. Therefore there is
no superseded candidate hash to accept: any reader source not matching the
table above remains unaccepted by this review.

The old accepted private interaction codec was not edited or imported by the
successor codec. The runner pins its source at
`1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d`
and similarly pins the old Lua channel/audit sources. This review does not
re-open their prior acceptance.

## Exact KOReader runtime

The provided run used only:

```text
/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
revision: v2026.03
deriver: /gnu/store/amd75p0f3namp1x2kwhkhipd568s9na2-koreader-bin-2026.03.drv
recursive hash: 1zp7gqcc6p6kg04090vw9hjh0pkw07skvfs3zajpwa8z5hb4fx5f
```

`run-tests.sh` independently evaluated the repository's canonical derivation,
confirmed that this exact output has that derivation, and reported
`bundle-mode: package-pinned`. No substitute or realization was requested.

The relevant immutable KOReader sources were also inspected directly:

| Pinned KOReader source | SHA-256 |
|---|---|
| `frontend/ui/widget/inputdialog.lua` | `a03bdd3827a3108d313a19407c7e2db6176e20c3066595356f4c86e3a50930b4` |
| `frontend/ui/widget/inputtext.lua` | `1431c5cb7f5e42c5494c9f7ebc570d74627c9299e6d00f9c54762b4abded0f66` |
| `frontend/ui/uimanager.lua` | `f74b56b1885647770da9596e753990dd065032b6f85777260c841c19b1999464` |
| `frontend/apps/reader/modules/readerhighlight.lua` | `1f6bde433c349ef8e07f2ca8f2d24b209127ca9d1a80e1a89b710a27d403e711` |

Those sources establish that the generated Save button invokes
`save_callback(self:getInputText())`; successful callbacks clear KOReader's
edited flag, while this fixture's deliberate `(false, false)` return leaves the
real dialog open without the generic success/failure modal. Actual InputText
insert/delete operations set `is_text_edited` and invoke the callback forwarded
to the fixture's `_on_edited`. This is the same callback exercised by the
automated `InputDialog:setInputText(..., true)` path.

## Widget and source ownership

The accepted plugin owns the exact `InputDialog`, generated Save/Close buttons,
selection-action callback, private channel object, and UI lifecycle. The Guile
host owns the connected peer, the in-memory authority value, commit decisions,
child identity, and fixture deadline.

The automated `save` command does not call a second submission method. It looks
up the real generated button by ID and invokes that button's Trapper-wrapped
callback. Submission content is the exact current `InputDialog:getInputText()`.
The plugin's only state-bearing input is the connected private channel at FD 3.
Its environment contains fixture identity, root, mode, and the literal FD
number, but no expected or recovered note. No note is read from argv, an
environment value, a filesystem oracle, stdout, or a console marker.

The selection action is installed and removed through the pinned public
`ReaderHighlight` methods. The audit additionally checks that the exact factory
in `_highlight_buttons` is the one invoked and the one returned by removal.

## UI state semantics

The state transitions are appropriately conservative:

1. `load-absent` and `load-value` are accepted only from `awaiting-load`.
   Present empty state and absent state both render empty text, but retain
   distinct `loaded-value` and `loaded-absent` states and titles.
2. An actual edit callback moves loaded, saved, or failed state to `dirty`.
3. Save is accepted only from `dirty` or `failed`, captures the exact current
   draft, disables the button, enters `pending`, and emits one `submit`.
4. Save while pending emits `ignored` and neither changes `pending_text` nor
   produces another submission.
5. `commit-failed` accepts only a closed failure code, clears the pending
   operation, leaves the exact widget text untouched, enables Save, and enters
   `failed`. Retrying therefore re-reads and resubmits the retained draft.
6. `commit-ok` requires both a pending operation and exact text equality with
   that one captured submission. It is the only command path containing a
   transition to `saved`.
7. If the widget was edited while the old commit was pending, the edit callback
   records that fact. The eventual matching receipt updates the committed
   baseline but leaves the current widget `dirty` and Save enabled. Even an
   edit away and back is treated conservatively; the old receipt cannot label
   the post-submission editing epoch Saved.
8. `present` requires current `saved` state and the exact retained committed
   text. Presentation itself does not change the storage state. Its `applied`
   event is only the later paint observation.

The provided run proves one failed attempt, an unchanged retry, one accepted
receipt, and a separate presentation. The independent state counterexamples add
the pending-edit cases that the provided script does not drive. They passed
**32/32** checks, including mismatched receipts, edit-away-and-back, failed-draft
retention, exact retry, duplicate suppression, premature presentation, and the
fact that presentation/paint cannot manufacture Saved.

## Real inherited topmost paint evidence

`UIAudit:retainDialog` wraps the exact dialog instance's inherited `paintTo`
before `UIManager:show`. The wrapper first invokes the retained original
`paintTo`, then records the dialog title, exact current input text, and whether
that exact dialog is `UIManager:getTopmostVisibleWidget()`.

State and presentation arms become seen only inside that post-inherited-paint,
topmost branch. The plugin sends `status` or `applied` only after the matching
arm is seen; otherwise it requests another real repaint and fails after 20
bounded attempts. Thus the accepted evidence is not a state setter or a
self-reported callback standing in for render execution.

The retained run observed topmost inherited paints for:

- generation 1: loaded absent, zero bytes;
- generation 2: loaded value, zero bytes;
- generation 3: nonempty loaded, dirty, pending, failed, retried pending,
  saved, then the separate presentation;
- generation 4: recovered value, dirty, pending, then navigation before the
  receipt; and
- generation 5: the authority's newly loaded value after reopen.

This proves invocation of the pinned inherited offscreen widget paint path with
the matching topmost widget state. It is not a screenshot comparison, physical
panel proof, latency measurement, or claim that every Unicode glyph has a
particular visual shape.

## Generation and lifecycle behavior

`open N` succeeds only with no active dialog and exact successor generation.
All other interaction commands except `finish` must match the active generation.
Navigation and Close clear the exact dialog reference, generation, pending
state, presentation tokens, and render tokens before sending their completion
event. Old load, receipt, and presentation commands are then `ignored` and
cannot mutate a newly opened interaction.

The real run exercised generations 1 through 5. Generation 4 committed in the
Guile in-memory authority, navigated before its receipt reached Lua, rejected
the old receipt and presentation, and then loaded that authority value into
generation 5 solely through FD 3. This is useful UI reopen evidence, but is not
a process restart or durable recovery.

At finish, the exact run established:

- all five retained dialogs were absent from the UI stack;
- the private ZMQ source had exactly one insertion and one removal;
- the channel was marked closed, its queue/input were cleared, and `F_GETFD`
  returned `EBADF` for the donated descriptor;
- a post-cleanup poll invoked no stale channel callback;
- the exact selection action had exactly one public add and one public removal;
- the KOReader child was reaped and no recorded PID/start-time identity remained
  live; and
- no socket or FIFO path remained in the retained run root.

With `KEEP_ARTIFACTS=1`, the outer owner record files remain as inert evidence,
but their PID/start-time identities do not exist. A normal run removes the whole
private run root.

## Closed private control and stream handling

The successor is a private UI transport, not Book Protocol. Its vocabulary is
closed to 11 authority-to-Lua commands and nine Lua-to-authority events. The
Guile codec must be called with the direction-specific allowlist; the Lua codec
has separate command and event maps. Per-kind empty/value semantics and closed
status/failure values are enforced by the consuming UI and authoritative fixture
in addition to lexical decoding.

Both implementations require canonical generation `1..1000000`, exactly three
pipe-delimited fields, lowercase even-length hexadecimal, well-formed UTF-8,
and no U+0000. Values are bounded by UTF-8 bytes, not code points: 4096 bytes is
accepted and 4097 is rejected. The Lua decoder rejects overlong encodings,
surrogate code points, values above U+10FFFF, arbitrary non-UTF-8 bytes, and
wrong-direction or unknown kinds. Newline inside note text is hex-encoded and
therefore cannot become framing.

The stream owners retain at most an 8,224-byte line plus one bounded read,
process one complete frame per callback, and retain at most eight queued output
frames. Reads and writes have 4 KiB per-pump budgets; output completes at most
four frames per pump. Partial writes retain an explicit offset. EINTR and
EAGAIN return control to the event loop rather than spinning. EOF before a
complete frame is fatal, and an unterminated line over the bound is fatal.

The independent Guile lexical matrix passed **29/29** checks. The exact Lua
channel matrix passed **38/38**, including valid fragmentation, two coalesced
frames delivered separately, partial EOF, overlong input, wrong direction,
noncanonical generations, uppercase/odd hex, malformed/overlong/surrogate UTF-8,
U+0000, multilingual byte boundaries, real socket EAGAIN, and finite queue
rejection. At the UI layer, a duplicate Save while pending is explicitly
ignored; elsewhere the scripted authority's exact next-event comparison makes
unexpected or duplicate active-sequence events fatal.

## Authoritative fixture and non-spoofable success

The Guile host does not accept a state result from KOReader stdout or stderr.
The child log is a separate bounded file; the host advances only on decoded
events from its connected socket peer. A child-printed
`BOOK_STATE_READER_HOST: result:ok` would therefore be in the wrong file and
cannot satisfy the runner.

The host emits its one result marker only after the exact event script, clean
KOReader exit, bounded-log inspection, exact submission count, unique Saved
paint evidence, and cleanup audit all succeed. `run-tests.sh` then requires one
and only one host result marker, no host failure marker, dead exact process
identities, and zero host status. The retained KOReader log was 12,210 bytes,
below its permitted 128 KiB fixture bound.

The authority itself is deliberately a scripted in-memory oracle. Its source
contains fixed test values and commit decisions; that is trusted test input, not
backend evidence. The relevant property here is that those values can reach Lua
only through the connected control FD.

## Operator mode

Source review confirms that optional `interactive` mode is genuinely different
from the automated script:

- the dialog is still the real `InputDialog` and starts with its keyboard
  visible;
- no `edit` or `save` automation commands are issued;
- an operator's actual widget edit enables the generated Save button;
- tapping that Save button emits `submit`, after which the Guile process updates
  its in-memory value and returns `commit-ok`; and
- after close, the public selection action opens the next generation and the
  authority sends a fresh load.

No expected note is accepted through operator argv or environment. The only
operator argument is the KOReader bundle. The default is the exact pinned store
path above.

This mode was not run in the independent review because it requires an attended
SDL display and human input and is explicitly outside `make check`. Its limits
are material: state lasts only for that Guile process, saves always succeed in
the simple in-memory authority, it has no finite automated deadline, and a
merely version-compatible bundle supplied by the operator is not covered by
this exact package-pinned acceptance.

## Executed reproductions

The source-exact provided gate is reproducible with:

```sh
cd pinenote/tools/book-state-reader
make check \
  KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

It passed:

```text
PASS: closed state-reader control grammar, bounds, UTF-8, and NUL scope
PASS: exact-runtime state channel framing and nonblocking delivery
bundle-mode: package-pinned
BOOK_STATE_READER_HOST: result:ok
PASS: persistent-note load/save/failure/paint/late/reopen fixture
```

The independent evidence and runnable counterexamples are under:

```text
/tmp/opencode/book-state-reader-independent-review-20260906
5bdb4a8c9d2c51a620dd607c1c59b31d4712a4d6f47c32bcb235ed7471345045  independent-review-manifest.json
```

Run the finite independent checks against the frozen sources with:

```sh
ROOT=/tmp/opencode/book-state-reader-independent-review-20260906
KOREADER=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03

timeout 10 guile --no-auto-compile \
  -L "$ROOT/source-snapshot/reader" \
  "$ROOT/private-control-adversarial.scm"

"$KOREADER/lib/koreader/luajit" \
  "$ROOT/state-channel-adversarial.lua" \
  "$ROOT/source-snapshot/reader/fixture/bookstatereader.koplugin"

"$KOREADER/lib/koreader/luajit" \
  "$ROOT/ui-state-counterexamples.lua" \
  "$ROOT/source-snapshot/reader/fixture/bookstatereader.koplugin"
```

Expected terminal summaries are:

```text
PRIVATE-CONTROL-ADVERSARIAL checks=29 failures=0
STATE-CHANNEL-ADVERSARIAL checks=38 failures=0
UI-STATE-COUNTEREXAMPLES checks=32 failures=0
```

The state counterexample harness loads the exact frozen candidate `main.lua`
under finite reviewer-owned UI/channel doubles so it can reach receipt/edit
interleavings not exposed as automation commands. It is semantic evidence, not
a substitute for the real inherited-widget run above.

## Remaining boundary

The next join may use these exact reader hashes as its UI-side input, but must
independently prove the real Book Session/state adapter/backend chain, operation
identity, save/reopen behavior across process boundaries, and recovery. It must
not relabel these five same-process UI generations as SQLite durability or
restart evidence.

The concurrent `pinenote/tools/book-state-integration/` and disk-helper work was
not inspected, modified, or executed. Accepted Book Session/backend/protocol/
adapter sources were not re-audited. No QEMU, runsc, ARM, image or package build,
device, SSH, network, mount, or hardware action occurred during this review.
