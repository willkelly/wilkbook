#!/usr/bin/env python3
"""Host-side tests for the manual/info -> EPUB converter (issue #17).

Runs the REPO's converter -- pinenote/packages/manuals/manuals.py, the same
file pinenote/packages/manuals.scm feeds to the build -- against fixtures,
and asserts the properties that decide whether KOReader can open the result
at all.  Nothing here needs the device, and nothing here PROVES rendering:
what is proven is that the books are well-formed EPUB 2, that every internal
link lands on an anchor that exists, and that the markup stays inside a
reviewed element vocabulary.  How crengine lays it out is unverified.

Standard library only.  mandoc is optional: without it the roff stage is
skipped and the post-processor is exercised against a committed fixture of
mandoc's own output.

    test-manuals.py TOOLDIR CONVERTERDIR [MANDOC]
"""

import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

FAILURES = [0]


def check(label, ok, detail=""):
    if ok:
        print("PASS: %s" % label)
    else:
        FAILURES[0] += 1
        print("FAIL: %s%s" % (label, (" -- " + detail) if detail else ""))
    return ok


def skip(label, why):
    print("SKIP: %s -- %s" % (label, why))


# The elements the generated books are allowed to use.  This is the renderer
# contract, pinned offline: it does not prove crengine lays them out well, it
# proves the converter never quietly starts emitting something outside the
# set that was reviewed against crengine's element table.  <section> is
# deliberately ABSENT -- mandoc emits it and clean_man_fragment rewrites it.
REVIEWED_ELEMENTS = {
    "html", "head", "title", "link", "body",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "p", "pre", "div", "span", "br",
    "b", "i", "code", "var", "small", "mark", "sub", "sup",
    "dl", "dt", "dd", "ul", "ol", "li",
    "table", "tr", "td", "th", "tbody", "thead",
    "a", "img", "hr", "blockquote",
}


# ---------------------------------------------------------------------------
# Fixtures built in a temp tree.  Generated rather than committed because the
# info format is defined by control bytes -- US as the node separator, NUL/BS
# around Texinfo's invisible markers -- and a fixture whose whole point is
# those bytes is unreviewable as a committed blob.
# ---------------------------------------------------------------------------

US = "\x1f"

INFO_DEMO = (
    "This is demo.info, produced by makeinfo version 7.1 from demo.texi.\n"
    + US + "\n"
    "File: demo.info,  Node: Top,  Next: First,  Up: (dir)\n"
    "\n"
    "The Demo Manual\n"
    "***************\n"
    "\n"
    "A manual that exists to be parsed.\n"
    "\n"
    "* Menu:\n"
    "\n"
    "* First::                      The first chapter\n"
    "* Options: Second.             The second chapter\n"
    "* Index::                      The index\n"
    + US + "\n"
    "File: demo.info,  Node: First,  Next: Second,  Prev: Top,  Up: Top\n"
    "\n"
    "1 The First Chapter\n"
    "*******************\n"
    "\n"
    "This paragraph was hard-wrapped by makeinfo at seventy-two columns\n"
    "and has to come back out as one flowing paragraph, not as a block of\n"
    "terminal output.  *Note Second:: is a capitalised cross reference.\n"
    "\n"
    "   A second paragraph, opened with the three-space indent makeinfo\n"
    "uses.  It mentions *note the options: Second. by label.\n"
    "\n"
    "     demo --example\n"
    "     demo --example --twice\n"
    "\n"
    "   And a reference to *note Nowhere:: that has no such node.\n"
    + US + "\n"
    "File: demo.info,  Node: Second,  Next: Index,  Prev: First,  Up: Top\n"
    "\n"
    "2 The Second Chapter\n"
    "********************\n"
    "\n"
    "2.1 Options\n"
    "===========\n"
    "\n"
    "'--verbose'\n"
    "'-v'\n"
    "     Say more.  This definition body is itself hard-wrapped and must\n"
    "     be reflowed inside its <dd>.\n"
    "\n"
    "          demo --verbose\n"
    "\n"
    "'--quiet'\n"
    "     Say less.\n"
    "\n"
    '[image src="demo.png" alt="A diagram" text="   +---+\n'
    "   | a |\n"
    '   +---+"]\n'
    + US + "\n"
    "File: demo.info,  Node: Index,  Prev: Second,  Up: Top\n"
    "\n"
    "Index\n"
    "*****\n"
    "\n"
    "\x00\x08[index\x00\x08]\n"
    "* Menu:\n"
    "\n"
    "* verbose:                               Second.              (line 6)\n"
    + US + "\n"
    "Tag Table:\n"
    "Node: Top\x7f52\n"
    "\x1fEnd Tag Table\n"
)

