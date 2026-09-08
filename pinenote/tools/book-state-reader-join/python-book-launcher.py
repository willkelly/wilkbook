#!/usr/bin/env python3
"""Load the exact accepted Python Book Protocol codec and fixed book."""

from __future__ import annotations

import hashlib
import importlib.util
import runpy
import stat
import sys
from pathlib import Path


ACCEPTED_CODEC_SHA256 = (
    "4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735"
)


def exact_regular(path_text: str) -> Path:
    path = Path(path_text)
    if not path.is_absolute() or path.resolve() != path:
        raise RuntimeError("launcher input is not absolute and canonical")
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise RuntimeError("launcher input is not a single-link regular file")
    return path


def main() -> int:
    if len(sys.argv) != 3:
        raise RuntimeError("usage: python-book-launcher.py CODEC FIXED-BOOK")
    codec = exact_regular(sys.argv[1])
    book = exact_regular(sys.argv[2])
    if hashlib.sha256(codec.read_bytes()).hexdigest() != ACCEPTED_CODEC_SHA256:
        raise RuntimeError("accepted Python Book Protocol identity changed")
    spec = importlib.util.spec_from_file_location("book_protocol", codec)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not construct exact codec module")
    module = importlib.util.module_from_spec(spec)
    sys.modules["book_protocol"] = module
    spec.loader.exec_module(module)
    if Path(module.__file__).resolve() != codec:
        raise RuntimeError("Python imported Book Protocol from another path")
    sys.argv = [str(book)]
    runpy.run_path(str(book), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
