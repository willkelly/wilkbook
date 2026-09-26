# The manuals shelf — reading man and info in KOReader

Issue #17. The reader image already ships `man-db` and `info-reader` out of
`%base-packages`, and with them a corpus of structured documents that is
completely unreachable: the device has no terminal, no user shell, and
exactly one application on screen. This is how that corpus becomes books.

**Status (2026-09-26): the shelf has run on glass, and now has a native
KOReader acceptance matrix.** The August 26 session opened the real
538-document man book: 30.3 s cold, 1.7 s cached (record below). The new
offline gate checks the realized generation-23 profile against its shelf,
then renders the real man book and `sed` Info manual in native KOReader.
It finds **49 missing manual identities** in the installed profile and
records them explicitly; the shelf is not complete. Representative Info
prose/examples/definition-table and TOC/link/Back navigation are now
exercised; whole-corpus typography and panel behaviour are not.

## Shape

```
pinenote/packages/manuals/manuals.py     the converter (discovery, man, info, EPUB)
pinenote/packages/manuals/build-manuals.py   its CLI
pinenote/packages/manuals.scm            (pinenote-manuals PACKAGES) -> a store dir of EPUBs
pinenote/services/manuals.scm            the service + configuration record
pinenote/tools/manuals/                  converter gate + native acceptance/census
```

`pinenote-reader.scm` names its package list once (`%pinenote-reader-packages`)
and hands the same list to the profile and to the shelf. However, Guix also
adds service packages and propagated inputs to the final system profile;
their documentation is absent from that explicit shelf input list. The
September 26 census below measures this difference.

## The corpus, measured

2026-08-24, over the 41 store prefixes the reader flavor's package list
resolves to on one workstation (Guix at `f250e74d`):

| | count | size |
| --- | --- | --- |
| man entries | 552 | — |
| … real pages | 532 | 4.43 MiB of roff, decompressed |
| … `.so` aliases | 20 | — |
| Texinfo manuals | 24 | 10.34 MiB of text, decompressed |
| … nodes | 3,245 | — |
| **output** | 25 EPUBs | **4.90 MiB** (man book: 1.87 MiB) |

Man sections present: 1 (255), 8 (236), 5 (36), 3am (11), 3 (9), 7 (5).

Conversion takes **~1.8 s** of x86_64 CPU for the whole corpus.

## The decisions

### 1. Eager at build time, not lazy on open

Eager, and the measurement is not close. The whole corpus converts in under
two seconds on the build machine and lands in the read-only store, where it
cannot rot and a reflash regenerates it. The tools that do the work —
`mandoc`, `python-minimal`, `zstd` — are **native** build inputs and add
nothing to the device's closure.

Lazy conversion would mean putting a roff formatter and a pipeline onto a
device that has neither, then paying RK3566 seconds per page on a reader
that spends most of its life suspended, for a result that never differs.
The only thing eager costs is 4.90 MiB in an image of hundreds.

### 2. Info is worth it — it is most of the corpus

The issue asks whether man is the 90 % case. Argued from what is installed,
it is not even the majority case: **info is 10.34 MiB of text against man's
4.43 MiB.** And the split is not neutral, because for the GNU tools the man
page is a generated stub that says so out loud — `coreutils`, `gawk`,
`grep`, `sed`, `tar`, `diffutils`, `findutils` and `wget` all ship a page
that ends by telling you the full documentation is a Texinfo manual. Convert
man alone and the device's own reference material for its own core tools is
the part you left behind.

Info is also the format that gains the most from the move. Its node graph is
real hypertext that a terminal reduces to keystrokes; in a document reader
menus become lists of links and cross references become links.

It stays a service-configuration field (`info?`) because dropping 24 books
is a legitimate choice, not because the case for including them is weak.

### 3. `mandoc -Thtml` needs a cleanup pass, not a rewrite