MAN_HELLO = """\
.Dd August 24, 2026
.Dt HELLO 1
.Os
.Sh NAME
.Nm hello
.Nd greet the world
.Sh DESCRIPTION
Greets.
"""


def build_fixture_tree(root):
    """Two package prefixes, in the shape Guix installs them."""
    a = os.path.join(root, "pkg-a")
    b = os.path.join(root, "pkg-b")
    for path in ("share/man/man1", "share/man/man8", "share/man/de/man1"):
        os.makedirs(os.path.join(a, path))
    os.makedirs(os.path.join(b, "share/man/man1"))
    os.makedirs(os.path.join(b, "share/info"))

    with open(os.path.join(a, "share/man/man1/hello.1"), "w") as fh:
        fh.write(MAN_HELLO)
    # A .so alias, gzipped: both the alias handling and the gzip path.
    import gzip
    with gzip.open(os.path.join(a, "share/man/man1/hi.1.gz"), "wb") as fh:
        fh.write(b".so man1/hello.1\n")
    # A translated page, which discovery must NOT pick up.
    with open(os.path.join(a, "share/man/de/man1/hello.1"), "w") as fh:
        fh.write(MAN_HELLO)
    with open(os.path.join(a, "share/man/man8/tool.8"), "w") as fh:
        fh.write(MAN_HELLO.replace("HELLO 1", "TOOL 8").replace("Nm hello",
                                                                "Nm tool"))
    # Same page name in a later prefix: the earlier one must win.
    with open(os.path.join(b, "share/man/man1/hello.1"), "w") as fh:
        fh.write(MAN_HELLO.replace("greet the world", "SHADOWED"))

    # A split manual: demo.info + demo.info-2 + demo.info-10, to pin the
    # numeric (not lexicographic) ordering of the continuation files.
    with open(os.path.join(b, "share/info/demo.info"), "w") as fh:
        fh.write(INFO_DEMO)
    for n in (2, 10):
        with open(os.path.join(b, "share/info/demo.info-%d" % n), "w") as fh:
            fh.write("")
    with open(os.path.join(b, "share/info/dir"), "w") as fh:
        fh.write("not a manual\n")
    with open(os.path.join(b, "share/info/demo.png"), "wb") as fh:
        fh.write(b"\x89PNG\r\n")
    return [a, b]


# ---------------------------------------------------------------------------
# Structural assertions shared by the unit and end-to-end passes
# ---------------------------------------------------------------------------

