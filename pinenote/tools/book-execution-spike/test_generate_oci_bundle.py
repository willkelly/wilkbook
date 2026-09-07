#!/usr/bin/env python3
"""Host-only tests for the retained Python policy oracle; runsc never runs."""

from __future__ import annotations

from contextlib import redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "wilkbook_generate_oci_bundle", HERE / "generate_oci_bundle.py"
)
assert SPEC and SPEC.loader
bundle_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle_module)


class BundleFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wilkbook-oci-test-", dir="/tmp/opencode"
        )
        self.top = Path(self.temporary.name)
        self.store = self.top / "store"
        self.store.mkdir()
        self.output_parent = self.top / "outputs"
        self.output_parent.mkdir()

        self.profile = self._item(
            "a", "wilkbook-book-execution-languages", directory=True
        )
        self.python = self._item("b", "python", directory=True)
        self.guile = self._item("c", "guile", directory=True)
        self.book_item = self._item("d", "book-fixture", directory=True)

        (self.python / "bin").mkdir()
        python = self.python / "bin/python3"
        python.write_bytes(b"trusted test executable\n")
        python.chmod(0o555)
        (self.guile / "bin").mkdir()
        guile = self.guile / "bin/guile"
        guile.write_bytes(b"trusted test executable\n")
        guile.chmod(0o555)
        (self.guile / "share").mkdir()
        (self.guile / "share/marker").write_text("guile\n", encoding="ascii")
        (self.profile / "bin").mkdir()
        (self.profile / "bin/python3").symlink_to(python)
        (self.profile / "bin/guile").symlink_to(guile)
        (self.profile / "manifest").write_text(
            "trusted fake Guix profile manifest\n", encoding="ascii"
        )

        self.book = self.book_item / "book.txt"
        self.book.write_text("selected immutable fixture\n", encoding="utf-8")
        self.book.chmod(0o444)

        # The selected profile path is intentionally a two-link alias chain.
        # This is how /etc/.../profile reaches an immutable Guix profile.
        self.profile_alias_1 = self.top / "profile-alias-1"
        self.profile_alias_2 = self.top / "profile-alias-2"
        self.profile_alias_1.symlink_to(self.profile)
        self.profile_alias_2.symlink_to(self.profile_alias_1)
        self.closure = [self.profile, self.python, self.guile]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _item(self, character: str, name: str, *, directory: bool) -> Path:
        path = self.store / (character * 32 + "-" + name)
        if directory:
            path.mkdir()
        else:
            path.write_text(name, encoding="ascii")
        return path

    def _generate(
        self,
        *,
        profile: Path | None = None,
        book: Path | None = None,
        closure: list[Path] | None = None,
        bundle_name: str = "bundle",
        container_id: str = "wilkbook-python-smoke",
        execution_profile: str,
    ) -> Path:
        return bundle_module.generate_bundle(
            profile_input=str(profile or self.profile_alias_2),
            book_input=str(book or self.book),
            bundle_input=str(self.output_parent / bundle_name),
            container_id=container_id,
            execution_profile=execution_profile,
            requisites_runner=lambda _profile: [
                str(path) for path in (closure if closure is not None else self.closure)
            ],
            store_root=self.store,
        )


