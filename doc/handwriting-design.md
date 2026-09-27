# Handwriting recognition: contextual decoding and correction

**Decision record, 2026-09-27.** The operator agreed to the architecture and
sequencing below: **begin with contextual decoding**, while designing for an
eventual continual-learning system. Recognition is derived, editable content
backed by preserved ink. Books can supply context, examples and executable
language helpers. This is a design direction, not a deployed notebook feature.
The operator subsequently accepted §7 as the **correction UI direction**, with
ghosting, flashing and draw speed explicitly part of the requirements. Exact
layout, rendering policy and performance budgets still need prototyping and
panel qualification; agreement on the design is not a hardware result.

Related records:

- [Experimental evidence](handwriting-baseline.md): recognizers, decoders,
  code-block baseline and the first weight-adaptation pilot.
- [Notebook](notebook.md): production ink, gestures, journal and device evidence.
- [Book protocols](book-computer-protocols.md) and
  [Workbench integration](workbench-device-integration.md): existing authority,
  sandbox and renderer boundaries to reuse; no recognition join exists yet.
- [Configuration](configuration.md): sparse, durable preferences direction.
- [Refresh policy](refresh-policy.md): display evidence and measurement history;
  the notebook record describes the current direct-driver UI/hint integration.

## 1. Decisions and motivation

1. **General ink recognition with composable recognition contexts.** Retain
   stroke and raster backends, plus eventual spatial-math specialists. Context
   combines writer, domain, book and current workspace evidence.
2. **Keep alternatives and their connection to ink.** Preserve alignment,
   candidate scores and evidence provenance through decoding and correction.
   A single early transcription loses information needed by later stages.
3. **Use context during decoding and again after the block is available.**
   Vocabulary, n-grams, syntax, scope and actual indentation can influence the
   first pass. A second pass can use later context and request new visual
   candidates for ambiguous spans, rather than only rerank existing strings.
4. **Books may specialize recognition locally.** Support symbol catalogues,
   labelled ink examples, tagged language data, executable context providers
   and optional compatible model adapters. Book-specific resources need not
   affect general notes.
5. **Start with contextual decoding, not a larger fine-tuning campaign.**
   First implement the evidence/candidate contract and a tolerant Scheme
   provider, with a small book resource pack and correction record format.
6. **Continual learning is an intended later system.** Immediate vocabulary
   learning, example retrieval and eventually background neural adaptation
   should benefit from explicit corrections and writing samples. Candidate
   updates need evaluation before adoption; plugged-in idle time is an intended
   scheduling opportunity, not proof of affordable device training.
7. **External inference is a backend option.** Plan an OpenAI-compatible
   transport for a companion workstation or hosted service, with capabilities
   explicit and routing owned by the host. Local operation remains meaningful.
8. **Correction is a first-class workflow.** The target remains dependable
   recognition with little proofreading. Current evidence warrants a usable
   correction path; a pleasant editor cannot substitute for recognition quality.
9. **E-ink behavior is part of correction usability.** Ghosting, flashing,
   input-to-visible latency and drawing cost must be assessed alongside accuracy
   and correction effort. A functionally correct desktop mockup is insufficient.

Why this sequence: Gemma's code-image experiment read all 16 Python lines
exactly, but the four Scheme blocks exposed punctuation, quoting and structure
errors. Combined CER was 2.06% on this small development collection, at roughly
5 GiB server memory. The first OnlineHTR writer-adaptation pilot showed no
dependable gain; its repeatable decoded improvement was one character on one
line. These are reasons to investigate context, not accuracy guarantees or
evidence that adaptation cannot work. Full measurements and limitations live
in the experimental record, rather than being redefined here.

## 2. Inputs and ownership

| Input | Purpose | Important distinction |
| --- | --- | --- |
| Versioned stroke journal and final raster | Observed marks, geometry, timing and erasure | Recognize visible ink, not erased historical strokes |
| Paired ink and literal transcription | Visual/trajectory training and examples | Prompted text is intended writing, not automatically a label |
| Tagged text, programs and confirmed notes | Character/token priors and vocabulary | Text alone does not teach a handwritten shape |
| Symbol catalogue | Symbol identity, examples, meaning and serialization | A unique sigil need not pretend to be an existing Unicode character |
| Language provider | Position-specific roles, scope and continuation preferences | Structural plausibility is evidence, not permission to repair ink |
| Workspace snapshot | Imports, definitions and surrounding accepted text | A hypothesized binding is weaker evidence than a confirmed one |
| Correction/acceptance events | Supervision and personal vocabulary | Transcription fixes and edits to meaning are different events |

