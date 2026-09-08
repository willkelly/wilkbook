#!/usr/bin/env python3
"""Read-only successor image/payload and historical role preflight."""

from __future__ import annotations

import csv
import hashlib
import os
from pathlib import Path
import stat
import struct
import sys


SOURCE_ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = Path("/gnu/store/j6i1p44vabm88dxa79f1dyzljzjgzyzc-disk-image")
ORIGINAL_SHA256 = "fd4f2ffffcb401fd0adb8dbb9d614517d967032c3d008a690fdcfbbb2ee8ae73"
ORIGINAL_SIZE = 2063552512
PARTITION_OFFSET = 1048576
PARTITION_SECTORS = 4028328
PREPARED_SHA256 = "74f821db578de134d0e2cd8c8c510dd6bab731c43b07dc729c926c9eadbc3e7d"
BUNDLE_MANIFEST_SHA256 = (
    "bd7151f0c4e729d40c4ed6ef65fe381ad07c30e4e3912089a83bfe0d1849245b"
)
BUNDLE_METADATA_SHA256 = (
    "7f459125d602fe9fac48ad134976d347a92531459cea5f36df59387076508392"
)
AUTHOR_EVIDENCE_SHA256 = (
    "9c6b55822571c5c69f6b06ed48a58f7987cbda53e072b741122995ac7e65cfe8"
)
BINDING_PARAMETERS_SHA256 = (
    "1239c6e2187f66adc81e2faf54bc4e8aeba38a6b42f830985674c65d7a05689e"
)
PAYLOAD_MANIFEST_SHA256 = (
    "dacfad2ad38644c8dd71556c94074f047f9a175c1ff1bc2c8e9d7e65a7a48f2e"
)
BUILD_STATUS_SHA256 = "3efd6b7f6e30e7764f44c7cc6d317d3f27858e7d784850ecdd4c6d56404bc6e7"
PACKET_SHA256 = "e8f79f5a1ecf2c5b3058ffebd36d750fc572af7814a1b0a4be8198cddf16ddaf"
AUTHOR_REPORT_SHA256 = "d9fe224e53bcc11c8bfb8cf1bb80c82a67b997089c097f012a17a2abb5968220"
PAYLOAD = {
    "boot-bundle/extlinux/Image":
        "5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9",
    "boot-bundle/extlinux/extlinux.conf":
        "230308b6312c7d5a0818d6b79b9b307f73a82e0c71c0e9abde9699efd1d9118f",
    "boot-bundle/extlinux/initrd.cpio.gz":
        "e842a865fcee63ae6c6364e64f1493907ccc90e81dc2dacf2edc4eddceb284ad",
    "rootfs.raw": PREPARED_SHA256,
}
OUTER = {
    "BUNDLE.scm": BUNDLE_METADATA_SHA256,
    "PAYLOAD.sha256": PAYLOAD_MANIFEST_SHA256,
    **PAYLOAD,
}

# Retain the accepted V6 role regression.  Neither value is successor authority.
V6_PAYLOAD_MANIFEST_SHA256 = (
    "9d188cd6ef2333ba6c28c515ea6c27748383256026284e8bbe2077e494c5fc82"
)
V6_STATUS_SHA256 = (
    "2099f4ed775f1d8151e547a7388a3bb60b3e89ebe0f3ec1b73fcf1f466873b25"
)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb", buffering=0) as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def manifest_entries(path: Path) -> list[tuple[str, str]]:
    entries = []
    for raw in path.read_bytes().splitlines():
        if len(raw) < 67 or raw[64:66] != b"  ":
            raise AssertionError(f"malformed manifest record: {path}")
        expected = raw[:64].decode("ascii")
        relative = raw[66:].decode("utf-8")
        if len(expected) != 64 or any(character not in "0123456789abcdef"
                                      for character in expected):
            raise AssertionError(f"malformed manifest digest: {path}")
        entries.append((relative, expected))
    return entries


def require_private_immutable_tree(root: Path) -> None:
    if (not root.is_absolute() or root != Path(os.path.realpath(root)) or
            not str(root).startswith("/tmp/opencode/")):
        raise AssertionError("bundle is not one canonical private /tmp/opencode tree")
    expected = {"MANIFEST.sha256", "BUNDLE.scm", "PAYLOAD.sha256", *PAYLOAD}
    actual: set[str] = set()
    for path in [root, *root.rglob("*")]:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise AssertionError(f"bundle contains symlink: {path}")
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o222:
            raise AssertionError(f"bundle entry is not caller-owned immutable: {path}")
        if stat.S_ISREG(info.st_mode):
            relative = str(path.relative_to(root))
            actual.add(relative)
            if info.st_nlink != 1:
                raise AssertionError(f"bundle data is not single-link: {relative}")
        elif not stat.S_ISDIR(info.st_mode):
            raise AssertionError(f"bundle contains special entry: {path}")
    if actual != expected:
        raise AssertionError(f"bundle roster differs: {sorted(actual ^ expected)}")