class GeneratedPolicyTests(BundleFixture):
    def test_custom_named_profile_is_validated_by_structure_not_suffix(self) -> None:
        self.assertFalse(self.profile.name.endswith("-profile"))
        bundle = self._generate(execution_profile="isolation-userns")
        self.assertEqual(
            os.readlink(bundle / "rootfs/profile"),
            f"/gnu/store/{self.profile.name}",
        )

    def test_exact_narrow_bundle_and_launch_policy(self) -> None:
        bundle = self._generate(execution_profile="functional-directfs")
        config = json.loads((bundle / "config.json").read_text(encoding="utf-8"))

        self.assertEqual(config["ociVersion"], "1.0.2")
        self.assertEqual(
            set(config),
            {"hostname", "linux", "mounts", "ociVersion", "process", "root"},
        )
        self.assertEqual(config["root"], {"path": "rootfs", "readonly": True})
        process = config["process"]
        self.assertFalse(process["terminal"])
        self.assertEqual(
            process["user"],
            {"uid": 65534, "gid": 65534, "additionalGids": [], "umask": 63},
        )
        self.assertTrue(process["noNewPrivileges"])
        self.assertEqual(
            process["capabilities"],
            {
                "ambient": [],
                "bounding": [],
                "effective": [],
                "inheritable": [],
                "permitted": [],
            },
        )
        self.assertEqual(process["args"][:3], ["/profile/bin/python3", "-I", "-c"])
        self.assertIn('Path("/book/input")', process["args"][3])
        self.assertIn('Path("/scratch/book-size")', process["args"][3])
        self.assertIn('sock.connect(("192.0.2.1", 9))', process["args"][3])
        self.assertIn(
            "BOOKEXEC-PAYLOAD-PYTHON book-bytes={len(data)}", process["args"][3]
        )
        self.assertEqual(
            process["env"],
            [
                "HOME=/scratch",
                "LANG=C.UTF-8",
                "LC_ALL=C.UTF-8",
                "PATH=/profile/bin",
                "PYTHONNOUSERSITE=1",
                "TMPDIR=/scratch",
            ],
        )
        self.assertNotIn("resources", config["linux"])
        self.assertEqual(
            config["linux"]["cgroupsPath"],
            "/wilkbook-execution-wilkbook-python-smoke",
        )
        self.assertEqual(
            set(config["linux"]),
            {"cgroupsPath", "maskedPaths", "namespaces", "readonlyPaths"},
        )
        self.assertNotIn(
            "user", {namespace["type"] for namespace in config["linux"]["namespaces"]}
        )

        mounts = config["mounts"]
        by_destination = {mount["destination"]: mount for mount in mounts}
        expected_store_destinations = {
            f"/gnu/store/{path.name}" for path in self.closure
        }
        actual_store_destinations = {
            destination
            for destination in by_destination
            if destination.startswith("/gnu/store/")
        }
        self.assertEqual(actual_store_destinations, expected_store_destinations)
        self.assertNotIn("/gnu/store", by_destination)
        for item in self.closure:
            mount = by_destination[f"/gnu/store/{item.name}"]
            self.assertEqual(mount["source"], str(item))
            self.assertEqual(mount["options"], ["bind", "ro", "nosuid", "nodev"])

        self.assertEqual(by_destination["/book/input"]["source"], str(self.book))
        self.assertEqual(
            by_destination["/book/input"]["options"],
            ["bind", "ro", "nosuid", "nodev", "noexec"],
        )
        scratch = by_destination["/scratch"]
        self.assertEqual(scratch["type"], "tmpfs")
        self.assertIn("size=16777216", scratch["options"])
        self.assertIn("mode=1777", scratch["options"])
        self.assertEqual(by_destination["/dev"]["type"], "tmpfs")
        self.assertNotIn("/dev/kvm", by_destination)
        self.assertNotIn("/data", by_destination)
        self.assertFalse(
            any(
                mount.get("source") == "/gnu/store"
                or str(mount.get("source", "")).startswith("/data")
                or str(mount.get("source", "")).startswith("/run/")
                for mount in mounts
            )
        )

        rootfs = bundle / "rootfs"
        self.assertEqual(
            os.readlink(rootfs / "profile"), f"/gnu/store/{self.profile.name}"
        )
        self.assertTrue((rootfs / "book/input").is_file())
        self.assertFalse((rootfs / "data").exists())
        self.assertFalse((rootfs / "run").exists())

        launch = json.loads((bundle / "launch.json").read_text(encoding="utf-8"))
        self.assertEqual(launch["executionProfile"], "functional-directfs")
        self.assertEqual(launch["claim"], "functional-only-not-isolation-acceptance")
        self.assertEqual(launch["requiredKernelConfig"], ["CONFIG_USER_NS=y"])
        self.assertEqual(
            launch["cgroupsPath"], "/wilkbook-execution-wilkbook-python-smoke"
        )
        self.assertEqual(launch["supervisorUid"], 0)
        self.assertEqual(
            launch["supervisorEnv"],
            [
                "HOME=/nonexistent",
                "LANG=C",
                "LC_ALL=C",
                "PATH=/run/current-system/profile/bin",
                f"TMPDIR={bundle}/supervisor-tmp",
            ],
        )
        self.assertEqual(
            launch["argv"],
            [
                "/run/current-system/profile/bin/runsc",
                f"--root={bundle}/runsc-state",
                "--debug=true",
                "--debug-log-format=text",
                "--alsologtostderr=true",
                f"--debug-log={bundle}/runsc-debug/",
                f"--panic-log={bundle}/runsc-panic/runsc.panic.%COMMAND%.log",
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
                "--directfs=true",
                "run",
                f"--bundle={bundle}",
                "wilkbook-python-smoke",
            ],
        )
        rendered = "\n".join(launch["argv"])
        self.assertNotIn("ptrace", rendered)
        self.assertNotIn("kvm", rendered.lower())
        self.assertNotIn("--ignore-cgroups", launch["argv"])
        self.assertIn("--ignore-cgroups=false", launch["argv"])
        run_script = (bundle / "run.sh").read_text(encoding="utf-8")
        self.assertNotIn("||", run_script)
        self.assertNotIn("$@", run_script)
        self.assertNotIn("ptrace", run_script)
        self.assertNotIn("kvm", run_script.lower())
        self.assertIn("/run/current-system/profile/bin/env -i", run_script)
        self.assertIn("/run/current-system/profile/bin/id -u", run_script)
        self.assertIn("requires guest-root runsc supervisor", run_script)
        self.assertNotIn("GVISOR_ENFORCE_RELEASE", run_script)
        self.assertNotIn("BOOKEXEC-PAYLOAD-PYTHON", run_script)
        self.assertIn(f"TMPDIR={bundle}/supervisor-tmp", run_script)
        self.assertEqual(stat.S_IMODE((bundle / "config.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((bundle / "run.sh").stat().st_mode), 0o500)
        self.assertEqual(stat.S_IMODE((bundle / "runsc-debug").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((bundle / "runsc-panic").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((bundle / "runsc-state").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((bundle / "supervisor-tmp").stat().st_mode), 0o700)

    def test_isolation_profile_is_explicit_and_requires_user_namespaces(self) -> None:
        bundle = self._generate(
            execution_profile="isolation-userns", bundle_name="isolation"
        )
        launch = json.loads((bundle / "launch.json").read_text(encoding="utf-8"))
        self.assertEqual(launch["executionProfile"], "isolation-userns")
        self.assertEqual(launch["claim"], "isolation-candidate-not-yet-accepted")
        self.assertEqual(launch["requiredKernelConfig"], ["CONFIG_USER_NS=y"])
        self.assertIn("--directfs=false", launch["argv"])
        self.assertNotIn("--directfs=true", launch["argv"])

    def test_cli_has_no_implicit_execution_profile(self) -> None:
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                bundle_module.parse_args(
                    [
                        "--profile",
                        str(self.profile),
                        "--book",
                        str(self.book),
                        "--bundle",
                        str(self.output_parent / "missing-mode"),
                    ]
                )

    def test_output_is_deterministic_except_trusted_bundle_path(self) -> None:
        first = self._generate(
            bundle_name="first", execution_profile="functional-directfs"
        )
        second = self._generate(
            bundle_name="second", execution_profile="functional-directfs"
        )
        first_config = (first / "config.json").read_bytes()
        second_config = (second / "config.json").read_bytes()
        self.assertEqual(first_config, second_config)
        first_launch = json.loads((first / "launch.json").read_text())
        second_launch = json.loads((second / "launch.json").read_text())
        for launch, bundle in ((first_launch, first), (second_launch, second)):
            launch["argv"] = [
                argument.replace(str(bundle), "BUNDLE")
                for argument in launch["argv"]
            ]
            launch["supervisorEnv"][-1] = "TMPDIR=SUPERVISOR-TMP"
        self.assertEqual(first_launch, second_launch)


class InputRejectionTests(BundleFixture):
    def assert_rejected(self, **kwargs) -> None:
        kwargs.setdefault("execution_profile", "functional-directfs")
        with self.assertRaises(bundle_module.BundleError):
            self._generate(**kwargs)

    def test_profile_alias_chain_is_the_only_input_symlink_exception(self) -> None:
        self._generate(execution_profile="functional-directfs")
        outside = self.top / "outside-profile"
        outside.mkdir()
        self.assert_rejected(profile=outside, bundle_name="outside")
        self.assert_rejected(profile=Path("relative-profile"), bundle_name="relative")

    def test_nonprofile_and_missing_language_entries_fail_closed(self) -> None:
        no_manifest = self._item("e", "ordinary-directory", directory=True)
        (no_manifest / "bin").mkdir()
        (no_manifest / "bin/python3").symlink_to(self.python / "bin/python3")
        (no_manifest / "bin/guile").symlink_to(self.guile / "bin/guile")
        with self.assertRaisesRegex(
            bundle_module.BundleError, "profile manifest is not a real regular"
        ):
            self._generate(
                profile=no_manifest,
                closure=[no_manifest, self.python, self.guile],
                bundle_name="missing-manifest",
                execution_profile="isolation-userns",
            )

        no_entries = self._item("f", "manifest-only", directory=True)
        (no_entries / "manifest").write_text("manifest\n", encoding="ascii")
        with self.assertRaisesRegex(bundle_module.BundleError, "profile has no bin/python3"):
            self._generate(
                profile=no_entries,
                closure=[no_entries, self.python, self.guile],
                bundle_name="missing-python",
                execution_profile="isolation-userns",
            )

        no_guile = self._item("g", "python-only", directory=True)
        (no_guile / "manifest").write_text("manifest\n", encoding="ascii")
        (no_guile / "bin").mkdir()
        (no_guile / "bin/python3").symlink_to(self.python / "bin/python3")
        with self.assertRaisesRegex(bundle_module.BundleError, "profile has no bin/guile"):
            self._generate(
                profile=no_guile,
                closure=[no_guile, self.python, self.guile],
                bundle_name="missing-guile",
                execution_profile="isolation-userns",
            )

    def test_book_must_be_canonical_regular_separate_store_file(self) -> None:
        book_alias = self.top / "book-alias"
        book_alias.symlink_to(self.book)
        self.assert_rejected(book=book_alias, bundle_name="book-link")
        self.assert_rejected(book=self.book_item, bundle_name="book-dir")
        self.assert_rejected(
            book=self.profile / "bin/python3", bundle_name="book-in-closure"
        )
        missing = self.book_item / "missing"
        self.assert_rejected(book=missing, bundle_name="book-missing")
        traversal = Path(str(self.book_item) + "/../" + self.book_item.name + "/book.txt")
        self.assert_rejected(book=traversal, bundle_name="book-traversal")

    def test_requisites_reject_missing_profile_duplicate_nested_and_symlink(self) -> None:
        self.assert_rejected(closure=[self.python], bundle_name="missing-profile")
        self.assert_rejected(
            closure=[self.profile, self.python, self.python], bundle_name="duplicate"
        )
        self.assert_rejected(
            closure=[self.profile, self.python / "bin/python3"],
            bundle_name="nested-requisite",
        )
        linked_item = self.store / ("e" * 32 + "-linked")
        linked_item.symlink_to(self.guile)
        self.assert_rejected(
            closure=[self.profile, self.python, linked_item],
            bundle_name="linked-requisite",
        )
        self.assert_rejected(
            closure=[self.profile, self.python, self.store],
            bundle_name="whole-store-requisite",
        )
        missing_item = self.store / ("f" * 32 + "-missing")
        self.assert_rejected(
            closure=[self.profile, self.python, missing_item],
            bundle_name="missing-requisite",
        )

    def test_invalid_container_id_and_existing_output_are_rejected(self) -> None:
        self.assert_rejected(container_id="../escape", bundle_name="bad-id")
        existing = self.output_parent / "existing"
        existing.mkdir()
        marker = existing / "user-work"
        marker.write_text("keep", encoding="ascii")
        with self.assertRaises(bundle_module.BundleError):
            self._generate(
                bundle_name="existing", execution_profile="functional-directfs"
            )
        self.assertEqual(marker.read_text(encoding="ascii"), "keep")

        linked_parent = self.top / "linked-output-parent"
        linked_parent.symlink_to(self.output_parent)
        with self.assertRaises(bundle_module.BundleError):
            bundle_module.generate_bundle(
                profile_input=str(self.profile_alias_2),
                book_input=str(self.book),
                bundle_input=str(linked_parent / "bundle"),
                container_id="wilkbook-python-smoke",
                execution_profile="functional-directfs",
                requisites_runner=lambda _profile: map(str, self.closure),
                store_root=self.store,
            )

    def test_unknown_execution_profile_is_rejected(self) -> None:
        self.assert_rejected(
            execution_profile="automatic", bundle_name="automatic-profile"
        )


class GuixInvocationTests(BundleFixture):
    def test_guix_gc_uses_an_argument_vector_and_sanitized_environment(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=f"{self.profile}\n{self.python}\n", stderr=""
        )
        with mock.patch.object(bundle_module.subprocess, "run", return_value=completed) as run:
            result = bundle_module.run_guix_requisites(
                self.python / "bin/python3", self.profile
            )
        self.assertEqual(result, [str(self.profile), str(self.python)])
        args, kwargs = run.call_args
        self.assertEqual(
            args[0],
            [
                str(self.python / "bin/python3"),
                "gc",
                "--requisites",
                str(self.profile),
            ],
        )
        self.assertNotIsInstance(args[0], str)
        self.assertEqual(
            kwargs["env"],
            {
                "HOME": "/nonexistent",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/run/current-system/profile/bin:/usr/bin:/bin",
            },
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
