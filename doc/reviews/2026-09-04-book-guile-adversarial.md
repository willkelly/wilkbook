# Book Protocol Guile/cross-language adversarial review — 2026-09-04

## Verdict

**Block integration.** The frame-size, UTF-8, surrogate, depth, duplicate-key,
and numeric-policy defenses mostly agree across the two implementations, but
the pinned Guile path has two cross-language contract failures that the green
suite does not cover:

1. the Guile decoder accepts malformed objects with a missing comma or one
   leading comma; and
2. the Guile encoder emits forbidden raw control bytes for valid strings
   containing controls such as U+0000.

Both were reproduced through the real inherited-descriptor Unix `socketpair`,
not just by calling `guile-json` in isolation. The first is on the untrusted
decode path. The second is reachable both from trusted local encoding and from
an untrusted valid frame that is decoded and included in a reply. Fix both and
pin adversarial two-language regressions before using this codec in a broker.

This review made no implementation edits and used no device, VM, target build,
or unbounded stress.

## Exact review snapshot and dependency

The conclusions apply to these SHA-256s. Files changed concurrently during the
review, so a different hash requires revalidation rather than inference.

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-protocol/README.md` | `6bf8dd79c2a41d1d3b0ddc68edb389255a2966e3f3292258c06732196ce31a83` |
| `pinenote/tools/book-protocol/Makefile` | `d7f375426f34f8ac321286c2b9cb9ff51b0ea419fc0aa0eb2625f30d94017cd4` |
| `pinenote/tools/book-protocol/book_protocol.py` | `780c5a3985066e56d7f53e0105bfe11631da27a226a8f982f85e70a916fddd38` |
| `pinenote/tools/book-protocol/book-protocol.scm` | `a13558e71fdf1c31b73ba4f09e952477fdbb4b7c0ca63ca0d66582a6094e3aa6` |
| `pinenote/tools/book-protocol/book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| `pinenote/tools/book-protocol/numeric-wire-vectors.json` | `8133e10d88c7ab2a397e8e9988319472e7f20a1ce671caedb32418d557c060ff` |
| `pinenote/tools/book-protocol/test_book_protocol.py` | `89c19031fd6a693b02be607af4a2dade5a666b9c43891ff95e0f58bb226bdad0` |
| `pinenote/tools/book-protocol/test-book-protocol.scm` | `a393c654eae0d8323331e3877643377bc83020b5262bba87ee4e37f002ec6d15` |
| `pinenote/tools/book-protocol/test_guile_conformance.py` | `fa88bfb3ab179392dc0f7e185cfc1a5187c52f589bc707ffad4309e784bc751e` |
| `pinenote/tools/book-protocol/guile-conformance-peer.scm` | `697a55e029c8ce083bda856e6d18aa8a016df31e5a02c4180d135170b3c98cbb` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |

`channels.scm` pins Guix
`f250e74dd4a4ba2e7f4a62369bf04c1b06756f9c`, nonguix
`653504e6551198c9b2b998c143d7cf2675b22547`, and saayix
`a6ac453939f69ccee0cd699ddf55ef1e25d7913e`. The actual test environment
resolved:

- Guile 3.0.11:
  `/gnu/store/k7vkw9x3wl3lni6a0i2w8xz2z8ylrqyz-guile-3.0.11`;
- `guile-json` 4.7.3:
  `/gnu/store/nw7d5iijwm9sa16k2swxjalgp0vlm01v-guile-json-4.7.3`; and
- Python 3.12.12:
  `/gnu/store/wrga4n0pddywrvdk28scnybm58sidgdf-python-3.12.12`.

The exact installed `guile-json` sources used in the grammar findings hash as:

| Installed dependency file | SHA-256 |
|---|---|
| `json.scm` | `b4971b653ec782251299a419ebe3288e692a6239bf5d5ce219d7c26440e32332` |
| `json/parser.scm` | `3c814d4409e4c24d3dd7e7dceddd664b09da930ff6c78986944777192ec29ea1` |
| `json/builder.scm` | `b369009bac7e7163de33ca0ebed12bfa238be62f18c97ffc88e087531c29d61c` |

