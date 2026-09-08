# Book Protocol Python framing adversarial review — 2026-09-04

## Verdict

**Changes requested before the asynchronous hello/action/present rung.** The
Python decoder's peer-byte path has good per-frame size/depth checks, strict
UTF-8, duplicate-key rejection, and fail-closed behavior once an iterator has
actually started. The accepted surrogate-pair fix behaves correctly. I found
no direct peer-only escape from the 64 KiB frame bound.

The main blocker is at the Python API boundary: an iterator is not marked
active until its first `next()`. A trusted event-loop caller can therefore hand
the decoder multiple chunks, consume them in reverse order, close handed-off
input without poisoning, or declare clean EOF before any handed-off bytes are
examined. That is too fragile for a protocol carrying initialization,
cancellation, generation, or capability operations.

This is an adversarial review of the framing prototype, **not a security audit**
of a broker, transport, sandbox, Guile runtime, KOReader integration, or future
message schemas. None of those exists in this gate.

## Exact review snapshot

The Python conclusions apply to these exact files:

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-protocol/book_protocol.py` | `be9fe45605313187a0269b49a9044db787db0773704f2fca59c57429c9cd545b` |
| `pinenote/tools/book-protocol/test_book_protocol.py` | `f8cc88d4e73180c139c58c8c6bdf676bf44bc635ab66d8fd261fde9daf36036b` |
| `pinenote/tools/book-protocol/README.md` | `0ea63fe31f18b3588b80211f037ce518ea6e2f37e384a7b04f448296f5a35fad` |
| `pinenote/tools/book-protocol/Makefile` | `d7f375426f34f8ac321286c2b9cb9ff51b0ea419fc0aa0eb2625f30d94017cd4` |
| `doc/book-computer-implementation.md` | `3d6fbec59ced5d6c9ac3f54145e136f6bac70aca99948ec7fc4b5be00985a01b` |
| `doc/wilkbook-self-hosting-book-computer.md` | `aef579f6b1126a9d0803054ee78249e75adfd0c82ac9a00ff3b021fe6ebe8f6e` |

The Guile implementation was being written concurrently. I read the following
snapshots only for cross-language context; I do **not** treat them as a finished
implementation or give them a Guile acceptance verdict here:

| Concurrent context file | SHA-256 |
|---|---|
| `pinenote/tools/book-protocol/book-protocol.scm` | `a13558e71fdf1c31b73ba4f09e952477fdbb4b7c0ca63ca0d66582a6094e3aa6` |
| `pinenote/tools/book-protocol/book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| `pinenote/tools/book-protocol/guile-conformance-peer.scm` | `697a55e029c8ce083bda856e6d18aa8a016df31e5a02c4180d135170b3c98cbb` |
| `pinenote/tools/book-protocol/test-book-protocol.scm` | `a393c654eae0d8323331e3877643377bc83020b5262bba87ee4e37f002ec6d15` |
| `pinenote/tools/book-protocol/test_guile_conformance.py` | `4d2e8c24a84e046e9567e28f88526309d8e0cd8c5789a01d017edc20f561d28b` |

The `guile-conformance-peer.scm` hash above is intentionally the exact captured
snapshot value. A later hash means the concurrent file changed and must be
reviewed again rather than inferred from this report.

## Findings, ranked

### 1. Medium — an unstarted lazy iterator does not reserve the decoder, permitting reorder and silent drop

`FrameDecoder.feed()` checks `_feeding`, but `_feeding = True` occurs inside
the generator body (`_feed`). Python does not execute that body when the
generator is created. The supplied active-iterator test starts its iterator
with `next()` before attempting re-entry, so it misses this state.

Exact reproduction from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import sys
sys.path.insert(0, "pinenote/tools/book-protocol")
from book_protocol import FrameDecoder, encode_frame

d = FrameDecoder()
first = d.feed(encode_frame({"seq": 1}))
second = d.feed(encode_frame({"seq": 2}))
print(list(second), list(first), d.poisoned)

d = FrameDecoder()
abandoned = d.feed(encode_frame({"seq": 1}) + encode_frame({"seq": 2}))
abandoned.close()
print(d.poisoned, list(d.feed(encode_frame({"seq": 3}))))

