"""Self-calibrating test epub generator for the optics harness.

Produces crafted full-page images -- content per the transition taxonomy plus
baked-in calibration markers (corner fiducials for homography, a gray-step
reference strip for photometry, a page-ID barcode) and an opening black/white
sync sequence -- packaged as a fixed-layout epub3 that KOReader pages through
one image per turn. Also emits manifest.json describing marker geometry (as
page fractions, so ingest is resolution-independent) and the labelled page
sequence + transition pairs the analyzer scores.

Deterministic: no RNG, no clock. `python3 testepub.py OUTDIR` builds it.
Needs Pillow. See README.md.
"""
from __future__ import annotations
from dataclasses import dataclass, field
import json
import os
import zipfile

from PIL import Image, ImageDraw

# Portrait reading geometry by default; ingest works off fractions so this is
# not load-bearing, but matching the panel keeps KOReader's fit 1:1.
W, H = 1404, 1872

# marker geometry as fractions of (W,H) -- the single source of truth, copied
# into the manifest so ingest and generator can never disagree.
FID = 0.045                      # fiducial square side (fraction of min dim)
INSET = 0.020                    # corner inset
PATCH_REFL = [0.0, 0.25, 0.5, 0.75, 1.0]   # gray-step strip, black..white
TOP_MARGIN = 0.075               # holds the patch strip
BOT_MARGIN = 0.055               # holds the page-id barcode
LR_MARGIN = 0.030
PAGEID_BITS = 8


def _px(fx, fy):
    return int(round(fx * W)), int(round(fy * H))


@dataclass
class Page:
    index: int
    kind: str
    pid: int
    img: Image.Image = None


def _ref(r):     # reflectance [0,1] -> 8-bit gray
    return int(round(max(0.0, min(1.0, r)) * 255))


def _fiducials(draw):
    """Four corner markers; a per-corner pip count makes orientation
    unambiguous to ingest. Returns list of {corner,cx,cy} in fractions."""
    s = FID * min(W, H)
    half_fx, half_fy = (s / 2) / W, (s / 2) / H
    corners = [("TL", INSET, INSET, 1), ("TR", 1 - INSET, INSET, 2),
               ("BL", INSET, 1 - INSET, 3), ("BR", 1 - INSET, 1 - INSET, 4)]
    out = []
    for name, fx, fy, pips in corners:
        cx = fx if fx < 0.5 else fx        # centroid fraction
        cx = fx + (half_fx if fx < 0.5 else -half_fx)
        cy = fy + (half_fy if fy < 0.5 else -half_fy)
        x0, y0 = _px(cx - half_fx, cy - half_fy)
        x1, y1 = _px(cx + half_fx, cy + half_fy)
        draw.rectangle([x0, y0, x1, y1], fill=0)                    # black square
        draw.rectangle([x0 + 4, y0 + 4, x1 - 4, y1 - 4], outline=255, width=3)
        # pips: small white dots along the top inner edge encode the corner id
        for k in range(pips):
            px = x0 + 8 + k * 8
            draw.rectangle([px, y0 + 8, px + 3, y0 + 11], fill=255)
        out.append({"corner": name, "cx": round(cx, 5), "cy": round(cy, 5),
                    "pips": pips})
    return out


def _patch_strip(draw):
    """Horizontal gray-step reference patches across the top margin, between
    the top fiducials. Returns list of {name,x,y,w,h,reflectance} fractions."""
    x0 = INSET + FID * min(W, H) / W + 0.01
    x1 = 1 - (INSET + FID * min(W, H) / W + 0.01)
    y = 0.012
    hgt = TOP_MARGIN - 0.028
    n = len(PATCH_REFL)
    span = (x1 - x0) / n
    out = []
    for i, r in enumerate(PATCH_REFL):
        fx = x0 + i * span + span * 0.1
        fw = span * 0.8
        a = _px(fx, y)
        b = _px(fx + fw, y + hgt)
        draw.rectangle([a[0], a[1], b[0], b[1]], fill=_ref(r))
        draw.rectangle([a[0], a[1], b[0], b[1]], outline=128, width=1)
        out.append({"name": f"p{i}", "x": round(fx, 5), "y": round(y, 5),
                    "w": round(fw, 5), "h": round(hgt, 5), "reflectance": r})
    return out