## Findings, ranked

### 1. High — the untrusted Guile decoder accepts malformed object separators

`guile-json` 4.7.3's `json-read-object` accepts a quoted next key without first
requiring a comma, and accepts a comma while the initial `added` state is true.
The wrapper's pre-parser deliberately tracks only strings, numbers, and
container delimiters, so it does not close this dependency grammar hole.

Exact socketpair reproduction in the pinned shell used the committed
`run_guile_peer()` and the Python reference decoder:

```python
for payload in (b'{"a":1 "b":2}', b'{,"a":1}'):
    frame = len(payload).to_bytes(4, "big") + payload
    print(list(FrameDecoder().feed(frame)))  # raises ProtocolError
    print(run_guile_peer(frame))             # Guile exits 0 and replies
```

Observed on the reviewed snapshot:

```text
payload b'{"a":1 "b":2}'
Python: ProtocolError: malformed JSON payload: Expecting ',' delimiter: line 1 column 8 (char 7)
Guile:  rc=0, stderr=b'', reply message={'a': 1, 'b': 2}

payload b'{,"a":1}'
Python: ProtocolError: malformed JSON payload: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)
Guile:  rc=0, stderr=b'', reply message={'a': 1}
```

`{"x":{"a":1 "b":2}}` is accepted in the same way at nested depth. Trailing
and doubled commas were rejected, so this is specifically a missing/leading
comma hole, not a claim that all malformed object syntax is accepted.

**Trust distinction:** these bytes come directly from a peer. They need no
trusted caller mistake. Their decoded values could have been sent as valid
JSON, so this is not by itself a demonstrated authority escalation, but it
breaks the stated strict JSON wire contract and makes language choice determine
whether a stream is accepted.

**Required regression:** literal top-level and nested missing-comma vectors and
a leading-comma vector must fail in both local decoders and through the real
Guile socket peer. Do not rely on a passing `guile-json` parse as proof of JSON
grammar for this pinned version.

### 2. High — the Guile encoder emits invalid JSON for most C0 controls

The decoder correctly accepts escaped JSON controls. `encode-frame` then calls
`scm->json-string` with `#:unicode #f`. In `guile-json` 4.7.3's builder that
mode directly writes characters not handled by its small named-escape case.
Consequently most U+0000–U+001F values are emitted literally inside a JSON
string, which RFC JSON forbids.

Exact real-socket round trip:

```text
input payload:    b'{"s":"\\u0000"}'
Guile exit:       0, stderr=b''
response payload: b'{"from":"guile","message":{"s":"\x00"}}'
Python result:    ProtocolError: malformed JSON payload: Invalid control character at: line 1 column 33 (char 32)
```

An exhaustive 32-code-point socketpair fixture found valid Guile output only
for the five named escapes U+0008, U+0009, U+000A, U+000C, and U+000D. It
produced invalid raw bytes for U+0000–U+0007, U+000B, and U+000E–U+001F. The
same defect applies to object keys. The Guile peer reports success because
`scm->json-string` does not throw.

**Trust distinction:** a trusted Guile caller can trigger this by encoding a
local string. More importantly, an untrusted peer can send entirely valid
`"\\u0000"`, have Guile decode it, and make an otherwise routine wrapped reply
invalid. A receiving Python decoder then poisons its stream.

**Required regression:** independently originate all 32 controls in Guile and
decode every emitted frame in Python; also send escaped controls from Python
through the Guile echo peer. Assert valid payload grammar and exact scalar
round-trip, not only Scheme equality. Preserve byte-limit accounting after
escaping. Using `#:unicode #t` would make the controls valid but also changes
the documented direct-UTF-8 behavior for code points above U+00FF, so that
tradeoff must be deliberate or the wrapper must supply correct string escaping.

### 3. Medium — duplicate checking is quadratic on the untrusted decode path

`validate-value!` keeps `seen` as a list and calls recursive `string-member?`
for every object member. A maximum-size object can therefore require quadratic
key comparisons after parsing even when every key is unique.

A persistent Guile socket peer was sent alternating exact-65,536-byte frames:

- control: one 65,528-byte string value;
- adversarial: numbered members `"0":0` through `"7403":0`, plus one `pad`
  member sized to make the payload exactly 65,536 bytes.

Six request/reply timings on this host were:

```text
string frame ms: 3.0, 2.8, 2.7, 3.8, 2.6, 2.7; median 2.7
unique-key ms:  242.8,245.9,242.0,243.6,240.6,240.1; median 242.4
ratio: 88.5x
```

Both frames are valid and equally byte-bounded. The absolute timing is
machine-specific; the quadratic implementation and 7,405-member fixture are
not. A sandbox can repeat such frames on one connection, and the future ARM
host will not be faster.

**Required fix before an untrusted broker:** use a string-keyed hash set (or an
equivalent linear duplicate detector) and keep a transport-level aggregate
work/rate/deadline budget. Pin the maximum-width unique-object case so later
duplicate hardening cannot silently restore quadratic work.

### 4. Medium design decision — Guile decode changes numeric type and can erase negative zero

The safe-integer and binary64 range checks themselves held, but
`guile-json`'s exact arithmetic changes representation based on token spelling.
The real peer produced:

```text
Python input payload     Guile response payload                 Python type/sign after Guile
{"n":1.0}               {"from":"guile","message":{"n":1}}   int
{"n":0.0}               {"from":"guile","message":{"n":0}}   int, positive
{"n":-0.0}              {"from":"guile","message":{"n":0}}   int, positive
```

The reverse direction is asymmetric: a Guile-originated `-0.0` is encoded as
`-0.0`, and Python preserves its negative sign. The README and new
`numeric-wire-vectors.json` now explicitly record the exact/inexact type
changes and forbid generic numbers for identity-bearing fields. That is the
right warning. The cross-language vector test checks only the resulting type
name, however; it does not assert each value or a signed-zero policy.

This is not a violation if the protocol defines JSON numbers only by their
rounded mathematical value and explicitly normalizes integral spellings and
signed zero. It is a defect if “binary64 value” promises preservation of all
binary64 distinctions. Plain Python `assertEqual` cannot decide this because
`1 == 1.0` and `0.0 == -0.0`.

**Required decision/regression:** define the semantic rule before schemas land,
then assert it explicitly in both directions. Regardless of that choice, IDs,
generations, counts, and capability-adjacent fields should require schema-level
integers (or strings), not generic rounded JSON numbers.

### 5. Low, trusted-input only — Guile's encoder limit is checked after serialization

`encode-frame` validates the local Scheme object, then allocates the complete
`scm->json-string`, then allocates its complete UTF-8 bytevector, and only then
checks `max-frame-size`. A one-MiB local string ended with the expected:

```text
book-protocol-error: frame payload exceeds the 65536-byte limit
```

but the source ordering proves this is an emitted-frame bound, not a bound on
encoder work or transient allocation. The Python snapshot now has a
conservative pre-serialization budget; Guile does not.

**Trust distinction:** peer framing cannot directly supply an oversized local
Scheme object, and wrapping one already-bounded decoded frame remains roughly
bounded. This is therefore not an untrusted decoder escape. It matters for
trusted broker responses built from unbounded book data and for any future
claim that encoding itself is bounded.

## Differential results and non-findings

The bounded corpus exercised literal payloads through Python → Guile → Python,
plus an independently originating Guile writer read incrementally by Python.
Apart from the findings above:

- `#:ordered #t` really retained duplicate pairs. Top-level, nested, escaped
  ASCII-equivalent, and direct-versus-surrogate-pair-equivalent duplicate keys
  were rejected by the wrapper.
- Escaped surrogate pairs decoded to one scalar. Lone high, lone low, and
  reversed surrogates were rejected. Guile itself does not permit constructing
  a surrogate `char` with `integer->char`.
- Raw UTF-8 emoji passed. Overlong UTF-8, byte `0xff`, and UTF-8 encodings of a
  surrogate were rejected as `frame payload is not well-formed UTF-8`.