d = FrameDecoder()
pending = d.feed(encode_frame({"seq": 1}))
d.finish()
try:
    list(pending)
except Exception as error:
    print(type(error).__name__, str(error), d.poisoned)
PY
```

Observed:

```text
[{'seq': 2}] [{'seq': 1}] False
False [{'seq': 3}]
ProtocolError decoder is closed after EOF False
```

Expected for the documented one-iterator invariant: the second `feed()` and
premature `finish()` should fail immediately, and closing an iterator that has
accepted coalesced input should poison rather than silently forget it. Observed:
valid messages are accepted out of stream order; `close()` before first
iteration drops all handed-off bytes without poison; and EOF is accepted as
clean before pending bytes are examined. This also makes README lines 35–37's
unqualified close/poison guarantee too broad.

**Trust/exploit distinction:** a peer cannot invoke Python methods or reorder
the iterators by itself. This requires a bug, queue, or scheduling mistake in
the trusted caller. It is nevertheless security-relevant integration debt:
reordering `initialize`, `call`, `cancel`, or generation-bearing updates can
change authority or stale-result decisions. The planned host is explicitly
asynchronous, so a documentation-only precondition is not enough.

**Action:** reserve ownership at `feed()` call time, not first `next()`, using a
small explicit iterator object or a primed generator whose `close()` runs
cleanup even before the first public item. Add tests for two unstarted feeds,
reverse consumption, close-before-first-next, finish-before-first-next, and
re-entry both before and during a yield. Do not fix this merely by weakening
the README unless the broker will never queue a feed iterator and that property
is mechanically enforced.

### 2. Medium design blocker — binary64 rounding creates identifier aliases, and current equality tests can hide cross-language type differences

The codec intentionally permits normal binary64 rounding. That is reasonable
for measurements but unsafe as an unstated representation for request IDs,
sequence numbers, generations, amounts, or capability-related values.

Exact reproduction:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import struct, sys
sys.path.insert(0, "pinenote/tools/book-protocol")
from book_protocol import FrameDecoder

def decode(token):
    payload = ('{"id":' + token + '}').encode("ascii")
    frame = struct.pack(">I", len(payload)) + payload
    return list(FrameDecoder().feed(frame))[0]["id"]

for left, right in [
    ("9007199254740991", "9007199254740991.1"),
    ("0.1", "0.10000000000000001"),
    ("0.0", "-0.0"),
]:
    a, b = decode(left), decode(right)
    print(left, repr(a), type(a).__name__, right, repr(b), type(b).__name__,
          a == b, hash(a) == hash(b))
print("0e1000:", repr(decode("0e1000")), type(decode("0e1000")).__name__)
PY
```

Observed on Python 3.11.14:

```text
9007199254740991 9007199254740991 int 9007199254740991.1 9007199254740991.0 float True True
0.1 0.1 float 0.10000000000000001 0.1 float True True
0.0 0.0 float -0.0 -0.0 float True True
0e1000: 0.0 float
```

This is **not a violation of the documented codec policy**; README lines 57–63
say that binary64 rounding applies. Nor is there an end-to-end exploit yet,
because no request schema or broker exists. The risk becomes exploitable if a
schema says only “number,” or if host code keys request state by the decoded
number: an attacker can create equality/hash aliases. Python also considers
`0 == 0.0`, and `unittest.assertEqual` therefore does not prove matching exact
numeric representations between languages. The concurrent Guile unit snapshot
expects exact `0` for `0e1000`, while Python returns inexact `0.0`; semantic
equality alone masks that difference.

**Action:** before defining the first messages, make all identity, generation,
sequence, count, and capability-adjacent fields either strings or lexically
integer fields validated as exact integers in every implementation. In Python,
schema checks must use `type(value) is int`, not `isinstance(value, int)` (which
also accepts booleans). Add shared literal wire vectors that assert type/class
as well as `==`, including `1`, `1.0`, `0e1000`, `-0`, `-0.0`, safe boundaries,
and rounded fractional aliases. Do not use raw JSON numbers for opaque handles.

### 3. Low/defense-in-depth — obviously unsafe integer and exponent tokens are converted to bignums before range rejection