def mbr_partition(path: Path) -> tuple[int, int, int, int]:
    with path.open("rb", buffering=0) as source:
        sector = source.read(512)
    if len(sector) != 512 or sector[510:] != b"\x55\xaa":
        raise AssertionError(f"{path} is not a DOS/MBR disk")
    entries = [sector[446 + 16 * index:462 + 16 * index]
               for index in range(4)]
    if any(entries[index] != bytes(16) for index in range(1, 4)):
        raise AssertionError(f"{path} does not have exactly one MBR partition")
    entry = entries[0]
    return entry[0], entry[4], struct.unpack_from("<I", entry, 8)[0], \
        struct.unpack_from("<I", entry, 12)[0]


def ext4_label(path: Path) -> bytes:
    with path.open("rb", buffering=0) as source:
        source.seek(PARTITION_OFFSET + 1024 + 120)
        return source.read(16).split(b"\0", 1)[0]


def compare_transformation(original: Path, prepared: Path) -> tuple[int, int, str, str]:
    changed = 0
    ranges = 0
    in_range = False
    original_digest = hashlib.sha256()
    prepared_digest = hashlib.sha256()
    with original.open("rb", buffering=0) as left, \
            prepared.open("rb", buffering=0) as right:
        while True:
            left_block = left.read(1024 * 1024)
            right_block = right.read(1024 * 1024)
            if len(left_block) != len(right_block):
                raise AssertionError("prepared image size differs from source image")
            if not left_block:
                break
            original_digest.update(left_block)
            prepared_digest.update(right_block)
            for before, after in zip(left_block, right_block, strict=True):
                differs = before != after
                if differs:
                    changed += 1
                    if not in_range:
                        ranges += 1
                in_range = differs
    return changed, ranges, original_digest.hexdigest(), prepared_digest.hexdigest()


def require_author_inputs(packet: Path) -> None:
    if digest(packet / "AUTHOR-EVIDENCE.sha256") != AUTHOR_EVIDENCE_SHA256:
        raise AssertionError("successor author image-evidence manifest differs")
    if digest(packet / "BINDING-PARAMETERS.tsv") != BINDING_PARAMETERS_SHA256:
        raise AssertionError("successor author 88-field binding table differs")
    with (packet / "BINDING-PARAMETERS.tsv").open(
            encoding="utf-8", newline="") as port:
        rows = list(csv.DictReader(port, delimiter="\t"))
    if len(rows) != 88 or len({row["field"] for row in rows}) != 88:
        raise AssertionError("binding table is not the closed 88-field map")
    if len({row["role"] for row in rows}) != 8:
        raise AssertionError("binding table is not the closed eight-role map")
    values = {row["field"]: row["value"] for row in rows}
    if (values.get("guest-review-sha256") !=
            "a7e13c9f7486f558da5bd2ec2feeaff809aca6fe46381d65c34e95004604de19" or
            values.get("image-review-document-sha256") !=
            "1a014ece021a59c12daebaa811938496754bf4e6e6b14679f89045ed37e51d53"):
        raise AssertionError("accepted V8 parent review identities changed")
    if (values.get("guest-source-manifest-sha256") !=
            "920bacf12f7f5c011671e1c10f1b56afb891cc4c9af387a78e3c74cc5f2d4492"):
        raise AssertionError("binding does not select the post-V9 guest successor")
    author_manifest = dict(manifest_entries(packet / "AUTHOR-EVIDENCE.sha256"))
    required = {
        "BINDING-PARAMETERS.tsv": BINDING_PARAMETERS_SHA256,
        "PACKET.txt": PACKET_SHA256,
        "AUTHOR-IMAGE-REPORT.txt": AUTHOR_REPORT_SHA256,
        "evidence/PAYLOAD.sha256": PAYLOAD_MANIFEST_SHA256,
        "evidence/BUILD-STATUS.json": BUILD_STATUS_SHA256,
    }
    if any(author_manifest.get(name) != expected
           for name, expected in required.items()):
        raise AssertionError("author image evidence does not bind required role inputs")
    report = (packet / "AUTHOR-IMAGE-REPORT.txt").read_text(encoding="utf-8")
    if ("independent-review=not-performed" not in report or
            "accepted-review-scope=parent-v8-only-not-successor" not in report):
        raise AssertionError("successor author report overstates inherited review scope")
    if (packet / "evidence/PAYLOAD.sha256").read_bytes() == \
            (packet / "evidence/BUILD-STATUS.json").read_bytes():
        raise AssertionError("payload and build-status role inputs alias")