Canonical ink and human edits remain durable records. Recognition outputs,
alignments, parser states and indexes are versioned derived artifacts. Preserve
manual corrections when regenerating hypotheses. Recognition must not execute
transcribed code.

Every request/result needs the ink revision, region, relevant text/context
revision, model/preprocessing identity and active resource-pack versions. A
result for an old snapshot cannot silently replace current work. References to
ink can describe a region or several stroke fragments; do not assume that each
character has an independently isolated stroke.

Correction and training data should retain the granularity actually verified:
a confirmed line can train a sequence model without becoming a set of trusted
per-character alignments. Rejection alone gives a negative example, not the
correct positive target. An ignored suggestion is not explicit rejection.

## 3. Pipeline and intermediate representation

```text
ink snapshot → final-ink replay + layout hypotheses
             → stroke / raster / specialist recognition
             → ink-aligned candidate graph
                  ↔ active symbol/vocabulary/language resources
                  ↔ incremental syntax, scope and layout evidence
             → context-guided decoding
             → whole-block reconciliation + targeted reconsideration
             → derived text / structured content with alternatives
             → review events → learning records
```

### Layout and backend contracts

Retain competing line groupings and spatial relationships when needed.
Handwritten code lines can overlap vertically; the collected code blocks
already do. A candidate graph should accommodate splits/joins, insertions,
deletions and different-length readings, rather than assume one ambiguous
character at a fixed string offset.

For mathematics, numerator/denominator and superscript/base relationships may
be more appropriate than a line sequence. An unresolved ink-backed region is
a valid result inside otherwise recognized content. Linear text serialization
must not discard the geometry needed to revisit a fraction or unique sigil.

Backends declare which of these they actually support:

- Single transcription or multiple hypotheses.
- Frame/token scores and their definition.
- Alignment to strokes or image regions.
- Image/stroke-conditioned scoring of supplied strings.
- Incremental continuation or structured-layout output.

Text-only output is usable, but it must not be represented as a visual
likelihood distribution. Raster recognition is a first-class option, including
for area-erased content; trajectory export remains refused where final-ink
semantics cannot be represented faithfully.

### Scoring and two-pass decoding

Keep separate contributions for ink evidence, sequence likelihood, scope
compatibility, spatial agreement and structural plausibility. Initially these
are **ranking scores**, not calibrated transcription probabilities. A VLM
already encodes language expectations; n-grams, syntax and scope also overlap.
Weighting and calibration must account for this correlation rather than count
the same evidence repeatedly.

The first pass uses cheap incremental state, vocabulary prefix trees and
language priors before plausible candidates disappear from the beam. The
second uses the whole block, repeated identifiers and later definitions. It
may ask the recognizer for additional candidates at a specific region; the
correct reading need not be present in the original top-N list.

Structural repair suggestions remain distinguishable from literal readings.
For example, a parser's missing-parenthesis recovery can make scope analysis
possible without inserting that parenthesis into the transcription. Preserve
an unresolved/new-spelling path even when known names are strongly preferred.

## 4. Recognition contexts and book resource packs

An active context composes general recognition, the writer's visual profile,
the language/domain, the book and current page/workspace information. Regions
can differ: a Scheme block and a prose margin note need not share a vocabulary
mixture. Tags may select personal language data from all confirmed notes or
from a narrower domain. Source identities and reversible counts/indexes should
allow corrections or exclusions to update those contributions later.

A versioned book resource pack can provide:

- A symbol catalogue with stable identities, display forms, optional Unicode
  or text serialization and labelled examples such as InkML/image pairs.
- Tagged text corpora or compatible precomputed n-gram data.
- Domain vocabulary, chapter-specific names and example programs.
- A context-provider implementation and its declared dialect/domain.
- Optional visual prototypes, extra classifier heads or compatible adapters.
- Applicability declarations: book activity, page, region or tag.

Absence from a vocabulary usually lowers a prior rather than makes a symbol
impossible. Greek letters should become competitive in the right context, but
an unfamiliar symbol must have an escape route. An explicitly constrained
answer alphabet can be stronger than a statistical corpus's accidental gaps.