`_parse_integer()` calls `int(token)` before comparing to the 53-bit limit.
The decimal-exponent guard likewise calls `int(exponent_text)` before comparing
to 1,000. CPython 3.11+ normally mitigates enormous integer conversions with a
process-global digit limit, but that limit can be disabled and older runtimes
do not supply the same defense. The protocol already knows that a safe integer
has at most 16 decimal digits and that a permitted exponent needs at most four.

Bounded reproduction (the setting deliberately models a runtime without the
CPython guard):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import struct, sys, time
sys.path.insert(0, "pinenote/tools/book-protocol")
from book_protocol import FrameDecoder
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)
for digits in (10000, 30000, 65000):
    payload = b'{"n":' + b'9' * digits + b'}'
    frame = struct.pack(">I", len(payload)) + payload
    samples = []
    for _ in range(3):
        decoder = FrameDecoder()
        started = time.perf_counter()
        try:
            list(decoder.feed(frame))
        except Exception:
            pass
        samples.append((time.perf_counter() - started) * 1000)
    print(digits, round(min(samples), 3), decoder.poisoned)
PY
```

Observed minimum host times were `0.486`, `2.952`, and `12.112` ms: visibly
superlinear conversion work before the same `ProtocolError`. The child remained
bounded and was not stress-run. A 64 KiB frame cap makes the cost finite, and
default CPython's digit guard mitigates this specific reproduction, so this is
not an unbounded allocation finding. Repeated frames and a slower ARM host still
make needless bignum work useful to a peer; aggregate connection CPU is not
bounded by this codec.

**Action:** reject by sign-stripped digit count and lexicographic comparison
before `int()`. Do the same for exponent text before converting it. Keep
connection CPU/rate/deadline limits outside the codec; a per-frame byte limit is
not an aggregate-work budget. Apply equivalent cheap-before-expensive review to
each language codec rather than relying on interpreter-specific safeguards.

### 4. Low, trusted-input only — the encoder's 64 KiB limit is post-serialization, not a work or allocation bound

The decoder rejects an oversized declared length after four bytes. The encoder,
however, validates the whole object, builds the complete JSON `str`, encodes a
complete UTF-8 `bytes`, and only then checks length.

Exact bounded reproduction:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import sys, tracemalloc
sys.path.insert(0, "pinenote/tools/book-protocol")
import book_protocol as bp
called = 0
original = bp.json.dumps
def wrapper(*args, **kwargs):
    global called
    called += 1
    return original(*args, **kwargs)
bp.json.dumps = wrapper
tracemalloc.start()
try:
    bp.encode_frame({"s": "x" * (1024 * 1024)})
except Exception as error:
    _, peak = tracemalloc.get_traced_memory()
    print(type(error).__name__, str(error), called, peak)
PY
```

Observed: `json.dumps` was called once, the reported payload was 1,048,584
bytes, and traced peak allocation was 2,098,499 bytes before rejection.

**Trust/exploit distinction:** peer wire bytes cannot reach this path. The
caller supplies an already materialized local Python object, so this is not a
decoder security defect. It matters if future documentation calls the encoder
“bounded,” or if trusted broker responses include unbounded book-derived data.
Untrusted SDK encoding happens inside the sandbox and should also have its own
resource quota.

**Action:** describe the current limit as an emitted-frame limit, not an encoder
work bound. Before host use, combine schema-specific output limits with an
incremental encoder or an early conservative byte budget. Add a test proving
the chosen oversized-output path fails before constructing an unbounded second
copy.

## Cross-language and guarantee cautions

- The accepted Python surrogate-pair change is sound in the reviewed snapshot:
  direct scalar UTF-8 and escaped pairs at the surrogate boundaries were
  accepted; lone, reversed, repeated-high, and repeated-low surrogates were
  rejected and poisoned. Duplicate detection also operated after unescaping.
- Compact JSON is not canonical JSON. Key order, whitespace, direct UTF-8 versus
  `\u` pairs, and numeric spellings can differ while decoding to equal values.
  This is permitted by the README, but raw frame bytes must not become a
  signature, idempotency, or object-identity input without a separately defined
  canonical form.
