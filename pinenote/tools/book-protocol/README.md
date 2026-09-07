# Experimental Book Protocol framing codec

This directory is a host-only framing experiment for a small possible Book
Protocol layer.  It has a Python standard-library reference codec and a Guile
implementation using `guile-json`.  Cross-language tests exercise the real
wire contract; this remains evidence, **not** a decision about the eventual
broker implementation language.  There is no broker, event loop, process
management, or device integration here.

## Wire format

Each frame is:

1. a four-byte unsigned big-endian payload length; then
2. exactly that many bytes containing one UTF-8 JSON object.

The length counts payload **bytes**, not Unicode characters, and must be in the
range 1 through 65,536 bytes.  The encoder emits compact JSON; the decoder does
not require that particular whitespace style.

```python
from book_protocol import FrameDecoder, encode_frame

wire_bytes = encode_frame({"type": "open", "book": "manual.epub"})

decoder = FrameDecoder()
for chunk in (wire_bytes[:2], wire_bytes[2:9], wire_bytes[9:]):
    for message in decoder.feed(chunk):
        print(message)
decoder.finish()  # declares clean EOF; rejects a partial header or payload
```

`feed()` does no I/O and never waits for more bytes.  It returns an explicit
iterator which reserves the decoder before `feed()` returns, even before the
first `next()`.  A second feed and `finish()` fail immediately while that
iterator owns the decoder, so queued feeds cannot be consumed out of order and
handed-off bytes cannot be hidden by premature clean EOF.  The iterator yields
one object at a time, so the decoder does not build an arbitrary output list
when many frames arrive together.  Exhaust each returned iterator before the
next `feed()` or `finish()`.  Closing it while any handed-off bytes remain —
including before the first `next()` — poisons the decoder rather than silently
dropping bytes.  The decoder retains at most one bounded payload (65,536 bytes)
or a partial four-byte header; bytes for later coalesced frames remain in the
caller-owned input until iteration continues.

## Deliberate limits

- The top level is an object.  Nested objects and arrays are allowed through a
  maximum container depth of 16, counting the top-level object as depth 1.  A
  lexical pass enforces this before Python's JSON parser can recurse.  Braces,
  brackets, and escaped quotes inside strings do not count.
- Duplicate object keys are rejected at every depth, including equivalent keys
  written with JSON escapes.
- Input must be strict UTF-8.  Strings and keys must decode to Unicode scalar
  values: lone surrogates are rejected, while valid JSON `\u` surrogate pairs
  are accepted as their corresponding scalar value.  The wire does not require
  a canonical scalar spelling: Python writes non-ASCII scalars directly as
  UTF-8, while Guile deliberately escapes code points above U+00FF so that
  `guile-json` 4.7.3 also escapes every C0 control correctly.
- Integers are limited to JavaScript's exactly interoperable safe range,
  `-(2^53-1)` through `2^53-1`.  Writing an out-of-range integral value with a
  decimal point or exponent does not bypass the check.
- Finite binary64 fractional values are accepted.  Generic number semantics are
  the mathematical value after binary64 rounding; lexical integer/inexact type
  and the sign of zero are not preserved across implementations.  NaN, positive
  or negative infinity, and nonzero decimal values that overflow or underflow
  binary64 are rejected.  Values requiring exact decimal semantics should be
  strings in a future message schema.  Decimal
  exponent magnitude is capped at 1,000, matching `guile-json` 4.7.3's parser;
  this matters only for zero because nonzero binary64 values overflow or
  underflow at much smaller exponents.  Integer magnitude and exponent are
  rejected by digit count and lexicographic comparison before integer
  conversion.  Arbitrarily many leading zeroes in an otherwise in-range
  exponent remain accepted and are stripped before `Decimal`/binary64
  conversion; leading-zero JSON integer spellings remain invalid JSON.
- Encoder input uses only the JSON data model: string-keyed dictionaries,
  lists, strings, bounded numbers, booleans, and `None`.  Python conveniences
  such as integer dictionary keys, tuples, and byte strings are rejected rather
  than silently converted.
- A framing, UTF-8, JSON, or value-policy error poisons the Python incremental
  decoder.  All later input and EOF calls fail closed; create a new decoder only
  for a new stream.  EOF with an incomplete header or payload is itself a
  poisoning protocol error.