Prefer cheap, detachable specialization first: vocabulary, example retrieval,
prefix trees and language data. Neural specialization may use a small head,
writer adapter, book adapter or LoRA where the architecture supports it.
**LoRA is an option, not a universal requirement.** Adding an adapter does not
automatically extend an output alphabet/tokenizer. Combining writer and book
adapters needs evaluation, even when each works separately. Compatibility
includes base model, vocabulary and preprocessing identities.

The host activates resources and supplies bounded context to sandboxed book
helpers using the existing authority/execution direction. Helpers do not gain
direct access to all personal notes, storage or endpoint credentials. Guile
coordination and Lua KOReader presentation remain the language direction;
model runtimes and sandboxed book languages can vary. Protocol names and wire
schemas are still to be designed, not additions to an existing accepted API.

## 5. First provider: tolerant Scheme context

Input is a context snapshot, a candidate partial program, a position or
ink-backed span, token prefix and structural hypotheses. Output can include:

- Possible roles: binding name, reference, quoted data, etc.
- Visible names with origin and scope information.
- Token/character continuations and relative preferences.
- Structural/layout diagnostics, including recovery assumptions.
- Whether scope information is complete, partial or unknown.

Support `define`, function parameters, `lambda`, the differing initializer
scopes of `let`/`let*`/`letrec`, imports and shadowing. Distinguish quoted data
from references and track quasiquote/unquote nesting. Unknown macro binding
forms and incomplete imports weaken scope claims instead of excluding names
with false certainty. Incremental execution should be cached/batched and
budgeted; a slow provider can fall back to cheaper evidence.

Competing parses can carry competing scopes. In a definition and later use
of `n?tes`, neither occurrence should irrevocably establish `notes` before
the other is considered. Both ink observations contribute to the joint
interpretation. Accepted text is stronger context than another provisional
model guess.

Parinfer-like reasoning is a candidate generator and consistency check. Feed
it measured line starts/alignment with uncertainty; model-generated spaces
are not independent geometric evidence. Quote and backquote can both precede
an opening parenthesis; a later unquote can distinguish them more strongly.
The writer-confirmed missing parenthesis is a required fidelity case: better
formed code can still be a worse transcription.

## 6. Eventual continual-learning system

Three timescales are intended:

1. **Immediate vocabulary/context updates.** Confirmed names and words enter
   the appropriate personal/domain/book context without retraining a network.
2. **Lightweight example learning.** Retrieve confirmed symbol/sequence
   examples and track writer-specific confusions, spacing and layout. New
   book notation can use prototypes before weight adaptation is justified.
3. **Background neural adaptation.** Select confirmed examples, mix older
   examples to reduce forgetting, train candidate adapters and evaluate before
   promotion. Preserve the original model and reversible adapter versions.

Use plugged-in idle periods subject to memory, thermal and work budgets; yield
to writing/reading and checkpoint or cancel for suspend/update teardown. The
actual affordable training workloads on the PineNote, GPU/NPU compatibility
and on-device energy remain qualification work. Companion-host training can
use the same dataset and adapter contracts.

Unreviewed recognition and external-model output remain hypotheses, not
authoritative labels. Broad explicit acceptance can label only the scope the
user actually reviewed. Semantic edits and syntax repairs are retained for
the document but excluded from literal ink supervision. A later undo/revision
supersedes a correction and invalidates its learning contribution; provenance
must make later dataset/model rebuilding possible.

Generated worksheets should target recurring confusions and coverage gaps:
isolated marks, contrasting pairs, identifiers in definitions and uses, and
natural code fragments. Preserve intended prompts separately from observed
transcriptions. Keep new sessions/prompt families held out; do not select and
train on every error from the qualification set, then reuse that set as an
independent test. Evaluate all predeclared variants and seeds rather than
promoting the most favorable small development result.

## 7. Correction UI direction

**Operator-approved direction, 2026-09-27**, including the requirement to
consider ghosting, flashing and draw speed. The rendering approach below is
the proposed implementation of that requirement; detailed choices remain open.

### Goal and entry point

**Keep writing as paper-and-pen; review derived text when asked.** Use a
`Review text` action in the notebook's existing floating panel, initially for
the current block or page. A review surface has explicit selection/editing
semantics so normal pen strokes and existing undo/navigation gestures do not
become implicit recognition commands. Final placement and gesture details
need an operator trial.