- The real Python↔Guile fixture in the concurrent snapshot covers an ordinary
  round trip and duplicate rejection. Language-local tests cover more edges,
  but the next conformance increment should use one shared corpus of literal
  wire vectors for Unicode, numeric, duplicate, frame-size, and depth edges.
  A Python-produced happy-path frame alone can hide matching assumptions, and
  plain equality can hide integer/inexact mismatches.
- A valid frame delivered before a later malformed coalesced frame remains
  delivered; poisoning does not roll back its effects. That streaming behavior
  is reasonable, but the future broker must not describe a socket read or batch
  of coalesced frames as atomic.

## Independent evidence and non-findings

- `make python-check` passed all 29 supplied Python tests. This was run only
  after the independent probes above; it is not the basis of the findings.
- A deterministic 2,000-case malformed-byte probe (0–64-byte payloads) produced
  only `ProtocolError` plus poison, with no unexpected exception class. A
  separate 500-case valid-object probe round-tripped random fragmentation with
  no mismatch.
- Exact 64 KiB payload handling, zero/oversized header rejection, strict UTF-8,
  nesting 16/17, duplicate keys (including escaped equivalence), truncation,
  and poison after an activated parser error behaved as documented.
- A cyclic local dictionary did **not** hang the explicit encoder walk: each
  traversal increases logical depth and it was rejected at depth 17. I do not
  report the initially suspected cycle DoS.
- Numeric tokens up to the frame limit remained finite in the bounded probes;
  a 65,002-character decimal significand took about 1.7 ms on this host. This
  does not substitute for aggregate CPU limits.
- I did not rerun the pinned Guix/Guile check while its implementation agent was
  writing these files. The ambient Guile intentionally lacks `(json)`, and the
  full pinned run could involve shared Guix work. The concurrent agent's
  recorded green result is not counted as independent review evidence here.
- No network, device, VM, deployment, or unbounded stress was used.

## Blockers to the next rung

1. Enforce single-feed ownership from `feed()` call time and pin the unstarted
   close/EOF/reorder cases with tests.
2. Define exact schemas for IDs, generations, sequences, counts, and handles;
   do not let generic binary64 values reach identity or authorization logic.
3. Cheaply reject impossible integer/exponent magnitudes before bignum
   conversion, then add transport-level frame-rate, CPU/deadline, inbound and
   outbound queue, diagnostic, and connection limits. The framing codec alone
   deliberately does not prove those bounds.
4. After the concurrent Guile files settle and receive their own adversarial
   review, run a pinned shared literal-vector corpus in both directions. Record
   semantic versus exact-type expectations and explicitly state that the wire
   encoding is noncanonical.

No hardware rung is justified by or needed for these fixes.

## Fix disposition submitted for independent re-review — 2026-09-04

This section was added after the implementation's pinned test run.  It records
the implementer's dispositions; it does **not** revise the findings above or
claim reviewer acceptance.  The original reviewer should independently rerun
the reproductions against the new snapshot.

1. **Unstarted feed ownership — fixed in the Python implementation.**
   `pinenote/tools/book-protocol/book_protocol.py` now returns an explicit
   `_FeedIterator` and reserves `_feeding` inside `FrameDecoder.feed()`, before
   returning it.  Closing with any handed-off bytes unconsumed, including
   before the first `next()`, poisons and releases the decoder.  A second feed
   and `finish()` fail while an unstarted or yield-suspended iterator owns it;
   the iterator also rejects self-reentry while decoding.  Exact regression
   cases are in `pinenote/tools/book-protocol/test_book_protocol.py`:
   `test_unstarted_feed_reserves_decoder_and_prevents_reverse_order`,
   `test_unstarted_feed_prevents_clean_eof_until_consumed`,
   `test_close_before_first_next_poisons_handed_off_input`,
   `test_active_iterator_must_be_finished_before_another_feed_or_eof`, and
   `test_same_iterator_cannot_reenter_while_decoding`.

