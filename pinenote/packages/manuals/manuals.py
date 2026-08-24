"""wilkbook: turn an installed man/info corpus into KOReader-readable EPUBs.

The reader image already ships man-db and info-reader out of %base-packages,
and with them ~500 man pages and ~20 Texinfo manuals -- a corpus that is
completely unreachable on a device with no terminal and exactly one
application on screen (issue #17).  This module converts that corpus, AT
BUILD TIME, into EPUB 2 books that KOReader's own engine opens like any
other document.

Why build time and not on-device conversion (measured 2026-08-24 over the
41 store prefixes of the reader flavor's package list):

  * 532 man pages + 20 .so aliases (4.43 MiB of roff) and 24 Texinfo
    manuals / 3,245 nodes (10.34 MiB of text) convert in ~1.8 s of x86_64
    CPU into 4.90 MiB of EPUB.  Doing that on the device would cost the
    RK3566 far more, on a reader that spends most of its life in suspend,
    for a result that is identical every time.
  * The conversion tools (mandoc, python) are BUILD-machine inputs, so
    nothing is added to the device's closure.  A lazy on-open path would
    have to put a roff formatter, a pipeline and a shell on the device.
  * The output lands in the read-only store, so it cannot rot, and a
    reflash regenerates it.

What this module deliberately does NOT do: render anything.  Whether
crengine (KOReader's engine) lays these books out well is NOT established
here -- see doc/manuals.md.  What IS established offline is that the
generated XHTML is well-formed, uses only a reviewed element vocabulary,
and that every internal link resolves to an anchor that exists.
"""

import bz2
import gzip
import hashlib
import html
import lzma
import os
import re
import shutil
import subprocess
import zipfile
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Reading the corpus off disk
# ---------------------------------------------------------------------------

# Guix compresses documentation, and WHICH compressor it uses has changed:
# a store sampled 2026-08-24 held 493 man pages as .zst and 20 as .gz, and
# every info file as .gz.  Sniff the magic instead of trusting the suffix --
# a suffix-driven reader silently fed 493 zstd frames to mandoc during the
# first probe of this work and mandoc happily produced garbage for all of
# them, exiting 0.
_MAGIC = (
    (b"\x1f\x8b", "gzip"),
    (b"BZh", "bzip2"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"LZIP", "lzip"),
)

COMPRESSED_SUFFIXES = (".gz", ".zst", ".bz2", ".xz", ".lz", ".Z")


class CorpusError(Exception):
    """A corpus input this converter refuses to guess about."""


def read_doc(path, zstd="zstd", lzip="lzip"):
    """Return the decompressed bytes of a documentation file.

    Raises CorpusError for a compression format we cannot decode, rather
    than returning the compressed bytes: passing a compressed frame on to
    mandoc produces plausible-looking garbage and a zero exit status.
    """
    with open(path, "rb") as fh:
        raw = fh.read()
    kind = None
    for magic, name in _MAGIC:
        if raw.startswith(magic):
            kind = name
            break
    if kind is None:
        return raw
    if kind == "gzip":
        return gzip.decompress(raw)
    if kind == "bzip2":
        return bz2.decompress(raw)
    if kind == "xz":
        return lzma.decompress(raw)
    if kind in ("zstd", "lzip"):
        tool = zstd if kind == "zstd" else lzip
        exe = shutil.which(tool) or tool
        proc = subprocess.run([exe, "-dcq"], input=raw, capture_output=True)
        if proc.returncode != 0:
            raise CorpusError(
                "%s: %s could not decompress it: %s"
                % (path, kind, proc.stderr.decode("utf-8", "replace").strip()))
        return proc.stdout
    raise CorpusError("%s: unhandled compression %r" % (path, kind))


def strip_doc_suffix(name):
    for suf in COMPRESSED_SUFFIXES:
        if name.endswith(suf):
            return name[: -len(suf)]
    return name


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# share/man/manN -- and NOT share/man/<locale>/manN.  The translated pages
# are a large fraction of the corpus (shadow alone ships 432 files, 405 of
# them translations) and the reader image is built with a single locale.
_MAN_DIR = re.compile(r"^man(\d[A-Za-z]*)$")
_SO_STUB = re.compile(rb"^\s*\.so\s+(\S+)\s*$")


@dataclass(order=True)
class ManPage:
    section: str
    name: str
    path: str = field(compare=False)
    alias_of: str = field(default=None, compare=False)  # "name.section"

    @property
    def page_id(self):
        return "%s.%s" % (self.name, self.section)