Start with one block at a time: a full-width ink excerpt above monospaced
editable text, with linked selection. This suits the existing overlapping-line
code samples and retains indentation geometry. A magnified crop can make tiny
marks readable without discarding a way to inspect the surrounding block.
Avoid a permanent overlay covering the writing surface.

```text
Review text — Scheme                            Back to ink
┌────────────────────────────────────────────────────────┐
│ Original ink excerpt; selected span outlined            │
└────────────────────────────────────────────────────────┘
  (define notes ...)
  (write (assoc-ref ntes 'title))
                    ^^^^ selected

  [notes]  [ntes]  [Other…]             [Keep ink / unresolved]
  [Previous suggestion] [Next suggestion]       [Undo correction]
  [Accept block]                      [Done]
```

This is an interaction sketch, not a fixed widget layout. Candidate counts,
target sizes and text/ink proportions should be tuned with real screenshots
and operator use. Use high-contrast outlines/underlines rather than color-only
states; stabilize the display while the user is selecting. Results arriving
in the background must not reorder targets underneath the pen.

### Fast path and exact fallback

- Tap a text span or its ink region to inspect a few distinct alternatives.
  Selecting one applies that reading immediately, with Undo; avoid a second
  confirmation for every word. Candidate descriptions such as `in scope`
  should be optional details, not fabricated confidence percentages.
- If selection alignment is uncertain, permit widening/narrowing the region
  or selecting a line. Split/join and whitespace errors must be correctable;
  a word-only chooser is insufficient for code.
- `Other…` opens exact text editing, with a code punctuation palette and a
  reliable keyboard path. Clearly distinguish quote/backquote, comma/comma-at,
  parentheses, brackets, braces, underscore, backslash and operators. Provide
  explicit newline, indent/dedent and optional visible-space controls. The
  keyboard must be able to enter a character the recognizer cannot emit.
- A temporary rewrite pad is an optional later input method, not the only
  fallback: repeating the same misrecognition must not trap the user. Rewritten
  ink is a new sample, not a mutation of the original notebook strokes.
- `Keep ink / unresolved` skips forced transcription of a region, including
  mathematics. It does not mark an existing candidate as accepted.

### Transcription corrections versus content edits

Default review action is **fix the reading of these marks**. Selecting `notes`
for ink that says `notes` creates a literal correction event. A separate
`Edit content` action allows changing the document's meaning or fixing a
mistake actually present in the handwriting. For example, adding the confirmed
missing parenthesis belongs there and must not teach recognition to invent ink.

Do not ask a modal classification question for every ordinary correction.
Make the active mode clear, allow reclassification/undo, and provide an easy
way to mark a span as genuinely unwritten or unresolved. The UI should show
the resulting content edit as such when returning to ink-linked review.

At least these states must remain distinguishable in storage and presentation:
unreviewed hypothesis, literal accepted/corrected text, unresolved ink, content
edit, and stale result after an ink/context change. `Done` saves progress and
leaves review; it is not acceptance of everything on the page. `Accept block`
explicitly records review of that block. Saving or exporting text alone does
not create positive labels.

### Review burden, persistence and repeated names

Offer both a normal whole-block view and next/previous suggested trouble spots.
Suggested spots can use disagreement, poor ink support and structural conflict,
but unmarked text is still unreviewed: high-confidence errors exist. Report
review coverage rather than imply all remaining text is correct when a queue
is empty. Never require the user to clear the queue just to keep writing.

Fixing a definition can trigger fresh proposals at related references. Preview
their differences before a grouped apply; do not silently turn a local
transcription correction into a global rename. Already accepted text stays
stable unless the user explicitly revisits it. Proposals must use the current
scope and revision, not simple string matching across the notebook.

Persist corrections, review position and unresolved regions through close,
suspend and restart. Undoing a correction changes derived text and its learning
event, not the canonical ink journal. Ink changes can stale overlapping
recognition; context changes can stale dependent proposals without deleting
the user's accepted edits. Late inference replies cannot overwrite an edit.
Provider failure/offline operation must still allow manual correction.

### UI questions still open

- Best ink/text proportions and block-selection behavior on the PineNote;
  compare the stacked layout with a toggled full-page view if space is tight.