2. **Numeric identity/schema risk — hard rule documented; schema enforcement
   remains deliberately unresolved.**
   `pinenote/tools/book-protocol/README.md` now requires opaque IDs and handles
   to be strings, and future generation/sequence/count fields to be lexical
   safe integers with type-strict validation (`type(value) is int` in Python,
   excluding booleans).  It explicitly forbids generic binary64 values as
   identity keys and raw noncanonical frames as signature/idempotency inputs.
   No broker schema exists, so the codec does not pretend to enforce these
   field rules.  `pinenote/tools/book-protocol/numeric-wire-vectors.json` is a
   shared literal corpus consumed by
   `pinenote/tools/book-protocol/test_book_protocol.py` and
   `pinenote/tools/book-protocol/test_guile_conformance.py`; tests assert Python
   classes and expose equality/hash aliases and Guile's current collapse of
   `1.0`, `0e1000`, and `-0.0` to integer spellings.  Guile lexical-integer
   field enforcement remains work for its independent review, not a claim made
   by this disposition.

3. **Bignum work before range rejection — fixed for Python.**
   `_parse_integer()` rejects by sign-stripped digit count and lexicographic
   comparison before converting at most 16 digits.  Exponents are checked the
   same way without `int()`; arbitrarily long leading-zero exponents whose
   numeric magnitude is at most 1000 are consciously accepted and normalized
   before `Decimal`/`float` conversion.  Regressions
   `test_integer_magnitude_is_rejected_before_int_conversion`,
   `test_exponent_magnitude_is_rejected_before_numeric_conversion`, and
   `test_long_leading_zero_exponents_are_normalized_then_accepted` prove the
   conversion boundary without relying on CPython's process-global digit
   guard.  Equivalent Guile cheap-before-expensive review is outside this
   Python fix and receives no acceptance claim here.

4. **Post-serialization encoder limit — fixed for Python's local serialization
   copies, with caller-owned and aggregate limits still explicit.**
   Before `json.dumps`, `pinenote/tools/book-protocol/book_protocol.py` now
   performs a depth-bounded compact-JSON byte-budget walk.  Minimum breadth and
   string-length checks reject impossible values early; accepted traversal
   keeps only the at-most-16-deep recursion path rather than a stack
   proportional to collection width.  Tests
   `test_oversized_string_is_rejected_before_json_serialization`,
   `test_impossibly_wide_list_is_rejected_before_iterating_its_children`, and
   the existing depth/max-frame boundaries prove `json.dumps` is not reached
   on those oversized paths.  The README does not claim all memory is bounded:
   the caller-owned object already exists, arbitrary subclasses remain trusted,
   and schema output limits plus aggregate CPU/rate/deadline/queue limits remain
   outside this codec.

The exact pinned command `make -C pinenote/tools/book-protocol check` passed 42
Python `unittest` cases and 34 unchanged Guile SRFI-64 checks after these
changes.  No Guile library/source file was modified for these dispositions; its
independent review remains separate.  No hardware, VM, target build, deployment,
or unbounded stress was used.

## Independent Python fix re-review — 2026-09-04

### Re-review verdict

**The four original Python fixes work on their intended built-in-value,
single-owner API paths, but the ownership fix has one new shallow-copy bypass.**
The original reorder, close-before-start, premature-EOF, bignum, and late
serialization reproductions are closed. Ordinary explicit close, exhaustion,
GC finalization, parser failure, and same-object reentrancy also behaved safely.

I do not yet accept the iterator's claimed mechanically unique ownership for
asynchronous integration: `copy.copy()` can clone `_FeedIterator`; a stale clone
can release the decoder while the real iterator still owns it, after which two
new feeds can again be consumed in reverse order. This requires trusted-caller
misuse, not peer bytes, but it recreates the ordering class that finding 1 made
a next-rung blocker. Make the iterator non-copyable or bind releases to an
identity token, then rerun the short reproduction below.

The generic-number finding is **not a remaining blocker to accepting this
schema-free framing codec**. The aliases are now deliberately exposed and the
README states the right hard rules. They become a mandatory gate in the same
change that first introduces `hello`/`initialize`/`call` schemas; they cannot be
deferred until after decoded fields reach lookup, ordering, cancellation, or
authorization logic.

This remains a Python framing re-review, not a security audit or a Guile
acceptance review.

