# Wilkbook: Toward a Self-Hosting Book Computer

**Status:** Accepted architecture direction with an offline bootstrap in progress

**Version:** 0.3

**Date:** 2026-09-06
**Implementation status:** Several framing, session, state, isolation, and fixed
interaction components are independently accepted at narrow evidence boundaries.
They are not a deployed or general book runtime; the self-hosting product remains
unimplemented.

## Purpose

> **Wilkbook should become a self-hosting book computer in which books can read books, augment books, create books, and construct the tools used to do all four.**

The decisive proof is not displaying an interactive exercise. It is using the book system, on the tablet, to create Exercise Studio, then using that tool-book to augment *Logic for Programmers* without exercise-specific changes to the trusted host.

### Reading map and claim status

- This document owns the product model and architecture.
- [Book computer protocol and state reference](book-computer-protocols.md) owns
  the current cross-cutting map of exact bootstrap messages, state machines,
  authority, generations, acknowledgement boundaries, and evidence status.
- [Offline implementation lane](book-computer-implementation.md) preserves the
  chronological implementation record and failed predecessors.
- [Book computer demonstration](book-computer-demo.md) records the accepted
  fixed-book AArch64/QEMU-to-real-KOReader result.
- [`status.md`](status.md) remains the only source of physical-hardware truth.

In this document, **accepted direction** is a product/design decision,
**accepted implementation** means independent review of exact source for its
stated scope, **candidate** means implemented but not independently accepted,
**blocked** means independent review prevents acceptance at the claimed boundary
even if narrower observations passed, and **future** means unimplemented. None
of those words means shipped unless it explicitly says so.

The implementation should extend Wilkbook's existing KOReader-based reader rather than build a replacement beside it. The accepted responsibility split is:

```text
KOReader       document layout, widgets, input, and final presentation
Guix           pinned software environments and dependency provisioning
gVisor/runsc   application-kernel isolation for executing book programs
Wilkbook       lifecycle, capability broker, workspaces, and book protocol
Book programs  languages, evaluators, editors, and domain-specific tools
```

### What changed in 0.3

Version 0.3 reconciles the architecture with the 2026-09-04 through 2026-09-06
offline implementation. JSON framing, the ordinary `hello`/`initialize`/
`action`/`present` session, the seven-message persistent-state model, the
SQLite backend and adapter, and an optional state-enabled session successor now
have accepted source-level evidence. A fixed two-language AArch64 gVisor/QEMU
demonstration reached real packaged KOReader offscreen. The persistent-note
native-UI fixture is independently accepted with an in-memory authority. A
native durable-state v1 functional join passed an independent source-only run,
but its exact-source evidence gate is blocked by incomplete executable closure;
its alleged lost-ack run proves only acknowledged receipt replay. Its trusted
receipt observer and the durable reader/two-boot QEMU joins remain incomplete.

The exact protocol facts now live in the consolidated reference above. This
architecture keeps richer resources, workspaces, surfaces, revisions,
provisioning, and self-hosting explicitly future rather than making the narrow
bootstrap look like the whole product.

### What changed in 0.2

This revision incorporates the KOReader/Wilkbook review and the subsequent container, Org Babel, and gVisor discussions. It replaces per-language sandbox designs with one execution boundary and small adapters **inside** that boundary. It also distinguishes source editing from renderer overlays, private files from authoritative workspace state, and saved data from visually settled output.

The self-hosting goal, recursive book model, EPUB direction, and immutable-revision approach are retained. The implementation sequence now starts with one end-to-end interaction in two languages, real isolation tests, and Workbench self-revision—not a complete abstract platform specification.

### Decision confidence is not implementation evidence

Each major section separates **Decision** (accepted direction, proposed implementation, or exploratory) from **Evidence** (reviewed code, upstream mechanism, or prototype needed), followed by a short **Needs attention** note. “Accepted direction” does not mean implemented or proven secure.

Repository observations below come from the preceding review of Wilkbook and KOReader v2026.03. They are integration pointers, not a new audit of current repository HEAD or a claim that ongoing stabilization is finished. Upstream sources for the execution design are collected in section 19. No PineNote gVisor performance or isolation test has been run for this document.

---

## 1. Executive thesis

Wilkbook should be a book-shaped computing environment, not a conventional tablet desktop with e-ink adaptations. The stable object is the book; computation appears as annotations, live regions, authoring tools, and scoped relationships to other books.

A generic trusted extension supplies loading, document access, delegated presentation, durable state, transactional workspaces, sandbox supervision, and capability checks. It must not contain the definitions of “exercise,” “truth table,” “course progress,” or “Exercise Studio.”

```text
small hand-authored seed Workbench
        ↓ creates and installs
successor Workbench revision
        ↓ creates
Exercise Studio book
        ↓ augments
Logic for Programmers
        ↓ supplies a real workload for
new exercise types, adapters, and tool-book revisions
```

The execution model should be **Babel-like in language extensibility, Linux-friendly inside the sandbox, and book-native at the boundary**. A book supplies an environment reference, a program, and an optional small adapter. The host grants particular book/workspace/surface handles—not ambient control of the tablet.

**Decision:** Accepted direction. **Evidence:** Product requirement, not a completed implementation. **Needs attention:** Prove the chain on-device with the host unchanged during tool creation and extension.

---

## 2. Product principles

### 2.1 A book, not a desktop

The document should remain the stable visual and conceptual object. We should avoid recreating windows, cursors, animated chrome, app launchers, and other desktop conventions unless a concrete workload proves they are necessary.

### 2.2 The stylus is for meaning; touch is for space

A useful default division is:

```text
stylus:
    write
    draw
    select semantically
    edit
    construct

touch:
    turn pages
    pan
    resize
    navigate
    reveal surrounding structure
```

This is a product principle, not an unbreakable input rule.

### 2.3 Ambiguity preserves ink

A pen gesture should become an action only when recognition is sufficiently confident and the result is safe and reversible. Otherwise, the stroke remains ordinary ink.

### 2.4 Revisions, not destructive mutation

Books, tools, and system books should create successor revisions rather than rewriting their only working copy in place.

```text
Workbench revision 1
    creates and tests
Workbench revision 2
```

Preview, install, rollback, and provenance should be first-class. Code rollback and state rollback must be designed separately; a new tool may migrate data.

### 2.5 One portable artifact; transactional working state

A published book or augmentation should be shareable as one file when useful. The live editing representation should not be forced to rewrite a ZIP/EPUB container after every pen stroke or edit.

```text
working form:
    operation journal + state + resources + preview

published form:
    extended EPUB, overlay, or self-contained capsule
```

### 2.6 Reversible, inspectable actions

Book operations should naturally support undo, history, replay, and audit. Append-only or operation-oriented state is a strong fit.

**Decision:** Accepted product principles. **Evidence:** Design commitments, not usability results. **Needs attention:** Stylus/touch vocabulary and practical rollback behavior on the tablet.

---

## 3. Extend the existing KOReader host

### 3.1 Implementation architecture

```text
Workbench / Exercise Studio / other tool-books
      definitions, resources, programs, environment references
                              │
            ┌─────────────────┴──────────────────┐
            │ trusted Wilkbook broker/supervisor │
            │ grants, state, workspaces, limits  │
            └─────────┬─────────────────┬────────┘
                      │                 │ bounded Book Protocol
          trusted KOReader bridge       ▼
                      │          gVisor sandbox / Sentry
             existing KOReader         │
        layout, widgets, UIManager     adapter + program(s)
                      │          Guix-prepared environment
          PineNote device integration
                      │
                    EBC

Separate preparation path:
    environment request → constrained provisioner → immutable closure
```

These are responsibilities, not a requirement for a separate daemon per box. The broker may initially be one service, but its privilege and IPC boundaries must remain explicit. Language adapters belong in the sandbox; the trusted Lua bridge belongs in KOReader.

A generic KOReader plugin is not a violation of self-hosting. A plugin containing exercise-specific schemas and evaluators would be. The host may know text fields, grids, selections, actions, and resources; Exercise Studio supplies their domain meaning.

### 3.2 Reuse before replacement

The preceding source review identified these integration points. Preserve them as a starting map and recheck them against the pinned implementation before coding.