- Number/depth-looking text inside strings did not trigger the lexical policy
  scanner. Escaped quotes and reverse solidi worked. Invalid escapes,
  unescaped line feed, and unterminated strings were rejected.
- Safe integers at ±9,007,199,254,740,991 passed. Plain, decimal-point, and
  exponent spellings of unsafe integral values were rejected. The minimum
  subnormal rounded to `5e-324` and passed; nonzero underflow and overflow were
  rejected. No safe-integer exponent bypass was found.
- The new absolute decimal-exponent cap matches the pinned parser:
  `0e1000` and the negative-exponent boundary pass, while magnitude 1001 fails
  with `JSON decimal exponent exceeds the limit of 1000`. An exact-65,536-byte
  exponent containing tens of thousands of leading zeroes and ending in
  `1000` remained accepted. A maximum-size exponent of nines was rejected in
  55.6 ms in a one-process socket fixture.
- The exponent cap introduces no extra incompatibility for the declared local
  encoder data model: accepted safe integers are emitted without such an
  exponent, accepted binary64 values cannot require exponent magnitude 1001,
  and local zero is not emitted that way. It intentionally rejects otherwise
  valid external JSON spellings such as `0e1001`; that narrowing is documented.
- The payload limit counts bytes. A payload consisting of object overhead plus
  16,382 emoji was exactly 65,536 UTF-8 bytes and was accepted by Guile; adding
  one byte was rejected from the prefix before payload allocation. An
  independently originating Guile exact-maximum Unicode frame was decoded by
  Python alongside four smaller frames.

## Blocking adapter and fixture limits

The adapter correctly preallocates only the validated 1–65,536-byte payload and
loops until the header or payload is complete. Real-socket partial-header and
partial-payload fixtures both remained alive and blocked after 300 ms. After
the writer half closed, both exited 2 with exactly:

```text
Book Protocol error: EOF truncated a Book Protocol frame
```

That is expected for the explicitly blocking adapter, not a newly claimed bug.
It does prove that the adapter supplies no deadline or cancellation itself.
The Python conformance helper's ten-second socket/process timeout is external
test supervision, not runtime transport behavior. The committed Guile
truncation tests use bytevector ports with EOF already available; they do not
exercise a live peer that stalls mid-frame. Nor do the current fixtures prove
nonblocking backpressure, cancellation, concurrent close, or descriptor
lifecycle under crash. Those limitations are accurately acknowledged in the
README and still block treating this adapter as the future event-loop layer.

After `book-protocol-error`, the module has no decoder poison object; safety
depends on the caller closing the whole port. The committed peer does so, as
documented. Oversized input sent in full can consequently give the sender
`ECONNRESET` when Guile rejects the four-byte prefix and closes with unread
payload; callers and tests should treat that as fail-closed, not as a response
frame.

## What the supplied counts prove

On the exact snapshot, the pinned command
`make -C pinenote/tools/book-protocol check` passed **42** Python `unittest`
methods and **34** Guile SRFI-64 assertions. This exactly substantiates the
README's numerical claim: 39 Python-local/reference-policy methods plus three
real Guile socketpair methods, and 34 Guile assertions.

The larger Python count includes useful numeric vectors and lifecycle fixes,
but the actual cross-language coverage is still only one ordinary two-message
echo, one duplicate-key rejection, and one numeric-type vector method. The two
high findings above pass the whole supplied suite. Thus the run substantiates a
green local suite and a real descriptor smoke test, not full two-language
conformance. Keep the accurate count, but add a shared literal-wire corpus
covering grammar, all controls, Unicode, limits, depth, duplicates, numeric
semantics, and EOF outcomes.

## Integration gate

Before the protocol is integrated with any broker or sandboxed process:

1. reject leading/missing object commas in Guile and pin local plus real-socket
   regressions;
2. make every Guile-encoded string valid JSON, pin all C0 controls in values
   and keys in both directions, and recheck the encoded-byte boundary;
3. replace quadratic duplicate detection and retain an aggregate transport
   work budget;
4. decide and pin exact numeric type/signed-zero semantics before defining
   identity-bearing fields; and
5. preserve the accurate test-count claim while distinguishing blocking smoke
   coverage from future deadline/cancellation/backpressure guarantees.