### Exact post-fix snapshot

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-protocol/book_protocol.py` | `780c5a3985066e56d7f53e0105bfe11631da27a226a8f982f85e70a916fddd38` |
| `pinenote/tools/book-protocol/test_book_protocol.py` | `89c19031fd6a693b02be607af4a2dade5a666b9c43891ff95e0f58bb226bdad0` |
| `pinenote/tools/book-protocol/numeric-wire-vectors.json` | `f55de8cb0253b9ae7ce08d82b13e2d331f703878b4bbc13d02822bca1bc72c9f` |
| `pinenote/tools/book-protocol/README.md` | `6bf8dd79c2a41d1d3b0ddc68edb389255a2966e3f3292258c06732196ce31a83` |
| `pinenote/tools/book-protocol/Makefile` | `d7f375426f34f8ac321286c2b9cb9ff51b0ea419fc0aa0eb2625f30d94017cd4` |
| `pinenote/tools/book-protocol/test_guile_conformance.py` (numeric-vector context only) | `f95cf49ea9b8aafdbd6e09aa5e8b4bcefec2e6bd02c56222c6eb2b58d75d9bf9` |
| This report including the implementer disposition, before this re-review was appended | `6a5c4f27dbb83dc388d7405d3128a170f72b6d55643a024643c68cc4aae55e5e` |

No Guile source conclusion is inferred from those files; the Guile reviewer was
active separately.

### Original finding dispositions after independent reproduction

#### 1. Unstarted feed ownership — **partially closed; ordinary paths fixed, copy bypass open**

The original three cases now produce:

```text
second-before-first: RuntimeError
first-result: [{'seq': 1}]
close-before-start: poisoned=True, buffered_bytes=0
feed-after-close: ProtocolError (poisoned)
finish-before-start: RuntimeError
pending-result: [{'seq': 1}]
finish-after-consumption: succeeds, poisoned=False
```

Thus an ordinary second `feed()` no longer obtains an iterator, unstarted close
poisons, and pending input blocks EOF. Additional independent state probes found:

- closing an empty feed releases without poison;
- closing or collecting an iterator after its exact final frame was yielded
  releases without poison and permits the next feed;
- collecting an unstarted iterator or one suspended before coalesced trailing
  input poisons and clears buffers;
- a reference cycle containing the iterator was finalized by explicit
  `gc.collect()` and poisoned correctly on CPython 3.11.14;
- injected `RuntimeError` and `KeyboardInterrupt` from `_decode_payload`
  poisoned, cleared buffers, released ownership, and made later input fail;
- reentrant `feed()`, `finish()`, and `close()` attempted from inside decode
  were all rejected while the original decode completed normally when those
  local errors were caught.

The new bypass is independently reproduced from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import copy, sys
sys.path.insert(0, "pinenote/tools/book-protocol")
from book_protocol import FrameDecoder, encode_frame

d = FrameDecoder()
one = d.feed(encode_frame({"seq": 1}))
print(next(one))

# Clone a yield-suspended iterator whose input is fully consumed. Closing the
# clone releases d._feeding even though `one` still owns the operation.
stale = copy.copy(one)
stale.close()
two = d.feed(encode_frame({"seq": 2}))

# The original can now perform a second stale release while `two` owns d.
one.close()
three = d.feed(encode_frame({"seq": 3}))
print(list(three), list(two), d.poisoned)
PY
```

Observed:

```text
{'seq': 1}
[{'seq': 3}] [{'seq': 2}] False
```

Expected: the returned stateful iterator cannot be cloned into a second owner,
or a release succeeds only when `decoder._active_iterator is self`. Observed:
both shallow copies can clear the one Boolean ownership flag, and later valid
chunks are accepted in reverse order without poison.

**Severity/trust:** medium correctness for the next asynchronous rung, but not a
peer-only exploit. A trusted caller must explicitly or generically shallow-copy
the private-class instance. Ordinary `for`, `next`, `close`, and GC paths do not
do so. Generators were naturally non-copyable, so the replacement explicit
iterator should preserve that property.

**Action:** at minimum implement `__copy__` and `__deepcopy__` as rejecting
operations and add this exact regression. Stronger defense is for
`FrameDecoder` to store the active iterator/token and let `__next__`, `close`,
and `_release` mutate decoder state only when identity matches. Also state that
one connection decoder is single-thread-owned; the current check/set sequence
does not claim thread safety.