def epub_report(path):
    """Parse one EPUB and return (problems, elements, chapter_count)."""
    problems, elements = [], set()
    zf = zipfile.ZipFile(path)
    names = set(zf.namelist())
    infos = zf.infolist()
    if infos[0].filename != "mimetype":
        problems.append("mimetype is not the first member")
    elif infos[0].compress_type != zipfile.ZIP_STORED:
        problems.append("mimetype is compressed")
    elif zf.read("mimetype") != b"application/epub+zip":
        problems.append("mimetype content is wrong")

    for meta in ("META-INF/container.xml", "OEBPS/content.opf",
                 "OEBPS/toc.ncx"):
        if meta not in names:
            problems.append("missing %s" % meta)
            continue
        try:
            ET.fromstring(zf.read(meta))
        except ET.ParseError as exc:
            problems.append("%s is not well-formed XML: %s" % (meta, exc))

    opf = ET.fromstring(zf.read("OEBPS/content.opf"))
    ns = "{http://www.idpf.org/2007/opf}"
    manifest = {}
    for item in opf.iter(ns + "item"):
        manifest[item.get("id")] = item.get("href")
        if "OEBPS/" + item.get("href") not in names:
            problems.append("manifest item %s is not in the archive"
                            % item.get("href"))
    spine = [r.get("idref") for r in opf.iter(ns + "itemref")]
    for idref in spine:
        if idref not in manifest:
            problems.append("spine references unknown item %s" % idref)

    ids = {}
    docs = {}
    for name in sorted(names):
        if not name.endswith(".xhtml"):
            continue
        text = zf.read(name).decode("utf-8")
        try:
            root = ET.fromstring(re.sub(r"<!DOCTYPE[^>]*>", "", text, count=1))
        except ET.ParseError as exc:
            problems.append("%s is not well-formed XML: %s" % (name, exc))
            continue
        docs[name] = root
        ids[name] = set()
        for el in root.iter():
            tag = el.tag.split("}")[-1]
            elements.add(tag)
            if el.get("id"):
                ids[name].add(el.get("id"))

    # Links are read out of the PARSED tree, never with a regex over the
    # source: man pages quote HTML in their examples, and a regex for
    # href="..." happily matches wget(1) explaining <a href="/foo.gif">.
    for name, root in docs.items():
        for anchor in root.iter("{http://www.w3.org/1999/xhtml}a"):
            href = anchor.get("href")
            if not href or href.startswith(("http:", "https:", "ftp:",
                                            "mailto:")):
                continue
            target, _, frag = href.partition("#")
            tname = name if not target else "OEBPS/" + target
            if tname not in names:
                problems.append("%s: link to missing document %s"
                                % (name, href))
            elif frag and frag not in ids.get(tname, ()):
                problems.append("%s: link to missing anchor %s" % (name, href))
    return problems, elements, len(docs)


def make_shelf_src(path, books):
    """A fake store directory of books, MANIFEST and all."""
    os.makedirs(path)
    for name in books:
        with open(os.path.join(path, name), "wb") as fh:
            fh.write(b"PK\x03\x04fake-" + name.encode())
    with open(os.path.join(path, "MANIFEST"), "w") as fh:
        for name in books:
            fh.write("man\tall\t%s\t1\n" % name)
    return path