| Need | Reviewed basis | Proposed addition |
|---|---|---|
| Book-selected actions | `ReaderHighlight:addToHighlightDialog()` | Register book-defined actions over a scoped selection. |
| Page overlays | `ReaderView:registerViewModule()` | One ordered Wilk layer manager with clipping and hit testing. |
| Resources and text locations | `CreDocument` resource, text, HTML, and XPointer access | A bounded document adapter rather than engine-object exposure. |
| Source editing | Text-editor plugin and `InputDialog` | Workspace-backed saves, validation, and diagnostics. |
| Repaint policy | `UIManager:setDirty()` and device refresh methods | Translate interaction updates into the existing path. |
| Device input and lifecycle | Wilkbook PineNote integration and reader service | Preserve routing; add scoped events and execution lifecycle. |

Sources and review-baseline caveat: [KOReader interfaces][ko-interfaces], [text editor][ko-editor], [Wilkbook integration][wilk-integration].

The reviewed Wilkbook packaging grafted device integration into a prebuilt KOReader bundle. Lua integration is therefore a different engineering commitment from changing bundled native engines. Do not assume a crengine modification is already covered by the existing packaging workflow. [Wilkbook package][wilk-package]

### 3.3 One presentation owner

Register one Wilkbook view module and order its internal layers explicitly. The reviewed KOReader code iterated registered modules with `pairs`, not an explicit stacking-order contract. Do not register each meta-book independently and assume a stable z-order. [ReaderView][ko-view]

KOReader owns placement, page layout, input routing, and final repainting. Programs submit bounded presentation updates to delegated surfaces. They never receive `/dev/fb0`, EBC control, global input devices, or pointers to KOReader objects.

### 3.4 Keep the trusted extension narrow

The host supplies generic operations and validates all requests, regardless of which SDK or adapter produced them. It should reuse KOReader rather than introduce a second UI event loop, compositor, or competing refresh scheduler.

A small extension API does not imply a tiny trusted computing base: KOReader, native document decoders, the bridge, broker, provisioner, launcher, gVisor, and relevant host kernel mechanisms still require maintenance. Isolating book programs does not retroactively isolate every static document parser.

**Decision:** Extend KOReader; do not replace it. **Evidence:** Useful interfaces identified in the preceding source review. **Needs attention:** Verify the pinned hooks, asynchronous service integration, layer/input ownership, and trusted parser exposure.

---

## 4. Delegated presentation and display policy

### 4.1 A surface is authority to one presentation area

A delegated surface should identify its owner, logical size, clip, permitted input, supported presentation operations, and current layout generation. A book component may update that surface; it may not paint arbitrary reader chrome or subscribe to all device input.

Support two complementary forms:

**Structured presentation:** host-rendered text, forms, choices, grids, and actions. Reuse KOReader's editor and widget facilities.

**Custom presentation:** bounded display lists or raster tiles for diagrams, simulations, and unusual tools. Where practical, decode complex formats inside the sandbox and cross the boundary using a simpler representation.

Both paths require size, command-count, allocation, and update-rate limits. Reject stale updates after navigation, rotation, reflow, or surface destruction. A response must identify the surface and layout generation to which it applies.

```text
component owns content
KOReader owns placement and input routing
Wilkbook validates and composes
existing device policy owns waveform choice
```

An overlay does not create space in a page. Attached panels, authored reserved regions, and structural publication revisions are separate mechanisms; section 9 defines that distinction.

### 4.2 Why semantic display hints remain useful

A damage rectangle identifies changed pixels, not whether they will be replaced immediately. The original names remain useful explanatory presets:

| Preset | Intended distinction |
|---|---|
| `PAGE_TURN` | Dense, completed content expected to remain stable. |
| `TRANSIENT_UI` | Temporary content likely to disappear. |
| `LIVE_INK` | Latency-sensitive incremental stroke updates. |
| `INK_SETTLE` | Finish the presentation of the same stroke stream. |
| `SELECTION_PREVIEW` | Provisional geometry repeatedly superseded. |
| `WIDGET_CHANGE` | A completed local content change. |
| `CLEAN` | Panel maintenance without a logical content change. |

These are not a required seven-value low-level API. Initially, carry a surface generation, damage, and whether an update is provisional or completed. Add role, quality preference, urgency, or expected rewrite timing only when measured workloads justify them. The richer dimensional scheme from 0.1 remains exploratory, not a bootstrap dependency.

Components do not choose `FAST`, `NORMAL`, `Y1`, or `Y4`. The bridge maps requests into `UIManager` and the PineNote device integration. Full cleaning and power control remain host-owned operations, not unrestricted book commands. The existing refresh path is the integration point, not a service to bypass. [UIManager][ko-uimanager]

### 4.3 Logical scene and ink

Within the Wilk layer manager, distinguish document-attached annotations, live regions, and temporary feedback. Cache a backing page or tiles only where it reduces work without conflicting with KOReader's own page lifecycle.

Immediate ink may stay host-rendered, while batched samples or completed strokes go to a sandbox for interpretation. Never require a synchronous language-process round trip for every pen sample. Preserve enough raw data for replay and later rerendering.

### 4.4 Three independent completion meanings

```text
Durably saved:
    data survives the documented failure boundary

Published:
    a presentation generation was submitted to the display path

Visually settled:
    the requested panel transition has progressed sufficiently
```

An answer can be saved before its feedback is painted. A stroke can be journaled before smoothing finishes. Neither `fsync` on the framebuffer nor a “settle” message is an authoring-storage commit.

A future driver fence can strengthen publication/quiescence guarantees; do not promise exact optical completion from a software event alone. The initial book protocol must distinguish its own acknowledgements from those driver guarantees.

**Decision:** Delegated surfaces and host-owned display policy are accepted
directions. **Evidence:** The accepted bootstrap implements one endpoint-bound
plain-text surface, generation invalidation, and exact KOReader offscreen paint.
The richer structured/custom surface protocol remains proposed. **Needs
attention:** Layout invalidation beyond navigation, custom-render limits, input
focus, and measured settling policy.

---

## 5. EPUB and one-file packaging

### 5.1 Default: an extended EPUB

The preferred publication envelope remains an ordinary EPUB with optional Wilk metadata, resources, and behavior. EPUB provides custom metadata vocabularies and linked metadata records; a structured Wilk manifest should carry complex definitions rather than stuffing them into short metadata values. The ordinary spine should remain useful without execution. [EPUB 3.3][epub33]

```text
/
├── mimetype
├── META-INF/container.xml
├── EPUB/
│   ├── package.opf
│   ├── nav.xhtml
│   ├── chapters/
│   └── assets/
└── WILK/
    ├── manifest.json
    ├── components/
    ├── schemas/
    ├── patches/
    └── fallback/
```

This is an illustrative layout, not a finished profile. Define manifest discovery, resource declarations, MIME types, and useful static fallbacks; validate sample exports. Base the first profile on EPUB 3.3's Recommendation rather than depending on unfinished changes in EPUB 3.4. [EPUB 3.3][epub33] [EPUB 3.4][epub34]

Metadata, package resources, execution authority, and installed environments are distinct. Merely opening an EPUB must not execute embedded programs, evaluate environment recipes, or approve requested capabilities.

### 5.2 Three distribution forms

| Form | Contents | Intended use |
|---|---|---|
| Extended EPUB | Readable publication plus Wilk definitions and resources. | Native interactive publication with static fallback. |
| Overlay | Base identity, augmentations, added objects/resources, and provenance. | Personal or shared additions without bundling the base. |
| Self-contained capsule | Overlay plus embedded base publication and optional dependencies. | Portable bundle preserving originals. |

Support one minimal export first, rather than fully specifying all three formats before a working book exists. Export should distinguish authored content from private answers, credentials, grant records, and runtime scratch. Sharing a tool never shares its previously granted authority.

### 5.3 Wrapping another EPUB

An embedded EPUB can be an opaque Wilk resource, but recursive interpretation would be a Wilk extension. Do not assume an ordinary reader descends into it as the outer spine, or that the exact nested packaging proposal is conforming without testing it. Multiple package rootfiles concern renditions of a publication, not arbitrary book-to-book augmentation. [EPUB multiple renditions][epub-renditions]

