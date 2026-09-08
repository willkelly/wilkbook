#!/usr/bin/env python3
"""Static checks for the finite public Book-execution source capsule."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


COMMIT = "fd2f6b2674208086e324c2f739155eb7e1b48ff2"
ACCEPTED_AARCH64_GVISOR_DERIVATION = Path(
    "/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv"
)
EXPECTED_DIAGNOSTIC_AARCH64_GVISOR_DERIVATION = Path(
    "/gnu/store/pb5v7rqa5iqwc98qzjpbnk474qgqbvmm-"
    "gvisor-source-built-diagnostic-20260831.0.drv"
)
SYSTEMS = {
    "source-control": "pinenote/systems/pinenote-book-execution-source-control.scm",
    "diagnostic": "pinenote/systems/pinenote-book-execution-diagnostic.scm",
    "protocol-control": "pinenote/systems/pinenote-book-execution-protocol-control.scm",
    "reader-interaction": "pinenote/systems/pinenote-book-execution-reader-interaction.scm",
}
SOURCE_FILES = {
    "runsc/cmd/run.go": "66832e6f90533d94cee4e162e71d0c40aa103fe7be4de92264676c1deaded58a",
    "runsc/cmd/sandboxsetup/fdmappings.go": "e135732811633d0be9e92599d48a5ec4cfc1e5c38ae150ed305cd167e4b79b76",
    "runsc/donation/donation.go": "e035efc442790a5ebf74fc8f4ad3dc525a746b6862e25e159f72c8160ba84eae",
    "runsc/boot/loader.go": "70508976f5b1d52094da8c002dd805fd9f2b8cb02a07ac3037fe8d3b250d7c15",
    "g3doc/user_guide/fuse.md": "35a02bf4059d9559fd1df80b2a688d5abd58ec9f45b04340b8eb0e1d82b9d5e5",
    "runsc/config/flags.go": "1a269e91665d022fa4cc4075b9b9c991735351a4e6beb4ab4a7a5b2c5983af50",
    "runsc/config/config.go": "ad760a4e98f24d6783dc4da72c6c02bd6794f71b8b4dc72ed48267b414e9cf1c",
    "runsc/container/null_netns.go": "eb799eee1c58618c36ef7235e3173a86ea0cbcee71bf37d2bbde7aa04cc86868",
    "runsc/specutils/namespace.go": "39d13e8fcf84f0f00312af24f0ec10b70664fdeb241ffec99ea52700924f8832",
    "runsc/container/container.go": "2cd847cc190722fb16ac35d313ee1cb0c12f9f3050d8e36a9580bff9b690efd4",
    "runsc/container/state_file.go": "7c4fba71aad13e7aadeb0cdc0baca9df707ffe8cd41463295e5b93b98eb1f8ba",
    "runsc/sandbox/sandbox.go": "5bb26b649bbe2bbfd5c61de1cbbadb4eb537ff5d5e6b610bac2e9dd11979198e",
}
COMMON_MANIFEST_FIELDS = (
    "gvisor-runtime-file-count=6",
    "current-system-runtime-status=unproven-pending-separate-qemu",
    "execution-profile=isolation-userns",
    "directfs=false",
    "network=none",
    "host-uds=none",
    "platform=systrap",
    "ignore-cgroups=false",
    "sidecar-usage-policy=strict",
    "sidecar-release-enforcement-policy=always",
)
RUNTIME_FLAGS = (
    "--platform=systrap",
    "--network=none",
    "--sidecar-usage-policy=strict",
    "--sidecar-release-enforcement-policy=always",
    "--ignore-cgroups=false",
    "--host-uds=none",
    "--directfs=false",
)
FORBIDDEN_CURRENT = (
    "gvisor-local-test-artifacts",
    "gvisor-v12-control-local-test-artifact",
    "gvisor-v12-diagnostic-local-test-artifact",
    "/tmp/opencode/wilkbook-gvisor-v6-source-build-v12",
)


class CheckError(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise CheckError(message)
    print(f"PASS: {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(root: Path, relative: str) -> str:
    path = root / relative
    check(not path.is_symlink() and path.is_file(), f"regular source: {relative}")
    return path.read_text(encoding="utf-8")


def check_static(root: Path) -> None:
    texts = {name: read(root, relative) for name, relative in SYSTEMS.items()}
    for name, text in texts.items():
        for forbidden in FORBIDDEN_CURRENT:
            check(forbidden not in text, f"{name} excludes {forbidden}")
        for field in COMMON_MANIFEST_FIELDS:
            check(field in text, f"{name} declares {field}")

    check(
        "(define %control-package gvisor/source)" in texts["source-control"],
        "source-control selects reusable unpatched source package",
    )
    check(
        "(define %diagnostic-package gvisor/source-diagnostic)"
        in texts["diagnostic"],
        "diagnostic selects explicit patched source variant",
    )
    check(
        "gvisor-diagnostic-patch=absent" in texts["source-control"]
        and "gvisor-diagnostic-patch=absent" in texts["protocol-control"]
        and "gvisor-diagnostic-patch=absent" in texts["reader-interaction"],
        "default current systems explicitly exclude diagnostic patch",
    )
    check(
        "gvisor-diagnostic-patch-sha256="
        "9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e"
        in texts["diagnostic"],
        "diagnostic system pins reviewed patch identity",
    )
    for name in ("protocol-control", "reader-interaction"):
        check("runsc-pass-fd=3:3" in texts[name], f"{name} declares FD 3 donation")

    base_oci = read(root, "pinenote/tools/book-execution-spike/oci-bundle.scm")
    protocol_oci = read(
        root, "pinenote/tools/book-execution-spike/oci-book-bundle.scm"
    )
    for flag in RUNTIME_FLAGS[:-1]:
        check(
            flag in base_oci and flag in protocol_oci,
            f"both OCI generators retain {flag}",
        )
    check(
        '"--directfs=false"' in protocol_oci
        and '"--directfs=true"' not in protocol_oci,
        "protocol generator has no DirectFS fallback",
    )
    check(
        protocol_oci.count('"--pass-fd=3:3"') == 1,
        "protocol generator donates exactly host FD 3 to guest FD 3",
    )

    members = read(
        root, "pinenote/tools/book-execution-spike/expected-release-members.txt"
    ).splitlines()
    check(len(members) == 6 and len(set(members)) == 6, "runtime roster has six files")
    package = read(root, "pinenote/packages/gvisor-source.scm")
    for member in members:
        check(member in package, f"source package names runtime member {member}")
    check(
        "(source gvisor-source-origin)" in package,
        "default package uses pristine fixed source origin",
    )
    runtime_packages = package[package.index("(define-public gvisor/source\n") :]
    default, diagnostic = runtime_packages.split(
        "(define-public gvisor/source-diagnostic", 1
    )
    check(
        "gvisor-diagnostic-systrap-error-context.patch" not in default,
        "default package excludes diagnostic source patch",
    )
    check(
        "(patches (list %gvisor-diagnostic-error-report-patch))" in diagnostic,
        "diagnostic package applies reviewed patch explicitly",
    )

    runner = read(
        root, "pinenote/tools/book-execution-spike/public-source/run.sh"
    )
    isolated = read(
        root, "pinenote/tools/book-execution-spike/public-source/guix-isolated.sh"
    )
    check(
        'run_guix_view "$module_view" gc --requisites "$derivation"' in runner,
        "dependency traversal uses the pinned time-machine launcher",
    )
    check(
        "guix gc --requisites" not in runner,
        "runner has no direct ambient Guix graph command",
    )
    check(
        "exec /usr/bin/env -i" in isolated,
        "Guix launcher starts from an empty inherited environment",
    )
    for variable in (
        "HOME",
        "XDG_CACHE_HOME",
        "GUILE_LOAD_PATH",
        "GUILE_LOAD_COMPILED_PATH",
        "GUILE_EXTENSIONS_PATH",
        "GUILE_AUTO_COMPILE",
    ):
        check(f"{variable}=" in isolated, f"isolated launcher fixes {variable}")
    for variable in (
        "GUIX_PACKAGE_PATH",
        "GUIX_BUILD_OPTIONS",
        "GUIX_ENVIRONMENT",
    ):
        check(variable not in isolated.split("exec /usr/bin/env -i", 1)[1],
              f"isolated launcher clears {variable}")


def check_gvisor_source(root: Path, source: Path, output: Path) -> None:
    check(source.is_dir() and not source.is_symlink(), "Guix-resolved gVisor source directory")
    check(not (source / ".git").exists(), "fixed Guix origin supplies no mutable Git metadata")
    for relative, expected in SOURCE_FILES.items():
        path = source / relative
        check(path.is_file() and not path.is_symlink(), f"gVisor source file: {relative}")
        check(sha256(path) == expected, f"pinned gVisor source identity: {relative}")

    inventory = root / "pinenote/tools/gvisor-package/inventory.py"
    golden = root / "pinenote/tools/gvisor-package/pinned-source-inventory.json"
    subprocess.run(
        [
            sys.executable,
            "-I",
            "-S",
            "-B",
            str(inventory),
            str(source),
            "--source-commit",
            COMMIT,
            "--output",
            str(output),
        ],
        check=True,
    )
    check(output.read_bytes() == golden.read_bytes(), "fixed-origin dependency inventory")
    parsed = json.loads(output.read_text(encoding="utf-8"))
    check(parsed["source"]["commit"] == COMMIT, "inventory records pinned commit")

    run = (source / "runsc/cmd/run.go").read_text(encoding="utf-8")
    mappings = (source / "runsc/cmd/sandboxsetup/fdmappings.go").read_text(
        encoding="utf-8"
    )
    donation = (source / "runsc/donation/donation.go").read_text(encoding="utf-8")
    loader = (source / "runsc/boot/loader.go").read_text(encoding="utf-8")
    guide = (source / "g3doc/user_guide/fuse.md").read_text(encoding="utf-8")
    check('f.Var(&r.passFDs, "pass-fd"' in run, "runsc registers public pass-fd")
    check("fdMap[mapping.Guest] = file" in run, "runsc keys donated files by guest FD")
    check(
        "Host:  fdHost" in mappings and "Guest: fdGuest" in mappings,
        "runsc parses host and guest FD mapping",
    )
    check(
        'fmt.Sprintf("--pass-fd=%d:%d", nextFD, fd)' in donation,
        "internal donation preserves guest FD mapping",
    )
    check(
        "guest: customFD.Guest" in loader
        and "fdMap[customFD.guest] = customFD.host" in loader,
        "Sentry loader imports the requested guest FD",
    )
    check(
        "The format is `--pass-fd=HOST_FD:GUEST_FD`" in guide,
        "pinned guide documents HOST_FD:GUEST_FD",
    )

    flags = (source / "runsc/config/flags.go").read_text(encoding="utf-8")
    config = (source / "runsc/config/config.go").read_text(encoding="utf-8")
    null_netns = (source / "runsc/container/null_netns.go").read_text(
        encoding="utf-8"
    )
    namespace = (source / "runsc/specutils/namespace.go").read_text(encoding="utf-8")
    container = (source / "runsc/container/container.go").read_text(encoding="utf-8")
    state_file = (source / "runsc/container/state_file.go").read_text(encoding="utf-8")
    sandbox = (source / "runsc/sandbox/sandbox.go").read_text(encoding="utf-8")
    check(
        "goferNetworkNamespacePtr(GoferNetworkNamespaceNull)" in flags,
        "null gofer network namespace remains the default",
    )
    check(
        'const NullNetNSFilename = "null-netns"' in namespace,
        "shared null-network namespace filename",
    )
    check(
        "if c.SharedRootDir != \"\"" in config and "return c.RootDir" in config,
        "empty shared root resolves to runtime root",
    )
    check(
        "os.OpenFile(path, os.O_RDONLY|os.O_CREATE, 0444)" in null_netns
        and "unix.MS_BIND" in null_netns
        and "unix.NS_GET_NSTYPE" in null_netns,
        "null-network namespace creation and identity checks",
    )
    check(
        "if err := pinNullNetNS(conf, cmd.Process.Pid)" in container,
        "first null-network gofer pins its namespace",
    )
    check(
        "c.Saver.Destroy()" in container
        and "os.Remove(s.statePath())" in state_file
        and "os.Remove(controlSocketPath)" in sandbox,
        "ordinary runtime metadata cleanup remains present",
    )


def package_identity(path: Path) -> str:
    name = path.name
    if len(name) < 34 or name[32] != "-":
        return name
    return name[33:]


def check_graph(variant: str, root_derivation: Path, graph: Path) -> None:
    raw_paths = [
        line for line in graph.read_text(encoding="utf-8").splitlines() if line
    ]
    check(bool(raw_paths), f"{variant} graph is nonempty")
    check(len(raw_paths) == len(set(raw_paths)), f"{variant} graph has no duplicates")
    for raw in raw_paths:
        if not (
            raw.startswith("/gnu/store/")
            and os.path.normpath(raw) == raw
            and "//" not in raw
        ):
            raise CheckError(f"{variant} graph entry is not canonical: {raw}")
        if not Path(raw).exists():
            raise CheckError(f"{variant} graph entry does not exist: {raw}")
    print(f"PASS: {variant} graph contains only existing canonical store paths")
    paths = [Path(raw) for raw in raw_paths]
    check(
        paths.count(root_derivation) == 1,
        f"{variant} graph contains its exact root system derivation",
    )
    identities = [package_identity(path) for path in paths]
    default = [name for name in identities if name == "gvisor-source-built-20260831.0.drv"]
    diagnostic = [
        name
        for name in identities
        if name == "gvisor-source-built-diagnostic-20260831.0.drv"
    ]
    if variant == "diagnostic":
        check(len(default) == 0, "diagnostic graph excludes unpatched runtime derivation")
        check(len(diagnostic) == 1, "diagnostic graph selects one patched runtime derivation")
        check(
            EXPECTED_DIAGNOSTIC_AARCH64_GVISOR_DERIVATION in paths,
            "diagnostic graph selects expected patched AArch64 runtime derivation",
        )
        check(
            sum("gvisor-diagnostic-systrap-error-context.patch" in name for name in identities)
            == 1,
            "diagnostic graph contains the explicit reviewed source patch",
        )
    else:
        check(len(default) == 1, f"{variant} graph selects one unpatched source runtime")
        check(
            ACCEPTED_AARCH64_GVISOR_DERIVATION in paths,
            f"{variant} graph selects accepted AArch64 source runtime derivation",
        )
        check(len(diagnostic) == 0, f"{variant} graph excludes diagnostic runtime")
        check(
            not any("gvisor-diagnostic-systrap-error-context.patch" in name for name in identities),
            f"{variant} graph excludes diagnostic source patch",
        )
    check(
        not any(name == "gvisor-bin-20260831.0.drv" for name in identities),
        f"{variant} graph excludes official binary runtime",
    )
    check(
        not any("gvisor-v12" in name or "local-test-artifact" in name for name in identities),
        f"{variant} graph excludes local v12 wrapper",
    )
    for path in paths:
        if path.suffix == ".drv" and path.is_file():
            data = path.read_bytes()
            if b"/tmp/opencode/wilkbook-gvisor-v6-source-build-v12" in data:
                raise CheckError(f"{variant} derivation retains manual artifact root: {path}")
    print(f"PASS: {variant} derivation graph has no manual artifact path")


def make_missing_view(source: Path, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise CheckError(f"negative module view already exists: {output}")
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if relative.as_posix() == "pinenote/packages/gvisor-source.scm":
            continue
        destination = output / relative
        if path.is_dir() and not path.is_symlink():
            destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        elif path.is_symlink():
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            destination.symlink_to(path.readlink())
        else:
            raise CheckError(f"unexpected module-view entry: {path}")
    check(
        not (output / "pinenote/packages/gvisor-source.scm").exists(),
        "negative view omits gvisor-source module",
    )


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    static_parser = subparsers.add_parser("static")
    static_parser.add_argument("root", type=Path)
    source_parser = subparsers.add_parser("gvisor-source")
    source_parser.add_argument("root", type=Path)
    source_parser.add_argument("source", type=Path)
    source_parser.add_argument("output", type=Path)
    graph_parser = subparsers.add_parser("graph")
    graph_parser.add_argument("variant", choices=tuple(SYSTEMS))
    graph_parser.add_argument("root_derivation", type=Path)
    graph_parser.add_argument("graph", type=Path)
    missing_parser = subparsers.add_parser("make-missing-view")
    missing_parser.add_argument("source", type=Path)
    missing_parser.add_argument("output", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    if arguments.command == "static":
        check_static(arguments.root)
    elif arguments.command == "gvisor-source":
        check_gvisor_source(arguments.root, arguments.source, arguments.output)
    elif arguments.command == "graph":
        check_graph(arguments.variant, arguments.root_derivation, arguments.graph)
    elif arguments.command == "make-missing-view":
        make_missing_view(arguments.source, arguments.output)
    else:
        raise AssertionError(arguments.command)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (CheckError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
