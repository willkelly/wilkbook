#!/usr/bin/env python3
"""Validate the self-calibrating test-epub generator: page count, that the
calibration markers render where the manifest claims, that the page-ID barcode
round-trips (a preview of the ingest decoder), that pid-varied content makes
same-kind adjacent pages visibly different, that the page-number + parity
marks render inside their manifest-reserved rects (clear of every calibration
marker), and that the epub is well formed.
Run: python3 test_epub.py  (needs Pillow + numpy).
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


def rects_overlap(r1, r2):
    """Open-interval overlap of two fractional {x,y,w,h} rects."""
    return (r1["x"] < r2["x"] + r2["w"] and r2["x"] < r1["x"] + r1["w"]
            and r1["y"] < r2["y"] + r2["h"] and r2["y"] < r1["y"] + r1["h"])


def crop_f(arr, r, W, H):
    """Crop a fractional {x,y,w,h} rect out of a [H,W] array."""
    x0, y0 = int(r["x"] * W), int(r["y"] * H)
    x1, y1 = int((r["x"] + r["w"]) * W), int((r["y"] + r["h"]) * H)
    return arr[y0:y1, x0:x1]


def page_arr(kind, pid):
    return np.asarray(te.render_page(te.Page(0, kind, pid)), np.float32) / 255.0


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

    print("case: pid-varied content -- same-kind adjacent pages differ visibly")
    x0f, y0f, x1f, y1f = te.content_rect_f()
    reserved = manifest["markers"]["reserved"]
    mask = np.zeros((H, W), bool)
    mask[int(y0f * H):int(y1f * H), int(x0f * W):int(x1f * W)] = True
    for r in reserved:      # exclude the per-page marks: content only
        mask[int(r["y"] * H):int((r["y"] + r["h"]) * H),
             int(r["x"] * W):int((r["x"] + r["w"]) * W)] = False
    same_kind = [(a, b) for a, b in zip(pages, pages[1:])
                 if a.kind == b.kind and not a.kind.startswith("sync")]
    check("card holds same-kind adjacent pairs", len(same_kind) >= 3,
          f"{[(a.kind, a.pid, b.pid) for a, b in same_kind]}")
    diff_ok, worst = [], None
    for a, b in same_kind:
        if a.kind == "blank":
            continue                    # blank stays blank; marks carry the turn
        d = np.abs(page_arr(a.kind, a.pid) - page_arr(b.kind, b.pid))[mask]
        frac, mean = float((d > 0.1).mean()), float(d.mean())
        diff_ok.append(frac > 0.02 and mean > 0.02)
        if worst is None or frac < worst[0]:
            worst = (frac, mean, a.kind, a.pid)
    check("every non-blank same-kind pair differs above the floor",
          bool(diff_ok) and all(diff_ok),
          f"worst frac={worst[0]:.3f} mean={worst[1]:.3f} ({worst[2]} pid {worst[3]})"
          if worst else "no pairs")
    blank_pairs = [(a, b) for a, b in same_kind if a.kind == "blank"]
    marks_ok = []
    for a, b in blank_pairs:            # marks alone must make the turn visible
        d = np.abs(page_arr(a.kind, a.pid) - page_arr(b.kind, b.pid))
        changed = max(float((crop_f(d, r, W, H) > 0.5).mean()) for r in reserved)
        marks_ok.append(changed > 0.2)
    check("blank->blank turns still visible via the page marks",
          all(marks_ok), f"{len(blank_pairs)} pairs" if blank_pairs else "none yet")

    print("case: page-number + parity marks in the reserved cells")
    check("digit height in the 0.10-0.12 spec band",
          0.10 <= te.PAGENUM_H <= 0.12, f"{te.PAGENUM_H}")
    rnum = next(r for r in reserved if r["what"] == "pagenum")
    rpa = next(r for r in reserved if r["what"] == "parity_a")
    rpb = next(r for r in reserved if r["what"] == "parity_b")
    crops = [crop_f(page_arr("blank", pid), rnum, W, H)
             for pid in (0, 1, 7, 8, 11, 25, 34, 48)]
    distinct = all(not np.array_equal(crops[i], crops[j])
                   for i in range(len(crops)) for j in range(i + 1, len(crops)))
    check("distinct pids render distinct page numbers", distinct)
    check("page number is dark ink inside its reserved cell",
          all(c.min() < 0.2 for c in crops))
    even, odd = page_arr("blank", 6), page_arr("blank", 7)
    check("even pid -> parity tile in corner A only",
          crop_f(even, rpa, W, H).mean() < 0.6
          and crop_f(even, rpb, W, H).mean() > 0.9)
    check("odd pid -> parity tile in corner B only",
          crop_f(odd, rpb, W, H).mean() < 0.6
          and crop_f(odd, rpa, W, H).mean() > 0.9)

    print("case: reserved rects vs calibration-marker geometry")
    check("manifest lists pagenum + both parity corners",
          [r["what"] for r in reserved] == ["pagenum", "parity_a", "parity_b"])
    check("reserved rects inside the content rect",
          all(r["x"] >= x0f and r["y"] >= y0f and r["x"] + r["w"] <= x1f
              and r["y"] + r["h"] <= y1f for r in reserved))
    half_fx = (te.FID * min(W, H) / 2) / W
    half_fy = (te.FID * min(W, H) / 2) / H
    markers = [{"x": f["cx"] - half_fx, "y": f["cy"] - half_fy,
                "w": 2 * half_fx, "h": 2 * half_fy,
                "what": f"fiducial_{f['corner']}"}
               for f in manifest["markers"]["fiducials"]]
    markers += [dict(p, what=p["name"]) for p in manifest["markers"]["patches"]]
    markers.append(dict(manifest["markers"]["pageid"], what="pageid"))
    clashes = [(r["what"], m["what"]) for r in reserved for m in markers
               if rects_overlap(r, m)]
    check("reserved rects clear of fiducials/patches/barcode", not clashes,
          f"{clashes}")
    self_clash = [(a["what"], b["what"]) for i, a in enumerate(reserved)
                  for b in reserved[i + 1:] if rects_overlap(a, b)]
    check("reserved rects don't overlap each other", not self_clash,
          f"{self_clash}")

    print("case: render_kind (kind, pid) adapter")
    check("render_kind(kind, pid) matches render_page",
          np.array_equal(np.asarray(te.render_kind("novel", pid=7)),
                         np.asarray(te.render_page(te.Page(0, "novel", 7)))))
    check("render_kind defaults to pid 0",
          np.array_equal(np.asarray(te.render_kind("blank")),
                         np.asarray(te.render_page(te.Page(0, "blank", 0)))))

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
