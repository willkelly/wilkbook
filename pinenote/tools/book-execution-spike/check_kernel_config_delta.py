#!/usr/bin/env python3
"""Compare installed kernel configs against an exact, reviewable allowlist.

This is an independent host evidence tool.  It does not participate in the
trusted guest/runtime path and never executes a target binary.
"""

from __future__ import annotations

import argparse
import difflib
import pathlib
import sys


def parse_config(path: pathlib.Path) -> tuple[dict[str, str], list[str]]:
    values: dict[str, str] = {}
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    for number, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if line.startswith("CONFIG_") and "=" in line:
            name, value = line.split("=", 1)
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            name = line[2 : -len(" is not set")]
            value = "n"
        else:
            continue
        if name in values:
            raise ValueError(f"{path}:{number}: duplicate symbol {name}")
        values[name] = value
    if not values:
        raise ValueError(f"{path}: no kernel configuration symbols found")
    return values, lines


def parse_allowlist(path: pathlib.Path) -> dict[str, tuple[str, str]]:
    allowed: dict[str, tuple[str, str]] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3 or not fields[0].startswith("CONFIG_"):
            raise ValueError(f"{path}:{number}: expected SYMBOL BASE FINAL")
        name, before, after = fields
        if name in allowed:
            raise ValueError(f"{path}:{number}: duplicate allowlist symbol {name}")
        if before == after:
            raise ValueError(f"{path}:{number}: unchanged allowlist entry {name}")
        allowed[name] = (before, after)
    if not allowed:
        raise ValueError(f"{path}: empty allowlist")
    return allowed


def symbol_delta(
    base: dict[str, str], final: dict[str, str]
) -> dict[str, tuple[str, str]]:
    return {
        name: (base.get(name, "<absent>"), final.get(name, "<absent>"))
        for name in sorted(base.keys() | final.keys())
        if base.get(name, "<absent>") != final.get(name, "<absent>")
    }


def write_evidence(
    output: pathlib.Path,
    base_path: pathlib.Path,
    final_path: pathlib.Path,
    base_lines: list[str],
    final_lines: list[str],
    delta: dict[str, tuple[str, str]],
) -> None:
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.chmod(0o700)
    diff = "".join(
        difflib.unified_diff(
            base_lines,
            final_lines,
            fromfile=str(base_path),
            tofile=str(final_path),
        )
    )
    (output / "kernel-config-full.diff").write_text(diff, encoding="utf-8")
    rows = ["symbol\tbase\tfinal\n"]
    rows.extend(f"{name}\t{before}\t{after}\n" for name, (before, after) in delta.items())
    (output / "kernel-config-symbol-delta.tsv").write_text(
        "".join(rows), encoding="utf-8"
    )
    for path in (
        output / "kernel-config-full.diff",
        output / "kernel-config-symbol-delta.tsv",
    ):
        path.chmod(0o600)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", type=pathlib.Path)
    parser.add_argument("final", type=pathlib.Path)
    parser.add_argument("allowlist", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args(argv)

    try:
        base, base_lines = parse_config(args.base)
        final, final_lines = parse_config(args.final)
        allowed = parse_allowlist(args.allowlist)
        delta = symbol_delta(base, final)
        write_evidence(
            args.output, args.base, args.final, base_lines, final_lines, delta
        )
        if delta != allowed:
            print("FAIL: configured kernel delta differs from exact allowlist", file=sys.stderr)
            print(f"  expected: {allowed!r}", file=sys.stderr)
            print(f"  observed: {delta!r}", file=sys.stderr)
            return 1
    except (OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print("PASS: final configured kernel delta is exactly:")
    for name, (before, after) in delta.items():
        print(f"  {name}: {before} -> {after}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