def run_stage(check, stage, tmp, root="/proc"):
    """Drive pinenote/services/manuals-stage.sh through every branch."""
    lib = os.path.join(tmp, "stage-lib")
    shelf = os.path.join(lib, "Manuals")
    stamp = os.path.join(lib, ".pinenote-manuals")
    os.makedirs(lib)

    def call(src, shelf_path=shelf, mount=root):
        proc = subprocess.run(["sh", stage, src, shelf_path, mount],
                              capture_output=True)
        return proc.returncode, proc.stdout.decode("utf-8", "replace").strip()

    src1 = make_shelf_src(os.path.join(tmp, "src1"), ["a.epub", "b.epub"])
    rc, out = call(src1)
    check("staging: a first run copies the books",
          rc == 0 and sorted(f for f in os.listdir(shelf)
                             if f.endswith(".epub")) == ["a.epub", "b.epub"],
          out)
    with open(stamp) as fh:
        check("staging: the stamp records the store path",
              fh.read().strip() == src1)
    with open(os.path.join(shelf, ".wilkbook-manifest")) as fh:
        check("staging: the shelf manifest names what was staged",
              sorted(fh.read().split()) == ["a.epub", "b.epub"])

    # A book the user put in the shelf, and one they will keep.
    user_book = os.path.join(shelf, "mine.epub")
    with open(user_book, "w") as fh:
        fh.write("mine")

    rc, out = call(src1)
    check("staging: a second run with the same source changes nothing",
          rc == 0 and "unchanged" in out, out)

    src2 = make_shelf_src(os.path.join(tmp, "src2"), ["a.epub", "c.epub"])
    rc, out = call(src2)
    staged = sorted(f for f in os.listdir(shelf) if f.endswith(".epub"))
    check("staging: a new build replaces the shelf's own books",
          rc == 0 and staged == ["a.epub", "c.epub", "mine.epub"], str(staged))
    check("staging: a book the user added is not deleted",
          os.path.exists(user_book))

    # The user deletes the shelf: it must stay deleted, and the stamp must
    # still advance so the next deploy does not resurrect it.
    shutil.rmtree(shelf)
    src3 = make_shelf_src(os.path.join(tmp, "src3"), ["a.epub"])
    rc, out = call(src3)
    check("staging: a shelf the user deleted is not recreated",
          rc == 0 and not os.path.exists(shelf) and "removed" in out, out)
    with open(stamp) as fh:
        check("staging: the stamp advances even when nothing is written",
              fh.read().strip() == src3)

    # Not a mount point: nothing at all, not even a directory.
    fake_root = os.path.join(tmp, "not-a-mount")
    os.makedirs(fake_root)
    other = os.path.join(fake_root, "books", "Manuals")
    rc, out = call(src1, shelf_path=other, mount=fake_root)
    check("staging: nothing happens when the data partition is not mounted",
          rc == 0 and not os.path.exists(other) and "not a mount point" in out,
          out)

    # A source with no MANIFEST is not a shelf.
    empty = os.path.join(tmp, "src-empty")
    os.makedirs(empty)
    lib2 = os.path.join(tmp, "stage-lib2")
    os.makedirs(lib2)
    rc, out = call(empty, shelf_path=os.path.join(lib2, "Manuals"))
    check("staging: a source with no MANIFEST is refused",
          rc == 0 and not os.path.exists(os.path.join(lib2, "Manuals"))
          and "no MANIFEST" in out, out)