Before calling Python's JSON serializer, the encoder performs a depth-bounded
walk with a 65,536-byte conservative compact-JSON budget.  Impossible string
lengths and collection breadth are rejected before visiting their contents;
accepted traversal keeps only the recursion path (at most depth 16), not a
stack proportional to a wide collection.  This bounds the JSON text and UTF-8
copies the encoder itself proceeds to construct.  It does **not** bound the
size or construction cost of the caller-owned Python object, prove an aggregate
CPU/rate limit, replace schema-specific output limits, or make arbitrary
container subclasses safe.

## Hard rules before any message schema

The codec currently validates generic JSON values only.  It does not know or
enforce request fields, and this experiment does not invent a broker schema.
Any future schema must apply these rules before decoded values reach identity,
ordering, cancellation, or authorization logic:

- Opaque IDs, handles, and capability handles are strings, never JSON numbers.
- Generations, sequences, and counts use lexical JSON integers within the safe
  range.  Python must check `type(value) is int`, not `isinstance(value, int)`,
  so booleans are excluded.  Every other implementation needs an equivalent
  exact, type-strict check.
- Fractional binary64 values are for fields which explicitly tolerate rounding,
  such as approximate measurements.  They are not identifiers or exact
  amounts.  Numerically equal/hash-equal aliases (`1`/`1.0`, signed zero, and
  rounded decimals) must not become identity keys.

For generic numbers, `1` and `1.0` may emerge with one representation, and
`-0.0` may emerge as positive integer zero, provided the accepted rounded
mathematical value is unchanged.  Neither exact/inexact type nor signed zero is
a protocol distinction.  A Guile-originated `-0.0` currently reaches Python as
a negative float, but that observation is not a preservation guarantee.

`numeric-wire-vectors.json` pins literal tokens including `1`, `1.0`,
`0e1000`, `-0`, `-0.0`, safe boundaries, and rounded aliases.  Python tests
assert exact decoded classes as well as equality aliases.  The dedicated Guile
fixture demonstrates rather than hides current differences: Guile's generic
parse/re-encode path turns `1.0`, `0e1000`, and `-0.0` into integer spellings.
The conformance test asserts each resulting value, Python type, and zero sign;
plain cross-language `==` is not evidence for typed fields.  Lexical-integer
schema enforcement in Guile remains unresolved and must be added with any
identity-bearing schema.

Compact output is not canonical JSON.  Key order, whitespace, Unicode escape
spelling, and number spelling may differ while values compare equal.  Raw frame
bytes must not be used for signatures, idempotency identities, cache keys, or
capability decisions without a separately specified canonical form.

If a future broker uses standard process streams, protocol framing and logs
remain separate concerns: protocol frames may use a designated byte stream,
while diagnostics stay on `stderr`.  This codec does not combine, label, or
multiplex child `stdout` and `stderr`, and application output must not be
mistaken for framing bytes.

## Guile representation and parser wrapper

`book-protocol.scm` provides `encode-frame`, `decode-frame`, and
`decode-payload`.  Guile objects are ordered alists with string keys, arrays are
vectors, and JSON null is the symbol `'null`.  Arbitrary symbols, exact
non-integer rationals, symbol keys, and other Guile conveniences are rejected
rather than serialized differently from the Python data model.

```scheme
(use-modules (book-protocol))

(define wire-bytes
  (encode-frame '(("type" . "open") ("book" . "manual.epub"))))
(decode-frame wire-bytes)
```

The wrapper relies on `guile-json` for JSON value, number, and string decoding;
it is not a replacement JSON parser.  Inspection and executable probes against
`guile-json` 4.7.3 established the behavior the wrapper accounts for:

- The dependency accepts one leading object comma and missing commas between
  object members.  A bounded token-order state machine now checks object/array
  separators, colons, and container state before invoking it.  Shared literal
  vectors pin top-level and nested forms through both local decoders and the
  inherited-descriptor fixture; `guile-json` still parses actual values.
- `#:ordered #t` preserves duplicate object pairs, so a post-parse walk can
  reject duplicates (including differently escaped spellings of one key).  The
  walk uses a string-keyed hash table.  An exact-65,536-byte, 7,405-member test
  instruments one hash probe per member rather than using a machine-dependent
  timing threshold.
- Valid escaped surrogate pairs become one Unicode scalar and lone or reversed
  surrogates raise `json-invalid`, matching the Python policy.