- Whether the punctuation palette plus existing keyboard is sufficient or a
  dedicated code keyboard earns its space.
- How much explanation (`in scope`, `ink alternative`, `structure suggestion`)
  is useful without making review slower.
- Whether a rewrite pad and grouped reference corrections justify their extra
  modes in the first device prototype.
- Exact acceptance/export wording, unresolved-region serialization and how to
  measure acceptable review effort with the operator.
- Measured latency/ghosting/flash budgets and the best refresh policy for the
  actual correction surfaces; qualify the rendering approach below on glass.

### E-ink interaction and rendering requirements

The correction UI must remain comfortable through a whole block of repeated
edits, not just look clean when first opened. **Ghosting** is residue persisting
after a refresh settles; **settling** is the transient development of a new
image. Measure these separately from flashes and input lag. Reducing flashing
by allowing unreadable punctuation residue is not a successful tradeoff.

**Stable, event-driven presentation:**

- Keep candidate buttons and the keyboard in stable positions. Reserve space
  for status text; update it at meaningful state changes rather than animate a
  spinner, pulse a selection, blink a caret or stream tokens onto the panel.
  A steady caret/outline and static busy indicator are the starting design.
- Prefer discrete block/crop changes over animated scrolling or zooming.
  Preserve the user's viewport during edits where possible. Indent, split/join
  and long-line changes still need correct re-layout, without animated reflow.
- Selecting, applying and undoing a reading should produce prompt local
  feedback without waiting for another inference or scope pass. Expensive
  inference, parsing and training must not occupy the input/render path.
  Later proposals can be batched when ready without moving active targets.

**Draw the final state once:** reuse the notebook panel's off-screen composition
pattern. Cache the unchanged ink crop and text layout where useful, invalidate
affected regions, and publish the composed result without an intermediate
erase-to-white or a page painted over and then under the panel. Coalesce
changes from the same action; avoid an acknowledgement paint followed by a
redundant identical result paint. Preserve actual edits and input events even
when superseded render requests can be coalesced. Measure cache memory and
invalidation correctness along with the rendering speedup.

| Interaction | Starting redraw policy to validate |
| --- | --- |
| Select another span | Restore the old outline and draw the new outline/candidate area; retain unchanged ink and text |
| Apply or undo a reading | Re-layout affected text and dependent controls, compose once, publish changed regions |
| Type punctuation or move the caret | Local editor/feedback damage; no periodic blink or full-page repaint |
| Open/close keyboard, magnify ink, change block | One composed transition; larger damage is expected, an automatic clearing flash is not required for every transition |
| Background inference completes | Stable, batched proposal update; no per-token paints or unsolicited viewport changes |

Dirty rectangles are an optimization intent, not proof of the driver's physical
update area. Audit actual publish/refresh requests and their visible effect.
When replacing glyphs, repaint their old footprint as well as the new one;
minimal damage must not leave stale text or outlines in the framebuffer.

