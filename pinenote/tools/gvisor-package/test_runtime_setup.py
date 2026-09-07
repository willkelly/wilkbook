#!/usr/bin/env python3
"""Mocked tool-root and source-audit tests for the runtime package gate."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


def load(path: Path):
    spec = importlib.util.spec_from_file_location("runtime_setup", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


MODULE = load(Path(sys.argv[1])) if len(sys.argv) > 1 else None


class RuntimeSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.native_gcc = self.tool_root(
            "native-gcc", MODULE.GCC_TOOLS, compiler_probe=True
        )
        self.native_binutils = self.tool_root("native-binutils", MODULE.BINUTILS_TOOLS)
        self.native_libc = self.tool_root("native-libc")
        self.clang = self.tool_root("clang", ("clang",))
        self.headers = self.tool_root("headers")
        self.libbpf = self.tool_root("libbpf")
        (self.headers / "include").mkdir()
        (self.libbpf / "include").mkdir()
        self.actions = self.tool_root("actions", ("bash", "cp", "mkdir", "dirname"))
        self.target_gcc = self.tool_root(
            "target-gcc",
            (f"aarch64-linux-gnu-{tool}" for tool in MODULE.GCC_TOOLS),
            compiler_probe=True,
        )
        self.target_binutils = self.tool_root(
            "target-binutils",
            (f"aarch64-linux-gnu-{tool}" for tool in MODULE.BINUTILS_TOOLS),
        )
        self.target_gcc_lib = self.tool_root("target-gcc-lib")
        self.target_libc = self.tool_root("target-libc")
        self.target_linux_headers = self.tool_root("target-linux-headers")
        (self.target_linux_headers / "include").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def tool_root(self, name: str, programs=(), compiler_probe=False) -> Path:
        root = self.root / name
        (root / "bin").mkdir(parents=True)
        if compiler_probe:
            (root / "include/c++").mkdir(parents=True)
            (root / "include/libc").mkdir(parents=True)
        for program in programs:
            path = root / "bin" / program
            if compiler_probe and program.endswith("g++"):
                path.write_text(
                    f"#!{sys.executable}\n"
                    "import sys\n"
                    f"sys.stderr.write('#include <...> search starts here:\\n {root}/include/c++\\n {root}/include/libc\\nEnd of search list.\\n')\n"
                )
            else:
                path.write_text("tool")
            path.chmod(0o755)
        return root

    def args(self, architecture="native-x86_64", output="out", **extra):
        values = dict(
            architecture=architecture,
            output=str(self.root / output),
            native_gcc=str(self.native_gcc),
            native_binutils=str(self.native_binutils),
            native_libc=str(self.native_libc),
            clang=str(self.clang),
            linux_headers=str(self.headers),
            libbpf=str(self.libbpf),
            action_shell=str(self.actions / "bin/bash"),
            action_cp=str(self.actions / "bin/cp"),
            action_mkdir=str(self.actions / "bin/mkdir"),
            action_dirname=str(self.actions / "bin/dirname"),
            action_root=[str(self.actions)],
            target_gcc=str(self.target_gcc),
            target_gcc_lib=str(self.target_gcc_lib),
            target_binutils=str(self.target_binutils),
            target_libc=str(self.target_libc),
            target_linux_headers=str(self.target_linux_headers),
            require_store=False,
        )
        values.update(extra)
        return argparse.Namespace(**values)

    def test_native_setup_has_only_explicit_paths(self):
        result = MODULE.prepare(self.args())
        environment = result["environment"]
        self.assertEqual(result["bazel_config"], "x86_64")
        self.assertNotIn("/usr", environment["PATH"])
        self.assertNotIn(":/bin", environment["PATH"])
        gcc = Path(environment["GVISOR_GUIX_NATIVE_TOOL_PREFIX"] + "gcc")
        self.assertFalse(gcc.is_symlink())
        self.assertIn(str(self.native_gcc / "bin/gcc"), gcc.read_text())
        self.assertIn(str(self.actions / "bin/bash"), gcc.read_text())
        self.assertEqual(
            environment["GVISOR_GUIX_AARCH64_TOOL_PREFIX"],
            f"{self.root}/out/toolchains/aarch64-linux-gnu/bin/aarch64-linux-gnu-",
        )
        self.assertEqual(
            environment["GVISOR_PREWARMER_INCLUDE_FLAGS"],
            f"-isystem {self.headers}/include",
        )
        self.assertEqual(
            environment["GVISOR_NATIVE_LINUX_INCLUDE"],
            f"{self.headers}/include",
        )
        self.assertEqual(
            environment["GVISOR_TARGET_LINUX_INCLUDE"],
            f"{self.target_linux_headers}/include",
        )
        self.assertEqual(
            environment["GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS"],
            f"-isystem {self.headers}/include",
        )
        self.assertEqual(
            environment["GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS"],
            f"-isystem {self.target_linux_headers}/include",
        )
        self.assertEqual(
            environment["GVISOR_VDSO_NATIVE_INCLUDE_FLAGS"],
            f"-isystem {self.headers}/include",
        )
        self.assertEqual(
            environment["GVISOR_VDSO_AARCH64_INCLUDE_FLAGS"],
            f"-isystem {self.target_linux_headers}/include",
        )
        self.assertEqual(
            (self.root / "out/environment/GVISOR_GUIX_NATIVE_INCLUDE_ROOTS").read_text(),
            environment["GVISOR_GUIX_NATIVE_INCLUDE_ROOTS"] + "\n",
        )

    def test_aarch64_setup_requires_and_links_cross_tools(self):
        result = MODULE.prepare(self.args("aarch64"))
        self.assertEqual(result["closure_file"], "release-closure-aarch64.txt")
        prefix = result["environment"]["GVISOR_GUIX_AARCH64_TOOL_PREFIX"]
        self.assertTrue(Path(prefix + "ld.gold").is_symlink())
        self.assertFalse(Path(prefix + "gcc").is_symlink())
        self.assertIn(
            str(self.target_gcc / "bin/aarch64-linux-gnu-gcc"),
            Path(prefix + "gcc").read_text(),
        )
        self.assertEqual(
            result["environment"]["GVISOR_PREWARMER_INCLUDE_FLAGS"],
            f"-isystem {self.target_linux_headers}/include",
        )
        self.assertEqual(
            result["environment"]["GVISOR_VDSO_AARCH64_INCLUDE_FLAGS"],
            f"-isystem {self.target_linux_headers}/include",
        )
        self.assertEqual(
            result["environment"]["GVISOR_TARGET_LINUX_INCLUDE"],
            f"{self.target_linux_headers}/include",
        )
        self.assertEqual(
            (self.root / "out/environment/GVISOR_PREWARMER_INCLUDE_FLAGS").read_text(),
            f"-isystem {self.target_linux_headers}/include\n",
        )
        self.assertIn(
            str(self.target_gcc / "include/libc"),
            result["environment"]["GVISOR_GUIX_AARCH64_INCLUDE_ROOTS"],
        )

    def test_aarch64_missing_toolchain_fails(self):
        with self.assertRaisesRegex(MODULE.SetupError, "missing target GCC"):
            MODULE.prepare(self.args("aarch64", target_gcc=None))

    def test_native_requires_cross_toolchain_for_split_arch_generators(self):
        with self.assertRaisesRegex(MODULE.SetupError, "missing target GCC"):
            MODULE.prepare(self.args(target_gcc=None))

    def test_missing_gold_fails_visibly(self):
        (self.native_binutils / "bin/ld.gold").unlink()
        with self.assertRaisesRegex(MODULE.SetupError, "ld.gold"):
            MODULE.prepare(self.args())

    def test_unsupported_architecture_fails(self):
        with self.assertRaisesRegex(MODULE.SetupError, "unsupported architecture"):
            MODULE.prepare(self.args("riscv64"))

    def test_store_gate_rejects_host_paths(self):
        with self.assertRaisesRegex(MODULE.SetupError, "not a Guix store path"):
            MODULE.prepare(self.args(require_store=True))

    def test_source_audit_accepts_only_patched_shape(self):
        source = self.root / "source"
        coral = self.root / "coral"
        rendered = self.root / "rendered"
        (source / "tools/bazeldefs/extensions").mkdir(parents=True)
        (source / "tools").mkdir(parents=True, exist_ok=True)
        (source / "tools/nogo/check").mkdir(parents=True)
        (source / "tools/nogo/cli").mkdir(parents=True)
        (source / "runsc/checkpointgofer").mkdir(parents=True)
        (source / "runsc/cmd/metricserver").mkdir(parents=True)
        (source / "runsc/cmd/sentry").mkdir(parents=True)
        (source / "runsc/prewarmer").mkdir(parents=True)
        (source / "pkg/sentry/platform/systrap/sysmsg").mkdir(parents=True)
        (source / "tools/parsers").mkdir(parents=True)
        (source / "vdso").mkdir(parents=True)
        coral.mkdir()
        (source / "tools/workspace_status.sh").write_text(
            "echo STABLE_VERSION release-20260831.0\n"
        )
        (source / "tools/bazeldefs/defs.bzl").write_text(
            'cmd = "$$GVISOR_BPF_CLANG -target bpf -D__x86_64__ '
            '$$GVISOR_BPF_INCLUDE_FLAGS"\n'
        )
        (source / "runsc/prewarmer/BUILD").write_text(
            'cmd = "$(CC) $$GVISOR_PREWARMER_INCLUDE_FLAGS"\n'
        )
        (source / "pkg/sentry/platform/systrap/sysmsg/build.bzl").write_text(
            'cmd = "$(CC) $$GVISOR_SYSMSG_NATIVE_INCLUDE_FLAGS " + '
            '"$$GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS"\n'
        )
        (source / "vdso/BUILD").write_text(
            'cmd = "$(CC) $$GVISOR_VDSO_NATIVE_INCLUDE_FLAGS " + '
            '"$$GVISOR_VDSO_AARCH64_INCLUDE_FLAGS"\n'
        )
        (source / "tools/nogo/defs.bzl").write_text(
            'go_ctx.stdlib_mod.path\n'
        )
        (source / "tools/nogo/cli/cli.go").write_text(
            r'regexp.MustCompile(`(?m)^go\s+(\S+)`)' + "\n"
        )
        (source / "tools/nogo/check/build.go").write_text(
            '\n'.join((
                '"crypto/internal/sysrand/internal/seccomp"',
                '"internal/obscuretestdata"',
                '"internal/testpty"',
                '"log/slog/internal/benchmarks"',
                '"net/internal/socktest"',
                '"reflect/internal/example1"',
                '"reflect/internal/example2"',
                'delete(pkgNames, path)',
                'package %q present in stdlib GOROOT but not in source',
            )) + '\n'
        )
        (source / "tools/arch.bzl").write_text(
            'command = \'"$GVISOR_GUIX_CP" source output\'\n'
            'use_default_shell_env = True\n'
        )
        (source / "tools/release.bzl").write_text(
            'command = \'"$GVISOR_GUIX_CP" source output; '
            '"$GVISOR_GUIX_MKDIR" -p dir; '
            '"$GVISOR_GUIX_DIRNAME" output\'\n'
            'use_default_shell_env = True\n'
        )
        for path, count in (
            (source / "runsc/BUILD", 3),
            (source / "runsc/checkpointgofer/BUILD", 1),
            (source / "runsc/cmd/metricserver/BUILD", 1),
            (source / "runsc/cmd/sentry/BUILD", 2),
            (source / "tools/parsers/BUILD", 1),
        ):
            path.write_text('{BUILD_EMBED_LABEL}\n' * count)
        (source / "tools/bazeldefs/BUILD").write_text("grep BUILD_EMBED_LABEL\n")
        (source / "tools/bazeldefs/extensions/coral_crosstool.bzl").write_text(
            '"//tools:crosstool-arm-dirs.patch"\n'
            '"//tools:remove_windows_deps.patch"\n'
            'sha256 = "f86d488ca353c5ee99187579fe408adb73e9f2bb1d69c6e3a42ffb904ce3ba01"\n'
        )
        (coral / "configure.bzl").write_text(
            "GVISOR_GUIX_NATIVE_TOOL_PREFIX GVISOR_GUIX_AARCH64_TOOL_PREFIX\n"
        )
        (coral / "BUILD.tpl").write_text("package(default_visibility = [\"//visibility:public\"])\n")
        (coral / "cc_toolchain_config.bzl.tpl").write_text(
            'C_VERSION = "%{c_version}%"\n'
            'CPP_VERSION = "%{cpp_version}%"\n'
            'NATIVE = "%{native_tool_prefix}%"\n'
            'AARCH64 = "%{aarch64_tool_prefix}%"\n'
            "NATIVE_INCLUDES = [%{native_include_directories}%]\n"
            "AARCH64_INCLUDES = [%{aarch64_include_directories}%]\n"
            'SYSTEM_INCLUDE_DIRECTORIES = {\n'
            '    "k8": [%{native_system_include_directory}%],\n'
            '    "aarch64": [%{aarch64_system_include_directory}%],\n'
            '}\n'
            'GOLD_LINKER_FLAG = "-fuse-ld=gold"\n'
        )
        MODULE.render_crosstool(
            argparse.Namespace(
                coral=str(coral),
                output=str(rendered),
                native_tool_prefix="/gnu/store/native/x86_64-linux-gnu-",
                native_include_roots="/gnu/store/native:/gnu/store/libc",
                aarch64_tool_prefix="/gnu/store/target/aarch64-linux-gnu-",
                aarch64_include_roots="/gnu/store/target:/gnu/store/target-libc",
                native_linux_include="/gnu/store/native-linux-headers/include",
                target_linux_include="/gnu/store/target-linux-headers/include",
            )
        )
        self.assertIn(
            '"k8": ["/gnu/store/native-linux-headers/include"]',
            (rendered / "cc_toolchain_config.bzl").read_text(),
        )
        self.assertIn(
            '"aarch64": ["/gnu/store/target-linux-headers/include"]',
            (rendered / "cc_toolchain_config.bzl").read_text(),
        )
        MODULE.audit(source, coral, rendered)
        nogo_filter = source / "tools/nogo/check/build.go"
        valid_nogo_filter = nogo_filter.read_text()
        nogo_filter.write_text(valid_nogo_filter.replace(
            "package %q present in stdlib GOROOT but not in source",
            "continue",
        ))
        with self.assertRaisesRegex(MODULE.SetupError, "filter lost marker"):
            MODULE.audit(source, coral, rendered)
        nogo_filter.write_text(valid_nogo_filter)
        (coral / "configure.bzl").write_text("/bin/bash\n")
        with self.assertRaisesRegex(MODULE.SetupError, "FHS"):
            MODULE.audit(source, coral, rendered)
        (coral / "configure.bzl").write_text("/usr/include\n")
        with self.assertRaisesRegex(MODULE.SetupError, "FHS"):
            MODULE.audit(source, coral, rendered)

    def test_crosstool_renderer_rejects_missing_marker(self):
        coral = self.root / "coral"
        coral.mkdir()
        (coral / "BUILD.tpl").write_text("BUILD\n")
        (coral / "cc_toolchain_config.bzl.tpl").write_text("no markers\n")
        args = argparse.Namespace(
            coral=str(coral),
            output=str(self.root / "rendered"),
            native_tool_prefix="/gnu/store/native/x86_64-linux-gnu-",
            native_include_roots="/gnu/store/native",
            aarch64_tool_prefix="/gnu/store/target/aarch64-linux-gnu-",
            aarch64_include_roots="/gnu/store/target",
            native_linux_include="/gnu/store/native-linux-headers/include",
            target_linux_include="/gnu/store/target-linux-headers/include",
        )
        with self.assertRaisesRegex(MODULE.SetupError, "marker count"):
            MODULE.render_crosstool(args)

    def test_configured_closure_accepts_renamed_configuration_ids(self):
        expected = self.root / "expected.txt"
        actual = self.root / "actual.txt"
        expected.write_text("//:root (aaaaaaa)\n//:file (null)\n//:dep (aaaaaaa)\n")
        actual.write_text("//:dep (bbbbbbb)\n//:file (null)\n//:root (bbbbbbb)\n")
        MODULE.compare_configured_closures(expected, actual)

    def test_configured_closure_rejects_changed_partition(self):
        expected = self.root / "expected.txt"
        actual = self.root / "actual.txt"
        expected.write_text("//:root (aaaaaaa)\n//:dep (aaaaaaa)\n")
        actual.write_text("//:root (bbbbbbb)\n//:dep (ccccccc)\n")
        with self.assertRaisesRegex(MODULE.SetupError, "partition differs"):
            MODULE.compare_configured_closures(expected, actual)

    def test_protobuf_authenticity_audit_requires_declared_tools(self):
        protobuf = self.root / "protobuf"
        source = (
            protobuf
            / "bazel/private/toolchains/prebuilt/protoc_authenticity.bzl"
        )
        source.parent.mkdir(parents=True)
        source.write_text(
            '''"$GVISOR_GUIX_GREP"\n"$GVISOR_GUIX_GREP"\n'''
            '''"$GVISOR_GUIX_CAT"\nuse_default_shell_env = True\n'''
            '''mismatch_exit_code = 1 if ctx.attr.fail_on_mismatch else 0\n'''
            '''"^libprotoc {RELEASE_VERSION}"\n'''
        )
        MODULE.audit_protobuf(protobuf)
        source.write_text(source.read_text().replace(
            "use_default_shell_env = True",
            "use_default_shell_env = False",
        ))
        with self.assertRaisesRegex(MODULE.SetupError, "required marker"):
            MODULE.audit_protobuf(protobuf)

    def test_package_audit_rejects_coral_source_override(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        scheme.write_text(
            source.read_text()
            + '\n"+coral_crosstool_extension+coral_crosstool="\n'
        )
        with self.assertRaisesRegex(MODULE.SetupError, "forbidden dependency"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_missing_downloader_gate(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        text = source.read_text()
        MODULE.audit_package_definition(source)
        marker = "(define-public gvisor/source"
        prefix, runtime = text.split(marker, 1)
        runtime = runtime.replace('"--repository_disable_download"', '"--download"', 1)
        scheme.write_text(prefix + marker + runtime)
        with self.assertRaisesRegex(MODULE.SetupError, "repository_disable_download"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_workspace_status_command(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        text = source.read_text().replace(
            '"--workspace_status_command="',
            '"--workspace_status_command=tools/workspace_status.sh"',
            1,
        )
        scheme.write_text(text)
        with self.assertRaisesRegex(MODULE.SetupError, "workspace_status_command"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_protoc_authenticity_bypass(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        scheme.write_text(
            source.read_text()
            + '\n"--@com_google_protobuf//bazel/toolchains:'
            + 'allow_nonstandard_protoc=true"\n'
        )
        with self.assertRaisesRegex(MODULE.SetupError, "forbidden dependency"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_missing_exec_config_environment(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        text = source.read_text().replace(
            '"--host_action_env=GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS="',
            '"--action_env=GVISOR_SYSMSG_AARCH64_INCLUDE_FLAGS="',
            1,
        )
        scheme.write_text(text)
        with self.assertRaisesRegex(MODULE.SetupError, "host_action_env"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_caller_home(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        scheme.write_text(source.read_text() + '\n(getenv "HOME")\n')
        with self.assertRaisesRegex(MODULE.SetupError, "forbidden dependency"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_missing_build_phase_srfi(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        text = source.read_text()
        marker = "(define-public gvisor/source"
        prefix, runtime = text.split(marker, 1)
        runtime = runtime.replace("(srfi srfi-1)", "(srfi srfi-9)", 1)
        scheme.write_text(prefix + marker + runtime)
        with self.assertRaisesRegex(MODULE.SetupError, "srfi-1"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_workspace_repo_contents_cache(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        text = source.read_text().replace(
            '(string-append private "/vendor-repo-contents")',
            '(string-append work "/vendor-repo-contents")',
            1,
        )
        scheme.write_text(text)
        with self.assertRaisesRegex(MODULE.SetupError, "inside the workspace"):
            MODULE.audit_package_definition(scheme)

    def test_package_audit_rejects_workspace_crosstool_override(self):
        scheme = self.root / "package.scm"
        source = Path(__file__).parents[2] / "packages/gvisor-source.scm"
        text = source.read_text().replace(
            '(string-append private "/crosstool")',
            '(string-append work "/crosstool")',
            1,
        )
        scheme.write_text(text)
        with self.assertRaisesRegex(MODULE.SetupError, "override moved inside"):
            MODULE.audit_package_definition(scheme)


if __name__ == "__main__":
    if MODULE is None:
        raise SystemExit("usage: test_runtime_setup.py RUNTIME_SETUP.py")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