@dataclass(order=True)
class InfoManual:
    name: str
    paths: list = field(default_factory=list, compare=False)


@dataclass
class Corpus:
    man: list = field(default_factory=list)
    info: list = field(default_factory=list)
    skipped: list = field(default_factory=list)


def _info_sort_key(path):
    # foo.info, foo.info-1, ... foo.info-11: numeric, not lexicographic, and
    # the unsuffixed file first because it carries the Top node.
    base = strip_doc_suffix(os.path.basename(path))
    m = re.search(r"\.info-(\d+)$", base)
    return (1, int(m.group(1))) if m else (0, 0)


def discover(roots, zstd="zstd", lzip="lzip"):
    """Enumerate the man pages and Texinfo manuals under a list of prefixes.

    `roots' are package prefixes (store paths in the real build).  Earlier
    roots win a name collision, which mirrors how a Guix profile resolves
    one: the union is built in the order the packages were given.
    """
    corpus = Corpus()
    seen_man = {}
    info_files = {}
    for root in roots:
        man_root = os.path.join(root, "share", "man")
        if os.path.isdir(man_root):
            for entry in sorted(os.listdir(man_root)):
                m = _MAN_DIR.match(entry)
                if not m:
                    continue
                section = m.group(1)
                sec_dir = os.path.join(man_root, entry)
                if not os.path.isdir(sec_dir):
                    continue
                for fn in sorted(os.listdir(sec_dir)):
                    path = os.path.join(sec_dir, fn)
                    if not os.path.isfile(path):
                        continue
                    base = strip_doc_suffix(fn)
                    name, _, ext = base.rpartition(".")
                    if not name:
                        corpus.skipped.append((path, "no section suffix"))
                        continue
                    page = ManPage(section=ext, name=name, path=path)
                    if page.page_id in seen_man:
                        corpus.skipped.append((path, "shadowed by an earlier package"))
                        continue
                    raw = read_doc(path, zstd=zstd, lzip=lzip)
                    stub = _SO_STUB.match(raw.strip())
                    if stub:
                        # ".so man1/grep.1" -- an alias page.  Recorded as a
                        # table-of-contents entry pointing at the real page
                        # rather than converted, so "man pkill" is findable.
                        target = stub.group(1).decode("utf-8", "replace")
                        tbase = strip_doc_suffix(os.path.basename(target))
                        tname, _, tsec = tbase.rpartition(".")
                        page.alias_of = "%s.%s" % (tname, tsec)
                    seen_man[page.page_id] = page
                    corpus.man.append(page)

        info_root = os.path.join(root, "share", "info")
        if os.path.isdir(info_root):
            for fn in sorted(os.listdir(info_root)):
                path = os.path.join(info_root, fn)
                if not os.path.isfile(path):
                    continue
                base = strip_doc_suffix(fn)
                m = re.match(r"^(.+?)\.info(-\d+)?$", base)
                if not m:
                    continue          # figures (.png/.jpg), dir, etc.
                manual = m.group(1)
                if manual == "dir":
                    continue
                info_files.setdefault(manual, [])
                if not any(os.path.basename(p) == fn for p in info_files[manual]):
                    info_files[manual].append(path)

    for manual in sorted(info_files):
        paths = sorted(info_files[manual], key=_info_sort_key)
        corpus.info.append(InfoManual(name=manual, paths=paths))
    corpus.man.sort()
    return corpus


# ---------------------------------------------------------------------------
# man -> XHTML
# ---------------------------------------------------------------------------

# mandoc -O man=#%N.%S turns every .Xr cross reference into an anchor of
# exactly the form we use for page ids, so grep(1) inside sed(1) becomes
# href="#grep.1" and resolves inside the same book with no post-processing.
MANDOC_OPTIONS = "fragment,man=#%N.%S"

_HEAD_FOOT = re.compile(
    r'<table class="(?:head|foot)">.*?</table>\s*', re.S)
_PERMALINK = re.compile(
    r'<a class="permalink" href="#[^"]*">(.*?)</a>', re.S)
_SECTION_OPEN = re.compile(r"<section\b([^>]*)>")
_SECTION_CLOSE = re.compile(r"</section>")
_HEADING = re.compile(r"<(/?)h([1-6])\b")
_ID_ATTR = re.compile(r'\bid="([^"]*)"')
_HREF_FRAG = re.compile(r'\bhref="#([^"]*)"')
_XR_LINK = re.compile(r'<a class="Xr" href="#([^"]*)">(.*?)</a>', re.S)
_ANY_LINK = re.compile(r'<a\b([^>]*)>(.*?)</a>', re.S)
_HREF_ATTR = re.compile(r'\bhref="([^"]*)"')
_NAME_LINE = re.compile(
    r'<h2[^>]*>NAME</h2>\s*<p[^>]*>(.*?)</p>', re.S | re.I)