def main(argv):
    tool_dir = argv[1]
    converter_dir = argv[2]
    mandoc = argv[3] if len(argv) > 3 and argv[3] else shutil.which("mandoc")

    sys.path.insert(0, converter_dir)
    import manuals as M

    tmp = tempfile.mkdtemp(prefix="wilkbook-manuals-")
    try:
        roots = build_fixture_tree(tmp)

        # -- decompression ------------------------------------------------
        import bz2 as _bz2, gzip as _gzip, lzma as _lzma
        payload = b".Sh NAME\n"
        for label, blob in (("gzip", _gzip.compress(payload)),
                            ("bzip2", _bz2.compress(payload)),
                            ("xz", _lzma.compress(payload)),
                            ("plain", payload)):
            p = os.path.join(tmp, "c-%s" % label)
            with open(p, "wb") as fh:
                fh.write(blob)
            check("read_doc decodes %s" % label, M.read_doc(p) == payload)

        # quirk: a compressed frame must never be handed on as if it were
        # roff.  mandoc accepts binary garbage and exits 0, so the first
        # probe of this work silently converted 493 zstd frames to nonsense.
        zpath = os.path.join(tmp, "c-zstd")
        with open(zpath, "wb") as fh:
            fh.write(b"\x28\xb5\x2f\xfd" + b"\x00" * 8)
        # Use a decompressor that EXISTS and FAILS, not one that is missing.
        # An absent binary raises OSError from exec and never reaches the
        # `returncode != 0` branch -- which is the only branch that can fire
        # inside the Guix derivation, where zstd is a real build input at an
        # absolute path.  Accepting OSError as a pass made this quirk test
        # vacuous with respect to the guard that actually operates.
        try:
            got = M.read_doc(zpath, zstd="false")
            check("quirk: read_doc refuses an undecodable zstd frame", False,
                  "returned %d bytes instead of raising" % len(got))
        except M.CorpusError:
            check("quirk: read_doc refuses an undecodable zstd frame", True,
                  "decompressor exited nonzero and read_doc raised")

        # -- discovery ----------------------------------------------------
        corpus = M.discover(roots)
        by_id = {p.page_id: p for p in corpus.man}
        check("discovery finds share/man/manN pages",
              {"hello.1", "hi.1", "tool.8"} <= set(by_id),
              str(sorted(by_id)))
        check("discovery ignores translated share/man/<locale>/manN",
              len([p for p in corpus.man if "/de/" in p.path]) == 0)
        check("discovery: the earlier prefix wins a name collision",
              by_id["hello.1"].path.startswith(roots[0]))
        check("discovery records the shadowed page as skipped",
              any("shadowed" in why for _, why in corpus.skipped),
              str(corpus.skipped))
        check("discovery resolves a .so stub to its target",
              by_id["hi.1"].alias_of == "hello.1",
              str(by_id["hi.1"].alias_of))
        check("discovery groups a split manual under one name",
              [m.name for m in corpus.info] == ["demo"],
              str([m.name for m in corpus.info]))
        check("discovery orders continuation files numerically",
              [os.path.basename(p) for p in corpus.info[0].paths]
              == ["demo.info", "demo.info-2", "demo.info-10"],
              str([os.path.basename(p) for p in corpus.info[0].paths]))

        # -- man post-processing, against a committed mandoc fixture -------
        golden = os.path.join(tool_dir, "fixtures", "wilkdemo.1.mandoc-html")
        with open(golden) as fh:
            raw = fh.read()
        known = {"wilkdemo.1": "wilkdemo.1.xhtml",
                 "wilkother.1": "wilkother.1.xhtml"}
        cleaned = M.clean_man_fragment(raw, "wilkdemo.1", known)
        check("man: the running head/foot tables are dropped",
              'class="head"' not in cleaned and 'class="foot"' not in cleaned)
        check("man: the SYNOPSIS table survives",
              'class="Nm"' in cleaned and "<table" in cleaned)
        check("man: permalink self-links are unwrapped",
              "permalink" not in cleaned)
        check("man: <section> becomes <div>",
              "<section" not in cleaned and "</section>" not in cleaned)
        check("man: .Sh h1 is demoted to h2",
              '<h2 class="Sh"' in cleaned and "<h1" not in cleaned)
        check("man: .Ss h2 is demoted to h3", '<h3 class="Ss"' in cleaned)
        check("man: ids are namespaced by page",
              'id="wilkdemo.1--NAME"' in cleaned)
        check("man: a cross reference inside the book becomes a link",
              'href="wilkother.1.xhtml"' in cleaned)
        check("man: a cross reference outside the book is unwrapped",
              "nosuchpage.9" not in cleaned and "nosuchpage(9)" in cleaned)
        check("man: an absolute link survives",
              'href="https://example.invalid/with-scheme"' in cleaned)
        check("man: a mailto link survives",
              'href="mailto:fixture@example.invalid"' in cleaned)
        check("man: a bare relative link is unwrapped",
              'href="example.invalid/no-scheme"' not in cleaned
              and "a bare link" in cleaned)
        try:
            ET.fromstring("<root>" + cleaned + "</root>")
            check("man: the cleaned fragment is well-formed XML", True)
        except ET.ParseError as exc:
            check("man: the cleaned fragment is well-formed XML", False,
                  str(exc))
        check("man: the NAME one-liner is extracted for the index",
              M.man_summary(cleaned).startswith("exercise every mandoc"),
              repr(M.man_summary(cleaned)))

        # -- info ---------------------------------------------------------
        # The regression that produced zero nodes for every manual: US is the
        # node separator and the XML sanitizer must not eat it.
        check("info: sanitize_info keeps the US node separator",
              M.sanitize_info("a" + US + "b") == "a" + US + "b")
        check("info: sanitize_info drops Texinfo's invisible index marker",
              M.sanitize_info("x\x00\x08[index\x00\x08]y") == "xy")
        check("info: sanitize_info drops stray control bytes",
              M.sanitize_info("a\x08b\x7fc") == "abc")

        nodes = M.parse_info(INFO_DEMO)
        names = [n.name for n in nodes]
        check("info: every File:/Node: chunk becomes a node",
              names == ["Top", "First", "Second", "Index"], str(names))
        check("info: the Tag Table chunk is not a node",
              "Tag Table" not in names)
        check("info: the underline character sets the heading level",
              [n.level for n in nodes] == [1, 1, 1, 1],
              str([n.level for n in nodes]))
        check("info: the node title comes from the underlined line",
              nodes[1].title == "1 The First Chapter", nodes[1].title)

        chapters = M.info_chapters("demo", INFO_DEMO)
        bodies = {c.name: c.body for c in chapters}
        check("info: a level-1 node starts a new chapter",
              len(chapters) == 4, str(len(chapters)))
        first = bodies["demo-1"]
        check("info: a hard-wrapped paragraph is reflowed into one <p>",
              "<p>This paragraph was hard-wrapped by makeinfo at seventy-two "
              "columns and has to come back out as one flowing paragraph"
              in first, first[:200])
        check("info: an indented example stays verbatim in a <pre>",
              "<pre>demo --example\ndemo --example --twice</pre>" in first,
              first[-400:])
        check("info: a capitalised *Note becomes a link",
              '>Second</a> is a capitalised cross reference' in first,
              first[:600])
        check("info: a labelled *note becomes a link with its label",
              ">the options</a>" in first, first[:900])
        check("info: a reference to a node that does not exist stays text",
              "Nowhere</a>" not in first and "Nowhere" in first)
        second = bodies["demo-2"]
        check("info: a @table item becomes <dt>/<dd>",
              "<dt>&#x2018;--verbose&#x2019;</dt>" in second
              or "<dt>'--verbose'</dt>" in second, second[:400])
        check("info: the definition body is reflowed inside its <dd>",
              "Say more.  This definition body is itself hard-wrapped and "
              "must be reflowed inside its &lt;dd&gt;." in second,
              second[:800])
        check("info: an example nested in a definition stays verbatim",
              "<pre>demo --verbose</pre>" in second, second[:1200])
        check("info: a sub-heading inside a node becomes a heading",
              "<h3>2.1 Options</h3>" in second and "====" not in second,
              second[:300])
        check("info: an @image falls back to its ASCII text",
              "+---+" in second and "demo.png" not in second, second[-400:])
        top = bodies["demo-0"]
        check("info: a menu becomes a list of links",
              "<ul><li><a href=" in top and "The first chapter" in top,
              top[:400])
        index = bodies["demo-3"]
        check("info: an index node's entries become links",
              'href="demo-2.xhtml#' in index, index[:400])

        # -- EPUB ---------------------------------------------------------
        book = os.path.join(tmp, "demo.epub")
        M.write_epub(book, "The Demo Manual", chapters)
        problems, elements, ndocs = epub_report(book)
        check("epub: structurally sound and every link resolves",
              not problems, "; ".join(problems[:5]))
        check("epub: every element used is in the reviewed set",
              elements <= REVIEWED_ELEMENTS,
              str(sorted(elements - REVIEWED_ELEMENTS)))

        zf = zipfile.ZipFile(book)
        ncx = ET.fromstring(zf.read("OEBPS/toc.ncx"))
        nns = "{http://www.daisy.org/z3986/2005/ncx/}"
        navmap = ncx.find(nns + "navMap")
        check("epub: the navigation map has one top-level entry per chapter",
              len(navmap.findall(nns + "navPoint")) == 4,
              str(len(navmap.findall(nns + "navPoint"))))

        # The cross-chapter nesting bug: a per-chapter navPoint stack closes
        # a section before the pages that belong under it.
        parent = M.Chapter(name="sec", title="Section 1", body="<p/>",
                           toc=[(1, "Section 1", "sec1")])
        childa = M.Chapter(name="a", title="a(1)", body="<p/>",
                           toc=[(2, "a(1)", "a.1")])
        childb = M.Chapter(name="b", title="b(1)", body="<p/>",
                           toc=[(2, "b(1)", "b.1")])
        nested = os.path.join(tmp, "nested.epub")
        M.write_epub(nested, "Nested", [parent, childa, childb])
        ncx2 = ET.fromstring(
            zipfile.ZipFile(nested).read("OEBPS/toc.ncx"))
        top_points = ncx2.find(nns + "navMap").findall(nns + "navPoint")
        check("epub: level-2 entries nest under the preceding level-1 entry",
              len(top_points) == 1
              and len(top_points[0].findall(nns + "navPoint")) == 2,
              "top=%d children=%d" % (
                  len(top_points),
                  len(top_points[0].findall(nns + "navPoint"))
                  if top_points else -1))

        again = os.path.join(tmp, "demo-again.epub")
        M.write_epub(again, "The Demo Manual", chapters)
        with open(book, "rb") as f1, open(again, "rb") as f2:
            check("epub: two writes of the same input are byte-identical",
                  f1.read() == f2.read())

        # -- end to end, only when a roff formatter is available -----------
        if not mandoc:
            skip("end-to-end build over the fixture prefixes",
                 "no mandoc on PATH")
        else:
            out = os.path.join(tmp, "shelf")
            builder = os.path.join(converter_dir, "build-manuals.py")
            proc = subprocess.run(
                [sys.executable, builder, "--quiet", "--out", out,
                 "--mandoc", mandoc] + roots,
                capture_output=True)
            ok = check("end-to-end: build-manuals.py exits 0",
                       proc.returncode == 0,
                       proc.stderr.decode("utf-8", "replace")[-400:])
            if ok:
                books = sorted(f for f in os.listdir(out)
                               if f.endswith(".epub"))
                check("end-to-end: one man book and one info book are written",
                      books == ["Manual pages.epub", "demo.epub"], str(books))
                with open(os.path.join(out, "MANIFEST")) as fh:
                    rows = [line.split("\t") for line in fh.read().split("\n")
                            if line]
                check("end-to-end: the MANIFEST names both books",
                      sorted(r[0] for r in rows) == ["info", "man"], str(rows))
                all_elements = set()
                for name in books:
                    problems, elements, ndocs = epub_report(
                        os.path.join(out, name))
                    check("end-to-end: %s is sound and fully linked" % name,
                          not problems, "; ".join(problems[:5]))
                    all_elements |= elements
                check("end-to-end: the built books stay in the reviewed "
                      "element set", all_elements <= REVIEWED_ELEMENTS,
                      str(sorted(all_elements - REVIEWED_ELEMENTS)))
                man = zipfile.ZipFile(os.path.join(out, "Manual pages.epub"))
                index = man.read("OEBPS/section-1.xhtml").decode()
                check("end-to-end: the section index lists a page with its "
                      "NAME line",
                      "hello(1)" in index and "greet the world" in index,
                      index[-400:])
                check("end-to-end: the section index points an alias at its "
                      "real page",
                      "hi(1)" in index and "see hello(1)" in index,
                      index[-400:])
                check("end-to-end: an alias gets no chapter of its own",
                      "OEBPS/hi.1.xhtml" not in man.namelist())

        # -- the staging one-shot ------------------------------------------
        # EXECUTED, not grepped.  The mount guard is the reason the script
        # takes its root explicitly: /proc is a mount point on every Linux
        # host, so every branch after the guard is reachable in a test.
        stage = os.path.join(tool_dir, "..", "..", "services",
                             "manuals-stage.sh")
        stage = os.path.normpath(stage)
        if not os.path.exists(stage):
            check("staging: manuals-stage.sh exists", False, stage)
        elif subprocess.run(["mountpoint", "-q", "/proc"]).returncode != 0:
            skip("staging one-shot", "/proc is not a mount point here")
        else:
            check("staging: the script parses",
                  subprocess.run(["sh", "-n", stage]).returncode == 0)
            run_stage(check, stage, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if FAILURES[0]:
        print("RESULT: %d check(s) failed" % FAILURES[0])
        return 1
    print("RESULT: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
