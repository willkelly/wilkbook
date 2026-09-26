# Book Workbench — source and revision prototype

This is the next offline authoring step after the generation-21 persistent
note. It gives one Guile source resource a durable draft, immutable revisions,
an installed revision, executable preview, rollback and export, with a generic
KOReader source editor. It is an explicit developer tool.

The first source contract is deliberately small:

```scheme
(define (workbench text)
  (string-append "Workbench: " text))
```

Edit the function to change its output, for example:

```scheme
(define (workbench text)
  (string-append "Uppercase: " (string-upcase text)))
```

The source is data to the authority and KOReader. A fixed runner loads it in a
separate execution process and speaks the existing ordinary Book Protocol over
FD 3. No source path, interpreter, database or environment can be chosen through
the UI channel.

## Check and run

From the repository root:

```sh
make book-workbench-check

# Explicit trusted-native desktop fixture; use only your own trusted code.
mkdir -m 700 "$HOME/workbench-dev"
sh pinenote/tools/book-workbench/run-native-demo.sh "$HOME/workbench-dev"
```

The check resolves native Guile/SQLite and KOReader dependencies through the
repository's pinned `channels.scm`, with grafts disabled before lowering. It
builds no kernel or OS image. Existing native dependencies can be supplied
explicitly as `BOOK_WORKBENCH_SUPERVISOR`
and `KOREADER_NATIVE_BUNDLE`. Test data and profiles are private temporary
directories under `/tmp/opencode`; failing checks retain their diagnostics.

The visible demo also resolves pinned Mesa for SDL's Wayland EGL/GLES renderer.
`BOOK_WORKBENCH_GRAPHICS` can select an explicit cached Mesa output containing
`lib/libEGL.so.1` and `lib/libGLESv2.so.2`. These libraries are selected by exact
path for the desktop reader. An SDL initialization, window, renderer or texture
failure exits with its original diagnostic instead of leaving an invisible
KOReader process running. For an intentional headless launch, use
`SDL_VIDEODRIVER=offscreen`; the automated checks use that backend. Offscreen
launches and `--export` do not build or load the desktop graphics dependency.
Supplying `BOOK_WORKBENCH_GRAPHICS` to `make book-workbench-check` additionally
tests those actual EGL/GLES libraries with SDL's offscreen backend, without a
compositor. This optional graphics check uses the supplied output directly.

In KOReader, open **More tools → Book Workbench (experimental)**:

1. Edit the source and **Save draft**.
2. **Preview** the saved draft with an input value. A syntax error, exception
   or timeout leaves the installed revision available.
3. **Activate** the successfully previewed version.
4. **Run installed** to execute the selected immutable revision.
5. **Roll back** to select the retained predecessor. Draft edits are preserved.
6. **Export** displays the installed source artifact. The launcher's export
   command can write it to a file:

```sh
sh pinenote/tools/book-workbench/run-native-demo.sh --export \
  "$HOME/workbench-dev" > workbench.wilk.json
```

Ordinary editor Close retains the connection for another menu open and removes
its idle socket polling. Persistent data lives under `DIRECTORY/workspace`.
After a transport failure,
exit desktop KOReader and rerun the launcher with the same directory to recover
the saved draft and installed revision from SQLite. Unsaved text retained in
an editor is only in that reader process's memory.

Editing, saving, previewing, activation and rollback use the same
interpreter environment; they do not rebuild an OS or evaluate Guix recipes.

## Ownership and completion

| Component | Responsibility |
| --- | --- |
| `book-workspace.scm` | Separate private source database, versioned draft, immutable source revisions, activation epoch, rollback and deterministic export |
| `workbench-authority.scm` | One endpoint's commands; matching a successful preview to the exact draft and activation epoch |
| `workbench-preview.scm` / `workbench-runner.scm` | Executable source/result exchange and bounded preview cleanup |
| `plugin/bookworkbench.koplugin/` | KOReader widgets, asynchronous replies, saved baseline, dialog lifetime and recovery controls |
| `native-authority.scm` | Explicit trusted-native composition root for desktop development and tests |

The authoring database is separate from the persistent note's schema-v1
database. It stores source and installation metadata, not note contents,
personal fonts, or the reader's system generation ledger. This prototype has
no program-owned persistent state or migration operation: code rollback cannot
rewind someone else's data.

**Save draft** acknowledges a SQLite commit. It does not install or execute
the source. A preview is useful for activation only within the requesting
endpoint and while its draft version, source digest and activation epoch still
match. Editing, reopening the editor, rollback, activation or disconnection
invalidates that authorization. Source/revision digests are identities, not
capabilities.

**Activate** seals that exact draft and atomically selects the revision through
an activation-epoch and draft-version compare-and-swap in the same transaction.
An old request cannot pass an R1 → R2 → R1 cycle merely because the revision
name is R1 again. A sealed but
unactivated revision is harmless retained source. **Run installed** selects
source from the installed revision, even when the draft differs or is broken.

Requests are serialized. The UI does not retry a write blindly after losing
its acknowledgement: reopening reads the actual durable snapshot. There is no
cross-connection operation-receipt/retry protocol in this authoring step.

## Bounds and current proof boundary

