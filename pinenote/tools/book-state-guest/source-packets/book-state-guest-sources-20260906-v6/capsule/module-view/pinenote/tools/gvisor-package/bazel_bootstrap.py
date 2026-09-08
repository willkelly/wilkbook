#!/usr/bin/env python3
"""Repack Bazel's fixed self-extracting archive for a Guix build chroot.

The launcher's fixed-width PT_INTERP bytes are changed in place, without
moving its embedded-file notes.  ELF payloads in the ZIP are patched before
Bazel extracts them.  Repacking, rather than editing an extracted install base, matters:
Bazel blesses extracted files with future mtimes and rejects a store-resident
install base after Guix normalizes those mtimes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


RAW_SHA256 = "17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c"
TRANSFORM_ID = "wilkbook-gvisor-guix-bazel-bootstrap-v2"
FIXED_DATE = (1980, 1, 1, 0, 0, 0)
RAW_LAUNCHER_INTERPRETER = b"/lib64/ld-linux-x86-64.so.2\0"
WRAPPED_LAUNCHER_INTERPRETER = b"/proc/self/fd/9\0"


class BootstrapError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def transformed_install_key(
    raw_sha256: str,
    patchelf: Path,
    interpreter: Path,
    wrapper_shell: Path,
    library_path: str,
) -> str:
    material = (
        f"{TRANSFORM_ID}\0{raw_sha256}\0{patchelf}\0{interpreter}\0"
        f"{wrapper_shell}\0{library_path}"
    ).encode()
    return hashlib.sha256(material).hexdigest()[:32]


def _copy_zip_info(
    info: zipfile.ZipInfo, filename: str | None = None
) -> zipfile.ZipInfo:
    result = zipfile.ZipInfo(filename or info.filename, FIXED_DATE)
    result.compress_type = info.compress_type
    result.comment = info.comment
    result.extra = info.extra
    result.internal_attr = info.internal_attr
    result.external_attr = info.external_attr
    result.create_system = info.create_system
    result.create_version = info.create_version
    result.extract_version = info.extract_version
    result.flag_bits = info.flag_bits & ~0x08
    return result


def _run(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def patch_elf(
    data: bytes,
    name: str,
    patchelf: Path,
    interpreter: Path,
    temporary: Path,
) -> tuple[bytes, bool, bool]:
    if not data.startswith(b"\x7fELF"):
        return data, False, False

    candidate = temporary / "elf"
    candidate.write_bytes(data)
    candidate.chmod(0o700)

    interpreter_result = _run([str(patchelf), "--print-interpreter", str(candidate)], capture=True)
    has_interpreter = interpreter_result.returncode == 0 and bool(interpreter_result.stdout.strip())
    if has_interpreter:
        result = _run(
            [str(patchelf), "--set-interpreter", str(interpreter), str(candidate)],
            capture=True,
        )
        if result.returncode:
            raise BootstrapError(f"patchelf could not set the interpreter for {name}: {result.stderr.strip()}")

    needed_result = _run([str(patchelf), "--print-needed", str(candidate)], capture=True)
    has_dynamic_dependencies = needed_result.returncode == 0 and bool(needed_result.stdout.strip())
    if not has_interpreter and not has_dynamic_dependencies:
        raise BootstrapError(f"unexpected static or relocatable ELF in Bazel bootstrap: {name}")
    return candidate.read_bytes(), has_interpreter, has_dynamic_dependencies


def repack(
    source: Path,
    output: Path,
    patchelf: Path,
    interpreter: Path,
    wrapper_shell: Path,
    library_path: str,
    expected_sha256: str,
    expected_elf_count: int,
    manifest_path: Path | None,
) -> dict:
    actual_sha256 = sha256_file(source)
    if actual_sha256 != expected_sha256:
        raise BootstrapError(
            f"Bazel bootstrap SHA-256 changed: expected {expected_sha256}, got {actual_sha256}"
        )
    if not patchelf.is_file() or not os.access(patchelf, os.X_OK):
        raise BootstrapError(f"patchelf is not executable: {patchelf}")
    if not interpreter.is_file():
        raise BootstrapError(f"dynamic loader does not exist: {interpreter}")
    if (
        not wrapper_shell.is_absolute()
        or not wrapper_shell.is_file()
        or not os.access(wrapper_shell, os.X_OK)
        or str(wrapper_shell).startswith(("/usr", "/bin", "/lib", "/lib64"))
    ):
        raise BootstrapError(f"wrapper shell is not an explicit executable: {wrapper_shell}")
    if not library_path or any(
        part.startswith(("/usr", "/lib", "/lib64")) for part in library_path.split(":")
    ):
        raise BootstrapError("library path must contain only explicit non-FHS package paths")
    install_key = transformed_install_key(
        actual_sha256, patchelf, interpreter, wrapper_shell, library_path
    )

    raw = source.read_bytes()
    with zipfile.ZipFile(source) as archive:
        infos = archive.infolist()
        if not infos or infos[0].filename != "A-server.jar":
            raise BootstrapError("Bazel bootstrap does not begin with A-server.jar")
        if infos[-1].filename != "install_base_key":
            raise BootstrapError("Bazel bootstrap install_base_key is not the final member")
        if len({info.filename for info in infos}) != len(infos):
            raise BootstrapError("Bazel bootstrap contains duplicate ZIP members")
        prefix_size = min(info.header_offset for info in infos)
        if not raw.startswith(b"\x7fELF"):
            raise BootstrapError("Bazel self-extracting launcher is not ELF")

        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="gvisor-bazel-repack-") as tmp:
            temporary = Path(tmp)
            if raw.count(RAW_LAUNCHER_INTERPRETER) != 1:
                raise BootstrapError("Bazel launcher's fixed interpreter changed")
            replacement = WRAPPED_LAUNCHER_INTERPRETER.ljust(
                len(RAW_LAUNCHER_INTERPRETER), b"\0"
            )
            patched_launcher = raw.replace(RAW_LAUNCHER_INTERPRETER, replacement)
            prefix = patched_launcher[:prefix_size]
            records: list[dict] = []
            payloads: list[tuple[zipfile.ZipInfo, bytes]] = []
            wrapped_executables: list[dict[str, str]] = []
            for info in infos:
                data = archive.read(info)
                if info.filename == "install_base_key":
                    data = install_key.encode()
                data, has_interpreter, has_dynamic_dependencies = patch_elf(
                    data, info.filename, patchelf, interpreter, temporary
                )
                if has_interpreter or has_dynamic_dependencies:
                    record = {
                        "member": info.filename,
                        "interpreter": has_interpreter,
                        "dynamic_dependencies": has_dynamic_dependencies,
                        "wrapped": has_interpreter,
                    }
                    if has_interpreter:
                        real_name = f"{info.filename}.gvisor-real"
                        record["payload_member"] = real_name
                        wrapper = (
                            f"#!{wrapper_shell}\n"
                            "set -eu\n"
                            f"export LD_LIBRARY_PATH={library_path}\n"
                            'exec -a "$0" "$0.gvisor-real" "$@"\n'
                        ).encode()
                        payloads.append((_copy_zip_info(info), wrapper))
                        payloads.append((_copy_zip_info(info, real_name), data))
                        wrapped_executables.append(
                            {"member": info.filename, "payload_member": real_name}
                        )
                    else:
                        payloads.append((_copy_zip_info(info), data))
                    records.append(record)
                else:
                    payloads.append((_copy_zip_info(info), data))

            if len(records) != expected_elf_count:
                raise BootstrapError(
                    f"Bazel bootstrap ELF count changed: expected {expected_elf_count}, got {len(records)}"
                )

            staging = temporary / "bazel"
            staging.write_bytes(prefix)
            with zipfile.ZipFile(staging, "a", allowZip64=True) as rewritten:
                for info, data in payloads:
                    rewritten.writestr(info, data, compresslevel=9)
            staging.chmod(0o555)
            shutil.copyfile(staging, output)
            output.chmod(0o555)

    with zipfile.ZipFile(output) as verification:
        if verification.testzip() is not None:
            raise BootstrapError("rewritten Bazel bootstrap failed its ZIP CRC check")
        rewritten_names = [info.filename for info in verification.infolist()]
        expected_names = []
        wrapped_names = {entry["member"] for entry in wrapped_executables}
        for info in infos:
            expected_names.append(info.filename)
            if info.filename in wrapped_names:
                expected_names.append(f"{info.filename}.gvisor-real")
        if rewritten_names != expected_names:
            raise BootstrapError("rewritten Bazel bootstrap changed transformed ZIP member order")
        key = verification.read("install_base_key").decode()
        if key != install_key:
            raise BootstrapError("rewritten Bazel bootstrap has the wrong install key")

    manifest = {
        "schema": 2,
        "transform": TRANSFORM_ID,
        "raw_sha256": actual_sha256,
        "repacked_sha256": sha256_file(output),
        "launcher_prefix_sha256": hashlib.sha256(prefix).hexdigest(),
        "launcher_interpreter": WRAPPED_LAUNCHER_INTERPRETER.rstrip(b"\0").decode(),
        "launcher_runpath": False,
        "wrapper_library_path": library_path,
        "embedded_wrapper_shell": str(wrapper_shell),
        "install_base_key": install_key,
        "elf_member_count": len(records),
        "elf_members": records,
        "wrapped_executable_count": len(wrapped_executables),
        "wrapped_executables": wrapped_executables,
        "embedded_jdk_retained": True,
    }
    if manifest_path is not None:
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--patchelf", type=Path, required=True)
    parser.add_argument("--interpreter", type=Path, required=True)
    parser.add_argument("--wrapper-shell", type=Path, required=True)
    parser.add_argument("--library-path", required=True)
    parser.add_argument("--expected-sha256", default=RAW_SHA256)
    parser.add_argument("--expected-elf-count", type=int, default=29)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args(argv)
    try:
        repack(
            args.source,
            args.output,
            args.patchelf,
            args.interpreter,
            args.wrapper_shell,
            args.library_path,
            args.expected_sha256,
            args.expected_elf_count,
            args.manifest,
        )
    except (BootstrapError, OSError, zipfile.BadZipFile) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