One additional error-state edge is **theoretical/local, not peer-reproduced**:
if `_decode_payload` unexpectedly raises `StopIteration`, `_FeedIterator`
poisons and releases but re-raises `StopIteration`, so `list(iterator)` sees
normal exhaustion rather than the internal failure. Current fixed parser code
has no peer-controlled path that raises this exception. Wrapping unexpected
`StopIteration` in `RuntimeError` or `ProtocolError` would preserve diagnostics;
add a fault-injection test if parser hooks are added later.

#### 2. Binary64 identity aliases — **closed for the framing-only gate; mandatory first-schema obligation**

Every original alias remains exactly observable, by design:

```text
9007199254740991 (int) == 9007199254740991.1 (float), hashes equal
0.1 == 0.10000000000000001, hashes equal
0.0 == -0.0, hashes equal
0e1000 decodes as Python float 0.0
```

The shared numeric vectors now assert Python classes and explicitly record
cross-language representation changes rather than letting plain equality hide
them. README lines 91–120 correctly prohibit numeric opaque handles/IDs,
generic binary64 identity keys, and raw noncanonical frame identity.

No request fields exist, so enforcing field semantics inside a generic JSON
codec would be premature. The precise obligations for the first schema change
are:

1. Opaque request IDs and handles are bounded strings, with connection ownership
   establishing authority; the string itself is not a grant.
2. Every generation, sequence, count, and integer precondition is checked before
   dispatch with `type(value) is int`, safe range, and a field-specific range
   (for example, counts are nonnegative and have a much smaller operational
   maximum). `bool` and all float/exponent spellings are negative cases.
3. Apply equivalent checks on incoming and outgoing messages in both languages.
   The Guile path currently cannot infer original lexical integer spelling after
   generic parse/re-encode, so its independent review must choose a schema-aware
   lexical check or another representation before typed fields ship.
4. Shared literal vectors must reject `true`, `1.0`, exponent spellings, signed
   float zero, rounded aliases, unsafe boundaries, and inappropriate negatives
   for each exact-integer field before any map lookup or side effect.
5. Define whether a schema violation poisons/closes the connection and test that
   no earlier request-state mutation occurs for that rejected message.

With those obligations attached to—not following—the first schema increment,
this issue no longer blocks the current framing-only gate.

#### 3. Bignum work before range rejection — **closed for Python; aggregate limits remain outside this gate**

Rerunning the original 10,000/30,000/65,000-digit integer probe with CPython's
digit guard disabled produced minimum times of `0.226`, `0.672`, and `1.480` ms,
instead of the original `0.486`, `2.952`, and `12.112` ms. More importantly, a
module-level bomb substituted for `int()` was never called for the 65,000-digit
token; rejection remained `ProtocolError` and poisoned the decoder.

The exponent boundary independently produced:

```text
1e1000                         accepted by lexical bound
1e1001                         rejected
1E-1000                        accepted by lexical bound
1E-1001                        rejected
0e + 60000 zeroes + 1000       normalized to 0e1000 and accepted
0e + 60000 zeroes + 1001       rejected before Decimal (zero calls)
```

This closes the Python cheap-before-bignum finding. Parsing the full at-most-64
KiB token still requires linear scanning and bounded decimal conversion for
permitted significands. Connection-wide CPU/rate/deadline limits remain a
required transport obligation, accurately excluded by the README; they are not
a reason to reject this isolated codec.

#### 4. Encoder post-serialization limit — **closed for built-in JSON values; declared subclass/caller bounds remain**

The original 1 MiB-string reproducer now raises the conservative budget
`ProtocolError` with `json.dumps_calls=0`. The approximately 1 MiB traced peak
was the caller's string created after tracing began, not a serialized text plus
UTF-8 copy. A 5,000-case generated differential found the budget exactly equal
to actual compact UTF-8 JSON length for every accepted built-in value. An
independent character check compared `_measure_string` with `json.dumps` for
all 63,488 non-surrogate BMP code points plus U+10000 and U+10FFFF: zero
mismatches. Random 2,000-stream fragmentation/coalescing also had zero decode
mismatches.

The explicit caveat is real: a malicious `str` subclass overriding `__len__`
and `__iter__` bypassed the early walk, reached `json.dumps`, allocated the full
1 MiB serialization, and was caught only by the retained post-check. This is a
trusted local-object behavior, not reachable from peer bytes, and the
implementer disposition already excludes arbitrary subclasses. Prefer exact
built-in types if that trust assumption changes. Under the documented current
scope, the original finding is closed.