No hardware session is justified for any of these fixes.

## Implementation disposition pending independent recheck — 2026-09-04

This section was appended only after the pinned implementation tests passed.
It records the implementer's disposition and does **not** alter the findings or
the integration-blocking verdict above.  A subsequent independent review must
re-run the original reproductions against the changed files.

1. **Malformed object separators — fixed in the Guile wrapper.**
   `pinenote/tools/book-protocol/book-protocol.scm` now extends the bounded
   lexical preflight with a small container/token-order state machine.  It
   enforces object and array comma, colon, key, value, and close states before
   `json-string->scm`; `guile-json` still performs string, number, keyword, and
   value decoding.  `pinenote/tools/book-protocol/malformed-object-vectors.json`
   pins top-level and nested missing/leading-comma payloads.  The same literals
   are rejected by the local Guile tests and by both the Python decoder and the
   real inherited-FD Guile socket fixture in
   `pinenote/tools/book-protocol/test_guile_conformance.py`.

2. **C0 output grammar — fixed by a deliberate `#:unicode #t` wire choice.**
   Guile encoding now asks `guile-json` 4.7.3 to escape Unicode.  This emits
   valid escapes for every C0 code point, leaves U+0080–U+00FF as direct UTF-8,
   emits `\uXXXX` above U+00FF in the BMP, and emits surrogate-pair escapes for
   supplementary scalars.  The protocol accepts both escaped and direct UTF-8
   scalar spellings and remains explicitly noncanonical.
   `pinenote/tools/book-protocol/test-book-protocol.scm` originates all 32 C0
   controls as individual keys and values and checks that no raw C0 byte is in
   the compact payload.  `pinenote/tools/book-protocol/guile-conformance-peer.scm`
   independently originates the same corpus plus supplementary Unicode for
   Python decoding; the reverse socket test sends Python-originated controls
   through Guile.  An escaping-aware U+0000 frame reaches exactly 65,536 payload
   bytes locally and over the socket.

3. **Quadratic duplicate detection — fixed with an instrumented hash path.**
   `validate-value!` now uses a string-keyed Guile hash table rather than a
   linear `seen` list.  A private parameterized test hook records exactly one
   hash lookup per member.  The local suite decodes an exact-65,536-byte object
   with 7,405 unique members and asserts 7,405 probes; there is no timing
   threshold.  Transport-level aggregate work/rate/deadline limits remain
   outside this codec.

4. **Numeric semantics — decided as rounded mathematical values, not lexical
   representation preservation.**
   Generic accepted JSON numbers denote their mathematical value after
   binary64 rounding where applicable.  Exact/inexact representation and the
   sign of zero are not protocol distinctions and need not survive a generic
   decode/re-encode path.  `pinenote/tools/book-protocol/numeric-wire-vectors.json`
   and the socket conformance test now assert the actual Python value, type, and
   zero sign after Guile.  A separate Guile-originated `-0.0` proves the reverse
   direction currently preserves a negative float without turning that
   observation into a guarantee.  Opaque identifiers/handles remain strings;
   future generations, sequences, and counts still require type-strict schema
   integers.  No such broker schema is claimed here.

5. **Post-serialization Guile encoder bound — fixed for local serialization
   work, with caller and aggregate limits still explicit.**
   Before `scm->json-string`, `validate-value!` now carries a conservative
   compact-JSON byte budget matching the chosen escaping mode.  String and
   vector lower bounds reject impossible inputs early; object traversal is
   sequential and retains only the depth-16 recursion path plus the required
   bounded duplicate hash, rather than a collection-width traversal stack or
   copy.  Private parameterized serializer instrumentation proves one-MiB
   strings and a 40,000-element vector fail before the JSON serializer.  The
   caller-owned Scheme object already exists, and schema output limits plus
   aggregate CPU/rate/deadline/queue limits remain unproven.

