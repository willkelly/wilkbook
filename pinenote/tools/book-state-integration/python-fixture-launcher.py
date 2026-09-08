#!/usr/bin/env python3
"""Load one pinned codec by exact path, then execute one pinned fixture.

Invoked with Python ``-I -S``.  No script/current/user/site/PYTHONPATH import
location can choose the Book Protocol module.
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
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
        raise RuntimeError("fixture launcher path is not absolute and canonical")
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise RuntimeError("fixture launcher input is not a single-link regular file")
    return path


def main() -> int:
    if len(sys.argv) < 4:
        raise RuntimeError(
            "usage: python-fixture-launcher.py CODEC FIXTURE [FIXTURE-ARGS...]"
        )
    codec = exact_regular(sys.argv[1])
    fixture = exact_regular(sys.argv[2])
    digest = hashlib.sha256(codec.read_bytes()).hexdigest()
    if digest != ACCEPTED_CODEC_SHA256:
        raise RuntimeError("Python Book Protocol codec identity changed")
    spec = importlib.util.spec_from_file_location("book_protocol", codec)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not create exact Book Protocol module spec")
    module = importlib.util.module_from_spec(spec)
    sys.modules["book_protocol"] = module
    spec.loader.exec_module(module)
    origin = Path(module.__file__).resolve() if module.__file__ else None
    if origin != codec:
        raise RuntimeError("Python Book Protocol resolved from the wrong path")
    print(f"BOOK_PROTOCOL_PY_ORIGIN: {origin} sha256={digest}", flush=True)
    sys.argv = [str(fixture), *sys.argv[3:]]
    runpy.run_path(str(fixture), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
