#!/usr/bin/env python3
"""Independent Python oracle for the trusted Guile OCI generator."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
ADAPTER = HERE / "invoke-oci-bundle-test.scm"
MODULE = HERE / "oci-bundle.scm"
SPEC = importlib.util.spec_from_file_location(
    "wilkbook_python_oci_oracle", HERE / "generate_oci_bundle.py"
)
assert SPEC and SPEC.loader
python_oracle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(python_oracle)


def ignore_sigchld() -> None:
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)


class GuileBundleFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wilkbook-guile-oci-test-", dir="/tmp/opencode"
        )
        self.top = Path(self.temporary.name)
        self.top.chmod(0o700)
        self.store = self.top / "store"
        self.store.mkdir(mode=0o700)
        self.output_parent = self.top / "outputs'private"
        self.output_parent.mkdir(mode=0o700)

        self.profile = self._item(
            "a", "wilkbook-book-execution-languages", directory=True
        )
        self.python = self._item("b", "python", directory=True)
        self.guile = self._item("c", "guile", directory=True)
        self.guile_json = self._item("d", "guile-json", directory=True)
        self.book_item = self._item("e", "book-fixture", directory=True)

        (self.python / "bin").mkdir()
        python = self.python / "bin/python3"
        python.write_bytes(b"trusted test executable\n")
        python.chmod(0o555)
        (self.guile / "bin").mkdir()
        guile = self.guile / "bin/guile"
        guile.write_bytes(b"trusted test executable\n")
        guile.chmod(0o555)
        (self.profile / "bin").mkdir()
        (self.profile / "bin/python3").symlink_to(python)
        (self.profile / "bin/guile").symlink_to(guile)
        (self.profile / "manifest").write_text(
            "trusted fake Guix profile manifest\n", encoding="ascii"
        )
        for item in (self.guile, self.guile_json):
            (item / "share").mkdir()

        self.book = self.book_item / "book.txt"
        self.book.write_text("selected immutable fixture\n", encoding="utf-8")
        self.book.chmod(0o444)

        self.profile_alias_1 = self.top / "profile-alias-1"
        self.profile_alias_2 = self.top / "profile-alias-2"
        self.profile_alias_1.symlink_to(self.profile)
        self.profile_alias_2.symlink_to(self.profile_alias_1)
        self.closure = [self.profile, self.python, self.guile, self.guile_json]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _item(self, character: str, name: str, *, directory: bool) -> Path:
        path = self.store / (character * 32 + "-" + name)
        if directory:
            path.mkdir()
        else:
            path.write_text(name, encoding="ascii")
        return path

    def _closure_file(self, paths: list[Path] | None = None) -> Path:
        closure_file = self.top / ("closure-" + str(len(list(self.top.glob("closure-*")))))
        closure_file.write_text(
            "".join(f"{path}\n" for path in (paths or self.closure)),
            encoding="utf-8",
        )
        return closure_file

    def _invoke_adapter(
        self,
        *arguments: str,
        inherit_sentinel: bool = False,
        ignored_sigchld: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "GUILE_AUTO_COMPILE": "0",
                "SSH_AUTH_SOCK": "/credential/agent.sock",
                "AWS_SECRET_ACCESS_KEY": "must-not-reach-child",
                "GVISOR_ENFORCE_RELEASE": "SKIP",
            }
        )
        pass_fds: tuple[int, ...] = ()
        sentinel_read = sentinel_write = None
        try:
            if inherit_sentinel:
                sentinel_read, sentinel_write = os.pipe()
                os.dup2(sentinel_read, 199, inheritable=True)
                pass_fds = (199,)
            return subprocess.run(
                [
                    "guile",
                    "--no-auto-compile",
                    "-L",
                    str(HERE),
                    str(ADAPTER),
                    *arguments,
                ],
                cwd=HERE,
                env=environment,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=15,
                pass_fds=pass_fds,
                preexec_fn=ignore_sigchld if ignored_sigchld else None,
            )
        finally:
            if inherit_sentinel:
                os.close(199)
                assert sentinel_read is not None and sentinel_write is not None
                if sentinel_read != 199:
                    os.close(sentinel_read)
                os.close(sentinel_write)

    def _generate_guile(
        self,
        *,
        name: str,
        execution_profile: str,
        container_id: str = "wilkbook-python-smoke",
        profile: Path | None = None,
        book: Path | None = None,
        closure: list[Path] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        bundle = self.output_parent / name
        result = self._invoke_adapter(
            "generate",
            str(profile or self.profile_alias_2),
            str(book or self.book),
            str(bundle),
            str(self.store),
            str(self._closure_file(closure)),
            execution_profile,
            container_id,
        )
        return result, bundle

    def _generate_python_reference(
        self, *, name: str, execution_profile: str, container_id: str
    ) -> Path:
        return python_oracle.generate_bundle(
            profile_input=str(self.profile_alias_2),
            book_input=str(self.book),
            bundle_input=str(self.output_parent / name),
            container_id=container_id,
            execution_profile=execution_profile,
            requisites_runner=lambda _: map(str, self.closure),
            store_root=self.store,
        )

    @staticmethod
    def _tree_snapshot(root: Path) -> list[tuple[str, str, int, str | None]]:
        snapshot = []
        for path in sorted(root.rglob("*")):
            info = path.lstat()
            kind = (
                "symlink"
                if stat.S_ISLNK(info.st_mode)
                else "directory"
                if stat.S_ISDIR(info.st_mode)
                else "regular"
                if stat.S_ISREG(info.st_mode)
                else "other"
            )
            snapshot.append(
                (
                    str(path.relative_to(root)),
                    kind,
                    stat.S_IMODE(info.st_mode),
                    os.readlink(path) if kind == "symlink" else None,
                )
            )
        return snapshot


class GuilePolicyOracleTests(GuileBundleFixture):
    def test_custom_named_profile_is_validated_by_structure_not_suffix(self) -> None:
        self.assertFalse(self.profile.name.endswith("-profile"))
        result, bundle = self._generate_guile(
            name="custom-profile-name", execution_profile="isolation-userns"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            os.readlink(bundle / "rootfs/profile"),
            f"/gnu/store/{self.profile.name}",
        )

    def test_nonprofile_and_missing_language_entries_fail_closed(self) -> None:
        no_manifest = self._item("f", "ordinary-directory", directory=True)
        (no_manifest / "bin").mkdir()
        (no_manifest / "bin/python3").symlink_to(self.python / "bin/python3")
        (no_manifest / "bin/guile").symlink_to(self.guile / "bin/guile")
        result, bundle = self._generate_guile(
            name="missing-manifest",
            execution_profile="isolation-userns",
            profile=no_manifest,
            closure=[no_manifest, self.python, self.guile, self.guile_json],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("profile manifest is not a real regular", result.stderr)
        self.assertFalse(bundle.exists())

        no_entries = self._item("g", "manifest-only", directory=True)
        (no_entries / "manifest").write_text("manifest\n", encoding="ascii")
        result, bundle = self._generate_guile(
            name="missing-python",
            execution_profile="isolation-userns",
            profile=no_entries,
            closure=[no_entries, self.python, self.guile, self.guile_json],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("profile has no bin/python3", result.stderr)
        self.assertFalse(bundle.exists())

        no_guile = self._item("h", "python-only", directory=True)
        (no_guile / "manifest").write_text("manifest\n", encoding="ascii")
        (no_guile / "bin").mkdir()
        (no_guile / "bin/python3").symlink_to(self.python / "bin/python3")
        result, bundle = self._generate_guile(
            name="missing-guile",
            execution_profile="isolation-userns",
            profile=no_guile,
            closure=[no_guile, self.python, self.guile, self.guile_json],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("profile has no bin/guile", result.stderr)
        self.assertFalse(bundle.exists())

    def test_guile_policy_matches_independent_python_oracle(self) -> None:
        container_id = "oracle-policy"
        result, guile_bundle = self._generate_guile(
            name="guile-bundle",
            execution_profile="isolation-userns",
            container_id=container_id,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        python_bundle = self._generate_python_reference(
            name="python-reference",
            execution_profile="isolation-userns",
            container_id=container_id,
        )

        guile_config = json.loads((guile_bundle / "config.json").read_text())
        python_config = json.loads((python_bundle / "config.json").read_text())
        self.assertEqual(guile_config, python_config)

        guile_launch = json.loads((guile_bundle / "launch.json").read_text())
        python_launch = json.loads((python_bundle / "launch.json").read_text())
        replacements = {
            str(guile_bundle): "BUNDLE",
            str(python_bundle): "BUNDLE",
        }

        def normalize(value):
            if isinstance(value, str):
                for source, replacement in replacements.items():
                    value = value.replace(source, replacement)
                return value
            if isinstance(value, list):
                return [normalize(item) for item in value]
            if isinstance(value, dict):
                return {key: normalize(item) for key, item in value.items()}
            return value

        self.assertEqual(normalize(guile_launch), normalize(python_launch))
        self.assertEqual(
            self._tree_snapshot(guile_bundle / "rootfs"),
            self._tree_snapshot(python_bundle / "rootfs"),
        )
        common_modes = {
            "config.json": 0o600,
            "launch.json": 0o600,
            "rootfs": 0o755,
            "run.sh": 0o500,
            "runsc-debug": 0o700,
            "runsc-panic": 0o700,
            "runsc-state": 0o700,
            "supervisor-tmp": 0o700,
        }
        for relative, mode in common_modes.items():
            self.assertEqual(
                stat.S_IMODE((guile_bundle / relative).lstat().st_mode), mode
            )
            self.assertEqual(
                stat.S_IMODE((python_bundle / relative).lstat().st_mode), mode
            )
        self.assertEqual(guile_config["linux"]["cgroupsPath"], "/wilkbook-execution-oracle-policy")
        self.assertNotIn("resources", guile_config["linux"])
        self.assertEqual(
            guile_launch["requiredKernelConfig"], ["CONFIG_USER_NS=y"]
        )
        self.assertIn("--directfs=false", guile_launch["argv"])
        self.assertIn("--network=none", guile_launch["argv"])
        self.assertIn("--debug=true", guile_launch["argv"])
        self.assertIn("--debug-log-format=text", guile_launch["argv"])
        self.assertIn("--alsologtostderr=true", guile_launch["argv"])
        self.assertIn(
            f"--debug-log={guile_bundle / 'runsc-debug'}/",
            guile_launch["argv"],
        )
        self.assertIn(
            "--panic-log="
            f"{guile_bundle / 'runsc-panic' / 'runsc.panic.%COMMAND%.log'}",
            guile_launch["argv"],
        )
        security_flags = [
            flag
            for flag in guile_launch["argv"]
            if flag in python_oracle.PINNED_RUNTIME_FLAGS
        ]
        self.assertEqual(
            security_flags, list(python_oracle.PINNED_RUNTIME_FLAGS)
        )
        self.assertEqual(
            [
                flag
                for flag in guile_launch["argv"]
                if flag.startswith("--debug")
                or flag.startswith("--panic-log=")
                or flag == "--alsologtostderr=true"
            ],
            [
                "--debug=true",
                "--debug-log-format=text",
                "--alsologtostderr=true",
                f"--debug-log={guile_bundle / 'runsc-debug'}/",
                "--panic-log="
                f"{guile_bundle / 'runsc-panic' / 'runsc.panic.%COMMAND%.log'}",
            ],
        )
        self.assertNotIn("--TESTONLY", "\n".join(guile_launch["argv"]))
        self.assertIn(
            "BOOKEXEC-PAYLOAD-PYTHON book-bytes={len(data)}",
            guile_config["process"]["args"][3],
        )

        launcher = (guile_bundle / "launch.scm").read_text(encoding="utf-8")
        wrapper = (guile_bundle / "run.sh").read_text(encoding="utf-8")
        self.assertIn("cgroup2-mounted?", launcher)
        self.assertIn("cgroup.controllers", launcher)
        self.assertIn("refusing stale cgroup path", launcher)
        self.assertIn("(environ supervisor-environment)", launcher)
        self.assertIn("(apply execl runsc argv)", launcher)
        self.assertIn("mark-inherited-fds-close-on-exec", launcher)
        self.assertIn("FD_CLOEXEC", launcher)
        self.assertIn("cannot remove the cgroup2 write probe", launcher)
        self.assertLess(
            launcher.index("(preflight-cgroup-child probe path-present? mkdir rmdir)"),
            launcher.index("(apply execl runsc argv)"),
        )
        self.assertIn("SIGCHLD", launcher)
        self.assertIn("SIGPIPE", launcher)
        self.assertIn("/outputs'private/", launcher)
        self.assertIn("/run/current-system/profile/bin/env' -i", wrapper)
        self.assertIn(
            "/etc/wilkbook-execution-spike/supervisor-profile/bin/guile", wrapper
        )
        self.assertIn("'\"'\"'", wrapper)
        self.assertNotIn("/run/current-system/profile/bin/id", wrapper)
        self.assertNotIn("GVISOR_ENFORCE_RELEASE", wrapper + launcher)
        self.assertNotIn("BOOKEXEC-PAYLOAD-PYTHON", wrapper + launcher)
        self.assertEqual(stat.S_IMODE((guile_bundle / "launch.scm").stat().st_mode), 0o400)
        self.assertEqual(stat.S_IMODE((guile_bundle / "run.sh").stat().st_mode), 0o500)

        syntax = subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-c",
                "(call-with-input-file (cadr (command-line)) "
                "(lambda (p) (let loop () (let ((x (read p))) "
                "(unless (eof-object? x) (loop))))))",
                str(guile_bundle / "launch.scm"),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(syntax.returncode, 0, syntax.stdout + syntax.stderr)
        shell_syntax = subprocess.run(
            ["sh", "-n", str(guile_bundle / "run.sh")],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(
            shell_syntax.returncode, 0, shell_syntax.stdout + shell_syntax.stderr
        )

        second_result, second_guile_bundle = self._generate_guile(
            name="deterministic-second",
            execution_profile="isolation-userns",
            container_id=container_id,
        )
        self.assertEqual(
            second_result.returncode, 0, second_result.stdout + second_result.stderr
        )
        self.assertEqual(
            (guile_bundle / "config.json").read_bytes(),
            (second_guile_bundle / "config.json").read_bytes(),
        )
        for relative in ("launch.json", "launch.scm", "run.sh"):
            first = (guile_bundle / relative).read_text(encoding="utf-8")
            second = (second_guile_bundle / relative).read_text(encoding="utf-8")
            self.assertEqual(
                first.replace(guile_bundle.name, "BUNDLE"),
                second.replace(second_guile_bundle.name, "BUNDLE"),
            )

    def test_generated_cgroup_probe_rmdir_failure_is_fatal_and_preserves_error(self) -> None:
        result, bundle = self._generate_guile(
            name="rmdir-failure",
            execution_profile="isolation-userns",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        harness = self.top / "test-generated-cgroup-preflight.scm"
        harness.write_text(
            """(use-modules (ice-9 rdelim))