The exact pinned command `make -C pinenote/tools/book-protocol check` passed 45
Python `unittest` methods and 49 Guile SRFI-64 assertions.  The Python library
was not modified for these dispositions; its independent recheck remains
separate.  The two dependency defects and their original socket reproductions
remain documented above as an upstream-quality report.  No row was added to
the concurrently edited shared upstream register; coordinate that separately
before filing or sending anything.  No hardware, VM, target build, deployment,
or unbounded stress was used.

## Independent re-review of all five dispositions — 2026-09-04

### Re-review verdict

**All five original findings are closed for the generic framing-codec scope on
the exact snapshot below.** The original real-socket failures no longer
reproduce. Independent structural mutations found no Python/Guile acceptance
split, independently originated C0 and maximum-size frames are valid in both
directions, the former deterministic quadratic duplicate walk now scales
approximately linearly on the original maximum-width fixture, and public
encoder calls reject oversized and cyclic values before serialization can run
unbounded.

This does **not** clear the blocking port adapter as a future asynchronous
broker transport. It still has no intrinsic deadline, cancellation,
backpressure, aggregate connection-work, or queue policy. It also does not
clear any future broker schema until Guile has type-strict lexical-integer
checks for generations, sequences, and counts. No broker schema exists in this
experiment, so that schema gate is explicit rather than a hidden defect in the
generic codec.

The re-review considered the exported/public codec and untrusted peer bytes.
The private test parameters are reachable with Guile's `@@` reflection, but a
hostile module already executing inside the trusted Guile process is outside
this framing threat model. No UI, KOReader, sandbox, authorization, or
end-to-end security conclusion follows from these tests.

