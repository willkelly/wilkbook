#!/usr/bin/env python3
"""Build the reader's shelf of manuals from a list of installed prefixes.

Invoked at BUILD time by pinenote/packages/manuals.scm with the store paths
of the packages the flavor installs, and by the host suite in
pinenote/tools/manuals with fixture directories.  Nothing here runs on the
device.

    build-manuals.py --out DIR [--mandoc PATH] [--zstd PATH] [--no-info]
                     [--no-man] PREFIX...

Writes one EPUB per man section and one per Texinfo manual into DIR, plus a
MANIFEST listing what was built (which is what the shepherd one-shot on the
device stages, and what the host tests read back).
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import manuals as M          # noqa: E402


def info_title(nodes, fallback):
    """A human title for a Texinfo manual: its Top node's own heading."""
    for node in nodes:
        if node.name.lower() == "top" and node.title.lower() != "top":
            return node.title
    return fallback


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mandoc", default="mandoc")
    ap.add_argument("--zstd", default="zstd")
    ap.add_argument("--lzip", default="lzip")
    ap.add_argument("--no-man", action="store_true")
    ap.add_argument("--no-info", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("prefix", nargs="+")
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    corpus = M.discover(args.prefix, zstd=args.zstd, lzip=args.lzip)
    manifest = []

    if not args.no_man and corpus.man:
        chapters = M.man_book(corpus.man, mandoc=args.mandoc,
                              zstd=args.zstd, lzip=args.lzip)
        if chapters:
            path = os.path.join(args.out, "%s.epub" % M.MAN_BOOK_TITLE)
            M.write_epub(path, M.MAN_BOOK_TITLE, chapters,
                         creator="the software installed on this device")
            manifest.append(("man", "all-sections", os.path.basename(path),
                             str(len(corpus.man))))

    if not args.no_info:
        for manual in corpus.info:
            text = "".join(
                M.read_doc(p, zstd=args.zstd, lzip=args.lzip)
                 .decode("utf-8", "replace")
                for p in manual.paths)
            nodes = M.parse_info(text)
            if not nodes:
                continue
            chapters = M.info_chapters(manual.name, text)
            if not chapters:
                continue
            title = info_title(nodes, manual.name)
            path = os.path.join(
                args.out, "%s.epub" % M.slugify_filename(manual.name))
            M.write_epub(path, title, chapters, creator="the GNU Project")
            manifest.append(("info", manual.name, os.path.basename(path),
                             str(len(nodes))))

    manifest_path = os.path.join(args.out, "MANIFEST")
    with open(manifest_path, "w") as fh:
        for row in manifest:
            fh.write("\t".join(row) + "\n")

    if not args.quiet:
        for kind, key, fn, count in manifest:
            size = os.path.getsize(os.path.join(args.out, fn))
            print("%-5s %-24s %-40s %5s entries  %7d bytes"
                  % (kind, key, fn, count, size))
        for path, why in corpus.skipped:
            print("skipped: %s (%s)" % (path, why))
    return 0 if manifest else 1


if __name__ == "__main__":
    sys.exit(main())