One-file packaging is separate from one-file execution readiness. An EPUB may name a pinned environment without bundling every dependency. A truly offline capsule would need the required platform closure or an already-installed equivalent; it can be much larger. The UI should distinguish “content available” from “interactive environment available.”

### 5.4 Editing is not continual ZIP rewriting

Workspaces hold source resources, object changes, and operation history. Committing produces an immutable revision; exporting produces a portable file. Do not rewrite the publication after every answer or pen sample.

An EPUB tool-book can augment a PDF or another source format. The package format of the tool does not determine which document adapters the target requires.

**Decision:** EPUB-first distribution is accepted; overlay/capsule details are proposed. **Evidence:** Standard metadata mechanisms exist. **Needs attention:** Conformance examples, export/reader round trips, dependency packaging, and private-state exclusion.

---

## 6. The recursive book model

Recursion should be expressed semantically, not primarily through nested ZIP files.

### 6.1 Core objects

#### `BookPackage` / `BookRevision`

An immutable authored or installed revision:

```text
identity
metadata
resources
semantic document
component declarations
relationships
provenance
signatures
```

#### `BookInstance`

User-specific durable state associated with a revision:

```text
progress
answers
annotations
preferences
component state
grants
operation history
```

#### `BookView`

One active presentation of a book, workspace, or composition:

```text
location and layout
mounted live regions
input subscriptions
transient interaction state
display transactions
```

#### `BookComponent`

A declarative or executable participant:

```text
identity and version
environment reference and revision
entry point and optional language adapter
session request and lifecycle scope
requested capabilities
state namespace
view/document contributions
```

#### `Workspace`

A transactional proposed book, augmentation, or successor revision:

```text
base revision(s)
mutable operation journal
new resources
new components
manifest edits
live preview
validation state
```

#### `Artifact`

A sealed result:

```text
installed revision
extended EPUB
overlay
self-contained capsule
exported resource
```

### 6.2 Relationships between books

A book may relate to another book by:

```text
embed:
    the child package is physically included

import:
    resources or interfaces are referenced by identity/hash

augment:
    overlays, actions, metadata, or behavior are contributed

derive:
    a new edition is defined as base + operations

aggregate:
    an approved collection is queried and presented
```

This supports the general transformation:

```text
book A augments book B and produces book C
```

`C` may be an overlay, a derived edition, a revision of `A`, or a new independent book.

### 6.3 Tool-books and lenses

A tool-book is attached to a target book as a lens:

```text
target book:
    supplies content and semantic structure

tool-book:
    supplies commands, editors, workflows, and renderers

workspace:
    receives proposed changes

composed view:
    previews the result
```

Exercise Studio is the first important example, but not a special host mode.

### 6.4 Meta-books

Meta-books operate over explicitly granted books or collections:

- full-text search;
- semantic search;
- tagging and collections;
- highlights across books;
- bibliographies and citations;
- teacher/course composition;
- translation or commentary layers;
- accessibility augmentation;
- book-making and revision management.

### 6.5 Execution objects are separate from book objects

An environment is immutable software, a sandbox is an execution/trust domain, and an interpreter session is optional live language state. None is identical to a book instance or view. Section 7 defines their ownership and reuse rules.

A recursive book relationship does not automatically launch another sandbox, import its entire environment, or delegate authority. Components may be activated on demand. One tool-book can use several domains, and a granted meta-book service can refer to several publications.

**Decision:** Recursive relationships and separate instance/view/workspace concepts are accepted direction. **Evidence:** Conceptual model, not implemented composition. **Needs attention:** Dependency versions, layer precedence, conflicts, and explicit activation/delegation.

---

## 7. Babel-like programs in Guix environments under gVisor

### 7.1 Separate language support from isolation

> **Guix supplies the software. gVisor contains its execution. Wilkbook grants its relationships to books and presentation. Language adapters are ordinary sandboxed programs.**

The useful Org Babel precedent is incremental language support: basic execution can precede richer result handling and persistent sessions. Borrow that model, not an assumption that trusted-editor evaluation constitutes a sandbox. Wilkbook does not require Emacs or Org syntax. [Babel language support][babel-languages] [Babel sessions][babel-sessions]

| Babel concept | Wilkbook counterpart |
|---|---|
| Source block | Named executable block or component resource. |
| Language backend | Small adapter inside the execution environment. |
| Header arguments | Inputs, execution options, session request, and requested interfaces. |
| Named session | Explicit interpreter session inside a scoped sandbox. |
| Results | Text, values, artifacts, proposed edits, or surface updates. |
| Tangling | Producing source resources in a book workspace. |

The minimum adapter accepts input, invokes code or an executable, and returns a result. Richer adapters can expose functions, interactive events, diagnostics, or persistent interpreter state. Advertise supported features; do not pretend all languages have identical execution semantics.

Guile and Python are the first two sandboxed proof languages through the
**same** host protocol. Guile also implements the trusted authority,
state/storage, OCI, and supervision side; Python in host tests is an independent
oracle, never an alternative production broker. The trusted KOReader bridge
remains Lua. LuaJIT, compiled programs, shell tools, and a Wasm engine can
follow inside the same execution boundary. No separate trusted KOReader module
is needed for each language.

### 7.2 Environment plus entrypoint, not book-controlled container flags

A book declares a software environment and program. The host resolves that declaration and constructs the sandbox configuration. A full operating system, Docker daemon, Kubernetes, or init system is not required: `runsc` can execute an OCI bundle directly. [gVisor OCI guide][gvisor-oci]

```yaml
# Illustrative declaration, not an implemented manifest schema.
component: exercise-authoring
protocol: wilk/0
environment:
  reference: logic-tools
  revision: LOCKED_ENVIRONMENT_REVISION
  platform: aarch64-linux
entrypoint:
  - /profile/bin/python3
  - /book/components/studio.py
adapter: /book/adapters/wilk-python.py
session: authoring
requests:
  - selected-document.read
  - draft-workspace.edit
  - delegated-surface.present
```

The supervisor supplies a read-only root and only the necessary Guix store closure at its expected paths, a sanitized environment, private writable directories, and explicit handles. Do not expose the entire host store, current working directory, or library simply for convenience. Preserve profiles/closures against garbage collection while installed revisions depend on them; storage budgeting and eviction need policy.

A declaration cannot supply arbitrary host paths, privileged OCI options, `runsc` control access, or self-approved grants. The intended launch is:

```text
Guix-prepared closure + host-generated execution policy → runsc
```

It is not a nested `guix shell --container` invocation used as the authority model. Editing program source normally reuses the environment and changes only draft resources.

### 7.3 Provisioning is separate from execution

Guix manifests are Scheme code, not inert dependency lists. Recipe evaluation therefore has an execution boundary of its own. [Guix manifests][guix-manifests]

```text
prepare:
    evaluate approved or constrained recipes
    resolve, fetch, verify, or build dependencies
    produce a pinned environment record and closure

execute:
    run a program in the prepared environment
    with current grants, limits, private state, and presentation handles
```

Initially use a small set of approved, pinned environments. Workbench may later create new recipes on the tablet and submit them to a separately constrained provisioner. Ordinary book sessions do not receive the Guix daemon socket, arbitrary channels, host build credentials, or unrestricted recipe evaluation.

Record channel/revision inputs, architecture, resolved closure, and source provenance. Reproducible inputs do not make code trustworthy or guarantee future dependency availability. Separate download/build consent and resource budgets from ordinary execution grants.

### 7.4 What the gVisor boundary supplies

gVisor's Sentry implements an application-kernel interface between the program and host Linux. It reduces direct exposure to the host syscall implementation; it is neither just a namespace container nor a full guest Linux boot. Host kernel, gVisor support processes, configuration, and the broker remain in the security boundary. gVisor does not protect a broker that authorizes the wrong operation. [gVisor security architecture][gvisor-security]

Native libraries, subprocesses, and FFI are legitimate **inside** this sandbox. We do not need separate “safe Guile” and “safe LuaJIT” implementations. Actual Linux-feature compatibility remains a test requirement for each environment. [Application compatibility][gvisor-compat]

A Wasm interpreter inside gVisor uses the same interface as Python. An optional future in-process Wasm backend would be a separate security decision—not an automatic shortcut around isolation.

