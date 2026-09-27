# manuals — converter, installed-corpus and real-reader gates

Rung 1 of the offline ladder (`doc/testing.md`). Covers the converter the
reader image is built from: `pinenote/packages/manuals/manuals.py`, run by
`pinenote/packages/manuals.scm` at system build time and by this suite
directly — the same file, not a copy.

    make manuals-check              # from the repo root
    ./run-tests.sh [/path/to/mandoc]

The converter unit gate uses standard library Python 3. No Guix module is
evaluated and the unit suite never reads the store. The separate acceptance
gate below uses Guile and an actual native KOReader. Neither touches a device.

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

## What the converter unit gate does NOT assert

**That KOReader renders any of it.** No engine runs in the unit gate. The element
whitelist is a contract against a reviewed list, not a rendering test, and
the separate acceptance gate supplies the actual reader boundary. Native
SDL is enough for that boundary; no QEMU build is needed. See
`doc/manuals.md` for the hardware record and remaining limits.

## The committed fixture

`fixtures/wilkdemo.1` is an mdoc page written to exercise every construct
the post-processor has to survive; `fixtures/wilkdemo.1.mandoc-html` is
mandoc's own output for it, committed so the post-processor is covered on a
host with no roff formatter. Regenerate after a mandoc upgrade with:

    mandoc -Thtml -O 'fragment,man=#%N.%S' -Ios=PineNote \
        fixtures/wilkdemo.1 > fixtures/wilkdemo.1.mandoc-html

A diff there is mandoc changing its output, which is exactly the kind of
drift this fixture exists to make visible.

## Installed manuals acceptance (Guile + Lua, no new Python tooling)

From the repo root, with already-realized inputs:

```sh
guile --no-auto-compile pinenote/tools/manuals/acceptance.scm \
  /gnu/store/x3qqz8r52pdh7jzghzfj8l44gfrqkncb-system \
  /gnu/store/qgz9gwiiamspffc61wc1gxdh8kl9ciys-pinenote-manuals \
  /gnu/store/11jrzxbvx4cn4m4ryhllr5a1w93zr1a0-koreader-bin-2026.03 \
  /tmp/opencode/manuals-acceptance-NEW
```

Arguments are `SYSTEM SHELF KOREADER_BUNDLE NEW_OUTPUT_DIR`. The output must
not exist; every run gets fresh private HOME/KO_HOME/XDG directories, copied
books and empty reader caches. Dependencies: Guile 3, Guix (read-only store
metadata query), coreutils (`timeout`, `sha256sum`), `which`, `strings`,
`unzip`, and compressors for the installed inputs (`gzip` for this Info
corpus). KOReader must be native v2026.03. Missing artifacts fail explicitly;
the gate never downloads or builds them. The historical replay is tied to
the explicit omission set; another profile may need a reviewed exception
file, not a silently recomputed expected answer.

The gate checks that the shelf belongs to the supplied system by following
its boot → Shepherd configuration → compiled manuals-service reference. It
queries the shelf's existing derivation and compares both realized converter
source files byte-for-byte with the checkout, refusing a stale converter.
No converter rewrite or additional conversion is needed for these realized
books. No fixture is counted as installed-system coverage.

### Acceptance matrix

| Boundary | What executes / asserts |
| --- | --- |
| Installed corpus | `corpus-check.scm`: independently walks final profile man/info files; names and exact omissions versus MANIFEST/section indexes; man aliases counted in indexes rather than missing NCX chapters; Info manifest counts equal NCX entries and compressed source node counts; no shelf identity absent from profile |
| Man reader | Full ReaderUI opens `Manual pages.epub`; real TOC menu selects Section 1 and `apropos(1)`; index → hit-tested link → page → Back; NAME/SYNOPSIS text; next/previous page |
| Info reader | Full ReaderUI opens `sed.epub`; nested TOC selects Introduction, Overview, Command-Line Options; prose, monospace example and definition-table text; Running sed → hit-tested Options link → Back |
| Paint | Real crengine layout and SDL framebuffer, 1404×1872 / 227 dpi; nonblank/light-and-dark pixel assertions and seven PNGs; text assertions read the engine's current-page range, not the EPUB XML |
| Negative controls | Census rejects missing `sed.epub`, false man entry count, stale/unreviewed omissions; actual KOReader rejects the man book as input to the Info matrix |
| Lifecycle | Each reader has a 120 s host deadline plus 2 s kill grace; positive runs require explicit result marker, exit 0 and clean UIManager teardown |

The host-only `manualacceptance.koplugin` is Lua. It is copied only into the
temporary KO_HOME. It uses the actual TOC Menu callback and ReaderLink's
coordinate hit-testing/follow/history methods; no reader/document module is
replaced with a fake. It does not emulate physical touch or use the PineNote
fbdev driver.

### Recorded result and omissions

`evidence/2026-09-26/` retains the census, exact input/source hashes, bounded
assertion log and three representative screenshots (man index, Info example,
Info table; under 0.7 MiB together). The full run directory also holds all
seven screenshots, native logs and negative-control logs. It is disposable;
no private documents or device data enter the run.

The generation-23 profile contains **732 untranslated man identities and
53 Info manuals**. Its shelf contains **711 man identities** (686 actual
page chapters, 25 aliases) and **25 Info manuals**. All included Info source
node counts match their generated counts. Exact exceptions live in
`profile-omissions.txt`:

- **21 man coverage gaps:** 16 OpenSSH pages, four Shepherd pages, libgc's
  `gc(3)`.
- **28 Info coverage gaps:** 11 untranslated manuals from service-added or
  propagated inputs (Guix/cookbook, Shepherd, fibers, Guile libraries,
  libunistring), plus 17 translated Guix/cookbook manuals. Info translations
  are not deliberately filtered by the converter.
- **697 localized man files:** outside the converter's untranslated-man
  discovery policy.
- **29 Info support files:** directory indexes/images, not independent
  manuals. Source images are not embedded; the converter's ASCII fallback
  remains the policy.

These are reviewed gaps, not a claim of complete installed documentation.
Service-added/propagated packages explain why sharing an explicit package
list with the OS does not cover the final profile. No package-list change
is made by this acceptance task.

The installed `sed(1)` source itself contains the “unable to create a proper
manual page” fallback; the book preserves it. `apropos(1)` provides the
substantive man sample. The inspected Info screenshots show real prose,
examples and definition indentation, but also show long command lines
wrapping with display hyphens. **Code-example fidelity is not signed off.**
This gate asserts rendering/navigation, not ideal typography or every
character's geometry. Other Info manuals, all aliases/cross-references,
large tables, images, alternate fonts/orientations, staging, fbdev/EBC,
physical touch and hardware latency remain outside this matrix.

The earlier real 538-document man book did open on glass August 26:
**30.3 s cold / 1.7 s cached**. That record was never proof of this newer,
larger corpus or representative Info navigation. Both statements can now be
read consistently in `doc/manuals.md`.
