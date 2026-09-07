#!/usr/bin/env python3
"""Load pinned modules by exact path before running one unittest source."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import sys
import unittest


def load(name: str, path_text: str):
    path = Path(path_text)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise RuntimeError(f"module path must be absolute and canonical: {path}")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot create loader for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"PYTHON-MODULE-ORIGIN: {name}={path} sha256={digest}")
    return module


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", nargs=2, action="append", default=[])
    parser.add_argument("--test", required=True)
    arguments = parser.parse_args()
    sys.dont_write_bytecode = True
    for name, path in arguments.module:
        load(name, path)
    test_module = load("_book_source_public_test", arguments.test)
    unittest.main(module=test_module, argv=[sys.argv[0]], verbosity=2)


if __name__ == "__main__":
    main()
