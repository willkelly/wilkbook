# Persistent text protocol model — implementation record 2026-09-06

## Disposition

The isolated typed-message and state-machine model is ready for independent
source review. It is not joined to the accepted Book Session, `(book-state)`, a
guest, or KOReader.

The implementation has seven fixed-shape version-1 messages, uses the accepted
Book Protocol frame/JSON codec unchanged, retains lexical evidence for every
integer field, and exposes only typed Scheme records. Its authority model binds
wire handle/generation fields to one endpoint-retained owner/backend-grant pair;
book identity, instance identity, namespace, storage schema, and paths are not
wire fields.

All required phases are executable rather than prose-only:
`ready`, `read-pending`, `clean`, `edit-dirty`, `commit-pending`, `commit-ack`,
and `closing`. The model has one pending slot and no worker, queue, transport,
storage, process management, or UI-state mirror.

## Host result

The final host-only gate compiled the module and tests with Guile arity/format
warnings enabled, then passed **76 SRFI-64 assertions**. Coverage includes:

- all message records through actual accepted frames and the payload decoder;
- exact fields, direction, duplicate/unknown/missing rejection, and lexical
  integer aliases for every integer field;
- 4096-byte UTF-8 text, absent versus explicitly present empty text, and no
  namespace/path fields;
- exact endpoint owner/grant propagation and grant mismatch closure;
- all seven phases and prevention of staged/pending replacement;
- durable receipt ordering, immediate and old lost-ack retry, and no rollback of
  a newer local view by an older receipt;
- changed-payload operation-ID rejection both from the current model cache and
  a durable fake-backend receipt ledger;
- stale CAS conflict with no overwrite, conflict read/reconcile, receipt quota,
  read-only access, explicit draft discard, and exact backend-operation identity;
- EOF/revocation rejecting late wire and backend operations; and
- close/reopen with a fresh grant and retained fake-backend text.

The storage side was a typed synchronous fake implementing the published
`(book-state)` operation/result contract. No SQLite/backend code was imported or
executed, so this is not durability evidence.

## Machine-frozen code subset

| Source | SHA-256 |
|---|---|
| `book-state-protocol.scm` | `358f8a724f9c7dacf3b8c1c3e01ad9db4f34fda2755c7682a6a277522ecb6194` |
| `test-book-state-protocol.scm` | `b968e7c4057a7a51e03f928968e9e799e143f37ae8b67f8f0172f217c7818705` |
| `Makefile` | `0d4a9dc27d6201bb65ed3a99e932f708c1dc85cb18807338006d1613e6ed7eb4` |

Accepted dependencies remained unchanged:

```text
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  book-protocol.scm
f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668  book-session.scm
```

`CONTRACT.md`, `README.md`, this review record, the concurrently published
backend contract/implementation, and all `doc/**` paths are deliberately
excluded from the machine freeze. The model was aligned to the backend's
published finite API, but that active owner may revise its files independently.

## Review packet

Private mode-0700 packet:

```text
/tmp/opencode/book-state-protocol-v1-code-only.ucqLHk
```

| Evidence | SHA-256 |
|---|---|
| `packet-manifest.json` | `7768784b32a5636aa7752578dc6e91dfe6ba8f8ecdc0a25dee39b2c9cae47bf9` |
| `code-source-hashes.txt` | `6e4a81b1f3b8e685f18c3023f8f7ed7aa2c7a8ff38dc30c243e37b3037d482bf` |
| `evidence-hashes.txt` | `2542f84069d0b801e70ab8112195e6a7f171a7f1f758853652926e3bf86ad2e3` |
| `run-host-check.sh` | `1cca1925ca2cf2e6e431d267b79752ba1f8ff61dc6a8ae5f26a12b9ec00e0e1c` |
| `host-check.log` | `be766e2035b3d108f19ef4604c2ddb4a0be48c7fef023e7734209179aeff63bd` |

Independent replay:

```sh
/tmp/opencode/book-state-protocol-v1-code-only.ucqLHk/run-host-check.sh \
  /tmp/opencode/wilkbook-book-computer
```

## Required decisions before integration

Review the five finite points at the end of `CONTRACT.md`: seven wire shapes
and no read ID; operation-ID alphabet; one optional existing-endpoint dispatcher
hook; backend record/revocation mapping; and separation of Save receipt,
presentation, and Lua paint acknowledgement.

No accepted codec/session/UI/demo/guest/outer/system source was changed. No
QEMU, runsc, ARM execution, SQLite backend operation, image/kernel/package
build, hardware, network, staging, commit, or push occurred.