`mandoc -Thtml -O fragment` output is good raw material: run over the whole
corpus it produced **zero** XML-malformed fragments and used only the five
XML-predefined entities, so it is directly usable as XHTML. But it is
formatted for a web page, not a book, and five things had to change
(`clean_man_fragment`, each with a test):

1. **The running head/foot tables go.** `GREP(1) · User Commands · GREP(1)`
   above and below every page is terminal-pager furniture.
2. **Permalink self-links are unwrapped.** mandoc wraps every heading and
   every `.It` term in `<a class="permalink" href="#itself">`; left alone,
   every heading in the book renders as a link.
3. **`<section>` becomes `<div>`.** HTML5 sectioning elements are not in
   crengine's element table, and an unknown element that should be a block
   is a layout hazard.
4. **Headings are demoted** `h1→h2`, `h2→h3`, because the book gives `h1` to
   the page title.
5. **Links are resolved or removed.** `mandoc -O man=#%N.%S` turns every
   `.Xr` into `href="#name.section"`, which is exactly the id space the book
   uses, so `grep(1)` inside `sed(1)` becomes a document link. A reference
   to a page that is *not* in the book is unwrapped to plain text, as is
   every bare relative href mandoc emits for `.Lk` without a scheme.
   `http(s)://`, `ftp://` and `mailto:` survive.

Ids are namespaced with the page id as well, which is belt-and-braces while
each page is its own XHTML file and is what keeps the transform correct if
pages are ever coalesced.

### 4. Info is reflowed, not dumped into `<pre>`

The issue's own framing rules out reproducing the 80-column experience, and
`makeinfo` hard-wraps its output to ~72 columns. So the converter classifies
each blank-line-separated block by indentation, which is the structure
`makeinfo` actually leaves behind:

- every line indented ≥ 5 → `@example`/`@display`, kept **verbatim** in a
  `<pre>`, dedented;
- unindented lines followed by indented ones → an `@table` entry: the
  unindented lines are `<dt>`, the indented remainder is `<dd>`, and the
  definition body **continues over following blocks** while they stay
  indented, so a multi-paragraph entry with a nested example survives;
- `* Menu:` or a run of `* entry` lines → a real `<ul>` of links (index
  nodes use the same syntax and get the same treatment);
- a title line under an ASCII rule → a heading, because a node can carry
  sub-headings that are not themselves nodes;
- anything else → a paragraph, **reflowed**, so it lays out to the panel.

`*note`/`*Note` cross references become links when the target node is in the
same book and degrade to plain text when it is not. `@image` falls back to
the ASCII art `makeinfo` already generated; the PNG is not embedded.

Two byte-level traps are pinned by tests because both were hit during this
work:

- **Guix compresses documentation, and with what has changed.** One store
  sampled here held 493 man pages as `.zst` and 20 as `.gz`. Python's
  standard library has no zstd decoder before 3.14, so the reader sniffs
  magic bytes and shells out. The first probe of this work trusted the
  suffix, fed 493 zstd frames straight to mandoc, and got plausible-looking
  garbage with a zero exit status for every one of them. `read_doc` now
  raises rather than pass a compressed frame on.
- **US (0x1f) is the info node separator.** The sanitizer that strips
  Texinfo's invisible `\0\b[index\0\b]` markers — illegal XML characters,
  and rejected by every conforming parser — initially stripped the whole C0
  range with it and silently turned every manual into zero nodes.

### 5. One book for all man sections, one XHTML per page

**Nothing can link from one EPUB into another**, so a split shelf can
never resolve a cross-section reference. That is the reason for one book:
`Manual pages.epub`, 1.87 MiB, 538 documents, one per page plus a
per-section index chapter listing every page with its `NAME` one-liner.
The table of contents nests page under section.