- With `#:unicode #f`, the dependency emits most C0 controls raw and therefore
  produces invalid JSON.  Guile encoding now deliberately uses `#:unicode #t`:
  all C0 controls are escaped, U+0008/U+0009/U+000A/U+000C/U+000D may use named
  escapes, U+0100–U+FFFF use `\uXXXX`, and supplementary scalars use surrogate
  pairs.  Direct UTF-8 and escaped scalar spellings are equally valid but not
  canonical.
- Numbers may be produced as exact bignums before conversion to inexact values,
  and the parser has no number callback.  A small lexical policy pass therefore
  bounds decimal exponents and rejects unsafe integral values and binary64
  under/overflow; JSON number grammar remains `guile-json`'s job.
- The parser is recursive.  The structural/numeric preflight bounds container
  depth before calling it without taking over string, number, keyword, or value
  decoding.

Before calling `scm->json-string`, the Guile encoder walks values with an
escaping-aware 65,536-byte budget.  It rejects impossible string/vector breadth
early, retains only the at-most-16-deep recursion path plus the required
per-object duplicate hash, and checks the emitted byte length again.  This
limits local serialization copies, not the already-existing caller object,
arbitrary extension types, aggregate connection work, or future schema output.
An exact-max frame containing escaped U+0000 values pins budgeting after the
new escaping choice.

`(book-protocol blocking-io)` is a deliberately separate blocking port adapter:
`read-frame` reads exactly one bounded frame and `write-frame` writes and
flushes one.  It is sufficient for the host conformance fixture, but it is not
the future broker's nonblocking/event-loop integration and says nothing about
whether KOReader's own I/O is nonblocking.  The adapter does not attempt stream
resynchronization: after `book-protocol-error`, its caller must close and
discard that port.  The conformance fixture does so.

The conformance fixture is an explicit host test, not a security fallback or a
runtime helper.  Python starts Guile with a dedicated inherited Unix
`socketpair` file descriptor.  Python-framed objects travel on that descriptor,
Guile decodes and wraps them, and Python decodes Guile's response.  The fixture
also writes a known diagnostic to captured `stdout`; the test proves those
bytes remain separate from the protocol descriptor.  Successful diagnostics
normally belong on `stderr`; the `stdout` marker is intentionally adversarial
test evidence that stdio is not the wire.

This experiment does **not** claim a security-complete parser or transport, and
it does **not** demonstrate that any end-to-end latency target has been met.

## Check

```sh
make -C pinenote/tools/book-protocol check
```

The full check intentionally requires Guix and does not skip or report mocked
success when Guile is unavailable.  It uses the repository's `channels.scm`
pin to create a small environment requesting only `guile`, `guile-json`, and
`python` as top-level packages.  From the repository root, the expanded
reproducible command is:

```sh
guix time-machine -C channels.scm -- shell guile guile-json python -- \
  sh -c 'cd pinenote/tools/book-protocol &&
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v &&
    guile --no-auto-compile -L . test-book-protocol.scm'
```

The ambient Guile 3.0.11 did not have `(json)` installed; `guix show
guile-json` resolved version 4.7.3 without a package build.  The pinned test
environment resolved Guile 3.0.11, `guile-json` 4.7.3, and Python 3.12.12.
Override `GUIX_SHELL` only when deliberately testing another package set.

The recorded 2026-09-04 pinned host run passed 45 Python `unittest` methods (39
Python-local/reference-policy methods plus six real Guile socketpair methods)
and 49 Guile SRFI-64 assertions.  No hardware or target build was involved.

`python-check`, `guile-check`, and `conformance-check` are narrower Makefile
targets.  The tests cover fragmented and coalesced input, exact
frame/depth/numeric boundaries, bounded buffering, escaped string syntax,
malformed UTF-8 and JSON, duplicate keys, non-object values, truncation at EOF,
poisoned fail-closed behavior, blocking adapter truncation, and Python↔Guile
framing over the dedicated descriptor.  The literal numeric vectors expose
actual values, zero signs, type changes, and equality aliases; they do not claim
schema enforcement.  Shared malformed-object vectors and independently
originated all-C0 key/value fixtures cover the two pinned dependency defects.

Still unproven: integration with any broker or KOReader process, nonblocking
backpressure and cancellation, schema/version negotiation, descriptor
lifecycle under crashes, resource accounting beyond the 64 KiB frame bound,
aggregate connection CPU/rate/deadline and queue limits, Guile lexical-integer
field enforcement, canonicalization/signatures, and end-to-end latency.