def _pageid(draw, pid):
    """Binary barcode of `pid` across the bottom margin: a black start cell,
    PAGEID_BITS data cells (black=1), a black stop cell. Returns geometry."""
    x0 = INSET + FID * min(W, H) / W + 0.01
    x1 = 1 - (INSET + FID * min(W, H) / W + 0.01)
    y = 1 - BOT_MARGIN + 0.008
    hgt = BOT_MARGIN - 0.020
    cells = PAGEID_BITS + 2                     # start + data + stop
    span = (x1 - x0) / cells
    bits = [1] + [(pid >> (PAGEID_BITS - 1 - i)) & 1 for i in range(PAGEID_BITS)] + [1]
    for i, bit in enumerate(bits):
        fx = x0 + i * span
        a = _px(fx, y)
        b = _px(fx + span * 0.85, y + hgt)
        draw.rectangle([a[0], a[1], b[0], b[1]], fill=0 if bit else 255)
        if not bit:
            draw.rectangle([a[0], a[1], b[0], b[1]], outline=200, width=1)
    return {"x": round(x0, 5), "y": round(y, 5), "w": round(x1 - x0, 5),
            "h": round(hgt, 5), "cells": cells, "bits": PAGEID_BITS}


def _content_rect():
    top = TOP_MARGIN + 0.005
    bot = 1 - BOT_MARGIN - 0.005
    x0, x1 = LR_MARGIN + 0.01, 1 - LR_MARGIN - 0.01
    return _px(x0, top), _px(x1, bot)


