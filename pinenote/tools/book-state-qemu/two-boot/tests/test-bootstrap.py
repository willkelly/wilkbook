#!/usr/bin/env python3
"""Finite startup-isolation and retained-byte regression checks."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PYTHON = Path(
    "/gnu/store/c9ga6sl21sy1cbxdllvxkj6qlnk4yzbh-python-3.11.14/bin/python3.11"
)
SHA256SUM = Path(
    "/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/sha256sum"
)
COMPILER = Path("/usr/bin/x86_64-linux-gnu-gcc-13")
COMPILER_SHA256 = "1b99826121ae6682a634e5efe09bd3e3df58ce58e0b28f849114ab5b89139c26"
LOADER_PROBE_SOURCE = r'''#define _GNU_SOURCE
#include <fcntl.h>
#include <link.h>
#include <string.h>
#include <unistd.h>

static void record_target(void) {
  char executable[4096];
  ssize_t size = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  const char prefix[] =
    "/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/";
  if (size <= 0) return;
  executable[size] = '\0';
  if (strncmp(executable, prefix, sizeof(prefix) - 1) != 0) return;
  const char *path = @CANARY_PATH@;
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd >= 0) {
    (void)write(fd, executable, (size_t)size);
    (void)write(fd, "\n", 1);
    (void)close(fd);
  }
}

__attribute__((constructor)) static void before_main(void) { record_target(); }
unsigned int la_version(unsigned int version) {
  record_target();
  return version < LAV_CURRENT ? version : LAV_CURRENT;
}
'''


def thaw(root: Path) -> None:
    if not root.exists():
        return
    for path in [root, *root.rglob("*")]:
        if path.is_dir():
            path.chmod(0o700)
        elif path.is_file():
            path.chmod(0o600)


def frozen_copy(base: Path, name: str) -> Path:
    destination = base / name
    shutil.copytree(ROOT, destination)
    for path in destination.rglob("*"):
        if path.is_file():
            path.chmod(0o400)
    for path in sorted((item for item in destination.rglob("*") if item.is_dir()),
                       key=lambda item: len(item.parts), reverse=True):
        path.chmod(0o500)
    destination.chmod(0o500)
    (destination / "run-two-boot.sh").chmod(0o500)
    return destination


def campaign_arguments(base: Path) -> list[str]:
    return [
        "--bundle", str(base / "caller-claims-reviewed-bundle"),
        "--campaign-base", str(base / "never-opened-campaign-base"),
        "--run-base", str(base / "never-opened-run-base"),
        "--evidence-base", str(base / "never-opened-evidence-base"),
    ]


def poison_environment(base: Path) -> tuple[dict[str, str], list[Path]]:
    load = base / "poison-load/two-boot"
    compiled = base / "poison-compiled/two-boot"
    home_compiled = base / "caller-home/.cache/guile/ccache/3.0-LE-8-4/two-boot"
    for directory in (load, compiled, home_compiled):
        directory.mkdir(parents=True, mode=0o700)
    source_canary = base / "SOURCE-PATH-CANARY"
    compiled_canary = base / "COMPILED-PATH-CANARY"
    home_canary = base / "HOME-CACHE-CANARY"
    bash_canary = base / "BASH-ENV-CANARY"
    bash_environment = base / "caller-bash-env"
    bash_environment.write_text(f'echo executed > "{bash_canary}"\n')
    source = load / "source-gate.scm"
    source.write_text(
        "(define-module (two-boot source-gate) "
        "#:export (verify-two-boot-source-root!))\n"
        f'(call-with-output-file "{source_canary}" '
        '(lambda (p) (display "executed" p)))\n'
        "(define (verify-two-boot-source-root! . _) #t)\n"
    )
    poison_scheme = base / "compiled-poison.scm"
    poison_scheme.write_text(
        "(define-module (two-boot sequential) "
        "#:export (call-with-two-sequential-boots))\n"
        f'(call-with-output-file "{compiled_canary}" '
        '(lambda (p) (display "executed" p)))\n'
        "(define (call-with-two-sequential-boots . _) (values \"x\" \"y\"))\n"
    )
    guild = shutil.which("guild")
    if guild is None:
        raise AssertionError("host test requires the already-installed Guile compiler")
    subprocess.run(
        [guild, "compile", "-o", str(compiled / "sequential.go"),
         str(poison_scheme)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=True,
        env={**os.environ, "GUILE_AUTO_COMPILE": "0"},
    )
    home_scheme = base / "home-poison.scm"
    home_scheme.write_text(
        "(define-module (two-boot image-binding) "
        "#:export (production-image-binding "
        "production-image-binding-status require-production-image-binding!))\n"
        f'(call-with-output-file "{home_canary}" '
        '(lambda (p) (display "executed" p)))\n'
        "(define production-image-binding '())\n"
        "(define (production-image-binding-status) 'available)\n"
        "(define (require-production-image-binding!) '())\n"
    )
    subprocess.run(
        [guild, "compile", "-o", str(home_compiled / "image-binding.go"),
         str(home_scheme)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=True,
        env={**os.environ, "GUILE_AUTO_COMPILE": "0"},
    )
    environment = dict(os.environ)
    environment.update({
        "HOME": str(base / "caller-home"),
        "XDG_CACHE_HOME": str(base / "caller-xdg-cache"),
        "XDG_CONFIG_HOME": str(base / "caller-xdg-config"),
        "GUILE_LOAD_PATH": str(base / "poison-load"),
        "GUILE_LOAD_COMPILED_PATH": str(base / "poison-compiled"),
        "GUILE_EXTENSIONS_PATH": str(base / "poison-extensions"),
        "BASH_ENV": str(bash_environment),
        "ENV": str(bash_environment),
    })
    return environment, [source_canary, compiled_canary, home_canary, bash_canary]


def assert_bundle_rejected(result: subprocess.CompletedProcess[bytes]) -> None:
    if result.returncode != 1:
        raise AssertionError(
            f"bootstrap returned {result.returncode}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}")
    if result.stdout != b"":
        raise AssertionError(f"unexpected bootstrap stdout: {result.stdout!r}")
    if b"book-state-two-boot-bundle-error" not in result.stderr:
        raise AssertionError(f"wrong exact-bundle rejection boundary: {result.stderr!r}")


def assert_no_bootstrap_leak(before: set[Path]) -> None:
    after = set(Path("/tmp/opencode").glob("book-state-two-boot-bootstrap.*"))
    if after != before:
        raise AssertionError(f"bootstrap private root leaked: {after - before}")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_loader_probe(base: Path) -> tuple[Path, Path]:
    base.mkdir(parents=True, mode=0o700)
    if digest(COMPILER) != COMPILER_SHA256:
        raise AssertionError("bounded host compiler differs from the reviewed binary")
    source = base / "loader-probe.c"
    shared = base / "loader-probe.so"
    canary = base / "FIXED-LOADER-CANARY"
    source.write_text(
        LOADER_PROBE_SOURCE.replace("@CANARY_PATH@", json.dumps(str(canary))))
    result = subprocess.run(
        [str(COMPILER), "-shared", "-fPIC", "-O2", "-Wl,-z,defs",
         "-o", str(shared), str(source)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=False,
        env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
    )
    if result.returncode != 0:
        raise AssertionError(
            f"loader probe compile failed\nstdout={result.stdout!r}\n"
            f"stderr={result.stderr!r}")

    # Hash the successful helper with both pinned Python and a pristine pinned
    # sha256sum invocation, before any positive-control loader environment exists.
    expected = digest(shared)
    pristine = subprocess.run(
        [str(SHA256SUM), "--", str(shared)], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False,
        env={"LANG": "C", "LC_ALL": "C"},
    )
    expected_output = f"{expected}  {shared}\n".encode()
    if (pristine.returncode != 0 or pristine.stdout != expected_output or
            pristine.stderr != b""):
        raise AssertionError("pristine helper hash disagrees with pinned Python")
    return shared, canary


def test_loader_injection(base: Path) -> int:
    shared, canary = build_loader_probe(base)
    source = frozen_copy(base, "launcher-source")
    (base / "caller-claims-reviewed-bundle").write_text("caller data\n")
    before = set(Path("/tmp/opencode").glob("book-state-two-boot-bootstrap.*"))
    assertions = 2
    for loader_name in ("LD_PRELOAD", "LD_AUDIT"):
        loader_environment = {
            "LANG": "C", "LC_ALL": "C",
            # Retain the reviewer's original environment shape too, but the
            # helper deliberately does not depend on this scrubbed value.
            "BTQ_PREAUTH_CANARY": str(canary),
            loader_name: str(shared),
        }

        # Positive control: the actual loader interface reaches the exact first
        # coreutils binary used by run-two-boot.sh.
        positive = subprocess.run(
            [str(SHA256SUM), "--", str(shared)], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
            check=False, env=loader_environment,
        )
        marker_lines = canary.read_text().splitlines() if canary.exists() else []
        if (positive.returncode != 0 or not marker_lines or
                any(line != str(SHA256SUM) for line in marker_lines)):
            raise AssertionError(f"{loader_name} positive control did not execute")
        canary.unlink()

        # Launch the original production entry, not an unrelated env wrapper.
        # Extra real and future loader variables exercise the generic boundary;
        # the valid campaign argv must still reach the exact bundle gate.
        launch_environment = dict(loader_environment)
        launch_environment.update({
            "LD_LIBRARY_PATH": str(base / "caller-library-path"),
            "LD_FUTURE_INJECTION_SWITCH": str(shared),
            "GLIBC_TUNABLES": "glibc.malloc.perturb=17",
            "GCONV_PATH": str(base / "caller-gconv"),
            "LOCPATH": str(base / "caller-locale"),
            "NLSPATH": str(base / "caller-messages/%N"),
        })
        result = subprocess.run(
            [str(source / "run-two-boot.sh"), *campaign_arguments(base)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=30, check=False,
            env=launch_environment,
        )
        assert_bundle_rejected(result)
        if canary.exists():
            raise AssertionError(
                f"{loader_name} reached a pinned dynamic utility before env -i")
        assert_no_bootstrap_leak(before)
        assertions += 3
    return assertions


def test_launcher_poison(base: Path) -> int:
    source = frozen_copy(base, "launcher-source")
    environment, canaries = poison_environment(base / "launcher-poison")
    # A regular caller object is not the source-pinned immutable bundle.  Its
    # rejection proves no campaign can begin from caller claims.
    (base / "caller-claims-reviewed-bundle").write_text("caller data\n")
    before = set(Path("/tmp/opencode").glob("book-state-two-boot-bootstrap.*"))
    result = subprocess.run(
        [str(source / "run-two-boot.sh"), *campaign_arguments(base)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=False, env=environment,
    )
    assert_bundle_rejected(result)
    if any(path.exists() for path in canaries):
        raise AssertionError("caller Guile source/compiled/HOME poison executed")
    assert_no_bootstrap_leak(before)
    return 3


def test_post_auth_caller_mutation(base: Path) -> int:
    source = frozen_copy(base, "mutation-source")
    environment, canaries = poison_environment(base / "mutation-poison")
    (base / "caller-claims-reviewed-bundle").write_text("caller data\n")
    bootstrap_root = Path(tempfile.mkdtemp(
        prefix="book-state-two-boot-bootstrap.", dir="/tmp/opencode"))
    bootstrap_root.chmod(0o700)
    ready_read, ready_write = os.pipe()
    continue_read, continue_write = os.pipe()
    command = [
        str(PYTHON), "-B", "-I", "-S", str(source / "bootstrap.py"),
        "--source-root", str(source), "--bootstrap-root", str(bootstrap_root),
        "--test-before-exec-ready-fd", str(ready_write),
        "--test-before-exec-continue-fd", str(continue_read), "--",
        *campaign_arguments(base),
    ]
    process = subprocess.Popen(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=environment,
        pass_fds=(ready_write, continue_read),
    )
    os.close(ready_write)
    os.close(continue_read)
    try:
        readable, _, _ = select.select([ready_read], [], [], 15)
        if not readable or os.read(ready_read, 64) != b"retained-source-ready\n":
            raise AssertionError("bootstrap did not reach retained-byte checkpoint")
        caller_canary = base / "MUTATED-CALLER-HELPER-RAN"
        helper = source / "run-two-boot.scm"
        helper.chmod(0o600)
        helper.write_text(
            f'(call-with-output-file "{caller_canary}" '
            '(lambda (p) (display "executed" p)))\n'
            + helper.read_text()
        )
        os.write(continue_write, b"C")
        os.close(continue_write)
        continue_write = -1
        stdout, stderr = process.communicate(timeout=30)
        result = subprocess.CompletedProcess(command, process.returncode,
                                             stdout, stderr)
        assert_bundle_rejected(result)
        if caller_canary.exists() or any(path.exists() for path in canaries):
            raise AssertionError("post-auth caller helper or ambient poison executed")
        if bootstrap_root.exists():
            raise AssertionError("guarded retained source root survived cleanup")
    finally:
        os.close(ready_read)
        if continue_write >= 0:
            os.close(continue_write)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    return 2


def main() -> int:
    base = Path(tempfile.mkdtemp(prefix="two-boot-bootstrap-test.",
                                dir="/tmp/opencode"))
    base.chmod(0o700)
    assertions = 0
    try:
        assertions += test_loader_injection(base / "loader-boundary")
        assertions += test_launcher_poison(base)
        assertions += test_post_auth_caller_mutation(base)
        print(
            "PASS: static-Bash loader boundary and authenticated retained capsule "
            "block LD_PRELOAD/LD_AUDIT, source/compiled/HOME poison, and "
            f"caller-helper mutation ({assertions} boundary assertions)"
        )
        return 0
    finally:
        thaw(base)
        shutil.rmtree(base)


if __name__ == "__main__":
    raise SystemExit(main())