_TAGS = re.compile(r"<[^>]*>")

# Links we are willing to leave in the book.  Everything else -- mandoc's
# .Lk with no scheme, and the handful of bare hrefs man(7) macros emit --
# is unwrapped to its own text: a link that resolves to nothing is a worse
# reading experience than no link, and on this device there is no browser
# behind it anyway.
LINK_SCHEMES = ("http://", "https://", "ftp://", "mailto:")


def render_man(page, mandoc="mandoc", zstd="zstd", lzip="lzip"):
    """Run mandoc over one page and return its raw XHTML fragment."""
    raw = read_doc(page.path, zstd=zstd, lzip=lzip)
    proc = subprocess.run(
        [mandoc, "-Thtml", "-O", MANDOC_OPTIONS, "-Ios=PineNote"],
        input=raw, capture_output=True)
    if proc.returncode != 0:
        raise CorpusError("%s: mandoc exited %d: %s"
                          % (page.path, proc.returncode,
                             proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout.decode("utf-8")


def clean_man_fragment(fragment, page_id, known_pages):
    """Turn one mandoc fragment into reader-shaped XHTML.

    `known_pages' maps a page id ("grep.1") to the href that reaches it in
    this book ("grep.1.xhtml").  A cross reference to a page that is not in
    the book is unwrapped to plain text: a dangling link is worse than no
    link, because the reader will happily follow it into nothing.

    Five transforms, each of which exists for a reason a reader can see:

      1. drop the running head/foot tables -- "GREP(1) ... User Commands ...
         GREP(1)" twice per page is terminal-pager furniture;
      2. unwrap the self-referential <a class="permalink"> that mandoc puts
         around every heading and every .It term, so headings stop rendering
         as links;
      3. <section> -> <div>: HTML5 sectioning elements are not in crengine's
         element table, and an unknown element that should be a block is a
         layout hazard;
      4. demote h1/h2 (mandoc's .Sh/.Ss) to h2/h3, because the book gives
         h1 to the page title;
      5. namespace every id and intra-page anchor with the page id.  This
         is belt-and-braces while each page is its own XHTML file, and it
         is what keeps the transform correct if pages are ever coalesced.
    """
    out = _HEAD_FOOT.sub("", fragment)
    # Repeat until stable: mandoc nests a permalink inside a heading only,
    # but being explicit costs nothing and a nested match would silently
    # leave one behind.
    while True:
        new = _PERMALINK.sub(lambda m: m.group(1), out)
        if new == out:
            break
        out = new

    def _drop_dangling(m):
        target, text = m.group(1), m.group(2)
        return m.group(0) if target in known_pages else text

    out = _XR_LINK.sub(_drop_dangling, out)
    out = _SECTION_OPEN.sub(r"<div\1>", out)
    out = _SECTION_CLOSE.sub("</div>", out)
    out = _HEADING.sub(
        lambda m: "<%sh%d" % (m.group(1), min(6, int(m.group(2)) + 1)), out)

    prefix = page_id + "--"
    out = _ID_ATTR.sub(lambda m: 'id="%s%s"' % (prefix, m.group(1)), out)

    def _fix_href(m):
        target = m.group(1)
        if target in known_pages:
            return 'href="%s"' % known_pages[target]
        return 'href="#%s%s"' % (prefix, target)

    out = _HREF_FRAG.sub(_fix_href, out)

    def _unwrap_unresolvable(m):
        attrs, text = m.group(1), m.group(2)
        href = _HREF_ATTR.search(attrs)
        if href is None:
            return text
        target = href.group(1)
        if target.startswith("#") or target.endswith(".xhtml") \
           or target.startswith(LINK_SCHEMES):
            return m.group(0)
        return text

    out = _ANY_LINK.sub(_unwrap_unresolvable, out)
    return out.strip()


def man_summary(cleaned):
    """The one-line NAME description, for the section index.  '' if absent."""
    m = _NAME_LINE.search(cleaned)
    if not m:
        return ""
    text = html.unescape(_TAGS.sub("", m.group(1)))
    text = " ".join(text.split())
    # "grep - print lines that match patterns" -> the part after the dash.
    for dash in (" — ", " - ", " – "):
        if dash in text:
            return text.split(dash, 1)[1]
    return text


# ---------------------------------------------------------------------------
# info -> XHTML
# ---------------------------------------------------------------------------

_NODE_SEP = "\x1f"
_NODE_HEADER = re.compile(
    r"^File:\s*([^,]*),\s*Node:\s*([^,]*?)\s*(?:,\s*(.*))?$")
_UNDERLINE = {"*": 1, "=": 2, "-": 3, ".": 4}
_MENU_ENTRY = re.compile(r"^\* ([^:]+)::\s*(.*)$")
_MENU_ENTRY_LONG = re.compile(r"^\* ([^:]+):\s+([^.]+)\.\s*(.*)$")
# "*Note" at the start of a sentence, "*note" mid-sentence -- both forms
# appear in every GNU manual, so the keyword match is case-insensitive.
_XREF = re.compile(r"\*note\s+([^:]+?)::", re.I)
_XREF_LONG = re.compile(r"\*note\s+([^:]+?):\s+([^.,]+)[.,]", re.I)
_IMAGE = re.compile(r'\[image src="[^"]*"(?:\s+alt="[^"]*")?'
                    r'(?:\s+text="(.*?)")?\s*\]', re.S)


@dataclass
class InfoNode:
    name: str
    title: str
    level: int
    body: list


# Texinfo hides machine-readable markers from the standalone info reader by
# bracketing them in NUL/BS: an index node opens with "\0\b[index\0\b]".
# Those bytes are not legal XML characters, and a book carrying them is
# rejected by every conforming parser -- caught by the offline XML gate,
# never by eye.
_INFO_MARKER = re.compile(r"\x00\x08\[.*?\x00\x08\]", re.S)
# US (0x1f) is EXCLUDED on purpose: it is the node separator, and a
# sanitizer that ate it turned every manual into zero nodes silently.
# Sanitizing therefore happens per node, after the split.
_C0 = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1e\x7f]")


def sanitize_info(text):
    """Drop Texinfo's invisible markers and any other non-XML control byte."""
    return _C0.sub("", _INFO_MARKER.sub("", text))


def parse_info(text):
    """Split a Texinfo `.info' file into its nodes.

    The format is simple and stable: nodes are separated by US (0x1f) and
    each opens with `File: x.info,  Node: N,  Next: ..., Prev: ..., Up: ...'.
    The Indirect/Tag Table sections of a split manual carry no such header
    and are dropped by that same test.
    """
    nodes = []
    for raw_chunk in text.split(_NODE_SEP):
        chunk = sanitize_info(raw_chunk)
        lines = chunk.split("\n")
        i = 0
        while i < len(lines) and not lines[i].strip():
            i += 1
        if i >= len(lines):
            continue
        m = _NODE_HEADER.match(lines[i].strip())
        if not m:
            continue
        name = m.group(2).strip()
        body = lines[i + 1:]
        while body and not body[0].strip():
            body.pop(0)
        title, level = name, 2
        if len(body) >= 2 and body[0].strip() and body[1].strip():
            underline = set(body[1].strip())
            if len(underline) == 1:
                ch = underline.pop()
                if ch in _UNDERLINE and len(body[1].strip()) >= 3:
                    title = body[0].strip()
                    level = _UNDERLINE[ch]
                    body = body[2:]
        while body and not body[0].strip():
            body.pop(0)
        while body and not body[-1].strip():
            body.pop()
        nodes.append(InfoNode(name=name, title=title, level=level, body=body))
    return nodes


def slug(text, used=None):
    s = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower() or "node"
    s = "n-" + s
    if used is None:
        return s
    base, n = s, 2
    while s in used:
        s = "%s-%d" % (base, n)
        n += 1
    used.add(s)
    return s


def _blocks(lines):
    """Split node body lines into blank-line-separated blocks."""
    out, cur = [], []
    for line in lines:
        if line.strip():
            cur.append(line.rstrip())
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _esc(text):
    return html.escape(text, quote=False)


def _link(target, label, anchors):
    """Render one node reference, as a link when the node is in this manual."""
    anchor = anchors.get(target)
    if anchor is None:
        return _esc(label)
    return '<a href="%s">%s</a>' % (_esc(anchor), _esc(label))


def _inline(text, anchors):
    """Escape a run of body text and turn its *note references into links.

    Substitution happens on the ALREADY-REFLOWED paragraph, so a reference
    that makeinfo wrapped across two lines is a single match here.
    """
    parts, pos = [], 0
    pattern = re.compile(_XREF_LONG.pattern + "|" + _XREF.pattern, re.I)
    for m in pattern.finditer(text):
        parts.append(_esc(text[pos:m.start()]))
        if m.group(1) is not None:
            label, target = m.group(1), m.group(2)
        else:
            label = target = m.group(3)
        parts.append(_link(target.strip(), label.strip(), anchors))
        pos = m.end()
    parts.append(_esc(text[pos:]))
    return "".join(parts)


def _is_heading(title, rule):
    """A title line followed by its ASCII underline, both at column 0."""
    if _indent(title) or _indent(rule) or not title.strip():
        return False
    bar = rule.strip()
    if len(bar) < 3 or len(set(bar)) != 1 or bar[0] not in _UNDERLINE:
        return False
    return abs(len(bar) - len(title.rstrip())) <= 2


def _render_blocks(lines, anchors, depth=0):
    """Render a node body.

    The classification is the whole point of the exercise: makeinfo hard-wraps
    info output to ~72 columns, and dumping that into a <pre> would reproduce
    the terminal the issue is asking us to escape.  So:

      * a title line under an ASCII rule is a heading -- a node can carry
        sub-headings that are not themselves nodes, and left alone they read
        as a paragraph with "===========" in it;
      * a block whose every line is indented >= 5 is an @example/@display --
        keep it verbatim, dedented, in a <pre>;
      * a block that opens with unindented lines and continues with lines
        indented >= 5 is an @table item -- the unindented lines are terms
        (<dt>) and the indented remainder is the definition (<dd>).  The
        definition CONTINUES over following blocks while they stay indented,
        because that is how makeinfo lays out an entry with more than one
        paragraph or a nested example; the whole thing is then rendered
        recursively, so the nesting works to any depth we allow;
      * a `* Menu:' block, or any block of `* entry' lines, is a menu --
        a real list of links;
      * anything else is a paragraph, REFLOWED (lines joined with a single
        space) so it lays out to the panel instead of to 72 columns.
    """
    blocks = _blocks(lines)
    out = []
    i = 0
    while i < len(blocks):
        block = blocks[i]
        i += 1

        if len(block) >= 2 and _is_heading(block[0], block[1]):
            level = min(6, _UNDERLINE[block[1].strip()[0]] + 1)
            out.append("<h%d>%s</h%d>"
                       % (level, _inline(block[0].strip(), anchors), level))
            if len(block) > 2:
                blocks.insert(i, block[2:])
            continue

        if block[0].strip() == "* Menu:":
            out.append(_render_menu(block[1:], anchors))
            continue
        if block[0].startswith("* ") \
           and all(line.startswith("* ") or _indent(line) >= 2
                   for line in block):
            out.append(_render_menu(block, anchors))
            continue

        indents = [_indent(line) for line in block]
        if min(indents) >= 5:
            body = "\n".join(line[5:] if len(line) >= 5 else line
                             for line in block)
            out.append("<pre>%s</pre>" % _esc(body))
            continue

        if depth < 4 and indents[0] == 0 and max(indents) >= 5:
            terms, rest = [], []
            for line in block:
                if not rest and _indent(line) == 0:
                    terms.append(line.strip())
                else:
                    rest.append(line)
            if terms and rest:
                while i < len(blocks) \
                        and min(_indent(l) for l in blocks[i]) >= 5:
                    rest.append("")
                    rest.extend(blocks[i])
                    i += 1
                dedented = [line[5:] if len(line) >= 5 else line.lstrip()
                            for line in rest]
                out.append("<dl>%s<dd>%s</dd></dl>" % (
                    "".join("<dt>%s</dt>" % _inline(t, anchors)
                            for t in terms),
                    _render_blocks(dedented, anchors, depth + 1)))
                continue

        text = " ".join(line.strip() for line in block)
        out.append("<p>%s</p>" % _inline(text, anchors))
    return "".join(out)


def _render_menu(lines, anchors):
    """Render a menu (or an index node, which uses the same syntax)."""
    items = []
    for line in lines:
        if line.startswith("* "):
            m = _MENU_ENTRY.match(line)
            if m:
                target = label = m.group(1).strip()
                desc = m.group(2).strip()
            else:
                m = _MENU_ENTRY_LONG.match(line)
                if not m:
                    continue
                label = m.group(1).strip()
                target = m.group(2).strip()
                desc = m.group(3).strip()
            items.append([target, label, desc])
        elif items and line.strip():
            items[-1][2] = (items[-1][2] + " " + line.strip()).strip()
    if not items:
        return ""
    out = ["<ul>"]
    for target, label, desc in items:
        entry = _link(target, label, anchors)
        if desc:
            entry += " &#8212; " + _inline(desc, anchors)
        out.append("<li>%s</li>" % entry)
    out.append("</ul>")
    return "".join(out)


def info_chapters(manual_name, text):
    """Convert one Texinfo manual into a list of Chapter objects.

    A new XHTML file starts at every level-1 node, so a large manual (guile
    is ~3 MiB of text) is a spine of chapter-sized documents rather than one
    enormous one, and the EPUB table of contents mirrors the node tree.
    """
    nodes = parse_info(text)
    if not nodes:
        return []
    # Two passes: assign every node an anchor first, so that a forward
    # reference in the first node already resolves.
    used, anchors, placement = set(), {}, []
    chapter_index = -1
    for node in nodes:
        if chapter_index < 0 or node.level <= 1:
            chapter_index += 1
        a = slug(node.name, used)
        placement.append((chapter_index, a, node))
        anchors[node.name] = "%s-%d.xhtml#%s" % (manual_name, chapter_index, a)

    # Within-chapter hrefs still carry the file name; that is legal and is
    # what an EPUB reader expects across spine items.
    chapters = []
    for idx in range(chapter_index + 1):
        parts, toc = [], []
        for cidx, anchor, node in placement:
            if cidx != idx:
                continue
            level = max(1, min(6, node.level))
            parts.append('<h%d id="%s">%s</h%d>'
                         % (level + 1, anchor, _esc(node.title), level + 1))
            # @image in info output is `[image src="x.png" alt="..."
            # text="<ascii art>"]'.  The PNG is not embedded (it would drag
            # an image pipeline into a build that has none); the ASCII
            # fallback makeinfo already produced is kept, indented so the
            # block classifier below treats it as verbatim.
            body = _IMAGE.sub(
                lambda m: "\n" + (m.group(1) or "").rstrip() + "\n",
                "\n".join(node.body))
            parts.append(_render_blocks(body.split("\n"), anchors))
            toc.append((node.level, node.title, anchor))
        chapters.append(Chapter(
            name="%s-%d" % (manual_name, idx),
            title=toc[0][1] if toc else manual_name,
            body="".join(parts),
            toc=toc))
    return chapters


# ---------------------------------------------------------------------------
# EPUB
# ---------------------------------------------------------------------------

# EPUB 2.0.1 with a toc.ncx, not EPUB 3 with a nav document: crengine (the
# engine KOReader uses for reflowable formats) has read EPUB 2 for its whole
# life, and the NCX is what gives KOReader's table-of-contents menu its
# nesting.
_EPOCH = (1980, 1, 1, 0, 0, 0)

STYLESHEET = """\
/* Deliberately small.  crengine implements a subset of CSS, and every rule
   here is one whose absence would leave the document readable anyway. */
body { font-family: serif; text-align: justify; margin: 0; }
h1, h2, h3, h4, h5, h6 { font-family: sans-serif; text-align: left;
                         page-break-after: avoid; }
h1 { font-size: 1.4em; margin: 1em 0 0.4em 0; }
h2 { font-size: 1.2em; margin: 1em 0 0.3em 0; }
h3 { font-size: 1.05em; margin: 0.8em 0 0.3em 0; }
p { margin: 0.4em 0; text-indent: 0; }
pre { font-family: monospace; font-size: 0.85em; white-space: pre-wrap;
      margin: 0.5em 0 0.5em 1em; text-align: left; }
dl { margin: 0.4em 0; }
dt { font-weight: bold; margin-top: 0.5em; }
dd { margin: 0 0 0.3em 1.5em; }
ul { margin: 0.4em 0 0.4em 1em; }
li { margin: 0.15em 0; }
table { margin: 0.4em 0; }
td { padding-right: 0.6em; vertical-align: top; }
a { text-decoration: none; }
.manual-text { margin: 0; }
"""

XHTML_TEMPLATE = """\
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" \
"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<title>%(title)s</title>
<link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
%(body)s
</body>
</html>
"""


@dataclass
class Chapter:
    name: str
    title: str
    body: str
    toc: list = field(default_factory=list)   # [(level, title, anchor)]

    @property
    def filename(self):
        return "%s.xhtml" % self.name

    def document(self):
        return XHTML_TEMPLATE % {"title": _esc(self.title), "body": self.body}


def _ncx(chapters, title, uid):
    """The EPUB 2 navigation map -- KOReader's table-of-contents menu.

    The open-navPoint stack spans the WHOLE spine, not one chapter: in the
    man book a section index is a level-1 entry and each of its pages is a
    level-2 entry living in its own XHTML file, so a per-chapter stack would
    close the section before its first page and flatten the tree.
    """
    points, order = [], [0]
    stack = []              # levels currently open, across all chapters

    def emit(chapter, entry):
        order[0] += 1
        _level, text, anchor = entry
        href = chapter.filename + ("#" + anchor if anchor else "")
        return ('<navPoint id="np-%d" playOrder="%d">'
                '<navLabel><text>%s</text></navLabel>'
                '<content src="%s"/>' % (order[0], order[0], _esc(text), href))

    for chapter in chapters:
        for entry in (chapter.toc or [(1, chapter.title, None)]):
            level = max(1, entry[0])
            while stack and stack[-1] >= level:
                points.append("</navPoint>")
                stack.pop()
            points.append(emit(chapter, entry))
            stack.append(level)
    while stack:
        points.append("</navPoint>")
        stack.pop()
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<head><meta name="dtb:uid" content="%s"/>'
            '<meta name="dtb:depth" content="3"/>'
            '<meta name="dtb:totalPageCount" content="0"/>'
            '<meta name="dtb:maxPageNumber" content="0"/></head>'
            '<docTitle><text>%s</text></docTitle>'
            '<navMap>%s</navMap></ncx>'
            % (uid, _esc(title), "".join(points)))