def _draw_content(draw, kind):
    (cx0, cy0), (cx1, cy1) = _content_rect()
    cw, ch = cx1 - cx0, cy1 - cy0
    ink = _ref(0.08)
    if kind == "novel":                         # dense text lines
        y = cy0 + 10
        for i in range((ch - 20) // 40):
            w = int(cw * (0.55 + 0.4 * ((i * 37) % 100) / 100.0))
            draw.rectangle([cx0 + 6, y, cx0 + 6 + w, y + 12], fill=ink)
            y += 40
    elif kind == "graphic":                     # graphic-novel gray panels
        draw.rectangle([cx0, cy0, cx1, cy0 + ch // 2 - 8], fill=_ref(0.35))
        draw.rectangle([cx0, cy0, cx1, cy0 + ch // 2 - 8], outline=0, width=4)
        draw.rectangle([cx0, cy0 + ch // 2 + 8, cx0 + cw // 2 - 8, cy1],
                       fill=_ref(0.6))
        draw.rectangle([cx0 + cw // 2 + 8, cy0 + ch // 2 + 8, cx1, cy1],
                       fill=_ref(0.15))
        for r in (cx0, cx0 + cw // 2 + 8):
            draw.rectangle([r, cy0 + ch // 2 + 8,
                            r + (cw // 2 - 8), cy1], outline=0, width=4)
    elif kind == "textbook":                    # text + a figure + caption
        y = cy0 + 10
        for i in range(6):
            draw.rectangle([cx0 + 6, y, cx0 + 6 + int(cw * 0.9), y + 12], fill=ink)
            y += 40
        fy0 = y + 20
        draw.rectangle([cx0 + cw // 6, fy0, cx0 + 5 * cw // 6, fy0 + ch // 3],
                       fill=_ref(0.5), outline=0, width=3)
        cap = fy0 + ch // 3 + 20
        draw.rectangle([cx0 + cw // 4, cap, cx0 + 3 * cw // 4, cap + 12], fill=ink)
    elif kind == "blank":                       # mainly blank
        draw.rectangle([cx0 + cw // 3, cy0 + 12, cx0 + 2 * cw // 3, cy0 + 24],
                       fill=ink)
    elif kind == "ux":                          # menu overlay over dim content
        draw.rectangle([cx0, cy0, cx1, cy1], fill=_ref(0.9))    # dimmed bg
        mx0, my0 = cx0 + cw // 5, cy0 + ch // 5
        mx1, my1 = cx1 - cw // 5, cy1 - ch // 5
        draw.rectangle([mx0, my0, mx1, my1], fill=_ref(0.98), outline=0, width=3)
        y = my0 + 24
        while y < my1 - 30:
            draw.rectangle([mx0 + 20, y, mx1 - 20, y + 14], fill=ink)
            draw.line([mx0 + 10, y + 30, mx1 - 10, y + 30], fill=_ref(0.7))
            y += 52
    elif kind == "index":                       # sparse single-column list
        y = cy0 + 20
        for i in range(10):
            w = int(cw * (0.3 + 0.2 * ((i * 53) % 100) / 100.0))
            draw.rectangle([cx0 + 6, y, cx0 + 6 + w, y + 12], fill=ink)
            y += 80
    # sync_black / sync_white handled by full-page fill before margins


def render_page(page: Page) -> Image.Image:
    if page.kind == "sync_black":
        return Image.new("L", (W, H), 0)
    if page.kind == "sync_white":
        return Image.new("L", (W, H), 255)
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)
    _draw_content(d, page.kind)
    _fiducials(d)
    _patch_strip(d)
    _pageid(d, page.pid)
    return img


# The sequence: opening sync flashes, then adjacent pairs that stress the
# driver differently. Transition `pair` labels drive the analyzer's expectations.
SEQUENCE = [
    "sync_black", "sync_white", "sync_black", "sync_white",   # zero the clock
    "blank", "novel", "novel", "graphic", "graphic", "textbook",
    "novel", "blank", "index", "index", "ux", "novel",
    "graphic", "novel", "blank",
]

# which transitions are the interesting stress cases (for analyzer weighting)
STRESS = {
    ("novel", "blank"): ["ghost"],       # text -> white: worst ghost-on-white
    ("graphic", "novel"): ["ghost"],     # image -> text: worst ghost-on-text
    ("blank", "novel"): ["settle"],
    ("novel", "graphic"): ["flash", "settle"],
    ("graphic", "graphic"): ["ghost"],
    ("index", "ux"): ["flash"],          # UX overlay open
    ("ux", "novel"): ["settle"],         # UX close
}


def build_pages():
    pages = []
    for i, kind in enumerate(SEQUENCE):
        pages.append(Page(index=i, kind=kind, pid=i))
    return pages


def build_manifest(pages):
    tmp = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(tmp)
    markers = {"fiducials": _fiducials(d), "patches": _patch_strip(d),
               "pageid": _pageid(d, 0)}
    transitions = []
    for a, b in zip(pages, pages[1:]):
        pair = f"{a.kind}->{b.kind}"
        transitions.append({
            "from": a.index, "to": b.index, "from_kind": a.kind,
            "to_kind": b.kind, "pair": pair,
            "stress": STRESS.get((a.kind, b.kind), []),
            "is_sync": a.kind.startswith("sync") or b.kind.startswith("sync"),
        })
    return {
        "resolution": [W, H],
        "markers": markers,
        "pages": [{"index": p.index, "kind": p.kind, "pid": p.pid} for p in pages],
        "transitions": transitions,
    }


# ---- fixed-layout epub3 packaging -------------------------------------------

def _opf(pages):
    items, spine = [], []
    for p in pages:
        items.append(f'    <item id="pg{p.index}" href="page_{p.index:03d}.xhtml" '
                     f'media-type="application/xhtml+xml"/>')
        items.append(f'    <item id="im{p.index}" href="img/page_{p.index:03d}.png" '
                     f'media-type="image/png"/>')
        spine.append(f'    <itemref idref="pg{p.index}"/>')
    return f'''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">wilkbook-optics-testcard</dc:identifier>
    <dc:title>wilkbook optics test card</dc:title>
    <dc:language>en</dc:language>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">portrait</meta>
  </metadata>
  <manifest>
{chr(10).join(items)}
  </manifest>
  <spine>
{chr(10).join(spine)}
  </spine>
</package>'''


def _xhtml(index):
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><meta charset="utf-8"/>
<meta name="viewport" content="width={W}, height={H}"/>
<style>html,body{{margin:0;padding:0}}img{{width:{W}px;height:{H}px;display:block}}</style>
</head>
<body><img src="img/page_{index:03d}.png" alt="page {index}"/></body>
</html>'''


CONTAINER = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"
    media-type="application/oebps-package+xml"/></rootfiles>
</container>'''


def build(outdir):
    os.makedirs(outdir, exist_ok=True)
    pages = build_pages()
    manifest = build_manifest(pages)
    with open(os.path.join(outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    epub_path = os.path.join(outdir, "optics-testcard.epub")
    with zipfile.ZipFile(epub_path, "w", zipfile.ZIP_DEFLATED) as z:
        # mimetype must be first and stored (uncompressed)
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip",
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/content.opf", _opf(pages))
        for p in pages:
            img = render_page(p)
            import io
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            z.writestr(f"OEBPS/img/page_{p.index:03d}.png", buf.getvalue())
            z.writestr(f"OEBPS/page_{p.index:03d}.xhtml", _xhtml(p.index))
    return epub_path, os.path.join(outdir, "manifest.json")


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "build/testcard"
    epub, man = build(out)
    print(f"wrote {epub}")
    print(f"wrote {man}  ({len(build_pages())} pages)")