**Correction (review, 2026-08-24).** An earlier draft justified this by
asserting that "cross-section references are the common case in a man
corpus". That was not measured, and it is wrong in the direction that
matters: `mandoc -O man=#%N.%S` linkifies only **mdoc** `.Xr` macros, and
this corpus is overwhelmingly **man(7)**, where a cross reference is plain
text that mandoc never turns into a link at all. So the single book
currently buys a *small measured* number of working links. Its cost was
unmeasured when this decision was written; the August 26 session below
subsequently measured first-open time and `.cr3` cache size on the RK3566.

The decision stands, with a substantial cold-open cost and a fast cached
open. Splitting later is a small change in `man_book`. One way to improve
the hypertext is to post-process man(7)'s
`<b>name</b>(section)` into a link whenever `name.section` is in
`known_pages`. That is filed rather than done here.

Per *page*, not per section, because section 1 alone is 2.3 MiB of generated
markup; as one spine item that is an enormous document to lay out, and every
cross reference inside it would be a same-file anchor.

Texinfo manuals are one book each, split into a new XHTML at every level-1
node so a large manual (guile is ~3 MiB of text) is a spine of chapters.

**The August 26 hardware measurement is 30.3 s cold / 1.7 s cached** for
the then-current 538-document book. The generation-23 book checked offline
below is larger (686 page documents plus six section indexes); it has no
new RK3566 timing measurement. Do not transfer either book's count or
timing to the other.

### 6. Copied into the library, not symlinked

KOReader writes a `.sdr` sidecar beside every document it opens and the
store is read-only, so `pinenote-manuals` copies its books into
`/data/books/Manuals`. ~4.9 MiB on the data partition, rewritten only when
the store path changes.

It is a shepherd one-shot and not an activation snippet for exactly the
reason `pinenote/services/library.scm` records: activation runs before p7 is
mounted, so an activation-time copy lands on the os2 root filesystem
underneath the mount, invisible forever and green in every test. Three rules
protect the user's directory:

1. `/data` must genuinely be a mount point, or nothing happens.
2. Stamp present but the shelf directory gone means **the user deleted it**;
   it stays deleted. The stamp lives on p7, so the deletion survives an os2
   reflash.
3. On a refresh only files named in the shelf's own previous manifest are
   removed. A book the user put there is theirs.

### 7. Out of scope: `share/doc`

The issue floats extending this to arbitrary documentation in the store.
Deliberately not done. `share/doc` is a much larger, far less uniform corpus
— HTML trees, PDFs, READMEs, changelogs, licence texts — with no single
structure to convert from and no obvious unit to make a book out of. It
would need its own decision about what is worth reading at all.

## Configuration