def _opf(chapters, title, uid, creator):
    manifest = ['<item id="ncx" href="toc.ncx" '
                'media-type="application/x-dtbncx+xml"/>',
                '<item id="css" href="style.css" media-type="text/css"/>']
    spine = []
    for i, chapter in enumerate(chapters):
        manifest.append('<item id="c%d" href="%s" '
                        'media-type="application/xhtml+xml"/>'
                        % (i, chapter.filename))
        spine.append('<itemref idref="c%d"/>' % i)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
            'unique-identifier="bookid">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:opf="http://www.idpf.org/2007/opf">'
            '<dc:title>%s</dc:title><dc:language>en</dc:language>'
            '<dc:creator opf:role="aut">%s</dc:creator>'
            '<dc:identifier id="bookid">%s</dc:identifier></metadata>'
            '<manifest>%s</manifest><spine toc="ncx">%s</spine></package>'
            % (_esc(title), _esc(creator), uid,
               "".join(manifest), "".join(spine)))


CONTAINER_XML = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>')


def write_epub(path, title, chapters, creator="wilkbook"):
    """Write one EPUB 2 book.  Byte-for-byte reproducible.

    Guix rebuilds this derivation whenever the package list changes, and a
    nondeterministic archive would make every such rebuild look like a real
    change.  So: fixed member order, fixed timestamps, and an identifier
    derived from the content rather than from a clock or a random UUID.
    """
    digest = hashlib.sha256()
    digest.update(title.encode("utf-8"))
    for chapter in chapters:
        digest.update(chapter.filename.encode("utf-8"))
        digest.update(chapter.document().encode("utf-8"))
    uid = "urn:uuid:" + "-".join([digest.hexdigest()[:8],
                                  digest.hexdigest()[8:12],
                                  digest.hexdigest()[12:16],
                                  digest.hexdigest()[16:20],
                                  digest.hexdigest()[20:32]])

    def member(zf, name, data, compress=zipfile.ZIP_DEFLATED):
        info = zipfile.ZipInfo(name, date_time=_EPOCH)
        info.compress_type = compress
        info.external_attr = 0o644 << 16
        zf.writestr(info, data)

    with zipfile.ZipFile(path, "w") as zf:
        # The mimetype member must come first and be STORED; that is what
        # makes an EPUB sniffable without unzipping it.
        member(zf, "mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        member(zf, "META-INF/container.xml", CONTAINER_XML)
        member(zf, "OEBPS/content.opf", _opf(chapters, title, uid, creator))
        member(zf, "OEBPS/toc.ncx", _ncx(chapters, title, uid))
        member(zf, "OEBPS/style.css", STYLESHEET)
        for chapter in chapters:
            member(zf, "OEBPS/" + chapter.filename, chapter.document())
    return uid


# ---------------------------------------------------------------------------
# Putting it together
# ---------------------------------------------------------------------------

SECTION_TITLES = {
    "1": "User commands",
    "2": "System calls",
    "3": "Library functions",
    "3am": "Gawk extension library",
    "4": "Devices and special files",
    "5": "File formats and conventions",
    "6": "Games",
    "7": "Miscellaneous",
    "8": "System administration",
    "9": "Kernel routines",
}


def section_title(section):
    return "Section %s — %s" % (
        section, SECTION_TITLES.get(section, "other pages"))


def slugify_filename(text, used=None):
    """A file name safe inside a zip and inside an href.

    Man page names are not: `[(1)' is a real coreutils page, and `.' as a
    leading character would make a hidden file.
    """
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", text)
    s = s.lstrip(".-") or "page"
    if used is None:
        return s
    base, n = s, 2
    while s in used:
        s = "%s-%d" % (base, n)
        n += 1
    used.add(s)
    return s


MAN_BOOK_TITLE = "Manual pages"


def man_book(pages, mandoc="mandoc", zstd="zstd", lzip="lzip"):
    """Build the chapter list for the whole man corpus, as ONE book.

    Two structural decisions, both about links:

      * ONE XHTML PER PAGE, not one per section.  Section 1 alone is 2.3 MiB
        of generated markup; as a single spine item that is one enormous
        document to lay out, and every cross reference inside it would be a
        same-file anchor.  As a spine of one document per page it is an
        ordinary book, and grep(1) -> sed(1) is an ordinary document link.
      * ONE BOOK FOR ALL SECTIONS.  Cross-section references are the common
        case in a man corpus (crontab(1) -> crontab(5), ps(1) -> proc(5)),
        and nothing can link from one EPUB into another.  Splitting per
        section would throw away most of the hypertext the issue is asking
        for.  The cost is a large book: ~5.7 MiB of markup, ~1.9 MiB packed.
        WHAT THAT COSTS ON FIRST OPEN ON THE DEVICE IS NOT MEASURED -- there
        is no hardware in this work.  Splitting is a one-line change here if
        it turns out to matter.

    Each section gets an index chapter listing its pages with their NAME
    one-liners; that is both the discovery surface and the level-1 entry
    the per-page table-of-contents entries nest under.
    """
    used = set()
    names = {}
    for page in sorted(pages):
        names[page.page_id] = slugify_filename(page.page_id, used)
    known = {pid: "%s.xhtml" % fn for pid, fn in names.items()}

    by_section = {}
    for page in sorted(pages):
        by_section.setdefault(page.section, []).append(page)

    chapters = []
    for section in sorted(by_section, key=_section_key):
        section_pages = by_section[section]
        index_items, page_chapters = [], []
        for page in section_pages:
            title = "%s(%s)" % (page.name, page.section)
            if page.alias_of:
                # A `.so' stub: the same page under another name.  It earns
                # an index entry pointing at the real page, so "pkill" is
                # findable, but no chapter of its own.
                href = known.get(page.alias_of)
                tname, _, tsec = (page.alias_of or "").rpartition(".")
                summary = "see %s(%s)" % (tname, tsec) if tname else "an alias"
            else:
                cleaned = clean_man_fragment(
                    render_man(page, mandoc=mandoc, zstd=zstd, lzip=lzip),
                    page.page_id, known)
                href = known[page.page_id]
                summary = man_summary(cleaned)
                page_chapters.append(Chapter(
                    name=names[page.page_id],
                    title=title,
                    body='<h1 id="%s">%s</h1>%s'
                         % (_esc(page.page_id), _esc(title), cleaned),
                    toc=[(2, title, page.page_id)]))
            item = _esc(title) if not href \
                else '<a href="%s">%s</a>' % (_esc(href), _esc(title))
            if summary:
                item += " &#8212; " + _esc(summary)
            index_items.append("<li>%s</li>" % item)

        anchor = "wilkbook-section-%s" % slugify_filename(section)
        chapters.append(Chapter(
            name=slugify_filename("section-%s" % section, used),
            title=section_title(section),
            body='<h1 id="%s">%s</h1><ul>%s</ul>'
                 % (_esc(anchor), _esc(section_title(section)),
                    "".join(index_items)),
            toc=[(1, section_title(section), anchor)]))
        # The section's pages follow its index in the spine, so their
        # level-2 entries nest under it in the navigation map.
        chapters.extend(page_chapters)
    return chapters


def _section_key(section):
    m = re.match(r"^(\d+)(.*)$", section)
    return (int(m.group(1)), m.group(2)) if m else (99, section)
