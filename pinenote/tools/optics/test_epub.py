#!/usr/bin/env python3
"""Validate the self-calibrating test-epub generator: page count, that the
calibration markers render where the manifest claims, that the page-ID barcode
round-trips (a preview of the ingest decoder), and that the epub is well formed.
Run: python3 test_epub.py  (needs Pillow).
"""
import io
import sys
import tempfile
import zipfile

import numpy as np
from PIL import Image

import testepub as te

_fails = []


def check(name, cond, detail=""):
    print(f"  [{'ok  ' if cond else 'FAIL'}] {name}{('  -- ' + detail) if detail else ''}")
    if not cond:
        _fails.append(name)


def decode_pageid(arr, pageid_geom, W, H):
    """Decode the bottom-margin barcode from a rendered page (arr in [0,1])."""
    x0 = pageid_geom["x"]
    span = pageid_geom["w"] / pageid_geom["cells"]
    y = pageid_geom["y"] + pageid_geom["h"] / 2
    bits = []
    for i in range(pageid_geom["cells"]):
        fx = x0 + i * span + span * 0.4
        px, py = int(fx * W), int(y * H)
        bits.append(1 if arr[py, px] < 0.5 else 0)   # black cell = 1
    # bits[0] and bits[-1] are start/stop (black=1); middle are data MSB-first
    data = bits[1:-1]
    val = 0
    for b in data:
        val = (val << 1) | b
    return val, bits[0] == 1 and bits[-1] == 1


def main():
    pages = te.build_pages()
    manifest = te.build_manifest(pages)
    W, H = te.W, te.H

    print("case: page sequence + manifest")
    check("page count matches sequence", len(pages) == len(te.SEQUENCE),
          f"{len(pages)} pages")
    check("manifest transitions = pages-1",
          len(manifest["transitions"]) == len(pages) - 1)
    check("sync pages flagged in transitions",
          all(t["is_sync"] for t in manifest["transitions"][:4]))
    kinds = {p["kind"] for p in manifest["pages"]}
    check("taxonomy covered",
          {"novel", "graphic", "textbook", "blank", "ux", "index"} <= kinds,
          f"kinds={sorted(kinds)}")

    print("case: calibration markers render where the manifest says")
    content_page = next(p for p in pages if p.kind == "novel")
    arr = np.asarray(te.render_page(content_page), np.float32) / 255.0
    fids_dark = []
    for fid in manifest["markers"]["fiducials"]:
        px, py = int(fid["cx"] * W), int(fid["cy"] * H)
        fids_dark.append(arr[py, px] < 0.3)
    check("all 4 fiducials dark at their centroids", all(fids_dark),
          f"{sum(fids_dark)}/4")
    patch_ok = []
    for patch in manifest["markers"]["patches"]:
        px = int((patch["x"] + patch["w"] / 2) * W)
        py = int((patch["y"] + patch["h"] / 2) * H)
        patch_ok.append(abs(arr[py, px] - patch["reflectance"]) < 0.12)
    check("gray-step patches match intended reflectance", all(patch_ok),
          f"{sum(patch_ok)}/{len(patch_ok)}")

    print("case: page-ID barcode round-trips")
    ok = []
    for p in pages:
        if p.kind.startswith("sync"):
            continue
        a = np.asarray(te.render_page(p), np.float32) / 255.0
        val, framed = decode_pageid(a, manifest["markers"]["pageid"], W, H)
        ok.append(framed and val == p.pid)
    check("every content page's id decodes", all(ok), f"{sum(ok)}/{len(ok)}")

    print("case: sync pages are full black / full white")
    sb = np.asarray(te.render_page(te.Page(0, "sync_black", 0)), np.float32) / 255
    sw = np.asarray(te.render_page(te.Page(1, "sync_white", 1)), np.float32) / 255
    check("sync_black is black", sb.mean() < 0.02, f"mean={sb.mean():.3f}")
    check("sync_white is white", sw.mean() > 0.98, f"mean={sw.mean():.3f}")

    print("case: epub is well formed")
    with tempfile.TemporaryDirectory() as d:
        epub_path, _ = te.build(d)
        with zipfile.ZipFile(epub_path) as z:
            names = z.namelist()
            check("mimetype is first entry", names[0] == "mimetype")
            info = z.getinfo("mimetype")
            check("mimetype stored (uncompressed)",
                  info.compress_type == zipfile.ZIP_STORED)
            check("mimetype content correct",
                  z.read("mimetype") == b"application/epub+zip")
            check("container.xml present", "META-INF/container.xml" in names)
            opf = z.read("OEBPS/content.opf").decode()
            check("opf lists every page in spine",
                  all(f'idref="pg{p.index}"' in opf for p in pages))
            imgs_present = all(f"OEBPS/img/page_{p.index:03d}.png" in names
                               for p in pages)
            check("every page image present", imgs_present)
            # a rendered image decodes and has the right size
            im = Image.open(io.BytesIO(z.read("OEBPS/img/page_004.png")))
            check("packaged image has panel resolution", im.size == (W, H),
                  f"{im.size}")

    print()
    if _fails:
        print(f"testepub: {len(_fails)} FAILED: {', '.join(_fails)}")
        return 1
    print("testepub: ok -- self-calibrating test card generates and round-trips")
    return 0


if __name__ == "__main__":
    sys.exit(main())