- One source resource, one workspace and one installed lineage per store.
- Source: at most 8,192 UTF-8 bytes, no NUL. Input: 1–2,048 bytes;
  result: 1–4,096 bytes. The private UI channel uses a bounded JSON payload
  carried in a lowercase-hex line; it is distinct from the book's FD-3 channel.
- One pending UI request, a fresh preview authorization after each source
  change, and bounded preview runtime/output. The native authority waits for
  input in 200 ms intervals so Guile can dispatch a queued termination signal,
  including during an incomplete line. This is not a device idle-power result.
- The catalog retains at most **128 immutable revisions for the lifetime of
  the workspace**, including the seed and any sealed but unactivated source.
  There is no automatic pruning. At capacity, new-source activation reports
  `revision-quota-exhausted`; draft saves, running/exporting installed source,
  rollback, and activation of already-sealed source still work. Export useful
  revisions before starting a separate developer workspace for further source
  revisions; this prototype has no archive importer.
- Export contains sealed source and its format/environment metadata. It is
  a small source artifact, not an EPUB or a general archive-import format.

The executable desktop checks use the explicitly named **trusted-native**
fixture. They establish source editing, real interpreter behavior, persistence,
failure handling and KOReader integration. They do not establish gVisor
containment, ARM64 execution, or on-device authoring. OCI preparation has its
own code and policy checks; runtime acceptance must exercise the generated
bundle rather than infer isolation from its fields.

The full self-hosting gate remains larger: a sandboxed Workbench must own its
authoring workflow, create a successor that can continue that workflow, and
pass the attended device acceptance in `doc/wilkbook-self-hosting-book-computer.md`
§14. This source editor/revision prototype supplies the storage, preview and
installation interfaces for that step. The separate
[`book-workbench-editor`](../book-workbench-editor/README.md) now exercises a
source-defined authoring workflow with scoped workspace operations in both an
explicit trusted-native fixture and the accepted ARM64 sandbox editor scenario.
Its distinct editor entry contract requires a fresh store; do not point it at
this text-function workspace. General book loading, on-tablet authoring,
instance-state migrations and Exercise Studio remain follow-up work.

## ARM64 sandbox execution gate

`workbench-sandbox.scm` implements the one-shot supervisor for the
preparation-only launch record in `PREVIEW.md`. It validates source, selected
environment and exact launch configuration before donating an ordinary
no-state endpoint. Host tests distinguish synthetic validation, controlled
native lifetime checks and public preflight refusals from actual gVisor runs.

The opt-in QEMU system and test adapter are separate from the desktop launcher:

```sh
make book-workbench-qemu-drv
# This lowers only; use the emitted IMAGE-DERIVATION for an explicit build.
sh pinenote/tools/book-workbench/run-qemu.sh --help
```

The gate reuses the pinned USER_NS test kernel and source-built gVisor. The
guest requires its own ext4 workspace disk and creates a fresh private scenario
directory. Retaining that disk for another boot does not by itself test
reopening the previous directory; the shared scenario reopens its own store
and authority during a single boot. The host adapter authenticates staged
inputs and bounds QEMU to 512 MiB, two vCPUs and 360 seconds. An optional
read-only workspace snapshot is published only after guest success and clean
power-down. It uses the existing disposable-QEMU engine, not the historical
sealed source-packet acceptance procedure.
Exact lowering/build/staging/run commands are in [`QEMU.md`](QEMU.md).

**Accepted 2026-09-15 on final v9 inputs:** 92 assertions across 14 actual
runsc executions passed edit → preview → activate → reopen → rollback, syntax
errors, exceptions, nontermination and installed execution after each failure.
Every invocation proved action delivery and complete cleanup. The retained
64 MiB workspace passed read-only fsck and SQLite audit; it kept the looping
draft while rollback restored the installed seed. This is a single-boot
authority/store close–reopen result, not same-workspace recovery across boots.

Remaining execution gates:

1. Extend the finite resource/access results below to complete runtime
   support-process accounting and the remaining policies (network isolation,
   scratch exhaustion, isolated read-only-mount enforcement and CPU-limit
   attribution). Matched controls alone do not close those cases.
2. Qualify on-tablet authoring and ARM KOReader widgets. The long-lived sandbox
   session and interactive disposable preview passed the separate v16 ARM64
   coordinator scenario; see
   [`book-workbench-editor/QEMU.md`](../book-workbench-editor/QEMU.md).
   The trusted reader retains installation confirmation and recovery controls.

Retain the reviewed ownership/pathname constraints in
`doc/reviews/2026-09-15-workbench-sandbox-and-self-authoring.md`, including the
refusal to force-delete runtime state after releasing process identities.

Those results precede device packaging and the attended Workbench test. The
current native note/widget results remain useful regressions for each step.

The September 19 continuation adds fixed resource/access probes to the QEMU
gate, plus native oracle tests that compile but never execute those hostile
programs. **The v13 ARM run passed 112 assertions across 20 sandbox executions:**
filesystem exclusion/write denial, host task-limit pressure and memcg OOM,
with complete cleanup and fresh successful execution after each. It retains the
pre-dispatch counter baseline and distinguishes host-limit containment from
graceful guest fork refusal. Read-only filesystem/SQLite audit passed, with
the database byte-identical to v9. Exact scope and retained failed attempts:
[`resource qualification record`](../../../doc/reviews/2026-09-19-workbench-resource-qualification.md).
