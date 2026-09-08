#!/usr/bin/env python3
"""Create and audit the explicit tool environment for gVisor's Bazel build."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


ARCHITECTURES = {
    "native-x86_64": ("x86_64", "release-closure-native-x86_64.txt"),
    "aarch64": ("aarch64", "release-closure-aarch64.txt"),
}
GCC_TOOLS = ("cpp", "g++", "gcc", "gcov")
BINUTILS_TOOLS = ("ar", "as", "dwp", "ld", "ld.gold", "nm", "objcopy", "objdump", "strip")


class SetupError(ValueError):
    pass


CONFIGURED_LABEL = re.compile(r"^(.*) \(([^()]*)\)$")


def checked_root(value: str, name: str, require_store: bool) -> Path:
    path = Path(value)
    if not path.is_absolute() or not path.is_dir():
        raise SetupError(f"{name} is not an absolute directory: {path}")
    if require_store and not str(path).startswith("/gnu/store/"):
        raise SetupError(f"{name} is not a Guix store path: {path}")
    return path


def checked_program(path: Path, name: str) -> Path:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SetupError(f"required tool is missing or not executable: {name}={path}")
    return path


def write_compiler_wrapper(destination: Path, shell: Path, compiler: Path) -> None:
    checked_program(shell, "compiler-wrapper shell")
    checked_program(compiler, "wrapped compiler")
    if destination.exists():
        raise SetupError(f"compiler wrapper already exists: {destination}")
    destination.write_text(
        f"#!{shell}\nexec {shlex.quote(str(compiler))} \"$@\"\n"
    )
    destination.chmod(0o755)


def compiler_include_directories(compiler: Path, require_store: bool) -> list[Path]:
    result = subprocess.run(
        [str(checked_program(compiler, "C++ compiler")), "-E", "-x", "c++", "-", "-v"],
        input="",
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env={"LANG": "C", "LC_ALL": "C"},
        check=False,
    )
    if result.returncode:
        raise SetupError(f"C++ compiler include probe failed: {compiler}")
    start = '#include <...> search starts here:'
    end = "End of search list."
    lines = result.stderr.splitlines()
    if lines.count(start) != 1 or lines.count(end) != 1:
        raise SetupError(f"C++ compiler emitted an unexpected include search list: {compiler}")
    selected = lines[lines.index(start) + 1 : lines.index(end)]
    directories: list[Path] = []
    for line in selected:
        value = line.strip().removesuffix(" (framework directory)")
        path = Path(value).resolve()
        if not path.is_absolute() or not path.is_dir():
            raise SetupError(f"C++ compiler reported a missing include directory: {value}")
        if require_store and not str(path).startswith("/gnu/store/"):
            raise SetupError(f"C++ compiler reported a non-store include directory: {path}")
        if path not in directories:
            directories.append(path)
    if not directories:
        raise SetupError(f"C++ compiler reported no include directories: {compiler}")
    return directories


def link_toolchain(
    output: Path,
    destination_triplet: str,
    gcc: Path,
    binutils: Path,
    source_triplet: str,
    action_shell: Path,
) -> str:
    bindir = output / "toolchains" / destination_triplet / "bin"
    bindir.mkdir(parents=True, exist_ok=False)

    def source(root: Path, tool: str) -> Path:
        prefix = f"{source_triplet}-" if source_triplet else ""
        return checked_program(root / "bin" / f"{prefix}{tool}", tool)

    for tool in GCC_TOOLS:
        program = source(gcc, tool)
        wrapper = bindir / f"{destination_triplet}-{tool}"
        write_compiler_wrapper(wrapper, action_shell, program)
        if destination_triplet == "x86_64-linux-gnu":
            (bindir / tool).symlink_to(wrapper)
    for tool in BINUTILS_TOOLS:
        program = source(binutils, tool)
        (bindir / f"{destination_triplet}-{tool}").symlink_to(program)
        if destination_triplet == "x86_64-linux-gnu":
            (bindir / tool).symlink_to(program)
    linker = source(binutils, "ld")
    (bindir / f"{destination_triplet}-compat-ld").symlink_to(linker)
    if destination_triplet == "x86_64-linux-gnu":
        (bindir / "cc").symlink_to(bindir / f"{destination_triplet}-gcc")
        (bindir / "c++").symlink_to(bindir / f"{destination_triplet}-g++")
    return str(bindir / f"{destination_triplet}-")


def prepare(args: argparse.Namespace) -> dict:
    if args.architecture not in ARCHITECTURES:
        raise SetupError(f"unsupported architecture: {args.architecture}")
    output = Path(args.output)
    if output.exists():
        raise SetupError(f"toolchain output already exists: {output}")
    output.mkdir(parents=True)

    native_gcc = checked_root(args.native_gcc, "native GCC", args.require_store)
    native_binutils = checked_root(args.native_binutils, "native binutils-gold", args.require_store)
    native_libc = checked_root(args.native_libc, "native libc", args.require_store)
    clang = checked_root(args.clang, "Clang", args.require_store)
    linux_headers = checked_root(args.linux_headers, "Linux headers", args.require_store)
    libbpf = checked_root(args.libbpf, "libbpf", args.require_store)
    action_shell = checked_program(Path(args.action_shell), "action shell")
    action_cp = checked_program(Path(args.action_cp), "action cp")
    action_mkdir = checked_program(Path(args.action_mkdir), "action mkdir")
    action_dirname = checked_program(Path(args.action_dirname), "action dirname")
    action_bins = [checked_root(value, "action tool", args.require_store) / "bin" for value in args.action_root]
    for path in action_bins:
        if not path.is_dir():
            raise SetupError(f"action tool has no bin directory: {path}")

    native_compiler = checked_program(native_gcc / "bin/g++", "native C++ compiler")
    native_prefix = link_toolchain(
        output, "x86_64-linux-gnu", native_gcc, native_binutils, "", action_shell
    )
    native_roots = compiler_include_directories(native_compiler, args.require_store)
    toolchain_bins = [str(Path(native_prefix).parent)]

    required = {
        "target GCC": args.target_gcc,
        "target GCC libraries": args.target_gcc_lib,
        "target binutils-gold": args.target_binutils,
        "target libc": args.target_libc,
        "target Linux headers": args.target_linux_headers,
    }
    missing = [name for name, value in required.items() if not value]
    if missing:
        raise SetupError(f"setup is missing {missing[0]}")
    target_gcc = checked_root(args.target_gcc, "target GCC", args.require_store)
    checked_root(args.target_gcc_lib, "target GCC libraries", args.require_store)
    target_binutils = checked_root(
        args.target_binutils, "target binutils-gold", args.require_store
    )
    checked_root(args.target_libc, "target libc", args.require_store)
    target_linux_headers = checked_root(
        args.target_linux_headers, "target Linux headers", args.require_store
    )
    target_prefix = link_toolchain(
        output,
        "aarch64-linux-gnu",
        target_gcc,
        target_binutils,
        "aarch64-linux-gnu",
        action_shell,
    )
    target_roots = compiler_include_directories(
        checked_program(
            target_gcc / "bin/aarch64-linux-gnu-g++", "target C++ compiler"
        ),
        args.require_store,
    )
    toolchain_bins.append(str(Path(target_prefix).parent))

    clang_program = checked_program(clang / "bin" / "clang", "clang")
    linux_include = linux_headers / "include"
    target_linux_include = target_linux_headers / "include"
    prewarmer_include = (
        target_linux_include if args.architecture == "aarch64" else linux_include
    )
    libbpf_include = libbpf / "include"
    if (
        not linux_include.is_dir()
        or not target_linux_include.is_dir()
        or not libbpf_include.is_dir()
        or not prewarmer_include.is_dir()
    ):
        raise SetupError("declared header input has no include directory")

    action_path = toolchain_bins + [str(path) for path in action_bins]
    if any(path.startswith(("/bin", "/usr")) for path in action_path):
        raise SetupError("action PATH contains an FHS directory")
    environment = {
        "GVISOR_BPF_CLANG": str(clang_program),
        "GVISOR_BPF_INCLUDE_FLAGS": f"-isystem {linux_include} -isystem {libbpf_include}",
        "GVISOR_GUIX_AARCH64_INCLUDE_ROOTS": ":".join(map(str, target_roots)),
        "GVISOR_GUIX_AARCH64_TOOL_PREFIX": target_prefix,
        "GVISOR_GUIX_CP": str(action_cp),
        "GVISOR_GUIX_DIRNAME": str(action_dirname),
        "GVISOR_GUIX_MKDIR": str(action_mkdir),
        "GVISOR_GUIX_NATIVE_INCLUDE_ROOTS": ":".join(map(str, native_roots)),
        "GVISOR_GUIX_NATIVE_TOOL_PREFIX": native_prefix,
        "GVISOR_PREWARMER_INCLUDE_FLAGS": f"-isystem {prewarmer_include}",
        "GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS": f"-isystem {target_linux_include}",
        "GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS": f"-isystem {linux_include}",
        "GVISOR_VDSO_AARCH64_INCLUDE_FLAGS": f"-isystem {target_linux_include}",
        "GVISOR_VDSO_NATIVE_INCLUDE_FLAGS": f"-isystem {linux_include}",
        "GVISOR_NATIVE_LINUX_INCLUDE": str(linux_include),
        "GVISOR_TARGET_LINUX_INCLUDE": str(target_linux_include),
        "PATH": ":".join(action_path),
    }
    result = {
        "schema": 1,
        "architecture": args.architecture,
        "bazel_config": ARCHITECTURES[args.architecture][0],
        "closure_file": ARCHITECTURES[args.architecture][1],
        "environment": environment,
    }
    (output / "runtime-setup.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    environment_dir = output / "environment"
    environment_dir.mkdir()
    for name, value in sorted(environment.items()):
        (environment_dir / name).write_text(value + "\n")
    return result


def audit_protobuf(protobuf: Path) -> None:
    authenticity = (
        protobuf
        / "bazel/private/toolchains/prebuilt/protoc_authenticity.bzl"
    ).read_text()
    required = (
        '"$GVISOR_GUIX_GREP"',
        '"$GVISOR_GUIX_CAT"',
        "use_default_shell_env = True",
        "mismatch_exit_code = 1 if ctx.attr.fail_on_mismatch else 0",
        '"^libprotoc {RELEASE_VERSION}"',
    )
    for marker in required:
        if marker not in authenticity:
            raise SetupError(
                f"protobuf authenticity check lost required marker {marker}"
            )
    if authenticity.count('"$GVISOR_GUIX_GREP"') != 2:
        raise SetupError("protobuf authenticity check does not declare both grep uses")
    if authenticity.count('"$GVISOR_GUIX_CAT"') != 1:
        raise SetupError("protobuf authenticity check does not declare its cat use")


def audit(
    source: Path,
    coral: Path,
    rendered_crosstool: Path,
    protobuf: Path | None = None,
) -> None:
    status = (source / "tools/workspace_status.sh").read_text()
    if "echo STABLE_VERSION release-20260831.0" not in status or "git describe" in status:
        raise SetupError("workspace status does not stamp the exact release")
    build_files = [
        source / "runsc/BUILD",
        source / "runsc/checkpointgofer/BUILD",
        source / "runsc/cmd/metricserver/BUILD",
        source / "runsc/cmd/sentry/BUILD",
        source / "tools/bazeldefs/BUILD",
        source / "tools/parsers/BUILD",
    ]
    stamping = "\n".join(path.read_text() for path in build_files)
    if "{STABLE_VERSION}" in stamping or "grep STABLE_VERSION" in stamping:
        raise SetupError("prepared source still requires the FHS workspace-status action")
    if stamping.count("{BUILD_EMBED_LABEL}") != 8:
        raise SetupError("prepared source has an unexpected release-label consumer count")
    if "grep BUILD_EMBED_LABEL" not in stamping:
        raise SetupError("prepared source version-file rule lost the built-in release label")
    bpf = (source / "tools/bazeldefs/defs.bzl").read_text()
    if (
        "$$GVISOR_BPF_CLANG" not in bpf
        or "$$GVISOR_BPF_INCLUDE_FLAGS" not in bpf
        or "-target bpf -D__x86_64__" not in bpf
    ):
        raise SetupError("BPF genrule does not use the declared Guix tools")
    if "/usr/include" in bpf or 'cmd = "clang ' in bpf:
        raise SetupError("BPF genrule retains an FHS or PATH-selected compiler")
    prewarmer = (source / "runsc/prewarmer/BUILD").read_text()
    if "$$GVISOR_PREWARMER_INCLUDE_FLAGS" not in prewarmer:
        raise SetupError("prewarmer genrule does not use declared target headers")
    if "/usr/include" in prewarmer or "CPATH" in prewarmer:
        raise SetupError("prewarmer genrule retains an FHS or global header path")
    sysmsg = (source / "pkg/sentry/platform/systrap/sysmsg/build.bzl").read_text()
    for marker in (
        "$$GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS",
        "$$GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS",
    ):
        if marker not in sysmsg:
            raise SetupError("sysmsg genrule does not select declared Linux headers")
    if "/usr/include" in sysmsg or "CPATH" in sysmsg:
        raise SetupError("sysmsg genrule retains an FHS or global header path")
    vdso = (source / "vdso/BUILD").read_text()
    for marker in (
        "$$GVISOR_VDSO_NATIVE_INCLUDE_FLAGS",
        "$$GVISOR_VDSO_AARCH64_INCLUDE_FLAGS",
    ):
        if marker not in vdso:
            raise SetupError("VDSO genrule does not select declared Linux headers")
    if "/usr/include" in vdso or "CPATH" in vdso:
        raise SetupError("VDSO genrule retains an FHS or global header path")
    nogo_defs = (source / "tools/nogo/defs.bzl").read_text()
    if "go_ctx.stdlib_mod.path" not in nogo_defs:
        raise SetupError("nogo does not pass Bazel's executable-relative go.mod path")
    nogo_cli = (source / "tools/nogo/cli/cli.go").read_text()
    if r"regexp.MustCompile(`(?m)^go\s+(\S+)`)" not in nogo_cli:
        raise SetupError("nogo does not recognize Go 1.26's multiline go.mod")
    nogo_filter = (source / "tools/nogo/check/build.go").read_text()
    for marker in (
        '"crypto/internal/sysrand/internal/seccomp"',
        '"internal/obscuretestdata"',
        '"internal/testpty"',
        '"log/slog/internal/benchmarks"',
        '"net/internal/socktest"',
        '"reflect/internal/example1"',
        '"reflect/internal/example2"',
        'delete(pkgNames, path)',
        'package %q present in stdlib GOROOT but not in source',
    ):
        if marker not in nogo_filter:
            raise SetupError(f"nogo standard-library filter lost marker {marker}")
    if "if !ok {\n\t\t\tcontinue" in nogo_filter:
        raise SetupError("nogo standard-library filter broadly ignores missing source")
    arch_rule = (source / "tools/arch.bzl").read_text()
    if '"$GVISOR_GUIX_CP"' not in arch_rule or "use_default_shell_env = True" not in arch_rule:
        raise SetupError("architecture copy action does not use declared Guix tools")
    release_rule = (source / "tools/release.bzl").read_text()
    for marker in (
        '"$GVISOR_GUIX_CP"',
        '"$GVISOR_GUIX_MKDIR"',
        '"$GVISOR_GUIX_DIRNAME"',
        "use_default_shell_env = True",
    ):
        if marker not in release_rule:
            raise SetupError("release shell action does not use declared Guix tools")
    extension = (source / "tools/bazeldefs/extensions/coral_crosstool.bzl").read_text()
    if "//tools:gvisor-coral-crosstool-guix.patch" in extension:
        raise SetupError("Coral source extension changed and would invalidate the reviewed lock")
    for marker in (
        '"//tools:crosstool-arm-dirs.patch"',
        '"//tools:remove_windows_deps.patch"',
        'sha256 = "f86d488ca353c5ee99187579fe408adb73e9f2bb1d69c6e3a42ffb904ce3ba01"',
    ):
        if marker not in extension:
            raise SetupError(f"Coral source extension lost reviewed marker {marker}")

    configure = (coral / "configure.bzl").read_text()
    template = (coral / "cc_toolchain_config.bzl.tpl").read_text()
    joined = configure + template
    if "/usr/" in joined or "/bin/bash" in joined or "/tools/arm-bcm" in joined:
        raise SetupError("configured Coral crosstool retains an FHS path")
    for marker in (
        "GVISOR_GUIX_NATIVE_TOOL_PREFIX",
        "GVISOR_GUIX_AARCH64_TOOL_PREFIX",
        "%{native_include_directories}%",
        "%{aarch64_include_directories}%",
        'GOLD_LINKER_FLAG = "-fuse-ld=gold"',
    ):
        if marker not in joined:
            raise SetupError(f"configured Coral crosstool is missing {marker}")
    audit_rendered_crosstool(coral, rendered_crosstool)
    if protobuf is not None:
        audit_protobuf(protobuf)


def _starlark_paths(value: str, name: str) -> str:
    paths = value.split(":")
    if not paths or any(not path.startswith("/") for path in paths):
        raise SetupError(f"{name} must contain absolute colon-separated paths")
    return ", ".join(json.dumps(path) for path in paths)


def render_crosstool(args: argparse.Namespace) -> None:
    coral = Path(args.coral)
    output = Path(args.output)
    if not coral.is_absolute() or not coral.is_dir():
        raise SetupError(f"Coral source is not an absolute directory: {coral}")
    if output.exists():
        raise SetupError(f"rendered crosstool output already exists: {output}")
    for prefix, name in (
        (args.native_tool_prefix, "native tool prefix"),
        (args.aarch64_tool_prefix, "AArch64 tool prefix"),
    ):
        if not prefix.startswith("/"):
            raise SetupError(f"{name} is not absolute: {prefix}")
    for include, name in (
        (args.native_linux_include, "native Linux include directory"),
        (args.target_linux_include, "target Linux include directory"),
    ):
        if not include.startswith("/"):
            raise SetupError(f"{name} is not absolute: {include}")

    build_template = coral / "BUILD.tpl"
    config_template = coral / "cc_toolchain_config.bzl.tpl"
    if not build_template.is_file() or not config_template.is_file():
        raise SetupError("patched Coral source is missing a crosstool template")
    replacements = {
        "%{aarch64_include_directories}%": _starlark_paths(
            args.aarch64_include_roots, "AArch64 include roots"
        ),
        "%{aarch64_tool_prefix}%": args.aarch64_tool_prefix,
        "%{native_include_directories}%": _starlark_paths(
            args.native_include_roots, "native include roots"
        ),
        "%{native_tool_prefix}%": args.native_tool_prefix,
        "%{c_version}%": "gnu17",
        "%{cpp_version}%": "c++11",
        "%{aarch64_system_include_directory}%": json.dumps(
            args.target_linux_include
        ),
        "%{native_system_include_directory}%": json.dumps(
            args.native_linux_include
        ),
    }
    config = config_template.read_text()
    for marker, value in replacements.items():
        if config.count(marker) != 1:
            raise SetupError(f"Coral template has unexpected marker count for {marker}")
        config = config.replace(marker, value)
    if re.search(r"%\{[^}]+\}%", config):
        raise SetupError("rendered Coral crosstool retains a template marker")
    if any(path in config for path in ("/usr/", "/bin/bash", "/tools/arm-bcm")):
        raise SetupError("rendered Coral crosstool retains an FHS path")
    if 'GOLD_LINKER_FLAG = "-fuse-ld=gold"' not in config:
        raise SetupError("rendered Coral crosstool lost binutils-gold selection")
    if "SYSTEM_INCLUDE_DIRECTORIES" not in config:
        raise SetupError("rendered Coral crosstool lost target-specific Linux headers")

    output.mkdir(parents=True)
    shutil.copyfile(build_template, output / "BUILD")
    (output / "cc_toolchain_config.bzl").write_text(config)
    (output / "REPO.bazel").write_text("")


def audit_rendered_crosstool(coral: Path, rendered: Path) -> None:
    expected = ["BUILD", "REPO.bazel", "cc_toolchain_config.bzl"]
    if not rendered.is_dir() or sorted(path.name for path in rendered.iterdir()) != expected:
        raise SetupError("rendered crosstool repository has an unexpected layout")
    if (rendered / "BUILD").read_bytes() != (coral / "BUILD.tpl").read_bytes():
        raise SetupError("rendered crosstool BUILD differs from the patched template")
    if (rendered / "REPO.bazel").read_text() != "":
        raise SetupError("rendered crosstool REPO.bazel is not empty")
    config = (rendered / "cc_toolchain_config.bzl").read_text()
    if re.search(r"%\{[^}]+\}%", config) or any(
        path in config for path in ("/usr/", "/bin/bash", "/tools/arm-bcm")
    ):
        raise SetupError("rendered crosstool retains a template or FHS path")
    for marker in (
        'GOLD_LINKER_FLAG = "-fuse-ld=gold"',
        "x86_64-linux-gnu-",
        "aarch64-linux-gnu-",
    ):
        if marker not in config:
            raise SetupError(f"rendered crosstool is missing {marker}")


def configured_closure_partition(path: Path) -> Counter:
    configurations: dict[str, Counter] = defaultdict(Counter)
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = CONFIGURED_LABEL.fullmatch(line)
        if not match:
            raise SetupError(f"invalid configured closure line {path}:{number}: {line}")
        label, configuration = match.groups()
        configurations[configuration][label] += 1
    if not configurations:
        raise SetupError(f"configured closure is empty: {path}")
    # Bazel's short configuration IDs are opaque hashes.  Declared Guix tool
    # paths intentionally rename them, so compare the complete multiset of
    # labels in each configuration partition rather than the hash spellings.
    return Counter(
        tuple(sorted(labels.items())) for labels in configurations.values()
    )


def compare_configured_closures(expected: Path, actual: Path) -> None:
    expected_partition = configured_closure_partition(expected)
    actual_partition = configured_closure_partition(actual)
    if actual_partition != expected_partition:
        raise SetupError("configured closure partition differs from the reviewed target manifest")


def audit_package_definition(scheme: Path) -> None:
    text = scheme.read_text()
    runtime = text[text.index('(define-public gvisor/source') :]
    required = (
        '(define-public gvisor/source',
        '(name "gvisor-source-built")',
        '(supported-systems \'("x86_64-linux"))',
        '(%current-target-system)',
        '"--repository_disable_download"',
        '"--repo_contents_cache="',
        '"--lockfile_mode=error"',
        '"--incompatible_strict_action_env"',
        '"--spawn_strategy=local"',
        '"--@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false"',
        '"--workspace_status_command="',
        '"--embed_label=release-20260831.0"',
        '"--action-shell"',
        '"--action_env=GVISOR_PREWARMER_INCLUDE_FLAGS="',
        '"--host_action_env=GVISOR_PREWARMER_INCLUDE_FLAGS="',
        '"--action_env=GVISOR_GUIX_CAT="',
        '"--host_action_env=GVISOR_GUIX_CAT="',
        '"--action_env=GVISOR_GUIX_GREP="',
        '"--host_action_env=GVISOR_GUIX_GREP="',
        '"--host_action_env=GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS="',
        '"--host_action_env=GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS="',
        '"--action_env=GVISOR_VDSO_NATIVE_INCLUDE_FLAGS="',
        '"--host_action_env=GVISOR_VDSO_NATIVE_INCLUDE_FLAGS="',
        '"--action_env=GVISOR_VDSO_AARCH64_INCLUDE_FLAGS="',
        '"--host_action_env=GVISOR_VDSO_AARCH64_INCLUDE_FLAGS="',
        '"GVISOR_PREWARMER_INCLUDE_FLAGS"',
        '"GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS"',
        '"GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS"',
        '"GVISOR_VDSO_NATIVE_INCLUDE_FLAGS"',
        '"GVISOR_VDSO_AARCH64_INCLUDE_FLAGS"',
        '"GVISOR_NATIVE_LINUX_INCLUDE"',
        '"GVISOR_TARGET_LINUX_INCLUDE"',
        '"--target-linux-include"',
        '"--vendor-protobuf"',
        '"../patches/gvisor-protobuf-authenticity-guix-tools.patch"',
        '"../patches/gvisor-nogo-bazel8-file-path.patch"',
        '"../patches/gvisor-nogo-go126-stdlib-filter.patch"',
        '"../patches/gvisor-vdso-guix-headers.patch"',
        '"--jobs=2"',
        '"--local_ram_resources=4096"',
        '"--host_jvm_args=-Xmx8192m"',
        '"--action_env=PATH="',
        '"--host_action_env=PATH="',
        '"--repo_env=PATH="',
        '"--action_env=CC="',
        '"--host_action_env=CXX="',
        '"--repo_env=LD="',
        '"--shell_executable="',
        '"--override_repository="',
        '"/coral-crosstool"',
        '"/crosstool"',
        '"+crosstool_extension+crosstool="',
        '"compare-closure"',
        '"/repository-cache"',
        '"/empty-cache"',
        '"/action-cache"',
        '"/.gvisor-bazel-private"',
        '"/vendor-repo-contents"',
        '"/analysis-repo-contents"',
        '"/build-repo-contents"',
        '(setenv "HOME" home)',
        '(setenv "PATH" action-path)',
        '(setenv "SHELL" bash)',
        '(for-each unsetenv',
        '"GVISOR_BPF_INCLUDE_FLAGS"',
        '"GVISOR_GUIX_NATIVE_TOOL_PREFIX"',
        '"GVISOR_GUIX_CP"',
        '"GVISOR_GUIX_MKDIR"',
        '"GVISOR_GUIX_DIRNAME"',
        '"--action-cp"',
        '"--action-mkdir"',
        '"--action-dirname"',
        '"GVISOR_GUIX_AARCH64_TOOL_PREFIX"',
    )
    for fragment in required:
        if fragment not in text:
            raise SetupError(f"runtime package definition lost required boundary {fragment}")
    forbidden = (
        "guix shell --container",
        "9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e",
        '(getenv "HOME")',
        '(getenv "XDG_CACHE_HOME")',
        '(setenv "CPATH"',
        '(setenv "C_INCLUDE_PATH"',
        '(setenv "CPLUS_INCLUDE_PATH"',
        '"+coral_crosstool_extension+coral_crosstool="',
        '(invoke "cmp" closure',
        '"--@com_google_protobuf//bazel/toolchains:allow_nonstandard_protoc',
    )
    for fragment in forbidden:
        if fragment in text:
            raise SetupError(f"runtime package definition contains forbidden dependency {fragment}")

    build_phase = runtime[
        runtime.index("(replace 'build") : runtime.index("(replace 'check")
    ]
    for fragment in (
        '"--repository_disable_download"',
        '"--repo_contents_cache="',
    ):
        if fragment not in build_phase:
            raise SetupError(
                f"runtime build phase lost required boundary {fragment}"
            )
    for interface in ("(srfi srfi-1)", "(srfi srfi-13)"):
        if interface not in build_phase:
            raise SetupError(
                f"runtime build phase lost required Guile interface {interface}"
            )
    for leaf in (
        "vendor-repo-contents",
        "analysis-repo-contents",
        "build-repo-contents",
    ):
        if f'(string-append work "/{leaf}")' in build_phase:
            raise SetupError("repository-contents cache moved inside the workspace")
    if '(string-append work "/crosstool")' in build_phase:
        raise SetupError("rendered crosstool override moved inside the workspace")


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser()
    commands = top.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("prepare")
    setup.add_argument("--architecture", required=True)
    setup.add_argument("--output", required=True)
    setup.add_argument("--native-gcc", required=True)
    setup.add_argument("--native-binutils", required=True)
    setup.add_argument("--native-libc", required=True)
    setup.add_argument("--clang", required=True)
    setup.add_argument("--linux-headers", required=True)
    setup.add_argument("--libbpf", required=True)
    setup.add_argument("--action-shell", required=True)
    setup.add_argument("--action-cp", required=True)
    setup.add_argument("--action-mkdir", required=True)
    setup.add_argument("--action-dirname", required=True)
    setup.add_argument("--action-root", action="append", default=[])
    setup.add_argument("--target-gcc")
    setup.add_argument("--target-gcc-lib")
    setup.add_argument("--target-linux-headers")
    setup.add_argument("--target-binutils")
    setup.add_argument("--target-libc")
    setup.add_argument("--require-store", action="store_true")
    check = commands.add_parser("audit")
    check.add_argument("--source", type=Path, required=True)
    check.add_argument("--vendor-coral", type=Path, required=True)
    check.add_argument("--rendered-crosstool", type=Path, required=True)
    check.add_argument("--vendor-protobuf", type=Path)
    render = commands.add_parser("render-crosstool")
    render.add_argument("--coral", required=True)
    render.add_argument("--output", required=True)
    render.add_argument("--native-tool-prefix", required=True)
    render.add_argument("--native-include-roots", required=True)
    render.add_argument("--aarch64-tool-prefix", required=True)
    render.add_argument("--aarch64-include-roots", required=True)
    render.add_argument("--native-linux-include", required=True)
    render.add_argument("--target-linux-include", required=True)
    closure = commands.add_parser("compare-closure")
    closure.add_argument("--expected", type=Path, required=True)
    closure.add_argument("--actual", type=Path, required=True)
    wrapper = commands.add_parser("compiler-wrapper")
    wrapper.add_argument("--shell", type=Path, required=True)
    wrapper.add_argument("--compiler", type=Path, required=True)
    wrapper.add_argument("--output", type=Path, required=True)
    package = commands.add_parser("audit-package")
    package.add_argument("--scheme", type=Path, required=True)
    return top


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "prepare":
            prepare(args)
        elif args.command == "audit":
            audit(
                args.source,
                args.vendor_coral,
                args.rendered_crosstool,
                args.vendor_protobuf,
            )
        elif args.command == "render-crosstool":
            render_crosstool(args)
        elif args.command == "compare-closure":
            compare_configured_closures(args.expected, args.actual)
        elif args.command == "compiler-wrapper":
            write_compiler_wrapper(args.output, args.shell, args.compiler)
        else:
            audit_package_definition(args.scheme)
    except (OSError, SetupError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