### 7.5 Default sandbox policy

The baseline policy is deny-by-default outside assigned resources:

| Area | Default |
|---|---|
| Program/dependencies | Read-only prepared closure. |
| Book inputs | Selected read-only resources or snapshots only. |
| Working files | Private scratch and an explicit output directory. |
| Persistent files | Optional, bounded, private per execution domain. |
| External network | Disabled; use explicitly granted broker operations. |
| Host devices/services | No framebuffer, input devices, general sockets, Guix daemon, or launcher control. |
| Shared book mutation | Broker-mediated workspace operations. |
| Resources | CPU/memory budgets, task limits, deadlines, and bounded storage/output. |

This is a proposed policy, not a complete OCI specification. Do not use `runsc do` as the production launcher: its documented convenience default exposes the host filesystem read-only. Construct a narrow bundle instead. [gVisor security architecture][gvisor-security]

Account for the whole sandbox: application state, Sentry, Gofer/support processes, and I/O. Host cgroups and guest task limits must be checked together; do not assume a guest process corresponds to a separate host process. Disk/scratch quotas and broker-induced work also require limits. [Resource model][gvisor-resources]

A failure to start the required sandbox must fail closed. A native or namespace-only development mode, if supplied, must be explicitly selected and visibly identified; it must not silently become the untrusted-book fallback.

### 7.6 The Book Protocol

Use a versioned message/object protocol, not a Lua ABI or a container filesystem
as the cross-book API. SDKs are conveniences; the trusted Guile authority
validates every raw message. JSON is the retained bootstrap encoding, not merely
a possibility and not a canonical signing or revision-identity form.

The accepted bootstrap is deliberately finite:

```text
ordinary session:
    book -> authority: hello, present
    authority -> book: initialize, action, cancel

persistent state:
    book -> authority: state-read, state-commit
    authority -> book: state-ready, state-value, state-committed,
                       state-conflict, state-commit-failed
```

The [protocol and state reference](book-computer-protocols.md) records every
field, direction, bound, state transition, and acknowledgement meaning. The
wire is a dedicated stream of four-byte big-endian lengths and UTF-8 JSON
objects, each at most 65,536 payload bytes. Opaque IDs are strings; exact
integer fields require lexical integer tokens. The broker derives caller
identity from the private endpoint object created with the supervised
connection, not from a peer field, component name, diagnostic label, handle
string, or FD number.

The accepted QEMU fixture proves `run --pass-fd=3:3` donation to two fixed book
programs and keeps stdout/stderr separate as bounded diagnostics. It does not
prove a general manifest-selected book, a reconnect/checkpoint path, aggregate
rate scheduling, automatic timer leases, or hostile-book qualification.
[runsc exec][gvisor-exec]

The earlier illustrative `call`/`reply`/`event`, resource and workspace
operations, subscriptions, `checkpoint_state`, `prepare_suspend`, and
`shutdown` messages are **future**, not accepted wire vocabulary. Add them only
as exact schemas with ownership, bounds, transitions, and executable negative
tests. Do not expose launcher control, host paths, framebuffer/page payloads, or
diagnostics on the protocol stream.

### 7.7 Small initial object surface

| Handle | Initial operations |
|---|---|
| `Resource` | Read a granted immutable input/resource. |
| `Document` | Read a selection, resolve an anchor, query supported structure. |
| `State` | Read/write private durable data through transactions. |
| `Surface` | Present bounded content and receive delegated events. |
| `Workspace` | Read/edit draft resources or objects; validate and preview. |
| `Artifact` | Import a permitted output; seal/export a revision. |

`Library` queries and longer-lived collection services come later. `RuntimeTest` is a scoped broker request to test draft code under a fixed environment and grant envelope—not permission to operate `runsc` directly.

An output filename is not a host path capability. Import files from an explicitly allowed output area with size bounds, path/symlink checks, and a stable snapshot before the trusted host consumes them.

### 7.8 One-shot and interactive use

**One-shot:** input plus resources → program → text/value/artifact/proposed edit → exit. A CLI program may need only a small wrapper. User intent to execute must be explicit; merely opening a book does not imply running arbitrary blocks.

**Interactive:** initialize → receive actions → update a surface or workspace → checkpoint/stop. A persistent interpreter supports authoring and repeated evaluation without reloading modules on every action.

Common forms can remain declarative. Their reusable evaluators and custom behavior live in book programs, not exercise-specific host code.

### 7.9 Environment, sandbox, session, component, view

```text
Environment:
    immutable software and dependencies; reusable across sandboxes

Sandbox:
    isolated execution and trust domain; may contain several processes

Interpreter session:
    optional named language state within a sandbox

Component:
    a book-defined participant using an environment and session policy

View:
    temporary presentation to which surfaces may be delegated
```

One book can use several sandboxes. One authorized tool sandbox can contain several languages or cooperating processes. A search meta-book may have a separately approved collection-wide service. Do not default to one live sandbox per installed book.

Scope session names by user, book instance, component/trust domain, and environment. **Sharing a sandbox is sharing a trust domain**: different handle lists inside one sandbox are not sufficient separation for mutually untrusted components. Reusing immutable dependencies is safe to design for; reusing private memory or scratch across unrelated domains is not.

A fresh interpreter in an existing sandbox is a new process, not fresh isolation. Do not downgrade grants on a warm sandbox and assume previously read data disappeared.

### 7.9.1 Versions and generations are typed, not interchangeable

