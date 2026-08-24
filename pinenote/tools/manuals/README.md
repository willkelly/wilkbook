# manuals — the man/info → EPUB converter's host gate

Rung 1 of the offline ladder (`doc/testing.md`). Covers the converter the
reader image is built from: `pinenote/packages/manuals/manuals.py`, run by
`pinenote/packages/manuals.scm` at system build time and by this suite
directly — the same file, not a copy.

    make manuals-check              # from the repo root
    ./run-tests.sh [/path/to/mandoc]

Standard library Python 3 only. No Guix module is evaluated, the store is
never read, and nothing touches a device.

## What it asserts

| Area | Checks |
| --- | --- |
| Decompression | gzip/bzip2/xz/plain round-trip, and — **quirk** — that an undecodable zstd frame *raises* instead of being passed on as roff |
| Discovery | `share/man/manN` only (never `share/man/<locale>/manN`); earlier prefix wins a collision; `.so` stubs resolve to their target; split `foo.info-N` files order numerically |
| man post-processing | head/foot tables dropped, permalinks unwrapped, `<section>`→`<div>`, headings demoted, ids namespaced, in-book cross references linked, out-of-book ones unwrapped, bare hrefs unwrapped, `mailto:`/`https:` kept, output well-formed XML, NAME one-liner extracted |
| info parsing | node/heading/level extraction, Tag Table dropped, invisible markers stripped, **US kept**, paragraphs reflowed, examples verbatim, `@table` → `<dl>`, menus → link lists, `*Note`/`*note` linked, unknown targets degraded to text, `@image` ASCII fallback |
| EPUB | `mimetype` first and stored; container/OPF/NCX well-formed; manifest ↔ archive ↔ spine agree; **every internal link resolves to an anchor that exists**; NCX nesting spans chapters; two writes are byte-identical |
| Vocabulary | every element emitted is in `REVIEWED_ELEMENTS` |
| Staging one-shot | `pinenote/services/manuals-stage.sh` **executed** against a fake library: first copy, no-op when current, refresh that replaces its own books and leaves the user's alone, a user-deleted shelf staying deleted with the stamp still advancing, an unmounted root, a source with no `MANIFEST` |

## What it does NOT assert

**That KOReader renders any of it.** No engine runs here. The element
whitelist is a contract against a reviewed list, not a rendering test, and
rung 4v (`qemu-virt-visual`) has never been pointed at these books. See
`doc/manuals.md` for the full list of what is unverified.

## The committed fixture

`fixtures/wilkdemo.1` is an mdoc page written to exercise every construct
the post-processor has to survive; `fixtures/wilkdemo.1.mandoc-html` is
mandoc's own output for it, committed so the post-processor is covered on a
host with no roff formatter. Regenerate after a mandoc upgrade with:

    mandoc -Thtml -O 'fragment,man=#%N.%S' -Ios=PineNote \
        fixtures/wilkdemo.1 > fixtures/wilkdemo.1.mandoc-html

A diff there is mandoc changing its output, which is exactly the kind of
drift this fixture exists to make visible.