**Use the existing refresh owner:** the KOReader host owns display policy,
not the book or recognition helper. Start with the current grayscale-safe UI
path (GL16 in the notebook's direct-driver integration) for antialiased text,
ink crops and keyboard surfaces. Do not place a grayscale review surface under
the canvas's DU hint. Review entry/exit, overlays, rotation and failures must
restore the correct hint ownership. Binary-only feedback could later use a
bounded DU region if its whole target region and transitions qualify; it is
not justification for a whole-screen FAST switch. The waveform name alone
does not establish latency or ghosting quality.

Reuse the existing explicit Refresh and idle-washer/debt machinery. Account
for correction interactions once at the responsible owner, avoid duplicate
wash requests or charges, and observe the existing active-input/proximity
guards and debt-ceiling behavior. Do not introduce a clearing wash on every
tap, candidate change or block acceptance, or claim that a GL16 repaint clears
wash debt. If concentrated edits make a region hard to read before idle cleanup,
explicit Refresh must remain reachable without losing correction state.
Any more aggressive cleanup policy needs evidence from the repeated-edit test.

Defer optional finishing work while interacting, but do not assume queued
optical work can always be cancelled once it starts. In the current direct
driver, renewed DU ink may wait behind in-flight GL16 on those pixels. Include
immediate return from review to writing (and a rewrite pad if implemented) in
the acceptance sequence. Driver scheduling/refresh changes remain separate
from the initial review UI implementation.

## 8. External inference and placement

Define a backend-neutral recognition request and implement an OpenAI-compatible
transport adapter as one option. Explicitly declare image support, structured
output, candidate scoring, log probabilities and limits; protocol compatibility
alone establishes none of these. A text-only selector ranks supplied readings,
whereas a vision backend can contribute new evidence from the ink image.

Useful roles are stronger image recognition, hard math/notation, a second
opinion on a region, batch processing and worksheet generation. A companion
workstation is particularly relevant to the current memory-heavy image
baseline. GPU/NPU and smaller local models remain in scope rather than being
excluded by a CPU baseline.

Host configuration selects local, companion or hosted routing and the context
to send. Book resources supply domain hints, not credentials or authority to
upload notes. Record request inputs, backend/model identity and outputs for
reproduction, excluding credentials. External output remains a hypothesis;
manual correction and retained ink remain usable when the service is absent.

## 9. Implementation sequence and evidence gates

1. **Candidate/context/correction records.** Define versioning, ink alignment,
   provenance and backend capabilities. Replay saved experiments through them.
2. **Contextual Scheme decoding.** Build the tolerant scope/syntax helper and
   connect it during decoding and block reconciliation, including requests for
   missing alternatives. Start with a small declarative book resource pack.
3. **Correction prototype alongside the decoder.** First exercise saved code
   blocks and the agreed review-sheet direction off-device, with the real Lua
   renderer where practical. Capture literal corrections distinctly from
   content edits.
4. **Cheap personalization.** Activate vocabulary and example retrieval from
   confirmed records. Measure cross-book/domain effects and reversibility.
5. **Scheduled continual training.** With enough clean, session-separated
   examples, implement dataset snapshots, candidate training, evaluation,
   adapter promotion/rollback and interruptible background scheduling.

For decoding, compare ink-only, language-assisted, scope-assisted and
layout-assisted variants; record candidate coverage as well as selected CER.
Report exact blocks, identifiers, punctuation, whitespace, introduced errors
and erroneous repair of literal writing mistakes. Preserve the missing
parenthesis and other actual omissions in references. Freeze policy before
collecting/evaluating fresh-session writing; current samples remain development
data. GPU, NPU, external and CPU results need their own resource measurements.

For correction, measure time and actions per block, remaining errors after
review, candidate-choice versus keyboard usage, segmentation fixes, missed
confident errors, accidental semantic edits and learnable verified examples.
Count the entire review task, not only taps on highlighted errors. Compare with
plain text correction; do not hide poor recognition behind selective review.

Host checks should cover revision races, selection/alignment, literal-versus-
content labels, rollback, persistence, unavailable providers and incomplete
math. Add paint/refresh traces and composed-frame checks: no intermediate
blanking, unchanged regions stay unchanged, old glyph footprints are restored,
idle UI generates no animation paints, stale callbacks cannot publish, and
hint/debt ownership survives keyboard and review lifecycle transitions. Host
measurements can establish layout/raster CPU time, allocations and publish
counts, but cannot establish optical ghosting or perceived panel speed.

Then use an attended panel sequence that repeatedly selects alternatives,
changes punctuation, types, indents, undoes, opens/closes the keyboard, changes
blocks, returns immediately to ink, pauses for cleanup, and suspends/reopens.
Include night mode and supported orientations. Record the generation, display
policy and panel temperature alongside:

- Input-to-first-visible-feedback and input-to-readable-result latency,
  including tail latency and rapid successive edits, separately from inference.
- Layout/raster time, publish count, damaged area and refresh/wash requests
  per action; distinguish logical actions, paints and actual optical passes.
- Observed flashes and their triggers, and settling time.
- Post-settle ghosting after repeated edits, especially quote/backquote/comma,
  parentheses, caret and selection outlines; compare before/after cleanup.
- Total review time, accidental taps and perceived responsiveness/comfort.

Use camera/optical observation for visible timing and residue rather than
equating a publish return or IRQ count with a readable frame. Establish
acceptable budgets with the operator from the prototype; no sub-frame response,
flash-free guarantee or numerical latency threshold is claimed by this design.
The architecture and UI direction are agreed; provider algorithms, model/adapter
choices, detailed layout/refresh policy and adoption thresholds require evidence.