A Guix service-configuration record (issue #12), changed by rebuild and
redeploy:

```scheme
(service pinenote-manuals-service-type
         (pinenote-manuals-configuration
          (packages (pinenote-fix-package-list %pinenote-reader-packages))
          (info? #t)
          (directory "/data/books/Manuals")))
```

`pinenote-fix-package-list` is not optional decoration. `base.scm` rewrites
`man-db` with `fix-cross-builds` before installing it, because plain `man-db`
pulls a `groff-minimal` whose cross build is broken; handing the shelf the
un-rewritten list would pull that broken build back into the graph through a
side door, with a failure nowhere near its cause. The rewrite is now one
exported procedure with two callers.

## What is verified, and how

Rung 1, `make manuals-check` (`pinenote/tools/manuals/`): decompression
including the zstd refusal, discovery, the five man transforms, the info
block classifier, EPUB structure, link resolution, NCX nesting, and
byte-for-byte determinism. Two runs must produce identical output.

The staging one-shot is **executed**, not grepped: `manuals-stage.sh` is a
real file for that reason, and the suite drives it against a fake library
through every branch — first copy, no-op when current, refresh that replaces
its own books and leaves the user's alone, a shelf the user deleted staying
deleted with the stamp still advancing, an unmounted root, and a source with
no `MANIFEST`. The mount guard takes its root as an explicit argument, which
is what makes that possible: `/proc` is a mount point on every Linux host.

Rung 2, `make reader-system-drv`: the system derivation computes, and the
cross split was checked against the derivation itself —

- `mandoc` in `pinenote-manuals.drv` is the **native** mandoc derivation
  (`zwa04d7j…`), not the aarch64 one (`767xiglq…`);
- `python-minimal` is likewise the native one;
- `coreutils` is the **aarch64** derivation, identical to
  `guix build -d --target=aarch64-linux-gnu coreutils`;
- `man-db` is **not** the plain cross `man-db` (`yipv34gg…`), i.e. the
  `fix-cross-builds` variant is what the shelf reads.

The derivation was also **built**, twice, which is a stronger statement than
"computes":

- natively over `coreutils` + `man-pages`: 3,203 man entries and the
  coreutils manual, 4.1 MiB of EPUB, built inside the Guix container;
- **cross, `--target=aarch64-linux-gnu`**, over `man-pages`: 3,098 entries
  converted from the aarch64 package by the x86_64 mandoc and python. That
  is the `#+`/`#$` split working at build time and not merely in the
  dependency graph.

Applied to the real corpus rather than fixtures, all 25 books came out with
zero malformed XHTML, zero links to a missing document or anchor, and zero
elements outside the reviewed set.

## Native acceptance and installed-profile census, 2026-09-26

Replay instructions and the exact omission list are in
`pinenote/tools/manuals/README.md`; bounded evidence is in that tool's
`evidence/2026-09-26/`. No new image, QEMU boot or hardware session was
needed: these system outputs were already realized locally.

| Input | Identity |
| --- | --- |
| System (generation 23, book-state-device-reader) | `/gnu/store/x3qqz8r52pdh7jzghzfj8l44gfrqkncb-system` |
| Final system profile | `/gnu/store/9ns0jahhhy2q82q1r3r5fcf4mn6mc571-profile` |
| Shelf referenced by that system's manuals service | `/gnu/store/qgz9gwiiamspffc61wc1gxdh8kl9ciys-pinenote-manuals` |
| Native KOReader v2026.03 | `/gnu/store/11jrzxbvx4cn4m4ryhllr5a1w93zr1a0-koreader-bin-2026.03` |

The independent Guile census checks names against the man section indexes
(aliases included), manifest counts against those indexes and Info NCX
entries, and included Info counts against nodes in the profile's compressed
source files. It hashes all 26 books and the manifest. It does not reuse
the Python converter's discovery logic. Exact exceptions are reviewed in
`profile-omissions.txt`; a newly missing item or a stale exception fails.

| Corpus category | Profile | Shelf / classification |
| --- | ---: | --- |
| Untranslated man identities | 732 | 711 included: 686 page chapters + 25 alias index entries |
| Missing man identities | 21 | 16 OpenSSH, four Shepherd, one libgc (`gc(3)`) |
| Info manuals, split files grouped | 53 | 25 included, 28 missing |
| Missing Info manuals | 28 | 11 untranslated service/propagated manuals + 17 translated Guix/cookbook manuals |
| Localized man files | 697 | Outside the converter's untranslated-man policy |
| Info auxiliary files | 29 | Directory indexes and images; not independent manuals |

The service/propagated omissions are **coverage gaps**, not an assertion
that these documents are unwanted. Info discovery does not itself filter
translations. Images still use the converter's ASCII fallback rather than
embedding the source pictures. `share/doc` remains out of scope.

The actual ReaderUI, PluginLoader, TOC Menu, ReaderLink, crengine and SDL
framebuffer run at 1404×1872 / 227 dpi, with fresh private settings, caches
and copied books. The Lua controller invokes the real TOC selection
callback; links are found in the rendered page and coordinate-hit-tested
before following them. Assertions check destination and restored page,
visible page text and nonblank painted pixels. Screenshots were inspected.

| Acceptance row | Actual book / operation | Result |
| --- | --- | --- |
| Man index | Section 1 list, names and one-liners | Pass |
| Man page | `apropos(1)` NAME, SYNOPSIS, description; next/previous page | Pass |
| Man navigation | TOC selection; index link to `apropos(1)`; Back to index | Pass |
| Info prose | `sed`, “1 Introduction”, reflowed paragraph | Pass |
| Info examples | “2.1 Overview”, monospace command examples | Rendered; wrapping caveat below |
| Info definition table | “2.2 Command-Line Options”, `--version` term and indented definition | Pass |
| Info navigation | Nested TOC entries; “2 Running sed” link to options; Back | Pass |
| Negative controls | Missing book, wrong manifest count, stale/unreviewed omissions, wrong book in real reader | Rejected as expected |

Two limits became concrete during this run:

- The installed `sed(1)` source is itself a fallback saying “unable to
  create a proper manual page”; the EPUB faithfully contains that stub.
  The substantive man check uses `apropos(1)` instead. This is an input
  limitation, not evidence of converter loss.
- Long command examples wrap and can acquire display hyphens (for example
  `output.txt` across a line/page boundary). The short substitution example
  is legible and the option table retains its term/definition layout, but
  this is **not full code-example fidelity sign-off**. The screenshots
  retain the problem; neither converter CSS nor reader defaults were
  changed during acceptance work.

## What remains unverified

- **Most books and pages have not been visually inspected.** The native
  matrix covers one substantive man page/index and selected `sed` Info
  content, not every manual, alias, cross-section reference, large table,
  image fallback, font size or orientation. Info/navigation on the physical
  reader remains outside the recorded August 26 hardware measurement.
- **The element whitelist is a contract, not a rendering test.** It says the
  converter has not started emitting markup outside a reviewed list; it does
  not say crengine lays that list out well.
- **The new native run does not exercise Shepherd staging or fbdev/EBC.**
  Staging did run on the device August 26; its exceptional branches remain
  host-tested. Native SDL proves the reader/document boundary without
  establishing refresh quality, touch feel, device latency or recovery.
- The current census is for **one identified system profile**, not every
  flavor/channel state. The 2026-08-24 census above is historical and has
  different versions/counts. No fixture is being counted as installed
  coverage in the September run.

## Next steps, if someone picks this up

1. Decide how the shelf should include service-added and propagated
   documentation; rerun the census without simply waiving new omissions.
2. Address long code-example wrapping/hyphenation, then extend the real-reader
   matrix to another Info manual and image/large-table cases.
3. Measure the larger current man book and clean-stop cache preservation on
   glass during an already-planned reader session. The old cold/cached
   timings are established, not an outstanding first measurement.
4. Consider a KOReader plugin only if navigation turns out to want something
   the file browser plus the TOC cannot do. It was not needed for this: the
   shelf *is* the discovery surface, and the per-section index chapters are
   the browsable list the issue asked for.

## Measured on glass, 2026-08-26 (study image, identical userspace)

The staging one-shot ran (full Texinfo shelf + `Manual pages.epub`,
2.5 MB, 538 documents). Open times for the man-pages book, measured
launch-to-first-paint:

| condition | time |
|---|---|
| uncached (first ever, or after any unclean stop) | **30.3 s** |
| crengine cache present | **1.7 s** |

The catch is the cache lifecycle: crengine writes its 8 MB cache file
ONLY on a clean close. SIGTERM — which is what shepherd's
`make-kill-destructor` stop sends, and what any crash amounts to —
leaves a **zero-byte truncated cache**, so the next open silently pays
the full 30 s again. SIGINT triggers the clean close (proven: the 8 MB
file appears and the 1.7 s open follows). Two fix directions: the
INT-first stop LANDED (reader-session's stop now sends SIGINT and
polls cooperatively before the kill fallback, pinned by
`make reader-stop-check`; the stop itself is glass-proven — 0.484 s on
2026-08-26, `doc/status.md` part 5 — but whether the clean close writes
the cache on the device still wants a check with a book open);
staging-time cache pre-warm remains open.