### Test accounting and remaining gate

- Independent host run: all **39 Python reference-policy tests passed**.
- The implementer disposition's claimed total of 42 consisted of those 39 plus
  three Guile subprocess tests at that snapshot. I did not run the Guile tests
  or the 34 Guile SRFI-64 checks: Guile has a separate active reviewer, and this
  re-review performed no Guix build or environment operation.
- No hardware, VM, device, network, deployment, or build was used.

**Remaining Python gate:** reject shallow copying or enforce identity-token
ownership, add the exact copy regression, and recheck it. The original findings
3 and 4 are closed. Finding 2 is closed for framing and is now a precise
same-change gate for the first schema. Aggregate transport bounds and Guile
correctness remain separate prerequisites for integrated execution, not claims
of this Python codec.

## Final Python cloning disposition — 2026-09-04

### Verdict

**Accepted for the supported Python framing API.** The shallow-copy ownership
bypass from the first re-review is closed. I found no remaining legitimate
public `copy`, `deepcopy`, or pickle path that clones or releases a decoder or
feed iterator. Failed clone/serialization attempts leave the original iterator
reserved, unpoisoned, and able to finish its stream in order.

This verdict does not ask the library to defend against hostile in-process code
that directly mutates private attributes, calls private methods, instantiates
`_FeedIterator`, or deliberately bypasses special-method dispatch through
reflection. Such code already has arbitrary access to the trusted Python
process and is outside the peer-wire adversary model.

### Exact final snapshot

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-protocol/book_protocol.py` | `4e2423e09291d29758a6441d460eee2abfb82f24ed589f477ad62021c95ebe735` |
| `pinenote/tools/book-protocol/test_book_protocol.py` | `ba83c7b909e0ea34b2cb70c3ee0cbb36297099a77e639e935b319a58d4e3127a` |
| `pinenote/tools/book-protocol/README.md` (public-contract context; Guile sections reviewed separately) | `d75183d9f4574d2a38f9c08e70e2f514dcbab0b114c074ea5633ade45f026613` |
| This report before this final disposition was appended | `896880136eef85b071e45bc957e5cdc54a8f2fff8984035b6525572c1221a3cf` |

### Independent reproduction

The exact former exploit now stops at its first clone attempt:

```text
first {'seq': 1}
copy rejected: TypeError feed iterators own stream state and cannot be copied
poisoned: False
second feed while original remains active: RuntimeError
after closing the fully-consumed original: [{'seq': 2}], poisoned=False
```

I then independently exercised both `FrameDecoder` and its returned iterator
through:

- `copy.copy()` and `copy.deepcopy()`;
- `pickle.dumps()` at every host-supported protocol, 0 through 5; and
- `pickle.Pickler(...).dump()`.

Each operation was tried before iteration and after the first `next()` of a
two-frame feed: **32 owner-copy attempts, all rejected with `TypeError`**. After
each rejection, `feed()`/`finish()` still reported the original active owner,
`poisoned` remained false, the original iterator produced frames 1 then 2, and
a subsequent feed produced frame 3. Failed copies of new, cleanly closed, and
already poisoned decoders also left their state unchanged.

The focused supplied Python suite then passed all **40 Python-only tests**. I
did not run Guile tests or builds; that implementation and its fixes have a
separate active reviewer. No public-API counterexample was found in this focused
pass, and no hardware, network, VM, deployment, or build was used.

### Final status of the original Python findings

1. **Iterator ownership/reordering: closed** for the supported public API.
2. **Generic numeric aliases: not a framing blocker.** The hard rule remains a
   mandatory same-change obligation when the first identity-bearing schema is
   introduced, exactly as specified in the first re-review.
3. **Cheap rejection before bignum conversion: closed for Python.** Aggregate
   transport CPU/rate limits remain outside this codec.
4. **Pre-serialization encoder budget: closed for built-in JSON values.** The
   documented trusted-subclass/caller-owned-object exclusions remain.

The Python framing portion no longer blocks the host protocol gate. Guile
correctness, first-schema validation, and integrated transport/backpressure
remain separate gates and are not accepted by this focused disposition.
