#!/usr/bin/env python3
"""Generate a fixed-layout PineNote touch-coordinate calibration EPUB.

The single 1404x1872 portrait page is a full-resolution grayscale PNG, using
the same KOReader-proven packaging pattern as the optics test EPUB.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import io
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image, ImageDraw, ImageFont


WIDTH = 1404
HEIGHT = 1872
EDGE_INSET = 96
DEFAULT_OUTPUT = Path("/tmp/wilkbook/pinenote-touch-targets.epub")

# Minimal visual system for the calibration sheet.  All generated tones,
# strokes, and text scales come from these tokens; geometry is panel-space.
PAPER = 255
INK = 0
GRID = 184
GRID_MAJOR = 112
STROKE_BORDER = 4
STROKE_GRID = 2
STROKE_GRID_MAJOR = 3
STROKE_CROSSHAIR = 8
STROKE_RING = 4
TEXT_SCALE_TARGET = 2
TEXT_SCALE_RULER = 1
TEXT_SCALE_EDGE = 2
TARGET_CLEAR_RADIUS = 62
TARGET_OUTER_RADIUS = 46
TARGET_INNER_RADIUS = 24
TARGET_CROSSHAIR_HALF = 56
TARGET_DOT_RADIUS = 7
LABEL_WIDTH = 230
LABEL_HEIGHT = 34
LABEL_GAP = 56

MIMETYPE = "application/epub+zip"
PAGE_PATH = "OEBPS/page.xhtml"
IMAGE_PATH = "OEBPS/img/page.png"
REQUIRED_MEMBERS = (
    "mimetype",
    "META-INF/container.xml",
    "OEBPS/content.opf",
    "OEBPS/nav.xhtml",
    IMAGE_PATH,
    PAGE_PATH,
)
XML_MEMBERS = (
    "META-INF/container.xml",
    "OEBPS/content.opf",
    "OEBPS/nav.xhtml",
    PAGE_PATH,
)
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


@dataclass(frozen=True)
class Target:
    target_id: str
    x: int
    y: int
    role: str


# The center is also the center quarter-grid intersection.  It appears once,
# leaving 17 unique test points rather than two coincident targets.
TARGETS = (
    Target("T01", 702, 936, "center quarter-grid"),
    Target("T02", EDGE_INSET, EDGE_INSET, "inset corner top-left"),
    Target("T03", WIDTH - EDGE_INSET, EDGE_INSET, "inset corner top-right"),
    Target("T04", WIDTH - EDGE_INSET, HEIGHT - EDGE_INSET,
           "inset corner bottom-right"),
    Target("T05", EDGE_INSET, HEIGHT - EDGE_INSET,
           "inset corner bottom-left"),
    Target("T06", WIDTH // 2, EDGE_INSET, "edge midpoint top"),
    Target("T07", WIDTH - EDGE_INSET, HEIGHT // 2, "edge midpoint right"),
    Target("T08", WIDTH // 2, HEIGHT - EDGE_INSET, "edge midpoint bottom"),
    Target("T09", EDGE_INSET, HEIGHT // 2, "edge midpoint left"),
    Target("T10", WIDTH // 4, HEIGHT // 4, "quarter-grid"),
    Target("T11", WIDTH // 2, HEIGHT // 4, "quarter-grid"),
    Target("T12", 3 * WIDTH // 4, HEIGHT // 4, "quarter-grid"),
    Target("T13", WIDTH // 4, HEIGHT // 2, "quarter-grid"),
    Target("T14", 3 * WIDTH // 4, HEIGHT // 2, "quarter-grid"),
    Target("T15", WIDTH // 4, 3 * HEIGHT // 4, "quarter-grid"),
    Target("T16", WIDTH // 2, 3 * HEIGHT // 4, "quarter-grid"),
    Target("T17", 3 * WIDTH // 4, 3 * HEIGHT // 4, "quarter-grid"),
)


CONTAINER_XML = '''<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
      media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''

CONTENT_OPF = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
  unique-identifier="uid" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:wilkbook:pinenote-touch-targets:v1</dc:identifier>
    <dc:title>PineNote touch targets</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-07-19T00:00:00Z</meta>
    <meta property="rendition:layout">pre-paginated</meta>
    <meta property="rendition:orientation">portrait</meta>
    <meta property="rendition:spread">none</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"
      properties="nav"/>
    <item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>
    <item id="image" href="img/page.png" media-type="image/png"/>
  </manifest>
  <spine page-progression-direction="ltr">
    <itemref idref="page"
      properties="rendition:layout-pre-paginated rendition:orientation-portrait rendition:spread-none"/>
  </spine>
</package>
'''

NAV_XHTML = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"
  xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>PineNote touch targets</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>Contents</h1>
    <ol><li><a href="page.xhtml">Calibration target</a></li></ol>
  </nav>
</body>
</html>
'''


def _target_label_position(target: Target) -> tuple[int, int]:
    """Place labels below centers, clamped inside the page perimeter."""
    x = max(8, min(WIDTH - LABEL_WIDTH - 8, target.x - LABEL_WIDTH // 2))
    y = target.y + LABEL_GAP
    if y + LABEL_HEIGHT > HEIGHT - 40:
        y = target.y - LABEL_GAP - LABEL_HEIGHT
    return x, y


_FONT = ImageFont.load_default()


def _text_mask(text: str, scale: int) -> Image.Image:
    """Return a deterministic, nearest-scaled mask using Pillow's built-in font."""
    bbox = _FONT.getbbox(text)
    width = max(1, bbox[2] - bbox[0] + 1)
    height = max(1, bbox[3] - bbox[1])
    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    draw.text((-bbox[0], -bbox[1]), text, font=_FONT, fill=255)
    if scale != 1:
        mask = mask.resize((mask.width * scale, mask.height * scale),
                           Image.Resampling.NEAREST)
    return mask


