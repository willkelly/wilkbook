#!/usr/bin/env python3
"""Mutation tests for the package/member/layout gate; no ELF is executed."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CHECKER = HERE / "check-gvisor-package.sh"
PACKAGE = REPO / "pinenote/packages/gvisor.scm"
MANIFEST = HERE / "expected-release-members.txt"


class PackageCheckerMutationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wilkbook-gvisor-check-test-", dir="/tmp/opencode"
        )
        self.top = Path(self.temporary.name)
        self.package_text = PACKAGE.read_text(encoding="utf-8")
        self.members = MANIFEST.read_text(encoding="utf-8").splitlines()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, package: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(CHECKER),
                "--package-definition",
                str(package),
                "--member-manifest",
                str(MANIFEST),
                *extra,
            ],
            cwd=REPO,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _write_package(self, name: str, text: str) -> Path:
        path = self.top / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_removing_each_package_member_is_rejected(self) -> None:
        for index, member in enumerate(self.members):
            with self.subTest(member=member):
                token = f'"{member}"'
                self.assertIn(token, self.package_text)
                mutated = self.package_text.replace(token, "", 1)
                result = self._run(
                    self._write_package(f"remove-{index}.scm", mutated)
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_adding_each_package_member_again_is_rejected(self) -> None:
        terminator = '    "runsc"))\n'
        self.assertIn(terminator, self.package_text)
        for index, member in enumerate(self.members):
            with self.subTest(member=member):
                addition = f'    "{member}"\n' + terminator
                mutated = self.package_text.replace(terminator, addition, 1)
                result = self._run(self._write_package(f"add-{index}.scm", mutated))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_sidecar_directory_changed_to_symlink_is_rejected(self) -> None:
        output = self.top / "output"
        bin_dir = output / "bin"
        external = self.top / "external-sidecars"
        bin_dir.mkdir(parents=True)
        external.mkdir()
        (bin_dir / "runsc").touch(mode=0o555)
        (bin_dir / "containerd-shim-runsc-v1").touch(mode=0o555)
        for member in self.members:
            if member.startswith("gvisor-bin/"):
                (external / Path(member).name).touch(mode=0o555)
        (bin_dir / "gvisor-bin").symlink_to(external)

        package = self._write_package("unchanged.scm", self.package_text)
        result = self._run(package, "--output", str(output))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("layout contains a symlink", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