The current bootstrap already has separate protocol version, endpoint identity,
surface generation, action sequence, state-grant generation, state version,
private UI generation, SQLite schema version, and Guix system generation. The
future model adds environment and `BookRevision` identities. Each has a
different owner and invalidation rule; none may be accepted merely because its
integer equals another. The [generation taxonomy](book-computer-protocols.md#9-generation-and-version-taxonomy)
is normative for current documentation.

### 7.10 Startup modes and checkpoint templates

| Mode | What remains ready | Purpose |
|---|---|---|
| Fresh sandbox | Installed dependencies only. | Separate trust domain or clean execution. |
| Fresh interpreter in warm sandbox | Sandbox and its private environment. | Babel-like one-shot blocks within the same domain. |
| Warm interpreter | Sandbox, modules, and intentional session state. | Responsive interactive authoring. |
| Restore clean template | Initialized, authority-free checkpoint. | Possible later fast fresh isolation. |

The first three must be measured separately. gVisor adds syscall, memory, and filesystem costs; it does not inherently make interpreter initialization faster than native execution. [Performance guide][gvisor-performance]

gVisor supports checkpoint/restore into a new container. Our template proposal is to initialize standard libraries **before** granting private book data, then restore into a fresh instance with a new broker handshake. [Checkpoint/restore][gvisor-checkpoint]

Template safety requires no captured grants, user data, live host channels, or reused instance identity. Define reinitialization of randomness and instance-local state, compatibility with environment/runtime/CPU features, and reconnect behavior. A per-user session checkpoint is private state, not a globally reusable template.

Checkpoint images are disposable startup caches, not authoritative authored-book storage. Plain restart from durable state must remain supported. Defer templates until ordinary launch, isolation, and suspend work.

### 7.11 ARM64, power, and release gates

gVisor documents ARM64 support. Package a pinned release and all of its required helper binaries, not only `runsc`; current installation guidance describes a multi-file distribution. Do not depend on runtime auto-downloads for the tablet. [Installation][gvisor-install]

Establish a Systrap baseline and compare KVM when the deployed kernel and boot configuration expose usable virtualization. Systrap does not require virtualization; KVM has different hardware and performance requirements. Neither is yet validated on this PineNote image. [Platforms][gvisor-platforms]

Upstream issue #13361 reports elevated idle CPU on an ARM64 Systrap setup using an Android-derived 6.12 kernel and `release-20260525.0`. It is a reason to measure idle wakeups and power, not evidence that Wilkbook has that defect. [ARM64 idle report][gvisor-idle]

Begin with on-demand sessions. On book close, suspend, crash, or grant revocation, stop accepting stale operations, cancel expendable work, persist acknowledged state, and stop the entire execution domain when required. Avoid leaving descendants alive after killing only the initial interpreter. Inhibiting suspend must be a bounded host-approved lease.

**Decision:** Guix + gVisor + broker is the selected prototype architecture;
Babel-style adapters are accepted direction. **Evidence:** The fixed Guile and
Python books have executed under the selected ARM64 gVisor/Systrap QEMU profile,
through donated Book Session FDs, and reached packaged KOReader offscreen. This
is accepted fixed-fixture compatibility and cleanup evidence, not integrated
PineNote proof or general hostile-book qualification. **Needs attention:** A
new USER_NS-enabled device generation, provisioning confinement, aggregate
resource policy, general book selection, startup/idle measurements, suspend,
and hardware lifecycle enforcement.

---

## 8. Capabilities and authority

### 8.1 Isolation and authority are separate

gVisor contains program execution. The broker decides what that execution may read, modify, render, export, or delegate. Neither replaces the other.

A capability handle should bind a target, allowed operations, bounds, lifetime, revocation identity, and delegation rules to a supervised execution domain. Treat handles as opaque and non-forgeable through validation and connection ownership; a requested permission string is not a grant.

```text
DocumentRead(selected target revision)
WorkspaceEdit(one draft)
StateWrite(private exercise-progress namespace)
SurfacePresent(one delegated surface and generation)
LibraryQuery(user-approved collection)
NetworkFetch(approved destinations and request policy)
```

Private scratch, language caches, and optional private databases may use ordinary files inside the sandbox. Shared book changes, authoritative workspace commits, and grants use broker operations. This preserves Linux-tool compatibility without exposing the library as a writable mount.

### 8.2 Delegation and trust domains

Exercise Studio may edit an entire draft while a preview evaluator receives only one exercise and test-state namespace. If those participants are mutually untrusted, put them in separate sandboxes and mediate their communication. An interpreter session or another process in the same sandbox is not the strong boundary between them.

Nested books never inherit ambient parent authority. Delegation must attenuate scope and remain revocable. Provenance and signatures identify packages; they do not automatically authorize more resources. Host-supplied system books may receive a distinct, explicitly managed grant profile.

### 8.3 Tags select policy; ordinary tags do not create authority

Separate descriptive metadata from user-controlled authorization collections. A component allowed to tag books must not be able to add arbitrary books to its own permitted search set.

A grant can mean “read books in this user-approved collection.” The broker resolves membership and issues bounded handles. Membership changes revoke future access and trigger source-specific derived-data invalidation.

### 8.4 Revocation is not forgetting

Revoking a handle prevents later authorized operations. It cannot automatically erase information already copied into a program, an embedding index, an exported artifact, or a remote service.

Track source revision/provenance for derived records. Define deletion/tombstoning, cache invalidation, private-store removal, and any limits on the guarantee. Stop or replace affected execution domains where previously acquired authority cannot safely be removed from a live session.

### 8.5 Grant UX and dynamic programming

Use intelligible grants: “edit this draft,” “read this selected passage,” or “index this approved collection,” rather than exposing syscall lists.

Book code may change dynamically within its existing execution domain. Workbench must be able to edit, evaluate, compile, and test source without requesting permission for every keystroke. New environment provisioning, new authority, publication, and activation of a successor revision are separate controlled actions.

```text
dynamic code/data:
    normal within the authorized sandbox

new dependencies:
    constrained provisioning workflow

new authority:
    separate host grant

installed successor:
    explicit revision activation with provenance and rollback
```

### 8.6 Enforcement and release boundary

The trusted bridge must not execute book-supplied Lua through KOReader's plugin loader or insert package resources into its trusted module search path. The existing plugin mechanism is host integration, not a book-code security boundary. [KOReader plugin loader][ko-pluginloader]

Validate protocol requests even from an approved adapter. Bound not just sandbox CPU/memory but broker work, rendering allocations, event queues, logs, and imports. Presentation results and package resources remain untrusted inputs.

A developer may explicitly enable trusted native experiments. Do not describe them as equivalent to the sandboxed profile, and do not distribute an untrusted-execution feature before the selected profile passes its isolation tests. Namespace-only fallback must not occur silently.

**Decision:** Object capabilities and explicit delegation are accepted direction. **Evidence:** Enforcement design, not a completed security audit. **Needs attention:** Concrete grant storage, protocol validation, confused-deputy tests, authorization metadata ownership, and derived-data revocation policy.

---

## 9. Workspaces, source documents, and durable revisions

### 9.1 A workspace is a proposed book, not a mutable installed package

A workspace combines base revisions, source-resource changes, Wilk-authored objects, operation history, component definitions, and preview state. Tools can create a blank book, an augmentation, or a successor of their own revision.

Keep three representations distinct:

```text
Imported publication:
    original resources and source-format identity

Wilk-authored objects:
    stable IDs, explicit schemas, editable fields and behavior bindings

Augmentation operations:
    attach, insert, replace, reference, or remove authored objects
```

Do not first convert every arbitrary EPUB into a universal editable AST. The initial bridge should query the structure KOReader actually exposes and preserve original resources. The reviewed `CreDocument` wrapper supplies useful resource and location access, not an established general-purpose live-DOM editing API. [CreDocument][ko-document]

### 9.2 Three different presentation/editing mechanisms

**Attached interaction:** a marker, selection action, link, or margin note opens a panel or an exercise page. This needs no insertion into the target's text layout and is the first integration target.

**Reserved inline region:** authored content reserves space and the host delegates an interaction surface there. Sizing, pagination, accessibility, and behavior under font changes need a prototype.

**Structural revision:** a workspace modifies source resources, generates a derived preview publication, and reopens/repositions it in KOReader. Initially, `insert_after` means such a source operation—not live mutation of crengine's document.

```text
answer changes → instance state and surface repaint
exercise-field edits → workspace object and editor update
chapter structure changes → regenerate preview and reload/reposition
```

Do not rebuild the EPUB on each answer or keystroke. Audit existing book-generation utilities before introducing a new exporter.

An EPUB tool-book may augment a PDF. Reflowable and paged document adapters must advertise different capabilities. A PDF selection can support attached exercises without pretending that paragraph insertion into its layout is available.

### 9.3 Source identity, renderer location, and view geometry

```text
Source identity:
    publication revision + resource + stable node/text/page anchor

Renderer location:
    KOReader location in the currently loaded document

View geometry:
    rectangles valid only for a specific layout generation
```

Persist semantic/source anchors and appropriate fixed-page geometry, not screen coordinates alone. Preserve text context or other recovery evidence. Ambiguous reattachment produces an orphan to review, not a confident-looking guess.

For overlays, identify both the exact base revision and any explicitly supported compatibility rules. Full content identity, publisher identifiers, filenames, and reader sidecar identities have different purposes and must not be substituted silently.

### 9.4 Transactions and operation history

Initial operations can be modest: set a field, add a resource, attach an object, declare a component, and commit a draft revision. Expand to structural transformations when the source adapter can implement them safely.

Carry operation IDs, provenance, expected revision, and transaction boundaries. Define acknowledgement durability, undo, crash recovery, and retry behavior. An operation log is useful infrastructure, not an automatic solution to distributed merges or reproducible execution.

Record external inputs/results when replay depends on them. Programs with time, randomness, or mutable private files are not deterministic merely because their launch messages are logged.

### 9.5 Persistent storage and rollback

Choose persistent locations deliberately and verify them across system upgrades. A possible layout is:

```text
persistent Wilkbook data root (path to be chosen):
    packages/       immutable revisions and resources
    instances/      user answers, annotations, preferences, durable state
    workspaces/     draft resources, journals, and snapshots
    authority/      grants and revocation/provenance records
    environments/   pinned environment records and retention references

reconstructible storage:
    previews, layout caches, clean startup templates, disposable scratch
```

Do not assume that KOReader's configuration directory has the same persistence guarantees as the library/data partition. Preserve compatible reading-position integration, but do not make path-based sidecars the authority store for authored tools. Portable state must be parsed as data, not executed as supplied Lua. [Reader service][wilk-reader] [DocSettings][ko-docsettings]

```text
edit → validate → isolated preview → seal revision → explicitly activate
```

Keep test-instance state separate from the user's working state. Activation may require a schema migration; rollback of code is not automatically rollback of data. Preserve snapshots or compatible versions before migrations, and test restoration with actual authored work.

Guix system generations manage the trusted host. Book revisions manage publications and user-created tools. Adding an exercise must not require an operating-system rebuild. Environment installation likewise has its own lifecycle rather than being confused with book-state commits.

**Decision:** Workspaces and immutable successors are accepted direction. **Evidence:** Integration and storage prototype needed. **Needs attention:** Source adapters, preview cost, identity, transactions, migrations, anchor recovery, and multi-overlay conflicts.

---

## 10. Books must be able to define book systems

For self-hosting, a book must be able to define new concepts without host changes.

A tool-book may define:

```text
schemas
typed block kinds
renderers
editors
commands
constraints
queries
workflows
component bindings
imports
fallback renderers
```

For example:

```text
type: logic.truth_table_exercise

fields:
    proposition
    variables
    expected_rows
    explanation
    hint_policy

views:
    reading
    answering
    authoring
    fallback

behavior:
    evaluate_answer
    reveal_hint
    record_attempt
```

The host sees a typed document object and generic contributions. It does not understand truth tables.

### 10.1 One object, several views

The same exercise object should support:

```text
reading view:
    question and static explanation

answering view:
    editable answer and feedback

authoring view:
    fields, evaluator selection, and preview

fallback view:
    useful static representation in an ordinary reader
```

This avoids a separate hidden CMS representation.

### 10.2 Declarative composition and ordinary code

Common systems should be constructible from data:

```text
schemas
forms
state machines
commands
constraints
queries
view composition
transform pipelines
```

Common exercise types should not require custom executable code:

```text
multiple choice
boolean expression
truth table
short text
numeric expression
ordering
matching
structured fill-in
```

A reusable evaluator component can implement shared operations, so using an existing exercise type need not require writing code. Creating new tools and evaluators, however, is a normal programming activity—not a special privileged escape hatch. Guile, Python, LuaJIT, compiled programs, and Wasm engines participate through the same sandbox protocol.

Do not build a universal meta-object system first. Begin with generic values, fields, grids, actions, resource/source editing, and callable program components. A book should compose these into its own editor and behavior; add more reflection only when self-revision needs it.

**Decision:** Book-defined tools and several views of the same object are accepted goals. **Evidence:** Prototype needed. **Needs attention:** The smallest useful composition model and on-device edit/test/debug ergonomics.

---

## 11. The self-hosting bootstrap

### Stage 0: hand-authored seed Workbench

The first Workbench may be authored outside Wilkbook, like the first compiler for a new language.

It should contain only generic facilities:

```text
browse semantic book structure
inspect and edit typed values
edit source text
create and arrange nodes
add package resources
declare or attach components
preview a workspace
validate
commit and install a revision
export an artifact
```

Its interface may be crude. Reuse KOReader's generic text and input editing machinery through the bridge; save into a workspace, not arbitrary host paths. Start with an installed, pinned environment so changing source does not require a new dependency build.

### Stage 1: Workbench revises itself

The first real proof:

1. Open Workbench’s source book.
2. Create a successor workspace.
3. Change both presentation and executable behavior using Workbench—not only a title or color.
4. Preview the successor.
5. Commit and install it as a new immutable revision.
6. Reopen and use the new feature.
7. Retain rollback to the previous revision.

### Stage 2: Workbench creates Exercise Studio

Exercise Studio is an ordinary tool-book assembled inside the system. It may import reusable pieces:

```text
structured form editor
semantic anchor picker
source editor
component test runner
preview view
artifact exporter
```

It adds domain-specific concepts:

```text
exercise templates
answer models
evaluators
hint policies
progress schemas
exercise-authoring workflow
```

### Stage 3: Exercise Studio augments *Logic for Programmers*

A tablet-native flow:

1. Open *Logic for Programmers*.
2. Attach Exercise Studio as an authoring lens.
3. Select a passage or anchor; begin with an attached interaction rather than assuming live inline insertion.
4. Create an exercise object.
5. Enter the prompt, answer model, evaluator, and hints.
6. Preview it in the target book.
7. Answer it as a learner.
8. Commit the augmentation.
9. Reopen it after restart.
10. Export an overlay or self-contained publication.

### Stage 4: Exercise Studio extends itself

Use Exercise Studio to add a new exercise type—such as natural-deduction proof steps—to a successor revision of Exercise Studio.

This is the stronger proof that the system is reflective rather than merely configurable. The installed bridge and supervisor remain unchanged during the demonstration.

A further extensibility proof is creating a new language adapter or tool component inside Workbench. Adding its dependency environment uses the controlled provisioning workflow; adding the adapter itself does not add trusted host code.

### Hard acceptance test

> Starting from a stock Wilkbook installation and the seed Workbench, with no SSH session and no external computer, a user can create and install an Exercise Studio book, then use it to add a new interactive exercise to *Logic for Programmers*, preview it, preserve it across restart, and export it as a portable augmentation.

Stronger test:

> The installed Exercise Studio can create a successor revision of itself that supports a new exercise type.

**Decision:** The self-hosting acceptance test is accepted. **Evidence:** Not yet demonstrated. **Needs attention:** Minimal seed, recoverable state migration, isolated preview, export, and genuinely on-device construction.

---

## 12. Exercise Studio as the first real meta-book

Exercise Studio is not a privileged application. It is a book attached to another book as a lens.

```text
Logic for Programmers
    supplies content and anchors

Exercise Studio
    supplies exercise types, editors, commands, and workflows

draft overlay
    receives the changes

composed preview
    shows the result
```

### 12.1 Outputs

#### Personal augmentation

A local patch/operation set bound to the selected base edition.

#### Shareable overlay

A portable augmentation that another user can apply if they have a compatible base.

#### Self-contained publication

A new extended EPUB or capsule containing the readable book, exercises, resources, components, and manifest.

Redistribution rules may determine which form is legally and practically appropriate.

### 12.2 Example object

```yaml
type: logic.boolean-equivalence

prompt: "Are these expressions equivalent?"

left_expression: "T && (I || D)"
right_expression: "(T && I) || (T && D)"

answer:
  editor: boolean-choice

evaluation:
  operation: compare-truth-tables

hints:
  - "Look for a valuation that distinguishes the expressions."

fallback:
  render: worked-example
```

The generic system does not know what this means. An imported logic component and view definitions do.

**Decision:** Exercise Studio is the first substantial tool-book target. **Evidence:** Concrete proposed workflow. **Needs attention:** Anchor integration, evaluator composition, static fallback, and portable augmentation tests.

---

## 13. Marginalia, settings, and other applications

These remain valuable, but should consume the same substrate rather than each inventing a separate framework.

### 13.1 Pen and ink

Raw pen capture, low-latency display, stroke storage, and input routing are host-level primitives. Annotation semantics and workflows can increasingly be implemented as a tool-book.

A useful pipeline:

```text
raw samples
→ immediate coarse/live ink
→ durable stroke operation
→ pen-up smoothing/vector fitting
→ quality settle
→ semantic attachment where applicable
```

A stroke should preserve:

```text
raw samples
fitted geometry
style
bounding box
document identity
visual anchor
optional semantic anchor
```

### 13.2 Marginalia tool-book

A Marginalia book/lens could provide:

- circle-to-select;
- margin-note attachment;
- underline/highlight semantics;
- scratch-out with undo;
- annotation collection views;
- export and sharing.

The first complete user experience remains compelling:

> Write a thought beside a passage, close the book, and later find the thought exactly where it belongs.

### 13.3 Settings book

A settings book is a first-party system book with narrowly scoped configuration grants, not an unrestricted root application. It exercises:

- live regions;
- typed state;
- capability-scoped configuration writes;
- static fallback documentation;
- and book-shaped system administration.

It should use generic discrete controls rather than create a separate GUI toolkit.

### 13.4 Search and tagging meta-books

A search meta-book can receive a scoped `LibraryQuery` plus text-read handles for books the user opted in through authorization collections. Descriptive tags alone cannot expand the grant. Results return book identities and semantic anchors, not host paths; derived records retain source provenance for invalidation.

**Decision:** Reuse the same book substrate for these applications. **Evidence:** Existing input/reader foundation; application flows remain proposals. **Needs attention:** Anchoring, gesture ambiguity, power lifecycle, and scoped system-book permissions.

---

## 14. Implementation sequence and acceptance gates

Develop a narrow working path, then document the interface it actually needs. Do not make complete EPUB, workspace, capability, and multi-runtime specifications prerequisites for the first book-defined interaction.

**Current status (2026-09-06):** host and QEMU bootstrap work has established a
bounded JSON/session path, fixed-language ARM64 gVisor compatibility, a fixed
offscreen KOReader interaction, separately accepted persistent-state
components, and an accepted in-memory persistent-note native-UI fixture. The
native real-storage v1 functional join passed independent source-only execution,
but exact-source acceptance is blocked by NI-1/NI-2. The trusted receipt
observer, corrected native successor, durable KOReader join,
two-boot QEMU state recovery, general Workbench, and every physical-device Book
Computer claim remain open. The phases below are product gates, so none is
complete merely because one of its offline prerequisites is accepted.

### Phase 0: preserve the reader baseline

Finish the known stabilization work and repeatable reader/suspend/recovery validation. Record exact image and package revisions. Maintain rollback and a bounded maintenance lane; do not wait for every speculative display optimization.

### Phase 1: execution proof, then qualification on the actual PineNote

Prepare a pinned Guix environment with Guile and Python; package a complete pinned gVisor runtime. Generate a narrow OCI bundle and connect one private broker channel. Prove input/result exchange in both languages with no language-specific trusted-host change. The fixed QEMU version of that exchange is accepted; the actual-PineNote and general-book versions are not.

Measure cold sandbox startup, new interpreter inside a warm sandbox, and warm interpreter response separately. Capture p50/p95/p99 and maximum where meaningful, total memory including support processes, idle CPU/wakeups/power, and suspend/restart behavior. Compare Systrap with KVM only after verifying KVM availability. Test real intended libraries, not only trivial output.

**Gate:** Usable execution and measured lifecycle costs under the selected profile. No unsupported startup-time or idle-power claims.

### Phase 2: one book-defined KOReader interaction

Add the generic trusted bridge through the existing integration mechanism. A tool-book defines a small record editor or form, invokes either language, and presents a value or diagram on a delegated surface. State survives reopening.

Use existing KOReader widgets, selection hooks, text editing, and repainting. Keep the UI asynchronous. Validate small presentation messages before adding complex rendering formats.

**Gate:** The same book interaction works with both adapters, and navigation/rotation rejects stale results.

### Phase 3: enforce the boundary before broad execution

Exercise denial and failure cases: ungranted files/network, forged or cross-session handles, output path traversal/symlink races, oversized/deep messages, render floods, infinite loops, allocation/task exhaustion, child-process survival, worker crash, and cancellation.

Test whole-domain shutdown, private-store separation, no runtime/provisioner socket exposure, no ambient credential inheritance, and recovery of acknowledged writes after forced termination. Bound broker work as well as sandbox work.

**Gate:** Repeatable isolation/lifecycle tests on the deployed configuration. A trusted development mode does not satisfy this gate.

### Phase 4: Workbench self-revision

Add the minimum workspace-backed generic editor, diagnostics, preview, revision activation, and export. Use Workbench to change both presentation and executable behavior in its successor. Run the changed code within the existing environment; test a deliberately broken successor and rollback.

**Gate:** The new feature was authored on-device, persists across restart, and requires no host rebuild. Known-good Workbench and pre-migration data remain recoverable.

### Phase 5: create Exercise Studio in the book system

Using Workbench, create exercise definitions, authoring/answering views, evaluator components, and attachment commands. Reuse generic host fields/grids/actions; keep logic-specific concepts out of the bridge.

**Gate:** Exercise Studio is an ordinary tool-book created on the tablet, not a disguised privileged plugin.

### Phase 6: augment the real target and extend the tool

Attach an exercise to a passage in the available *Logic for Programmers* edition, test it, preserve progress, and export a portable augmentation. Start with an attached panel or exercise page; add inline structural insertion only after source/preview behavior is proven.

Then use the book system to add a genuinely new exercise behavior or language adapter, activate a successor Studio, and use it. The trusted host stays unchanged.

**Gate:** The central self-hosting acceptance test and tool-extension test pass.

### Phase 7: grow only from demonstrated needs

Add reserved inline regions, structural EPUB previews, user-created environment provisioning, collection-scoped search, multiple lenses, or clean checkpoint templates as separate experiments. New environment recipes use the constrained preparation workflow, not privileged host evaluation.

Turn proven interfaces into `Wilk EPUB Profile`, `Book Protocol`, `Execution Profile`, and `Workspace Operations` documents with versioned conformance tests. Prefer executable examples and captured traces to speculative surface area.

**Decision:** This is the proposed delivery sequence. **Evidence:** Accepted
offline prerequisites are identified above and in the protocol reference; no
whole product phase is declared complete by this document. **Needs attention:**
Concrete budgets, integrated durable reader state, test-harness ownership,
pinned device configuration, and on-tablet usability.

---

## 15. Decision and evidence summary

| Area | Decision | Evidence | Needs attention |
|---|---|---|---|
| Self-hosting book computer | Accepted direction | User requirement | On-device tool construction and extension. |
| Extend KOReader | Accepted direction | Pinned v2026.03 hooks, widgets, lifecycle, and exact offscreen paint accepted | Immutable shipping plugin and device lifecycle. |
| Guix environments | Selected prototype | Existing provisioning mechanisms | Closure packaging, retention, safe recipe evaluation. |
| gVisor isolation | Selected prototype | Fixed ARM64 Systrap Guile/Python execution accepted in QEMU | PineNote USER_NS generation, hostile workload, resource and power tests. |
| Babel-style adapters | Accepted direction | Same accepted fixed Book Session exchange in Guile and Python | General book/adapter selection. |
| Native libraries/FFI inside sandbox | Accepted direction | Execution boundary is below language | Workload-specific syscall/JIT/library compatibility. |
| Warm interpreter sessions | Proposed | Ordinary session model and `runsc exec` | Latency, memory, idle power, cleanup. |
| Clean checkpoint templates | Exploratory optimization | Upstream checkpoint/restore | Authority-free snapshots, reconnection, measured benefit. |
| Book Protocol bootstrap | Accepted implementation | Framing plus ordinary and state schemas/FSMs accepted at exact hashes | Aggregate scheduling, timer leases, richer exact object schemas. |
| Persistent text state | Accepted components and native UI; blocked v1 join | SQLite/backend/protocol/adapter/delegate and in-memory KOReader UI accepted separately; native functional join independently passed | NI-1 executable closure, NI-2 drop-before-ack/restart/retry scenario, receipt observer, durable reader and two-boot QEMU join. |
| Delegated surfaces | Accepted direction; narrow text bootstrap | One bound text surface, generations, and exact offscreen paint accepted | Clipping, rich content, input, safe custom rendering. |
| Workspace/revision model | Accepted direction, unimplemented | Proposed operations only | Persistence, migrations, activation/rollback, structural previews. |
| EPUB envelope | Accepted direction | Standard extension mechanisms | Valid examples, fallback, dependency portability. |
| Capabilities | Accepted direction with narrow implementation | Endpoint-owned surface/state grants and revocation accepted | General object grants, delegation, storage/auditing UX. |
| Inline document editing | Exploratory | Not established by reviewed wrapper | Source transformation and preview integration. |
| Reflective tools | Accepted goal | Bootstrap tests specified | Small compositional primitives, not universal meta-model. |
| Meta-books/collections | Proposed | Recursive object model | Authorization membership and derived-data invalidation. |
| Stylus interaction | Accepted direction | Existing device/input foundation | Raw replay, anchoring, gesture policy, on-glass ergonomics. |
| Untrusted-book release | Not yet established | Fixed known books under selected profile only | General hostile-book and resource qualification. |

---

## 16. Focused open questions

### 16.1 Exact execution profile

The fixed QEMU profile now pins source-built gVisor
`release-20260831.0`, its complete six-file helper layout, Systrap,
`isolation-userns`, no network, `--directfs=false`, a PineNote-derived 7.1.8
test kernel with `CONFIG_USER_NS=y`, and Book Session FD 3 donation. Open:
which reviewed successor generation runs this on the PineNote; what privilege
and whole-domain resource controls qualify hostile books; and what are cold
start, memory, idle-power, suspend, and shutdown costs on hardware?

### 16.2 Environment provisioning and availability

How are recipes evaluated safely, builds/downloads authorized, closures retained, and storage reclaimed? Can a user create an environment entirely on-device without needing an unrestricted daemon? What does an exported book guarantee about offline execution and architecture support?

### 16.3 Minimal protocol and lifecycle

The current reference fixes JSON framing, ordinary session and persistent-state
messages, endpoint identity, stale-surface rejection, CAS/idempotency, and the
separation of receipt, presentation, and paint. Open: a trusted typed completion
observer for durable reader `commit-ok`; automatic timer leases and aggregate
scheduling; reconnect and suspend policy; and exact behavior for in-flight
writes and surfaces across reader or supervisor restart.

### 16.4 Minimum authoring model

Which generic fields, grids, actions, source editors, and display primitives are sufficient for Workbench to revise itself? What truly requires code versus reusable declarations? Avoid designing a universal programming language before testing this.

### 16.5 Source editing and anchors

How do exact-edition anchors map to renderer locations after reflow or a derived revision? Which transforms can preserve imported EPUB resources safely? What remains attachment-only for PDFs? What is an acceptable structural-preview cost?

### 16.6 Grants and derived data

Who can change authorization collection membership? How are recursive grants attenuated? Which copied data can be invalidated on revocation, and which deletion guarantees cannot honestly be made?

### 16.7 Composition and presentation

How do simultaneous lenses order layers, share input, request layout space, and resolve conflicting source operations? What format minimizes trusted decoding while supporting rich custom tools?

### 16.8 State and revision migration

Which data is authoritative, private, portable, reconstructible, or retained only for rollback? How does a user revert a broken tool after it changed state schemas? How are private sandbox databases checkpointed or recovered without confusing them with immutable book revisions?

### 16.9 Startup optimization

Does a warm sandbox save energy for real authoring sessions? Do clean templates outperform plain launch at the relevant environment size? How are entropy, external channels, identities, and version compatibility refreshed? These are measurement questions, not assumed wins.

### 16.10 On-tablet usability

Can people compose, test, debug, and revise tools comfortably without SSH or another computer? How much source editing is practical, and which structured interactions materially improve it? Learn this on glass rather than from an abstract schema alone.

---

## 17. Explicit non-goals for the next stage

- A general-purpose desktop.
- A new publication format built from scratch.
- A canonical API tied to one language or per-language trusted sandbox.
- Docker, Kubernetes, or a full guest operating system as bootstrap prerequisites.
- Silent downgrade from gVisor to a weaker execution profile.
- A requirement to checkpoint interpreters before basic execution works.
- Exercise-specific logic in the trusted host.
- Silent in-place mutation of installed books.
- Implicit capability inheritance through book recursion.
- Arbitrary third-party code execution before isolation is real.
- Cloud synchronization as a prerequisite.
- A replacement document engine, compositor, or large GUI widget toolkit before reusing KOReader.
- AI chat as the organizing user interface.
- Endless display optimization without a measured book workload that needs it.

---

## 18. Guiding formulation

> **KOReader remains the reader and presentation host. Guix supplies pinned environments. gVisor is the proposed execution boundary. Small Babel-like adapters make ordinary languages participate. The Book Protocol connects sandboxed programs to explicitly granted book objects, workspaces, state, and surfaces.**

> **EPUB is the portable publication envelope, not the security boundary or live database. Workspaces produce immutable revisions. Meta-books are ordinary books with scoped relationships to other books.**

The central product test remains unchanged:

> **The system used to add exercises to *Logic for Programmers* must itself be created using the book system on Wilkbook.**

The operating principle is:

> **Easy to program in many languages; explicit about authority; quick to activate; genuinely quiet while someone reads.**

---

## 19. Sources and implementation pointers

The broad architecture and future object/workspace/publication schemas in this
document are proposals. The narrow bootstrap wire contracts are implemented and
status-tracked in the [protocol and state reference](book-computer-protocols.md),
whose exact source/review pointers supersede illustrative prose here. The
references below support upstream mechanisms or identify integration points;
they do not establish the unimplemented remainder of this design.

**Review baseline:** KOReader v2026.03 remains the pinned reader release used by
the accepted host and QEMU offscreen fixtures. Broad future hooks still require
revalidation when implemented; accepted fixture claims remain bound to their
exact source hashes and review dispositions rather than to this architecture's
date alone.

**Execution and standards references:** checked on 2026-09-04. Pin versions in implementation; live documentation and issue status can change.

### Existing reader integration

- [Wilkbook KOReader packaging][wilk-package], [PineNote integration][wilk-integration], and [reader-session service][wilk-reader].
- [KOReader ReaderHighlight][ko-interfaces], [ReaderView][ko-view], and [CreDocument][ko-document].
- [KOReader text editor][ko-editor], [UIManager][ko-uimanager], [plugin loader][ko-pluginloader], and [DocSettings][ko-docsettings].

### Execution and isolation

- [Org Babel language support][babel-languages] and [session/environment semantics][babel-sessions].
- [Guix manifest model][guix-manifests].
- [gVisor security architecture][gvisor-security], [platform guide][gvisor-platforms], and [resource model][gvisor-resources].
- [Direct OCI execution][gvisor-oci], [runsc exec and FD passing][gvisor-exec], and [checkpoint/restore][gvisor-checkpoint].
- [Performance][gvisor-performance], [application compatibility][gvisor-compat], [ARM64/install packaging][gvisor-install], and the [ARM64 idle-CPU report][gvisor-idle]. The report is from another environment, not a Wilkbook benchmark.

### Publication standards

- [EPUB 3.3][epub33], [EPUB 3.4][epub34], and [multiple-rendition publications][epub-renditions].

[wilk-package]: https://github.com/willkelly/wilkbook/blob/main/pinenote/packages/koreader.scm
[wilk-integration]: https://github.com/willkelly/wilkbook/tree/main/pinenote/packages/koreader-device
[wilk-reader]: https://github.com/willkelly/wilkbook/blob/main/pinenote/services/reader-session.scm
[ko-interfaces]: https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/modules/readerhighlight.lua
[ko-view]: https://github.com/koreader/koreader/blob/v2026.03/frontend/apps/reader/modules/readerview.lua
[ko-document]: https://github.com/koreader/koreader/blob/v2026.03/frontend/document/credocument.lua
[ko-editor]: https://github.com/koreader/koreader/blob/v2026.03/plugins/texteditor.koplugin/main.lua
[ko-uimanager]: https://github.com/koreader/koreader/blob/v2026.03/frontend/ui/uimanager.lua
[ko-pluginloader]: https://github.com/koreader/koreader/blob/v2026.03/frontend/pluginloader.lua
[ko-docsettings]: https://github.com/koreader/koreader/blob/v2026.03/frontend/docsettings.lua
[babel-languages]: https://orgmode.org/worg/org-contrib/babel/languages/index.html
[babel-sessions]: https://orgmode.org/manual/Environment-of-a-Code-Block.html
[guix-manifests]: https://guix.gnu.org/cookbook/en/html_node/Basic-setup-with-manifests.html
[gvisor-security]: https://gvisor.dev/docs/architecture_guide/intro/
[gvisor-platforms]: https://gvisor.dev/docs/architecture_guide/platforms/
[gvisor-resources]: https://gvisor.dev/docs/architecture_guide/resources/
[gvisor-oci]: https://gvisor.dev/docs/user_guide/quick_start/oci/
[gvisor-exec]: https://github.com/google/gvisor/blob/master/runsc/cmd/exec.go
[gvisor-checkpoint]: https://gvisor.dev/docs/user_guide/checkpoint_restore/
[gvisor-performance]: https://gvisor.dev/docs/architecture_guide/performance/
[gvisor-compat]: https://gvisor.dev/docs/user_guide/compatibility/
[gvisor-install]: https://gvisor.dev/docs/user_guide/install/
[gvisor-idle]: https://github.com/google/gvisor/issues/13361
[epub33]: https://www.w3.org/TR/epub-33/
[epub34]: https://www.w3.org/TR/epub-34/
[epub-renditions]: https://www.w3.org/TR/epub-multi-rend-11/