def rendered_table_rows(packet: Path) -> list[str]:
    with (packet / "BINDING-PARAMETERS.tsv").open(
            encoding="utf-8", newline="") as port:
        rows = list(csv.DictReader(port, delimiter="\t"))
    result = []
    for row in rows:
        value = row["value"]
        if row["type"] not in {"integer", "symbol"}:
            value = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
        result.append(f"({row['field']} . {value})")
    return result


def scheme_alist_rows(path: Path, marker: str) -> list[str]:
    lines = path.read_text().splitlines()
    start = next(index for index, line in enumerate(lines) if line.strip() == marker)
    rows = []
    for line in lines[start:start + 88]:
        value = line.strip()
        if value.startswith("'("):
            value = value[2:]
        elif value.startswith("(("):
            value = value[1:]
        if value.endswith("))"):
            value = value[:-1]
        rows.append(value)
    if len(rows) != 88:
        raise AssertionError(f"metadata alist does not have 88 rows: {path}")
    return rows


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: test-reviewed-payload.py PRIVATE_BUNDLE IMAGE_AUTHOR_PACKET")
    root = Path(sys.argv[1])
    author_packet = Path(sys.argv[2])
    require_author_inputs(author_packet)
    require_private_immutable_tree(root)

    author_rows = rendered_table_rows(author_packet)
    if scheme_alist_rows(root / "BUNDLE.scm", "((schema . 3)") != author_rows:
        raise AssertionError("BUNDLE.scm is not the exact author successor table")
    if scheme_alist_rows(
            SOURCE_ROOT / "modules/two-boot/image-binding.scm",
            "'((schema . 3)") != author_rows:
        raise AssertionError("source image binding is not the exact author successor table")

    if V6_PAYLOAD_MANIFEST_SHA256 == V6_STATUS_SHA256:
        raise AssertionError("historical V6 payload/status roles alias")
    if digest(root / "MANIFEST.sha256") != BUNDLE_MANIFEST_SHA256:
        raise AssertionError("bundle manifest differs from source binding")
    if manifest_entries(root / "MANIFEST.sha256") != list(OUTER.items()):
        raise AssertionError("bundle outer manifest roster or values differ")
    if digest(root / "PAYLOAD.sha256") != PAYLOAD_MANIFEST_SHA256:
        raise AssertionError("copied successor PAYLOAD.sha256 differs")
    if (root / "PAYLOAD.sha256").read_bytes() != \
            (author_packet / "evidence/PAYLOAD.sha256").read_bytes():
        raise AssertionError("bundle does not contain the exact author manifest copy")
    if manifest_entries(root / "PAYLOAD.sha256") != list(PAYLOAD.items()):
        raise AssertionError("successor payload manifest is not the author four-entry map")

    for relative, expected in PAYLOAD.items():
        if relative != "rootfs.raw" and digest(root / relative) != expected:
            raise AssertionError(f"bundle payload differs: {relative}")

    prepared = root / "rootfs.raw"
    if ORIGINAL.stat().st_size != ORIGINAL_SIZE or prepared.stat().st_size != ORIGINAL_SIZE:
        raise AssertionError("author successor original/prepared image size differs")
    expected_partition = (0x80, 0x83, PARTITION_OFFSET // 512, PARTITION_SECTORS)
    if mbr_partition(ORIGINAL) != expected_partition:
        raise AssertionError("original image does not have the accepted DOS/MBR layout")
    if mbr_partition(prepared) != expected_partition:
        raise AssertionError("prepared baseline does not retain the DOS/MBR layout")
    if ext4_label(ORIGINAL) != b"Guix_image" or ext4_label(prepared) != b"PNGuixRoot":
        raise AssertionError("prepared baseline is not the accepted ext4 label change")
    changed, ranges, original_hash, prepared_hash = compare_transformation(
        ORIGINAL, prepared)
    if original_hash != ORIGINAL_SHA256 or prepared_hash != PREPARED_SHA256:
        raise AssertionError("author successor original/prepared digest differs")
    if (changed, ranges) != (97, 27):
        raise AssertionError(
            f"prepared label-only delta differs: bytes={changed} ranges={ranges}")

    config = (root / "boot-bundle/extlinux/extlinux.conf").read_text()
    append = [line.strip()[7:].strip() for line in config.splitlines()
              if line.strip().lower().startswith("append ")]
    if (len(append) != 1 or "root=LABEL=PNGuixRoot" not in append[0].split() or
            "console=ttyAMA0" not in append[0].split() or
            "console=tty0" in append[0].split()):
        raise AssertionError("prepared boot config has the wrong fixed QEMU tokens")
    print(
        "PASS: author successor inputs and immutable seven-file bundle match without extending parent review; "
        "PAYLOAD.sha256 is exact; label-only delta=97 bytes/27 ranges; "
        "historical V6 STATUS remains non-authoritative"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