### Exact re-reviewed snapshot

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-protocol/README.md` | `d75183d9f4574d2a38f9c08e70e2f514dcbab0b114c074ea5633ade45f026613` |
| `pinenote/tools/book-protocol/Makefile` | `d7f375426f34f8ac321286c2b9cb9ff51b0ea419fc0aa0eb2625f30d94017cd4` |
| `pinenote/tools/book-protocol/book_protocol.py` | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| `pinenote/tools/book-protocol/book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| `pinenote/tools/book-protocol/book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| `pinenote/tools/book-protocol/malformed-object-vectors.json` | `337ceb83781803135c3739387e3d224ee8d060d09ad6adb967379672dd03b651` |
| `pinenote/tools/book-protocol/numeric-wire-vectors.json` | `f55de8cb0253b9ae7ce08d82b13e2d331f703878b4bbc13d02822bca1bc72c9f` |
| `pinenote/tools/book-protocol/test_book_protocol.py` | `ba83c7b909e0ea34b2cb70c3ee0cbb36297099a77e639e935b319a58d4e3127a` |
| `pinenote/tools/book-protocol/test-book-protocol.scm` | `b7ae2f377e17b899417cd5badcb641f922c0b4e21428f818184be8ffe0214665` |
| `pinenote/tools/book-protocol/test_guile_conformance.py` | `f95cf49ea9b8aafdbd6e09aa5e8b4bcefec2e6bd02c56222c6eb2b58d75d9bf9` |
| `pinenote/tools/book-protocol/guile-conformance-peer.scm` | `4aa4727dc2e6bf5afe4d0b9a72767ee9a02874addd784dfbfce38b8c63179648` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |
| `doc/upstream-register.md` (item 26 context only) | `0bb8e51f3e218bad36dc0c47ced8d7a29bd0bad8bb5acc39daa86c002acf53cd` |

The pin still resolves Guile 3.0.11, `guile-json` 4.7.3, and Python
3.12.12 at the store paths recorded in the original review. The installed
`guile-json` parser/builder source hashes are likewise unchanged. Upstream
register item 26 correctly says `needs-work; not sent`; this re-review neither
files nor sends anything upstream.

### Finding 1 recheck — closed: structural grammar scanner rejects the dependency hole

The four original inherited-FD socket cases now fail closed with no response:

```text
{"a":1 "b":2}                 rc=2  JSON object value is missing a comma or colon
{,"a":1}                      rc=2  unexpected or leading JSON comma
{"outer":{"a":1 "b":2}}     rc=2  JSON object value is missing a comma or colon
{"outer":{,"a":1}}            rc=2  unexpected or leading JSON comma
```

This was not accepted merely because the supplied four-vector test passed. An
independent socket corpus covered 35 cases: legal space/tab/LF/CR placement;
nested objects and arrays; empty containers; strings containing structural
lookalikes; and leading, missing, trailing, doubled, or misplaced commas and
colons at root, object, array, and nested positions. It also covered missing
values, unquoted keys, adjacent values, mismatched/unterminated containers, and
multiple top-level values. All six valid cases were accepted by both codecs and
all 29 invalid cases were rejected by both.

A second deterministic mutation fixture deleted, inserted, or replaced
structural punctuation and whitespace around two nested object/array bases. Of
428 unique mutations, Python and Guile each accepted the same 45 and rejected
the same 383; every accepted Guile response was itself valid to Python. The
four JSON whitespace characters were accepted, while NBSP, form feed, vertical
tab, and BOM in whitespace positions were rejected by both. These tests cover
the state transitions beyond the narrower committed object-comma corpus.

Source inspection agrees with the result: parent state is consumed before a
nested container is pushed; post-comma object/array states disallow closing;
and key, colon, value, comma/end, and root/end states are distinct. Strings are
scanned only to find their lexical end, while `guile-json` remains responsible
for escape and value grammar as documented. No structural bypass was found.

### Finding 2 recheck — closed: every C0 output is valid and byte accounting matches the new mode

The original valid input `{"s":"\u0000"}` now returns a valid escaped reply;
the response no longer contains raw NUL. An independent all-C0 object used each
U+0000–U+001F scalar in both a key and a value and sent it through the real
socket in both directions:

```text
Python -> Guile -> Python: rc=0, exact value round trip, 0 raw C0 payload bytes
Guile -> Python:          rc=0, exact key/value round trip, 0 raw C0 payload bytes
```

The Guile-origin fixture independently confirmed the deliberate wire choice:
U+00FF remained direct two-byte UTF-8, U+0100 became `\u0100`, and U+1F600
became `\ud83d\ude00`. Python accepted all spellings. A Guile-origin escaped
U+0000 frame had an exact 65,536-byte payload and decoded to 10,923 scalars;
adding one ASCII scalar was rejected by the budget. Separately, an untrusted
direct-UTF-8 payload with 16,382 emoji remained exactly 65,536 bytes and the
Guile reader acknowledged it; a 65,537-byte prefix was rejected before payload
allocation.

Independent local boundary cases filled the payload exactly with each encoding
class—ASCII, quote, a named control, another C0 control, U+0080, U+00FF,
U+0100, and a supplementary scalar—and then added one byte. Every exact case
encoded to 65,536 bytes and every one-over case raised
`book-protocol-error`. An exact-size all-ASCII object key behaved the same.
Thus the `#:unicode #t` fix closes both JSON validity and its associated
maximum-byte accounting issue.

### Finding 3 recheck — closed: deterministic quadratic walk removed

The public path now performs one `hash-ref` and one `hash-set!` per decoded
member instead of scanning a growing `seen` list. Direct, nested,
escape-equivalent (`"a"`/`"\u0061"`), and direct/escaped supplementary
duplicates all failed over the socket; distinct case-sensitive keys passed.

The original exact-65,536-byte, 7,405-member fixture was rerun in one persistent
socket process, alternating with the exact-size one-string control. Eight
samples gave:

```text
one-string frame: median 2.81 ms
7,405-member frame: median 7.06 ms
ratio: 2.52x
```

The pre-fix medians were 2.7 ms and 242.4 ms (88.5x). An independent scaling
run over unpadded unique objects gave medians of 0.451, 0.942, 2.291, 4.131,
and 6.764 ms for 500, 1,000, 2,000, 4,000, and 7,000 members respectively.
That runtime evidence and the source shape independently support approximately
linear behavior for the original adversarial family.

The private `duplicate-probe-hook` assertion is useful as a member-visit
regression but is not by itself an independent proof of hash complexity: the
hook runs immediately before, rather than inside, `hash-ref`, and does not
count `hash-set!` or collision-chain work. Its “one probe per member” test name
should be read as one instrument marker/member. This is **not a remaining
blocker** because source inspection plus the independent size/timing series
confirms removal of the deterministic list scan. It also does not replace the
still-required aggregate connection CPU/rate limit.

