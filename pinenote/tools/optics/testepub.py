"""Self-calibrating test epub generator for the optics harness.

Produces crafted full-page images -- content per the transition taxonomy plus
baked-in calibration markers (corner fiducials for homography, a gray-step
reference strip for photometry, a page-ID barcode) and an opening black/white
sync sequence -- packaged as a fixed-layout epub3 that KOReader pages through
one image per turn. Also emits manifest.json describing marker geometry (as
page fractions, so ingest is resolution-independent) and the labelled page
sequence + transition pairs the analyzer scores.

Card v2 (PLAN.md section 2, items 1-3):
  * content is pid-varied -- every kind (except blank) derives a coarse,
    human-visible layout variation arithmetically from the pid, so same-kind
    adjacent pages differ at a glance (real signal on same-kind STRESS pairs);
  * every content page carries human-visible page marks -- a large 7-segment
    page number bottom-right and a parity tile alternating corners -- whose
    footprints are published in manifest['markers']['reserved'] so ingest can
    exclude them from ghost/white/clean masks (a number that legitimately
    changes every page must not read as ghost);
  * the sequence is the sync block + THREE repetitions of the stress
    sub-sequence, with unique pids throughout (pid = sequence index) and
    per-transition 'rep' labels so the analyzer can aggregate each kind-pair
    across repetitions (mean/sigma/worst).

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
# LANDSCAPE-native card (2026-07-11): the panel's fb is natively 1872x1404,
# and KOReader-side rotation to portrait WEDGES the rockchip_ebc driver (first
# portrait refresh leaves the panel unresponsive to all fb writes until a
# module reload -- live-reproduced twice; see doc/driver-findings-report.md).
# A landscape card on the native-landscape screen needs no rotation at all and
# fills the panel edge to edge. All marker geometry is fractional, so ingest
# and the camera are orientation-agnostic.
W, H = 1872, 1404

# marker geometry as fractions of (W,H) -- the single source of truth, copied
# into the manifest so ingest and generator can never disagree.
FID = 0.045                      # fiducial square side (fraction of min dim)
INSET = 0.020                    # corner inset
PATCH_REFL = [0.0, 0.25, 0.5, 0.75, 1.0]   # gray-step strip, black..white
TOP_MARGIN = 0.075               # holds the patch strip
BOT_MARGIN = 0.055               # holds the page-id barcode
LR_MARGIN = 0.030
PAGEID_BITS = 8

# human-visible page marks (page number + parity tile); their footprints are
# published in manifest['markers']['reserved'] for mask exclusion at ingest.
PAGENUM_H = 0.11         # 7-seg digit height, fraction of page height (0.10-0.12)
PAGENUM_ASPECT = 0.55    # digit width as a multiple of digit height (in pixels)
PAGENUM_MAX_DIGITS = 3   # field sized for any PAGEID_BITS=8 pid (0..255)
PARITY_SIZE = 0.030      # parity tile side, fraction of page height
RESERVE_PAD = 0.006      # margin baked into the reserved rects around the marks


def _px(fx, fy):
    return int(round(fx * W)), int(round(fy * H))


@dataclass
class Page:
    index: int
    kind: str
    pid: int
    img: Image.Image = None
    rep: int = None          # stress-block repetition (None for sync pages)


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


def content_rect_f():
    """The content area as page fractions (x0, y0, x1, y1)."""
    return (LR_MARGIN + 0.01, TOP_MARGIN + 0.005,
            1 - LR_MARGIN - 0.01, 1 - BOT_MARGIN - 0.005)


def _content_rect():
    x0, y0, x1, y1 = content_rect_f()
    return _px(x0, y0), _px(x1, y1)


def _pads():
    """Reserved-rect padding as (x, y) fractions -- square in pixels."""
    return RESERVE_PAD * H / W, RESERVE_PAD


def _reserved_rects():
    """Fractional rects reserved for the human-visible page marks: the 7-seg
    page number (bottom-right) and BOTH parity-tile corners (top-left /
    top-right of the content area; the tile alternates by pid parity). Ingest
    must exclude these from ghost/white/clean masks -- a mark that legitimately
    changes every page must not read as ghost. All three rects live INSIDE the
    content rect with standoffs from its edges, so they can never overlap the
    margin markers (fiducials, patch strip, barcode) and stay clear of the
    camera-space fiducial search windows near the page corners."""
    x0, top, x1, bot = content_rect_f()
    padx, pady = _pads()
    dh = PAGENUM_H
    dw = PAGENUM_ASPECT * dh * H / W
    gap = 0.25 * dw
    field_w = PAGENUM_MAX_DIGITS * dw + (PAGENUM_MAX_DIGITS - 1) * gap
    num = {"x": x1 - 0.012 - (field_w + 2 * padx),
           "y": bot - 0.022 - (dh + 2 * pady),
           "w": field_w + 2 * padx, "h": dh + 2 * pady, "what": "pagenum"}
    tw, th = PARITY_SIZE * H / W + 2 * padx, PARITY_SIZE + 2 * pady
    pa = {"x": x0 + 0.012, "y": top + 0.012, "w": tw, "h": th,
          "what": "parity_a"}
    pb = {"x": x1 - 0.012 - tw, "y": top + 0.012, "w": tw, "h": th,
          "what": "parity_b"}
    return [{k: (round(v, 5) if isinstance(v, float) else v)
             for k, v in r.items()} for r in (num, pa, pb)]


# segments lit per digit; standard 7-segment layout (a=top, b=top-right,
# c=bottom-right, d=bottom, e=bottom-left, f=top-left, g=middle)
_SEG7 = {"0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
         "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg"}


def _draw_7seg(draw, digit, x0, y0, x1, y1):
    """One solid-black 7-segment digit filling the pixel box."""
    t = max(2, int(round(0.16 * (y1 - y0))))
    ym = (y0 + y1) // 2
    seg = {"a": [x0, y0, x1, y0 + t], "b": [x1 - t, y0, x1, ym],
           "c": [x1 - t, ym, x1, y1], "d": [x0, y1 - t, x1, y1],
           "e": [x0, ym, x0 + t, y1], "f": [x0, y0, x0 + t, ym],
           "g": [x0, ym - t // 2, x1, ym - t // 2 + t]}
    for s in _SEG7[digit]:
        draw.rectangle(seg[s], fill=0)


def _page_marks(draw, pid):
    """Human-visible page marks, drawn over content inside the reserved rects
    (_reserved_rects is the single source of truth, copied into the manifest):
    a large right-aligned 7-seg page number bottom-right plus a solid black
    parity tile that alternates corners (even pid -> parity_a top-left, odd ->
    parity_b top-right), so a live operator can SEE pages turning and video
    review can verify dwell per page."""
    if not 0 <= pid < 10 ** PAGENUM_MAX_DIGITS:
        raise ValueError(f"pid {pid} does not fit the page-number field")
    num, pa, pb = _reserved_rects()
    padx, pady = _pads()
    dh = num["h"] - 2 * pady
    dw = PAGENUM_ASPECT * dh * H / W
    gap = 0.25 * dw
    xr = num["x"] + num["w"] - padx           # digits right-aligned in the field
    for k, digit in enumerate(reversed(str(pid))):
        a = _px(xr - k * (dw + gap) - dw, num["y"] + pady)
        b = _px(xr - k * (dw + gap), num["y"] + pady + dh)
        _draw_7seg(draw, digit, a[0], a[1], b[0], b[1])
    tile = pa if pid % 2 == 0 else pb
    a = _px(tile["x"] + padx, tile["y"] + pady)
    b = _px(tile["x"] + tile["w"] - padx, tile["y"] + tile["h"] - pady)
    draw.rectangle([a[0], a[1], b[0], b[1]], fill=0)


def _draw_content(draw, kind, pid=0):
    """Content for one page `kind`, varied deterministically by `pid`.

    Every kind (except blank, which stays blank -- its turns are made visible
    by the page marks) renders a coarse, human-visible layout variation
    derived arithmetically from `pid` -- no RNG, no shared state -- so
    same-kind adjacent pages differ at a glance: real ghost signal on the
    same-kind STRESS pairs, and a live operator can tell pages are turning.
    Moduli are chosen so adjacent pids always differ and stress-block repeats
    (pid step = 15) don't alias back to an identical layout."""
    (cx0, cy0), (cx1, cy1) = _content_rect()
    cw, ch = cx1 - cx0, cy1 - cy0
    ink = _ref(0.08)
    if kind == "novel":                         # dense text lines
        # pid shifts every line's length phase and moves a paragraph break
        # (an empty line slot + an indented next line) down the page.
        n = max(1, (ch - 20) // 40)
        brk = 2 + (pid * 3) % max(1, n - 3)
        y = cy0 + 10
        for i in range(n):
            if i == brk:
                y += 40                          # paragraph gap
                continue
            indent = 40 if i == brk + 1 else 0
            w = int(cw * (0.55 + 0.4 * ((i * 37 + pid * 53) % 100) / 100.0))
            w = min(w, cw - 12 - indent)
            draw.rectangle([cx0 + 6 + indent, y, cx0 + 6 + indent + w, y + 12],
                           fill=ink)
            y += 40
    elif kind == "graphic":                     # graphic-novel gray panels
        # pid rotates the three panel gray levels (mod-4 fold so repeats of
        # the stress block don't alias) and flips which half holds the
        # full-width panel (mod 2, so adjacent pids always swap).
        g = [0.35, 0.6, 0.15]
        r = (pid % 4) % 3
        g = g[r:] + g[:r]
        mid_top, mid_bot = cy0 + ch // 2 - 8, cy0 + ch // 2 + 8
        halves = [(cx0, cx0 + cw // 2 - 8), (cx0 + cw // 2 + 8, cx1)]
        if pid % 2 == 0:                        # full panel top, halves bottom
            draw.rectangle([cx0, cy0, cx1, mid_top], fill=_ref(g[0]))
            draw.rectangle([cx0, cy0, cx1, mid_top], outline=0, width=4)
            for (hx0, hx1), lv in zip(halves, g[1:]):
                draw.rectangle([hx0, mid_bot, hx1, cy1], fill=_ref(lv))
                draw.rectangle([hx0, mid_bot, hx1, cy1], outline=0, width=4)
        else:                                   # halves top, full panel bottom
            for (hx0, hx1), lv in zip(halves, g[1:]):
                draw.rectangle([hx0, cy0, hx1, mid_top], fill=_ref(lv))
                draw.rectangle([hx0, cy0, hx1, mid_top], outline=0, width=4)
            draw.rectangle([cx0, mid_bot, cx1, cy1], fill=_ref(g[0]))
            draw.rectangle([cx0, mid_bot, cx1, cy1], outline=0, width=4)
    elif kind == "textbook":                    # text + a figure + caption
        # pid moves the figure among three vertical slots (mod-7 fold so the
        # slot also varies across stress-block repeats).
        slot = (pid % 7) % 3
        edges = [cy0 + k * ch // 3 for k in range(4)]
        for k in range(3):
            if k == slot:
                fy0, fy1 = edges[k] + 12, edges[k + 1] - 8
                draw.rectangle([cx0 + cw // 6, fy0,
                                cx0 + 5 * cw // 6, fy1 - 26],
                               fill=_ref(0.5), outline=0, width=3)
                draw.rectangle([cx0 + cw // 4, fy1 - 18,
                                cx0 + 3 * cw // 4, fy1 - 6], fill=ink)
            else:
                y = edges[k] + 12
                while y + 12 <= edges[k + 1] - 8:
                    draw.rectangle([cx0 + 6, y, cx0 + 6 + int(cw * 0.9), y + 12],
                                   fill=ink)
                    y += 40
    elif kind == "blank":                       # mainly blank (pid-invariant)
        draw.rectangle([cx0 + cw // 3, cy0 + 12, cx0 + 2 * cw // 3, cy0 + 24],
                       fill=ink)
    elif kind == "ux":                          # menu overlay over dim content
        draw.rectangle([cx0, cy0, cx1, cy1], fill=_ref(0.9))    # dimmed bg
        # pid nudges the menu widget around (mod 4 in x, mod 7 in y: adjacent
        # pids and stress-block repeats both move it).
        dx = ((pid % 4) * 2 - 3) * cw // 16
        dy = ((pid % 7) - 3) * ch // 24
        mx0, my0 = cx0 + cw // 5 + dx, cy0 + ch // 5 + dy
        mx1, my1 = cx1 - cw // 5 + dx, cy1 - ch // 5 + dy
        draw.rectangle([mx0, my0, mx1, my1], fill=_ref(0.98), outline=0, width=3)
        y = my0 + 24
        while y < my1 - 30:
            draw.rectangle([mx0 + 20, y, mx1 - 20, y + 14], fill=ink)
            draw.line([mx0 + 10, y + 30, mx1 - 10, y + 30], fill=_ref(0.7))
            y += 52
    elif kind == "index":                       # sparse single-column list
        # pid varies the entry count, the start offset, and the width phase.
        n = 6 + (pid % 5) * 2
        y = cy0 + 20 + (pid % 4) * (ch // 24)
        step = max(40, (cy1 - y - 20) // n)
        for i in range(n):
            if y + 12 > cy1 - 8:
                break
            w = int(cw * (0.3 + 0.2 * ((i * 53 + pid * 29) % 100) / 100.0))
            draw.rectangle([cx0 + 6, y, cx0 + 6 + w, y + 12], fill=ink)
            y += step
    # sync_black / sync_white handled by full-page fill before margins


def render_page(page: Page) -> Image.Image:
    if page.kind == "sync_black":
        return Image.new("L", (W, H), 0)
    if page.kind == "sync_white":
        return Image.new("L", (W, H), 255)
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)
    _draw_content(d, page.kind, page.pid)
    _page_marks(d, page.pid)
    _fiducials(d)
    _patch_strip(d)
    _pageid(d, page.pid)
    return img


def render_kind(kind, pid=0):
    """Render a page by (kind, pid) -- the render contract downstream
    components (ingest/analyze re-rendering of intended pages) are adopting.
    Returns the PIL image at the current module resolution; divide by 255.0
    for the reflectance convention. Sync kinds ignore pid."""
    return render_page(Page(index=0, kind=kind, pid=pid))


# The sequence: an opening sync block that zeroes the clock, then THREE
# repetitions of the stress sub-sequence -- adjacent pairs that stress the
# driver differently; transition `pair` labels drive the analyzer's
# expectations, and the per-transition `rep` label (0/1/2) lets it aggregate
# each kind-pair across repetitions. Kinds repeat but every page keeps a
# unique pid (= its sequence index; PAGEID_BITS=8 leaves 256-pid headroom).
# Each repetition holds two fully-in-rep ('novel','blank') adjacent pairs
# (block offsets 6->7 and 13->14).
SYNC_BLOCK = ["sync_black", "sync_white", "sync_black", "sync_white"]
STRESS_BLOCK = [
    "blank", "novel", "novel", "graphic", "graphic", "textbook",
    "novel", "blank", "index", "index", "ux", "novel",
    "graphic", "novel", "blank",
]
STRESS_REPEATS = 3
SEQUENCE = SYNC_BLOCK + STRESS_BLOCK * STRESS_REPEATS

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
    n_sync = len(SYNC_BLOCK)
    pages = []
    for i, kind in enumerate(SEQUENCE):
        rep = None if i < n_sync else (i - n_sync) // len(STRESS_BLOCK)
        pages.append(Page(index=i, kind=kind, pid=i, rep=rep))
    return pages


def build_manifest(pages):
    tmp = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(tmp)
    markers = {"fiducials": _fiducials(d), "patches": _patch_strip(d),
               "pageid": _pageid(d, 0),
               # footprints of the per-page human-visible marks (page number +
               # both parity-tile corners): ingest must EXCLUDE these from
               # ghost/white/clean masks -- they legitimately change every page.
               "reserved": _reserved_rects()}
    transitions = []
    for a, b in zip(pages, pages[1:]):
        pair = f"{a.kind}->{b.kind}"
        is_sync = a.kind.startswith("sync") or b.kind.startswith("sync")
        transitions.append({
            "from": a.index, "to": b.index, "from_kind": a.kind,
            "to_kind": b.kind, "pair": pair,
            "stress": STRESS.get((a.kind, b.kind), []),
            "is_sync": is_sync,
            # a transition belongs to the repetition its DESTINATION page
            # lands in (the wash is scored on the arriving page; this also
            # assigns the rep-boundary blank->blank turns unambiguously).
            # Sync-adjacent transitions carry null.
            "rep": None if is_sync else b.rep,
        })
    return {
        "resolution": [W, H],
        "markers": markers,
        "pages": [{"index": p.index, "kind": p.kind, "pid": p.pid,
                   "rep": p.rep} for p in pages],
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
