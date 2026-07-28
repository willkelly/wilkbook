#!/usr/bin/env python3
"""Extract new-file sources verbatim from the forward-port patch.

The wbf host tool compiles the *exact* drm_epd_helper.[ch] carried in
pinenote/patches/linux-pinenote-7.0-forward-port.patch, so the tests always
exercise the code that ships in the kernel.  Usage:

    extract-from-patch.py PATCH OUTDIR PATH...

Each PATH must be a new-file diff (--- /dev/null) inside PATCH; it is
written under OUTDIR with its basename-preserving relative path.
"""

import re
import sys
from pathlib import Path


def extract(patch_text: str, path: str) -> str:
    marker = "+++ b/" + path
    start = patch_text.index(marker)
    body = patch_text[start:]
    body = body[body.index("@@"):]
    hunk_header, body = body.split("\n", 1)
    match = re.fullmatch(r"@@ -0,0 \+1,(\d+) @@", hunk_header)
    if match is None:
        raise ValueError(f"{path}: unsupported new-file hunk: {hunk_header}")
    expected_lines = int(match.group(1))
    lines = []
    for line in body.splitlines():
        if line.startswith("+"):
            lines.append(line[1:])
        else:
            # New-file diffs are one hunk of pure additions; anything else
            # ends the section.
            break
    if len(lines) != expected_lines:
        raise ValueError(
            f"{path}: hunk advertises {expected_lines} added lines, "
            f"but contains {len(lines)}"
        )
    return "\n".join(lines) + "\n"


def validate_new_file_hunks(patch_text: str) -> None:
    for section in patch_text.split("\ndiff --git "):
        if "\n--- /dev/null\n" not in section:
            continue
        match = re.search(r"^\+\+\+ b/(.+)$", section, re.MULTILINE)
        if match is None:
            raise ValueError("new-file diff lacks a b/ path")
        extract(patch_text, match.group(1))


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    patch = Path(sys.argv[1]).read_text()
    validate_new_file_hunks(patch)
    outdir = Path(sys.argv[2])
    for path in sys.argv[3:]:
        out = outdir / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(extract(patch, path))
        print(f"extracted {path} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