def _draw_text(image: Image.Image, text: str, center: tuple[int, int],
               scale: int, rotation: int = 0) -> None:
    mask = _text_mask(text, scale)
    if rotation == 90:
        mask = mask.transpose(Image.Transpose.ROTATE_90)
    elif rotation == -90:
        mask = mask.transpose(Image.Transpose.ROTATE_270)
    x = center[0] - mask.width // 2
    y = center[1] - mask.height // 2
    image.paste(INK, (x, y), mask)


def _draw_grid(draw: ImageDraw.ImageDraw) -> None:
    for x in (WIDTH // 4, WIDTH // 2, 3 * WIDTH // 4):
        tone = GRID_MAJOR if x == WIDTH // 2 else GRID
        width = STROKE_GRID_MAJOR if x == WIDTH // 2 else STROKE_GRID
        draw.line((x, 0, x, HEIGHT - 1), fill=tone, width=width)
    for y in (HEIGHT // 4, HEIGHT // 2, 3 * HEIGHT // 4):
        tone = GRID_MAJOR if y == HEIGHT // 2 else GRID
        width = STROKE_GRID_MAJOR if y == HEIGHT // 2 else STROKE_GRID
        draw.line((0, y, WIDTH - 1, y), fill=tone, width=width)


def _draw_rulers(image: Image.Image, draw: ImageDraw.ImageDraw) -> None:
    for x in range(0, WIDTH + 1, 117):
        length = 24 if x % (WIDTH // 4) == 0 else 12
        draw.line((x, 0, x, length), fill=INK, width=STROKE_BORDER)
        draw.line((x, HEIGHT - 1, x, HEIGHT - 1 - length),
                  fill=INK, width=STROKE_BORDER)
    for y in range(0, HEIGHT + 1, 117):
        length = 24 if y % (HEIGHT // 4) == 0 else 12
        draw.line((0, y, length, y), fill=INK, width=STROKE_BORDER)
        draw.line((WIDTH - 1, y, WIDTH - 1 - length, y),
                  fill=INK, width=STROKE_BORDER)

    for x in (0, WIDTH // 4, WIDTH // 2, 3 * WIDTH // 4, WIDTH):
        inset_x = 26 if x == 0 else WIDTH - 30 if x == WIDTH else x
        _draw_text(image, f"x={x}", (inset_x, HEIGHT - 11), TEXT_SCALE_RULER)
    for y in (0, HEIGHT // 4, HEIGHT // 2, 3 * HEIGHT // 4, HEIGHT):
        label = HEIGHT - 1 if y == HEIGHT else y
        text_y = 12 if y == 0 else HEIGHT - 30 if y == HEIGHT else y - 10
        _draw_text(image, f"y={label}", (30, text_y), TEXT_SCALE_RULER)


def _draw_target(image: Image.Image, draw: ImageDraw.ImageDraw,
                 target: Target) -> None:
    x, y = target.x, target.y
    r = TARGET_CLEAR_RADIUS
    draw.ellipse((x - r, y - r, x + r, y + r), fill=PAPER)
    draw.line((x - TARGET_CROSSHAIR_HALF, y, x + TARGET_CROSSHAIR_HALF, y),
              fill=INK, width=STROKE_CROSSHAIR)
    draw.line((x, y - TARGET_CROSSHAIR_HALF, x, y + TARGET_CROSSHAIR_HALF),
              fill=INK, width=STROKE_CROSSHAIR)
    for radius in (TARGET_OUTER_RADIUS, TARGET_INNER_RADIUS):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius),
                     outline=INK, width=STROKE_RING)
    r = TARGET_DOT_RADIUS
    draw.ellipse((x - r, y - r, x + r, y + r), fill=INK)

    label_x, label_y = _target_label_position(target)
    draw.rectangle((label_x, label_y, label_x + LABEL_WIDTH - 1,
                    label_y + LABEL_HEIGHT - 1), fill=PAPER, outline=INK, width=2)
    _draw_text(image, f"{target.target_id}  ({x},{y})",
               (label_x + LABEL_WIDTH // 2, label_y + LABEL_HEIGHT // 2),
               TEXT_SCALE_TARGET)


def render_page() -> Image.Image:
    image = Image.new("L", (WIDTH, HEIGHT), PAPER)
    draw = ImageDraw.Draw(image)
    _draw_grid(draw)
    _draw_rulers(image, draw)
    draw.rectangle((2, 2, WIDTH - 3, HEIGHT - 3), outline=INK,
                   width=STROKE_BORDER)
    _draw_text(image, "PHYSICAL TOP / LOGICAL Y=0", (WIDTH // 2, 19),
               TEXT_SCALE_EDGE)
    _draw_text(image, "BOTTOM / LOGICAL Y=1871", (WIDTH // 2, HEIGHT - 31),
               TEXT_SCALE_EDGE)
    _draw_text(image, "LEFT / LOGICAL X=0", (34, HEIGHT // 2 - 190),
               TEXT_SCALE_EDGE, rotation=-90)
    _draw_text(image, "RIGHT / LOGICAL X=1403", (WIDTH - 35, HEIGHT // 2 + 190),
               TEXT_SCALE_EDGE, rotation=90)
    for target in TARGETS:
        _draw_target(image, draw, target)
    return image


def page_xhtml() -> str:
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><meta charset="utf-8"/>
<meta name="viewport" content="width={WIDTH}, height={HEIGHT}"/>
<style>html,body{{margin:0;padding:0}}img{{width:100%;height:100%;display:block}}</style>
</head>
<body><img src="img/page.png" alt="PineNote touch-coordinate calibration page"/></body>
</html>
'''


def _zip_info(name: str, compress_type: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
    info.compress_type = compress_type
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info


def _write_member(archive: zipfile.ZipFile, name: str, content: str,
                  compress_type: int = zipfile.ZIP_DEFLATED) -> None:
    archive.writestr(_zip_info(name, compress_type), content.encode("utf-8"))


def _write_bytes(archive: zipfile.ZipFile, name: str, content: bytes,
                 compress_type: int = zipfile.ZIP_DEFLATED) -> None:
    archive.writestr(_zip_info(name, compress_type), content)


def build(output: Path | str = DEFAULT_OUTPUT) -> Path:
    """Write and self-check the calibration EPUB, returning its path."""
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w") as archive:
        _write_member(archive, "mimetype", MIMETYPE, zipfile.ZIP_STORED)
        _write_member(archive, "META-INF/container.xml", CONTAINER_XML)
        _write_member(archive, "OEBPS/content.opf", CONTENT_OPF)
        _write_member(archive, "OEBPS/nav.xhtml", NAV_XHTML)
        buffer = io.BytesIO()
        render_page().save(buffer, format="PNG", compress_level=9, optimize=False)
        _write_bytes(archive, IMAGE_PATH, buffer.getvalue())
        _write_member(archive, PAGE_PATH, page_xhtml())
    validate(output)
    return output


def validate(epub_path: Path | str) -> None:
    """Verify EPUB packaging, fixed-layout metadata, and target geometry."""
    epub_path = Path(epub_path)
    errors: list[str] = []
    try:
        with zipfile.ZipFile(epub_path) as archive:
            names = archive.namelist()
            if tuple(names) != REQUIRED_MEMBERS:
                errors.append(f"archive members/order {names!r}")
            if not names or names[0] != "mimetype":
                errors.append("mimetype is not the first archive member")
            elif archive.getinfo("mimetype").compress_type != zipfile.ZIP_STORED:
                errors.append("mimetype is compressed")
            if archive.read("mimetype") != MIMETYPE.encode("ascii"):
                errors.append("mimetype content is incorrect")
            bad_member = archive.testzip()
            if bad_member is not None:
                errors.append(f"CRC failure in {bad_member}")

            parsed = {}
            for name in XML_MEMBERS:
                try:
                    parsed[name] = ET.fromstring(archive.read(name))
                except ET.ParseError as exc:
                    errors.append(f"invalid XML in {name}: {exc}")
            if errors:
                raise ValueError("; ".join(errors))

            opf = parsed["OEBPS/content.opf"]
            opf_ns = {"opf": "http://www.idpf.org/2007/opf"}
            properties = {
                node.get("property"): (node.text or "").strip()
                for node in opf.findall(".//opf:meta", opf_ns)
            }
            expected_properties = {
                "rendition:layout": "pre-paginated",
                "rendition:orientation": "portrait",
                "rendition:spread": "none",
            }
            for key, value in expected_properties.items():
                if properties.get(key) != value:
                    errors.append(f"missing OPF metadata {key}={value}")
            spine_refs = opf.findall(".//opf:spine/opf:itemref", opf_ns)
            if len(spine_refs) != 1 or spine_refs[0].get("idref") != "page":
                errors.append("spine is not exactly the single calibration page")
            image_items = opf.findall('.//opf:item[@media-type="image/png"]', opf_ns)
            if len(image_items) != 1 or image_items[0].get("href") != "img/page.png":
                errors.append("OPF does not declare exactly img/page.png as image/png")

            page = parsed[PAGE_PATH]
            xhtml_ns = {"x": "http://www.w3.org/1999/xhtml"}
            viewport = page.find('.//x:meta[@name="viewport"]', xhtml_ns)
            if viewport is None or viewport.get("content") != f"width={WIDTH}, height={HEIGHT}":
                errors.append("viewport is not exactly 1404x1872")
            images = page.findall(".//x:img", xhtml_ns)
            if len(images) != 1 or images[0].get("src") != "img/page.png":
                errors.append("XHTML does not contain exactly one img/page.png image")
            page_source = archive.read(PAGE_PATH).decode("utf-8")
            if "<svg" in page_source.lower():
                errors.append("XHTML still contains SVG")
            proven_css = "img{width:100%;height:100%;display:block}"
            if proven_css not in page_source:
                errors.append("XHTML is missing the proven full-page image CSS")

            if len({(target.x, target.y) for target in TARGETS}) != len(TARGETS):
                errors.append("target coordinates are not unique")
            try:
                with Image.open(io.BytesIO(archive.read(IMAGE_PATH))) as image:
                    if image.format != "PNG":
                        errors.append("page image does not decode as PNG")
                    image.load()
                    if image.mode != "L":
                        errors.append(f"page image mode is {image.mode}, not grayscale L")
                    if image.size != (WIDTH, HEIGHT):
                        errors.append(f"page image size is {image.size}, not 1404x1872")
                    extrema = image.getextrema()
                    if extrema in ((INK, INK), (PAPER, PAPER)):
                        errors.append(f"page image is degenerate with extrema {extrema}")
                    for target in TARGETS:
                        if image.getpixel((target.x, target.y)) != INK:
                            errors.append(f"target {target.target_id} center is not black")
                        for dx, dy in ((-38, -38), (38, -38), (-38, 38), (38, 38)):
                            if image.getpixel((target.x + dx, target.y + dy)) != PAPER:
                                errors.append(
                                    f"target {target.target_id} control ({dx},{dy}) is not white"
                                )
                        label_x, label_y = _target_label_position(target)
                        label = image.crop((label_x, label_y,
                                            label_x + LABEL_WIDTH,
                                            label_y + LABEL_HEIGHT))
                        if label.getextrema() != (INK, PAPER):
                            errors.append(f"target {target.target_id} label lacks black/white contrast")
            except (OSError, ValueError) as exc:
                errors.append(f"invalid page PNG: {exc}")
    except (KeyError, zipfile.BadZipFile) as exc:
        errors.append(f"invalid EPUB archive: {exc}")

    if errors:
        raise ValueError("EPUB self-check failed: " + "; ".join(errors))


def sha256_file(path: Path | str) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=DEFAULT_OUTPUT,
                        help=f"output EPUB (default: {DEFAULT_OUTPUT})")
    parser.add_argument("--check", action="store_true",
                        help="validate an existing output instead of regenerating it")
    args = parser.parse_args(argv)
    try:
        if args.check:
            validate(args.output)
            output = args.output
        else:
            output = build(args.output)
    except (OSError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"self-check: ok ({len(TARGETS)} targets, {WIDTH}x{HEIGHT}, one page)")
    print(f"output: {output.resolve()}")
    print(f"sha256: {sha256_file(output)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