### Finding 4 recheck — closed by an explicit generic-number decision; schema gate remains open

The original numeric socket literals still produce the same representations:

```text
1.0 -> 1 (int)       0e1000 -> 0 (int, positive)
0.0 -> 0 (int)       -0.0   -> 0 (int, positive)
9007199254740991.1 -> 9007199254740991.0 (float)
0.10000000000000001 -> 0.1 (float)
```

The README now explicitly defines generic numbers by rounded mathematical
value, not preservation of lexical exactness, Python/Guile type, or signed
zero. The revised literal vectors assert response `repr`, type, and zero sign;
a Guile-originated `-0.0` still reaches Python with a negative sign but is
correctly documented as an observation, not a guarantee. This resolves the
generic-codec ambiguity without pretending that numeric aliases are safe IDs.

The hard schema gate remains: opaque IDs/handles are strings, and any future
generation, sequence, or count field must add and test a type-strict lexical
integer rule in Guile. There is no broker message schema in this experiment, so
there is nothing further to validate at this rung and no permission to infer
future schema safety.

### Finding 5 recheck — closed: conservative budget precedes serialization and cycles terminate

Source order independently confirms `validate-value!` runs with the 65,536-byte
budget before the private `json-encoder` parameter is invoked. Its per-scalar
costs match the selected `guile-json` mode in all boundary classes listed
above. The post-serialization byte check remains as defense in depth.

Public-API adversarial calls produced these bounded outcomes:

```text
exact escaped-control payload    accepted at 65,536 bytes
one scalar over                  encoding-budget ProtocolError, 0.570 ms
one-MiB local string             string-budget ProtocolError, 1.954 ms
40,000-element vector           array-budget ProtocolError, 0.061 ms
40,000-member object            string-budget ProtocolError, 14.282 ms
self-referential vector          nesting ProtocolError, 0.020 ms
self-referential object value    nesting ProtocolError, 0.017 ms
cyclic object entry spine        duplicate-key ProtocolError, 0.007 ms
```

Times include fixture construction where it occurred and are evidence of
termination, not performance requirements. Impossible vector breadth is
rejected from its length lower bound; objects are visited sequentially only
until their bounded encoding budget is exhausted. The already-created caller
object, schema-specific output size, and aggregate connection work remain
outside this guarantee exactly as the README says.

### Supplied suite, blocking scope, and remaining integration blockers

The pinned `make -C pinenote/tools/book-protocol check` is green, but the exact
current count is **46 Python `unittest` methods and 49 Guile SRFI-64
assertions**, not the implementer's/README's 45 + 49. There are six real Guile
socketpair methods and 40 Python-local methods. The extra Python-only
`test_stream_owners_cannot_be_copied_or_pickled` landed concurrently and is
outside this Guile review; the count text is stale by one. This bookkeeping
error is not a framing blocker, but it should be corrected before presenting
the recorded run as exact.

`blocking-io.scm` is byte-for-byte unchanged. Independent live-socket partial
header and partial payload peers were both still blocked after 300 ms, then
exited 2 with `EOF truncated a Book Protocol frame` when the writer closed;
clean EOF exited 0. This honestly proves blocking EOF behavior only. The
fixture's ten-second supervisor is not a protocol deadline, and none of these
results establish nonblocking backpressure, cancellation, crash cleanup, or
UI/process security.

There are no remaining blockers from the **five original Guile framing
findings**. Before integration with an untrusted broker process, the remaining
gates are outside this generic codec:

1. provide a nonblocking transport owner with deadlines, cancellation,
   backpressure, bounded queues, and descriptor/crash lifecycle;
2. impose aggregate per-connection CPU/rate limits rather than treating 64 KiB
   as a work budget; and
3. define actual message schemas and add Guile lexical-integer enforcement for
   every identity/order/count field before those values reach broker logic.

No hardware or build is needed for those host-side gates, and this re-review
makes no UI or end-to-end security claim.