(define launcher (cadr (command-line)))
(call-with-input-file launcher
  (lambda (port)
    (let loop ()
      (let ((form (read port)))
        (unless (eof-object? form)
          (when (and (pair? form) (memq (car form) '(use-modules define)))
            (eval form (current-module)))
          (loop))))))
(define created? #f)
(define cgroup-procs-present? #t)
(define mkdir-count 0)
(define rmdir-count 0)
(define (fake-present? path)
  (and created? cgroup-procs-present?
       (string=? path "/fake-cgroup/probe/cgroup.procs")))
(define (fake-mkdir path mode)
  (set! mkdir-count (+ mkdir-count 1))
  (set! created? #t))
(define (fake-rmdir path)
  (set! rmdir-count (+ rmdir-count 1))
  (throw 'system-error "injected rmdir failure"))
(define observed
  (catch 'wilkbook-cgroup-preflight-error
    (lambda ()
      (preflight-cgroup-child "/fake-cgroup/probe"
                               fake-present? fake-mkdir fake-rmdir)
      #f)
    (lambda (key message) message)))
(unless (string=? observed "cannot remove the cgroup2 write probe")
  (error "normal cleanup did not preserve its fail-closed error" observed))
(unless (= mkdir-count 1)
  (error "probe creation count changed" mkdir-count))
(unless (= rmdir-count 2)
  (error "error cleanup did not retry exactly once" rmdir-count))
(set! created? #f)
(set! cgroup-procs-present? #f)
(set! mkdir-count 0)
(set! rmdir-count 0)
(define earlier-error
  (catch 'wilkbook-cgroup-preflight-error
    (lambda ()
      (preflight-cgroup-child "/fake-cgroup/probe"
                               fake-present? fake-mkdir fake-rmdir)
      #f)
    (lambda (key message) message)))
(unless (string=? earlier-error "cgroup2 child lacks cgroup.procs")
  (error "error cleanup replaced the earlier exception" earlier-error))
(unless (= rmdir-count 1)
  (error "earlier-error cleanup count changed" rmdir-count))
(display "rmdir-failure-fail-closed\n")
(display "error-cleanup-retried-with-original-preserved\n")
(display "earlier-error-preserved-across-failed-cleanup\n")
""",
            encoding="utf-8",
        )
        injected = subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                str(harness),
                str(bundle / "launch.scm"),
            ],
            check=False,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(injected.returncode, 0, injected.stdout + injected.stderr)
        self.assertEqual(
            injected.stdout.splitlines(),
            [
                "rmdir-failure-fail-closed",
                "error-cleanup-retried-with-original-preserved",
                "earlier-error-preserved-across-failed-cleanup",
            ],
        )

    def test_both_explicit_profiles_require_user_namespaces(self) -> None:
        cli = HERE / "generate-oci-bundle.scm"
        help_result = subprocess.run(
            ["guile", "--no-auto-compile", str(cli), "--help"],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(
            help_result.returncode, 0, help_result.stdout + help_result.stderr
        )
        self.assertIn("--execution-profile PROFILE", help_result.stdout)
        missing_profile = subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                str(cli),
                "--profile",
                str(self.profile_alias_2),
                "--book",
                str(self.book),
                "--bundle",
                str(self.output_parent / "missing-profile"),
            ],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(missing_profile.returncode, 0)
        self.assertIn("missing required --execution-profile", missing_profile.stderr)

        for index, (profile, directfs) in enumerate(
            (("functional-directfs", "true"), ("isolation-userns", "false"))
        ):
            with self.subTest(profile=profile):
                result, bundle = self._generate_guile(
                    name=f"profile-{index}", execution_profile=profile
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                launch = json.loads((bundle / "launch.json").read_text())
                self.assertEqual(
                    launch["requiredKernelConfig"], ["CONFIG_USER_NS=y"]
                )
                self.assertIn(f"--directfs={directfs}", launch["argv"])
                self.assertIn("--network=none", launch["argv"])

        result, _ = self._generate_guile(
            name="no-fallback", execution_profile="automatic"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown execution profile", result.stderr)

    def test_guile_json_escapes_every_c0_and_supplementary_unicode(self) -> None:
        result = self._invoke_adapter("json-controls")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(
            any(
                ord(character) < 32 and character not in "\n\r\t"
                for character in result.stdout
            )
        )
        short_escapes = {8: "\\b", 9: "\\t", 10: "\\n", 12: "\\f", 13: "\\r"}
        for value in range(32):
            self.assertIn(short_escapes.get(value, f"\\u{value:04x}"), result.stdout)
        self.assertIn("\\ud83d\\ude00", result.stdout)
        decoded = json.loads(result.stdout)
        self.assertEqual(decoded["controls"], "".join(map(chr, range(32))))
        self.assertEqual(decoded["supplementary"], "😀")
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("#:unicode #t", source)

    def test_invalid_inputs_fail_closed_without_replacing_operator_path(self) -> None:
        alias = self.top / "book-alias"
        alias.symlink_to(self.book)
        result, bundle = self._generate_guile(
            name="book-alias", execution_profile="isolation-userns", book=alias
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain a symlink", result.stderr)
        self.assertFalse(bundle.exists())

        result, bundle = self._generate_guile(
            name="duplicate",
            execution_profile="isolation-userns",
            closure=[*self.closure, self.python],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate Guix requisite", result.stderr)
        self.assertFalse(bundle.exists())

        existing = self.output_parent / "existing"
        existing.mkdir()
        marker = existing / "operator-work"
        marker.write_text("keep", encoding="ascii")
        result, _ = self._generate_guile(
            name="existing", execution_profile="isolation-userns"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(encoding="ascii"), "keep")

        self.output_parent.chmod(0o755)
        result, bundle = self._generate_guile(
            name="public-parent", execution_profile="isolation-userns"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned by the caller and mode 0700", result.stderr)
        self.assertFalse(bundle.exists())

    def test_guix_requisites_uses_vector_and_sanitized_environment(self) -> None:
        record = self.top / "guix-environment"
        arguments = self.top / "guix-arguments"
        fake_guix = self.top / "fake-guix"
        fake_guix.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            f"printf '%s\\n' \"$HOME\" \"$LANG\" \"$LC_ALL\" \"$PATH\" "
            f"\"${{SSH_AUTH_SOCK-unset}}\" \"${{AWS_SECRET_ACCESS_KEY-unset}}\" "
            f"\"${{GVISOR_ENFORCE_RELEASE-unset}}\" > {record}\n"
            f"if test -e /proc/self/fd/199; then echo open; else echo closed; fi >> {record}\n"
            f"printf '%s\\n' \"$@\" > {arguments}\n"
            f"printf '%s\\n' {self.profile} {self.python}\n",
            encoding="utf-8",
        )
        fake_guix.chmod(0o755)
        result = self._invoke_adapter(
            "guix-requisites",
            str(fake_guix),
            str(self.profile),
            inherit_sentinel=True,
            ignored_sigchld=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.profile), str(self.python)])
        self.assertEqual(
            record.read_text(encoding="utf-8").splitlines(),
            [
                "/nonexistent",
                "C",
                "C",
                "/run/current-system/profile/bin:/usr/bin:/bin",
                "unset",
                "unset",
                "unset",
                "closed",
            ],
        )
        self.assertEqual(
            arguments.read_text(encoding="utf-8").splitlines(),
            ["gc", "--requisites", str(self.profile)],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
