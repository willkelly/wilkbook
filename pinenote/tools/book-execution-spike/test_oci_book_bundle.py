#!/usr/bin/env python3
"""Host-only policy tests for the fixed Book Protocol OCI bundles."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
ADAPTER = HERE / "invoke-oci-book-bundle-test.scm"
MODULE = HERE / "oci-book-bundle.scm"

PINNED_FLAGS = [
    "--platform=systrap",
    "--network=none",
    "--sidecar-usage-policy=strict",
    "--sidecar-release-enforcement-policy=always",
    "--ignore-cgroups=false",
    "--host-uds=none",
    "--host-fifo=none",
    "--character-device-policy=emulated-only",
    "--allow-suid=false",
    "--allow-flag-override=false",
    "--allow-rootfs-tar-annotation=false",
    "--overlay2=none",
    "--rootless=false",
    "--file-access=exclusive",
    "--file-access-mounts=exclusive",
    "--net-raw=false",
    "--allow-packet-socket-write=false",
    "--directfs=false",
]


class FixedProtocolBundleTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wilkbook-protocol-oci.", dir="/tmp/opencode"
        )
        self.top = Path(self.temporary.name)
        self.top.chmod(0o700)
        self.store = self.top / "store"
        self.store.mkdir(mode=0o700)
        self.output = self.top / "output"
        self.output.mkdir(mode=0o700)

        self.profile = self.item("a", "languages", directory=True)
        self.python = self.item("b", "python", directory=True)
        self.guile = self.item("c", "guile", directory=True)
        self.guile_json = self.item("d", "guile-json", directory=True)
        (self.python / "bin").mkdir()
        (self.python / "bin/python3").write_text("python\n", encoding="ascii")
        (self.python / "bin/python3").chmod(0o555)
        (self.guile / "bin").mkdir()
        (self.guile / "bin/guile").write_text("guile\n", encoding="ascii")
        (self.guile / "bin/guile").chmod(0o555)
        (self.profile / "bin").mkdir()
        (self.profile / "bin/python3").symlink_to(self.python / "bin/python3")
        (self.profile / "bin/guile").symlink_to(self.guile / "bin/guile")
        (self.profile / "manifest").write_text("manifest\n", encoding="ascii")

        self.guile_entry = self.item("e", "guile-book.scm", directory=False)
        self.guile_protocol = self.item(
            "f", "book-protocol.scm", directory=False
        )
        self.blocking = self.item("g", "blocking-io.scm", directory=False)
        self.python_entry = self.item("h", "python-book.py", directory=False)
        self.python_protocol = self.item(
            "i", "book_protocol.py", directory=False
        )
        self.closure = [self.profile, self.python, self.guile, self.guile_json]
        self.closure_file = self.top / "closure"
        self.closure_file.write_text(
            "".join(f"{item}\n" for item in self.closure), encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def item(self, character: str, name: str, *, directory: bool) -> Path:
        path = self.store / (character * 32 + "-" + name)
        if directory:
            path.mkdir()
        else:
            path.write_text(f"fixed {name}\n", encoding="utf-8")
            path.chmod(0o444)
        return path

    def invoke(self, kind: str, bundle: Path) -> subprocess.CompletedProcess[str]:
        common = [
            "guile",
            "--no-auto-compile",
            "-L",
            str(HERE),
            str(ADAPTER),
            kind,
            str(self.profile),
        ]
        if kind == "guile":
            arguments = [
                *common,
                str(self.guile_entry),
                str(self.guile_protocol),
                str(self.blocking),
                str(bundle),
                str(self.store),
                str(self.closure_file),
                "wilkbook-guile-book-protocol",
            ]
        else:
            arguments = [
                *common,
                str(self.python_entry),
                str(self.python_protocol),
                str(bundle),
                str(self.store),
                str(self.closure_file),
                "wilkbook-python-book-protocol",
            ]
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": os.environ["PATH"],
        }
        for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
            if name in os.environ:
                environment[name] = os.environ[name]
        return subprocess.run(
            arguments,
            cwd=HERE,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )

    @staticmethod
    def mounts(config: dict[str, object]) -> dict[str, dict[str, object]]:
        return {
            str(mount["destination"]): mount
            for mount in config["mounts"]  # type: ignore[index,union-attr]
        }

    def assert_common_policy(
        self, bundle: Path, config: dict[str, object], launch: dict[str, object]
    ) -> None:
        argv = launch["argv"]
        self.assertEqual(argv[0], "/run/current-system/profile/bin/runsc")
        self.assertEqual(argv[-4:], [
            "run",
            "--pass-fd=3:3",
            f"--bundle={bundle}",
            launch["cgroupsPath"].removeprefix("/wilkbook-execution-"),
        ])
        self.assertEqual(
            argv[1:-4],
            [
                f"--root={bundle}/runsc-state",
                "--debug=true",
                "--debug-log-format=text",
                "--alsologtostderr=true",
                f"--debug-log={bundle}/runsc-debug/",
                f"--panic-log={bundle}/runsc-panic/runsc.panic.%COMMAND%.log",
                *PINNED_FLAGS,
            ],
        )
        self.assertNotIn("--directfs=true", argv)
        self.assertEqual(launch["executionProfile"], "isolation-userns")
        self.assertEqual(launch["requiredKernelConfig"], ["CONFIG_USER_NS=y"])
        self.assertEqual(launch["guestProtocolFd"], 3)
        self.assertEqual(launch["supervisorUid"], 0)
        self.assertEqual(config["linux"]["cgroupsPath"], launch["cgroupsPath"])
        self.assertNotIn("resources", config["linux"])
        self.assertTrue(config["root"]["readonly"])
        self.assertFalse(config["process"]["terminal"])
        self.assertTrue(config["process"]["noNewPrivileges"])
        self.assertEqual(
            config["process"]["capabilities"],
            {
                "ambient": [],
                "bounding": [],
                "effective": [],
                "inheritable": [],
                "permitted": [],
            },
        )
        self.assertEqual(
            config["process"]["user"],
            {"additionalGids": [], "gid": 65534, "uid": 65534, "umask": 63},
        )
        limits = {
            item["type"]: (item["soft"], item["hard"])
            for item in config["process"]["rlimits"]
        }
        self.assertEqual(limits["RLIMIT_FSIZE"], (1048576, 1048576))
        self.assertEqual(limits["RLIMIT_CORE"], (0, 0))
        self.assertEqual(limits["RLIMIT_NOFILE"], (64, 64))
        self.assertNotIn("identity", json.dumps(config).lower())
        self.assertFalse((bundle / "run.sh").exists())
        self.assertFalse((bundle / "launch.scm").exists())
        self.assertEqual(stat.S_IMODE((bundle / "config.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((bundle / "launch.json").stat().st_mode), 0o600)
        for directory in (
            "runsc-state",
            "supervisor-tmp",
            "runsc-debug",
            "runsc-panic",
        ):
            self.assertEqual(stat.S_IMODE((bundle / directory).stat().st_mode), 0o700)

    def test_both_fixed_bundles_have_exact_sources_and_policy(self) -> None:
        bundles = {
            "guile": self.output / "guile",
            "python": self.output / "python",
        }
        expected_sources = {
            "guile": {
                "/book/entry.scm": self.guile_entry,
                "/book/modules/book-protocol.scm": self.guile_protocol,
                "/book/modules/book-protocol/blocking-io.scm": self.blocking,
            },
            "python": {
                "/book/entry.py": self.python_entry,
                "/book/modules/book_protocol.py": self.python_protocol,
            },
        }
        for kind, bundle in bundles.items():
            with self.subTest(kind=kind):
                result = self.invoke(kind, bundle)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, f"{bundle}\n")
                config = json.loads((bundle / "config.json").read_text())
                launch = json.loads((bundle / "launch.json").read_text())
                self.assert_common_policy(bundle, config, launch)
                self.assertEqual(launch["fixtureKind"], kind)
                mounts = self.mounts(config)
                for destination, source in expected_sources[kind].items():
                    self.assertEqual(mounts[destination]["source"], str(source))
                    self.assertEqual(
                        mounts[destination]["options"],
                        ["bind", "ro", "nosuid", "nodev", "noexec"],
                    )
                self.assertEqual(
                    {destination for destination in mounts if destination.startswith("/book")},
                    set(expected_sources[kind]),
                )
                for source in expected_sources[kind].values():
                    self.assertNotIn(
                        f"/gnu/store/{source.name}",
                        {
                            destination
                            for destination in mounts
                            if destination.startswith("/gnu/store/")
                        },
                    )
                self.assertIn("BOOK_SESSION_FD=3", config["process"]["env"])

        guile_config = json.loads((bundles["guile"] / "config.json").read_text())
        self.assertEqual(
            guile_config["process"]["args"],
            [
                "/profile/bin/guile",
                "--no-auto-compile",
                "-L",
                "/book/modules",
                "/book/entry.scm",
            ],
        )
        python_config = json.loads((bundles["python"] / "config.json").read_text())
        self.assertEqual(python_config["process"]["args"][:4], [
            "/profile/bin/python3", "-I", "-B", "-c"
        ])
        self.assertIn("runpy.run_path('/book/entry.py'", python_config["process"]["args"][4])
        self.assertNotIn("argv", python_config["process"]["args"][4])

    def test_source_alias_and_duplicate_fail_before_bundle_creation(self) -> None:
        alias = self.top / "guile-entry-alias"
        alias.symlink_to(self.guile_entry)
        original = self.guile_entry
        self.guile_entry = alias
        bundle = self.output / "alias"
        result = self.invoke("guile", bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain a symlink", result.stderr)
        self.assertFalse(bundle.exists())
        self.guile_entry = original

        self.blocking = self.guile_protocol
        duplicate = self.output / "duplicate"
        result = self.invoke("guile", duplicate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be distinct", result.stderr)
        self.assertFalse(duplicate.exists())

    def test_generator_has_no_cli_or_arbitrary_program_surface(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        self.assertNotIn("getopt-long", source)
        self.assertNotIn("command-line", source)
        self.assertNotIn("oci-book-bundle-main", source)
        self.assertNotIn("program-input", source)
        self.assertNotIn("--preserve-fds", source)
        self.assertEqual(source.count('"--pass-fd=3:3"'), 1)
        self.assertEqual(source.count('"--directfs=false"'), 1)
        self.assertNotIn('"--directfs=true"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
