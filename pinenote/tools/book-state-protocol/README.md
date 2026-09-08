# Typed persistent-text protocol model

This directory contains a concrete Guile message schema and finite authority
state machine for the first persistent-book operation: read and CAS-commit one
optional text value. It is host-only and uses a trusted fake backend in tests.
It does not prove SQLite durability, sandbox execution, QEMU transport, or
KOReader behavior.

The module imports the accepted `(book-protocol)` codec unchanged. It provides:

- seven typed SRFI-9 wire-message records with exact-field frame decoders;
- lexical-integer schema checks over already accepted JSON;
- a SQLite-free `[A-Za-z0-9_-]{1,128}` operation-ID predicate usable by
  untrusted/client-side Guile code;
- endpoint-bound owner/grant operations matching `(book-state)`;
- the bounded `ready` → read/edit/commit → `closing` model; and
- typed backend results for value, durable receipt, conflict, quota, and
  revocation/error paths.

The complete wire and transition tables are in `CONTRACT.md`.

## Minimal future Book Session seam

Do not add a second broker, raw port registry, Python authority, or JSON codec.
After independent review, the smallest join is:

1. the existing Guile Book Session endpoint retains one trusted state binding;
2. after the accepted `hello`, its existing schema dispatcher optionally routes
   only `state-read` and `state-commit` objects to this model;
3. the same endpoint output queue carries `state-ready` and state replies;
4. a synchronous Guile adapter calls `(book-state)` outside the Book Session
   transition mutex and applies the typed result; and
5. endpoint EOF/revocation closes this model and revokes the backend grant.

Python remains valid only as a sandboxed fixture book or independent test
oracle. It is not a production state broker.

## Later operator-editable demonstration

The useful first demonstration is one persistent textbook note in the existing
package-pinned KOReader v2026.03, not four automated result strings:

1. open a fixed book instance and issue a fresh endpoint grant;
2. read state and put absent/loaded text into one retained KOReader
   `InputDialog`;
3. let the operator edit freely; Guile records only the submitted Save text,
   not per-keystroke UI state;
4. a fixed Guile or Python fixture book requests `state-commit` with a unique
   operation ID and the loaded version;
5. show “Saved vN” only after the backend receipt, then independently require
   the existing topmost `paintTo`/`applied` proof;
6. close the book, revoke the grant, restart the reader/book process, issue a
   new grant for the same trusted instance, read, and show the stored text.

Operator mode leaves the dialog editable and exposes Save/Close actions.
Repeatable host/UI automation may inject one fixed Unicode note and invoke the
same registered Save action, but must not bypass the callback, manufacture a
backend receipt, or treat protocol acknowledgement as paint. The current
frozen four-presentation Lua fixture should not be extended until this protocol
and the backend join are independently accepted.

## Host check

Run inside the already pinned Book Protocol Guile/guile-json environment:

```sh
make -C pinenote/tools/book-state-protocol check
```

The test uses actual accepted frames and a typed in-memory fake backend. It
covers all message records, exact fields/directions, lexical integer aliases,
UTF-8 bounds, absent versus empty, endpoint binding, one-pending-operation
transitions, durable lost-ack retry, changed-payload operation-ID rejection,
stale CAS, quota, close/EOF/revocation, and reopen with a new grant.

This command performs no QEMU, runsc, ARM, image, package, or hardware work.
