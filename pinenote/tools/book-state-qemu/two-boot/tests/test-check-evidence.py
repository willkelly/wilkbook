#!/usr/bin/env python3
"""Mutation and summary-only rejection checks for check-evidence.py."""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
CHECKER = HERE.parent / "check-evidence.py"
GENERATOR = HERE / "make-synthetic-evidence.py"
SPEC = importlib.util.spec_from_file_location("synthetic", GENERATOR)
assert SPEC and SPEC.loader
synthetic = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = synthetic
SPEC.loader.exec_module(synthetic)


def run(root: Path, payload: str, expected: int,
        final: str | None = None) -> subprocess.CompletedProcess[bytes]:
    command = [sys.executable, "-B", "-I", "-S", str(CHECKER), "--evidence", str(root),
               "--payload-manifest-sha256", payload]
    if final is not None:
        command.extend(["--final-manifest-sha256", final])
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"checker returned {result.returncode}, wanted {expected}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}")
    return result


def run_single(root: Path, boot: int, expected: int) -> None:
    result = subprocess.run(
        [sys.executable, "-B", "-I", "-S", str(CHECKER),
         "--single-boot-evidence", str(root / f"boot{boot}"),
         "--boot-index", str(boot)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"single-boot checker returned {result.returncode}, wanted {expected}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}")


def run_cross(root: Path, expected: int) -> None:
    result = subprocess.run(
        [sys.executable, "-B", "-I", "-S", str(CHECKER),
         "--cross-boot-evidence", str(root)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=False,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"cross-boot checker returned {result.returncode}, wanted {expected}\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}")


def case(base: Path, name: str, mutate) -> None:
    root = base / name
    synthetic.make(root)
    mutate(root)
    payload = synthetic.seal_payload(root)
    run(root, payload, 1)


def final_case(base: Path, name: str, mutate) -> tuple[str, str,
                                                       subprocess.CompletedProcess[bytes]]:
    """Exercise the actual fully sealed production-checker entry."""
    root = base / name
    synthetic.make(root)
    mutate(root)
    payload = synthetic.seal_payload(root)
    final = synthetic.seal_final(root)
    result = run(root, payload, 1, final)
    if result.stdout != b"" or not result.stderr.startswith(
            b"FAIL: two-boot evidence:"):
        raise AssertionError(
            f"sealed rejection emitted the wrong result\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}")
    return payload, final, result


def mutate_console(root: Path, boot: int, transform) -> None:
    path = root / f"boot{boot}/run/console.log"
    path.write_bytes(transform(path.read_bytes()))


def remove_boundary_records(data: bytes, language: str | None = None) -> bytes:
    selected = f"language={language}".encode() if language else None
    return b"".join(
        line for line in data.splitlines(keepends=True)
        if not ((synthetic.checker.SANDBOX_BOUNDARY_STEM in line or
                 synthetic.checker.SANDBOX_SOURCE_STEM in line) and
                (selected is None or selected in line))
    )


def boundary_pair(data: bytes, language: str) -> bytes:
    lines = data.splitlines(keepends=True)
    selected = f"language={language}".encode()
    positions = [
        index for index, line in enumerate(lines)
        if synthetic.checker.SANDBOX_SOURCE_STEM in line and selected in line
    ]
    if len(positions) != 1:
        raise AssertionError(f"fixture lacks one {language} attribution")
    index = positions[0]
    if (index + 1 >= len(lines) or
            lines[index + 1].rstrip(b"\r\n") !=
            synthetic.checker.SANDBOX_BOUNDARY_MARKERS[language]):
        raise AssertionError(f"fixture lacks adjacent {language} marker")
    return lines[index] + lines[index + 1]


def replace_attribution_fragment(
        root: Path, boot: int, language: str, old: bytes, new: bytes) -> None:
    def transform(data: bytes) -> bytes:
        lines = data.splitlines(keepends=True)
        selected = f"language={language}".encode()
        found = 0
        for index, line in enumerate(lines):
            if synthetic.checker.SANDBOX_SOURCE_STEM in line and selected in line:
                replaced = line.replace(old, new, 1)
                if replaced == line:
                    raise AssertionError(f"missing attribution fragment {old!r}")
                lines[index] = replaced
                found += 1
        if found != 1:
            raise AssertionError(f"fixture lacks one {language} attribution")
        return b"".join(lines)
    mutate_console(root, boot, transform)


def replay_sealed_missing_both() -> int:
    base = Path(tempfile.mkdtemp(
        prefix="two-boot-missing-boundary-replay.", dir="/tmp/opencode"))
    base.chmod(0o700)
    try:
        payload, final, result = final_case(
            base, "sealed-final-missing-both-boundaries", lambda root: [
                mutate_console(root, boot,
                               lambda data: remove_boundary_records(data))
                for boot in (1, 2)
            ])
        print("schema=1")
        print("model=fully-sealed-final-missing-both-boundaries")
        print("predecessor-v4-checker-sha256="
              "cd350aae94e8b48ec36863fd2ddb51fa6a032c99bbe7a68dae4a9a1db5fb6660")
        print("predecessor-v4-payload-manifest-sha256="
              "832706621b602f8c69d643bc9eb79e18ac8c58903ce75138978bde58f5851762")
        print("predecessor-v4-final-manifest-sha256="
              "2ea45e41ae21d36f6c4222aeb26a8883c1edd04fb09480450aa58424af8c8e8b")
        print("predecessor-v4-checker-status=0")
        print(f"successor-checker-sha256={synthetic.digest(CHECKER)}")
        print(f"successor-model-payload-manifest-sha256={payload}")
        print(f"successor-model-final-manifest-sha256={final}")
        print("sandbox-boundary-marker-count=0")
        print("sandbox-source-attribution-count=0")
        print(f"successor-checker-status={result.returncode}")
        print(f"successor-checker-stdout-bytes={len(result.stdout)}")
        print("result=pass-predecessor-counterexample-rejected")
        return 0
    finally:
        synthetic.thaw(base)
        shutil.rmtree(base)


def main() -> int:
    base = Path(tempfile.mkdtemp(prefix="two-boot-checker-test.", dir="/tmp/opencode"))
    base.chmod(0o700)
    try:
        markers = synthetic.checker.expected_reader_markers(1)
        initial_paint = [
            "BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=1:state=loaded-absent:text-bytes=0",
            "BOOK_STATE_READER_UI_AUDIT: paintTo-presentation:generation=1:text-bytes=0",
            "BOOK_STATE_READER: status-painted:generation=1:state=loaded-absent",
            "BOOK_STATE_READER: presentation-painted:generation=1:text-bytes=0",
        ]
        start = markers.index(initial_paint[0])
        if markers[start:start + len(initial_paint)] != initial_paint:
            raise AssertionError(
                "checker does not model the real same-paint initial audit order")
        modeled_console = synthetic.console(1)
        if (b"book-state guest exited with status 0; requesting shutdown" in
                modeled_console):
            raise AssertionError(
                "synthetic UART evidence contains Shepherd's captured stderr line")
        valid = base / "valid-model"
        payload = synthetic.make(valid)
        for boot in (1, 2):
            observed = synthetic.checker.check_console(
                valid / f"boot{boot}/run/console.log", boot)
            if ([item.operation for item in observed.sandbox_attributions] !=
                    [f"op_guile_{'a' if boot == 1 else 'b'}",
                     f"op_python_{'a' if boot == 1 else 'b'}"] or
                    [item.resulting_state_version
                     for item in observed.sandbox_attributions] != [boot, boot] or
                    not all(item.capture_sha256
                            for item in observed.sandbox_attributions)):
                raise AssertionError("checker discarded modeled attribution metadata")
        run_single(valid, 1, 0)
        run_single(valid, 2, 0)
        run_cross(valid, 1)  # campaign/final files are forbidden before cleanup.
        run(valid, payload, 0)
        final = synthetic.seal_final(valid)
        run(valid, payload, 0, final)
        (valid / "CHECKER.txt").chmod(0o600)
        run(valid, payload, 1, final)

        # Reproduce the reviewer's decisive shape through the real fully sealed
        # final entry: both boots otherwise pass, but all four actual child
        # boundary records and their attributions are absent.
        final_case(base, "sealed-final-missing-both-boundaries", lambda root: [
            mutate_console(root, boot, lambda data: remove_boundary_records(data))
            for boot in (1, 2)
        ])

        final_case(base, "sealed-final-missing-one-boundary", lambda root:
                   mutate_console(root, 1, lambda data:
                                  remove_boundary_records(data, "python")))

        guile_marker = synthetic.checker.SANDBOX_BOUNDARY_MARKERS["guile"]
        python_marker = synthetic.checker.SANDBOX_BOUNDARY_MARKERS["python"]
        final_case(base, "sealed-final-duplicate-boundary", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       guile_marker + b"\n", guile_marker + b"\n" +
                       guile_marker + b"\n", 1)))
        final_case(base, "sealed-final-wrong-language-boundary", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       guile_marker, python_marker, 1)))
        final_case(base, "sealed-final-failed-boundary", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       b"language=guile result=pass storage-mount=absent",
                       b"language=guile result=fail storage-mount=absent", 1)))
        final_case(base, "sealed-final-wrong-probe-value", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       b"storage-fd=absent ui-transport=absent",
                       b"storage-fd=present ui-transport=absent", 1)))
        final_case(base, "sealed-final-prefixed-boundary", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       guile_marker, b"[   12.000000] " + guile_marker, 1)))
        final_case(base, "sealed-final-quoted-boundary-substring", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       b"BOOK-STATE-GUEST inspector-path=",
                       b"BOOK-TEXT-LITERAL quoted=\"" + guile_marker + b"\"\n"
                       b"BOOK-STATE-GUEST inspector-path=", 1)))
        final_case(base, "sealed-final-nonpass-attribution-only", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       guile_marker + b"\n", b"", 1)))
        final_case(base, "sealed-final-wrong-attribution-language", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       b"sandbox-boundary-source language=guile",
                       b"sandbox-boundary-source language=python", 1)))
        final_case(base, "sealed-final-wrong-attribution-container", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       b"container=wilkbook-guile-book-state",
                       b"container=wilkbook-python-book-state", 1)))
        final_case(base, "sealed-final-wrong-attribution-source", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                       b"source=owned-finalized-runsc.stdout",
                       b"source=unowned-runsc.stdout", 1)))
        final_case(base, "sealed-final-malformed-attribution-hash", lambda root:
                   mutate_console(root, 1, lambda data: data.replace(
                        synthetic.checker.SANDBOX_BOUNDARY_MARKER_SHA256[
                            "guile"].encode(), b"0" * 64, 1)))

        def swap_complete_same_language_pairs(root: Path) -> None:
            first_path = root / "boot1/run/console.log"
            second_path = root / "boot2/run/console.log"
            first = first_path.read_bytes()
            second = second_path.read_bytes()
            first_pairs = {
                language: boundary_pair(first, language)
                for language in ("guile", "python")
            }
            second_pairs = {
                language: boundary_pair(second, language)
                for language in ("guile", "python")
            }
            for language in ("guile", "python"):
                first = first.replace(first_pairs[language], second_pairs[language], 1)
                second = second.replace(second_pairs[language], first_pairs[language], 1)
            first_path.write_bytes(first)
            second_path.write_bytes(second)
        final_case(base, "sealed-final-balanced-cross-boot-pair-swap",
                   swap_complete_same_language_pairs)

        def swap_operation_fields_only(root: Path) -> None:
            replace_attribution_fragment(
                root, 1, "guile", b"operation=op_guile_a",
                b"operation=op_guile_b")
            replace_attribution_fragment(
                root, 2, "guile", b"operation=op_guile_b",
                b"operation=op_guile_a")
        final_case(base, "sealed-final-balanced-operation-only-swap",
                   swap_operation_fields_only)

        def swap_version_fields_only(root: Path) -> None:
            replace_attribution_fragment(
                root, 1, "python", b"resulting-state-version=1",
                b"resulting-state-version=2")
            replace_attribution_fragment(
                root, 2, "python", b"resulting-state-version=2",
                b"resulting-state-version=1")
        final_case(base, "sealed-final-balanced-version-only-swap",
                   swap_version_fields_only)

        final_case(base, "sealed-final-blank-boundary-operation", lambda root:
                   replace_attribution_fragment(
                       root, 1, "guile", b"operation=op_guile_a",
                       b"operation="))
        final_case(base, "sealed-final-invalid-boundary-operation", lambda root:
                   replace_attribution_fragment(
                       root, 1, "guile", b"operation=op_guile_a",
                       b"operation=op.guile.a"))
        final_case(base, "sealed-final-zero-boundary-version", lambda root:
                   replace_attribution_fragment(
                       root, 1, "python", b"resulting-state-version=1",
                       b"resulting-state-version=0"))
        final_case(base, "sealed-final-leading-zero-boundary-version", lambda root:
                   replace_attribution_fragment(
                       root, 1, "python", b"resulting-state-version=1",
                       b"resulting-state-version=01"))

        def put_other_boot_fields_in_boot1(root: Path) -> None:
            replace_attribution_fragment(
                root, 1, "guile",
                b"operation=op_guile_a resulting-state-version=1",
                b"operation=op_guile_b resulting-state-version=2")
        final_case(base, "sealed-final-other-boot-fields-in-one-pair",
                   put_other_boot_fields_in_boot1)

        def move_boot2_boundaries_into_boot1(root: Path) -> None:
            second_path = root / "boot2/run/console.log"
            second = second_path.read_bytes()
            copied = b"".join(
                line for line in second.splitlines(keepends=True)
                if (synthetic.checker.SANDBOX_BOUNDARY_STEM in line or
                    synthetic.checker.SANDBOX_SOURCE_STEM in line)
            )
            second_path.write_bytes(remove_boundary_records(second))
            mutate_console(root, 1, lambda data: data.replace(
                b"BOOK-STATE-GUEST inspector-path=", copied +
                b"BOOK-STATE-GUEST inspector-path=", 1))
        final_case(base, "sealed-final-cross-boot-marker-reuse",
                   move_boot2_boundaries_into_boot1)

        def swap_boot_consoles(root: Path) -> None:
            first = root / "boot1/run/console.log"
            second = root / "boot2/run/console.log"
            first_bytes, second_bytes = first.read_bytes(), second.read_bytes()
            first.write_bytes(second_bytes)
            second.write_bytes(first_bytes)
        final_case(base, "sealed-final-swapped-boot-console-evidence",
                   swap_boot_consoles)

        def old_v6_guest_identity(root: Path) -> None:
            old = {
                "guest-source-manifest-sha256":
                    "8a86fa2a1e7b8b388ab2858580d279fae9afc42dcd166f64fce4c1030f52d221",
                "guest-source-snapshot-manifest-sha256":
                    "2b99fcca343823eca6f5f665bfb7a5e053fed7eede1ce99501c99a9747d7a7e8",
                "guest-capsule-roster-sha256":
                    "9e5f4edc0b2c6babea1a576aa8f7c270136a2ceda6f650d64bde18a0d4308f3d",
                "guest-authority-source-sha256":
                    "e1bc1c871b0502d17ccdc7056564989cd455fae943133300df88e60e11dbdf3c",
                "guest-contract-sha256":
                    "68248685cecf8a46a565d854e8168112432f5bb8caf5dc30505ab788e2ddce76",
            }
            synthetic.replace_record(root / "campaign.record", old)
            for boot in (1, 2):
                synthetic.replace_record(root / f"boot{boot}/boot.record", old)
                synthetic.refresh_boot_reference(root, boot)
        final_case(base, "sealed-final-old-v6-guest-identity",
                   old_v6_guest_identity)

        def old_v7_guest_identity(root: Path) -> None:
            old = {
                "guest-source-manifest-sha256":
                    "cb86ceec72ed59353e4ec75f88c292594b210de26074a98a35293c9ccef5e7ce",
                "guest-source-snapshot-manifest-sha256":
                    "dc068b4c04a9168c9d6f34f9dc1486ad2b0788f53d4906602de6dc9a99aa8c4e",
                "guest-capsule-roster-sha256":
                    "c26f69012d1069bfbb9f5df8dbd610aa63a288e74fabfd325c9842b3d532de07",
                "guest-authority-source-sha256":
                    "d852a183608dacf5758e0424f1494522f93c57646b7b396ba80902ffbb240fdd",
                "guest-contract-sha256":
                    "e6186630579a8b7326adb575fe73b0cf6a2a69ebc110b7f6a26ac65101a9e265",
            }
            synthetic.replace_record(root / "campaign.record", old)
            for boot in (1, 2):
                synthetic.replace_record(root / f"boot{boot}/boot.record", old)
                synthetic.refresh_boot_reference(root, boot)
        final_case(base, "sealed-final-old-v7-guest-identity",
                   old_v7_guest_identity)

        cross_valid = base / "valid-cross-model"
        synthetic.make(cross_valid)
        for name in ("campaign.record", "book-state.ext4", "PAYLOAD.sha256",
                     "CROSS-CHECKER.txt", "CROSS-CHECKER.stderr"):
            (cross_valid / name).unlink()
        run_cross(cross_valid, 0)
        cross_bad = base / "cross-boot-operation-reuse"
        shutil.copytree(cross_valid, cross_bad)
        console = cross_bad / "boot2/run/console.log"
        console.write_bytes(console.read_bytes().replace(
            b"operation=op_guile_b", b"operation=op_guile_a"))
        run_cross(cross_bad, 1)

        single_bad = base / "single-boot-semantic-failure"
        synthetic.make(single_bad)
        (single_bad / "boot1/run/console.log").write_bytes(
            (single_bad / "boot1/run/console.log").read_bytes().replace(
                b"namespaces=2 receipts=2", b"namespaces=2 receipts=4"))
        run_single(single_bad, 1, 1)

        case(base, "ui-reordered", lambda root: (
            (lambda path, lines: path.write_bytes(lines[1] + lines[0] + b"".join(lines[2:])))
            (root / "boot1/run/reader-ui/ui-guest-to-reader.bin",
             (root / "boot1/run/reader-ui/ui-guest-to-reader.bin").read_bytes().splitlines(True))))

        case(base, "console-duplicate", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes().replace(
                    b"BOOKEXEC-KERNEL-IDENTITY-PASS\n",
                     b"BOOKEXEC-KERNEL-IDENTITY-PASS\nBOOKEXEC-KERNEL-IDENTITY-PASS\n"))))

        case(base, "console-generic-fail-after-powerdown", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes() +
                b"FAIL: independent injected console failure\n")))

        case(base, "console-generic-fail-before-result", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes().replace(
                    b"BOOK-STATE-GUEST result=pass",
                    b"FAIL: pre-result failure\nBOOK-STATE-GUEST result=pass"))))

        case(base, "console-timestamped-generic-fail", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes() +
                b"[   12.250000] FAIL: timestamped failure\n")))

        case(base, "console-whitespace-generic-fail", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes() +
                b"  FAIL: whitespace failure\n")))

        quoted = base / "console-quoted-fail-text"
        quoted_payload = synthetic.make(quoted)
        quoted_console = quoted / "boot1/run/console.log"
        quoted_console.write_bytes(quoted_console.read_bytes().replace(
            b"[    2.000000] synthetic shutdown progress\n",
            b"BOOK-TEXT-LITERAL quoted=\"FAIL:\"\n"
            b"[    2.000000] synthetic shutdown progress\n"))
        quoted_payload = synthetic.seal_payload(quoted)
        run(quoted, quoted_payload, 0)

        case(base, "console-powerdown-reordered", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes()
                .replace(b"[    3.000000] reboot: Power down\n", b"", 1)
                .replace(b"BOOK-STATE-GUEST result=pass",
                         b"[    3.000000] reboot: Power down\n"
                         b"BOOK-STATE-GUEST result=pass", 1))))

        case(base, "console-nontransport-service-status", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes() +
                b"book-state guest exited with status 0; requesting shutdown\n")))

        case(base, "receipt-contradiction", lambda root: (
            (root / "boot2/run/console.log").write_bytes(
                (root / "boot2/run/console.log").read_bytes().replace(
                    b"namespaces=2 receipts=4", b"namespaces=2 receipts=2"))))

        def graph_mutation(root: Path) -> None:
            graph = root / "boot1/qemu-graph.scm"
            graph.write_text(graph.read_text().replace('"-display"', '"-S" "-display"', 1))
            synthetic.replace_record(root / "boot1/boot.record", {
                "qemu-graph-sha256": synthetic.digest(graph),
            })
            synthetic.refresh_boot_reference(root, 1)
        case(base, "paused-graph", graph_mutation)

        def root_mutation(root: Path, replacement: str) -> None:
            graph = root / "boot1/qemu-graph.scm"
            original = graph.read_text()
            if original.count("root=PNGuixRoot") != 1:
                raise AssertionError("fixture lacks one Guix-native root token")
            graph.write_text(original.replace("root=PNGuixRoot", replacement, 1))
            synthetic.replace_record(root / "boot1/boot.record", {
                "qemu-graph-sha256": synthetic.digest(graph),
            })
            synthetic.refresh_boot_reference(root, 1)

        case(base, "label-prefix-root", lambda root:
             root_mutation(root, "root=LABEL=PNGuixRoot"))
        case(base, "duplicate-root", lambda root:
             root_mutation(root, "root=PNGuixRoot root=PNGuixRoot"))
        case(base, "wrong-root", lambda root:
             root_mutation(root, "root=/dev/vda1"))

        def duplicate_boot(root: Path) -> None:
            first = synthetic.checker.read_record(root / "boot1/boot.record")["boot-id"]
            synthetic.replace_record(root / "boot2/boot.record", {"boot-id": first})
            synthetic.refresh_boot_reference(root, 2)
        case(base, "duplicate-boot-id", duplicate_boot)

        case(base, "summary-only", lambda root:
             (root / "boot1/run/reader-ui/ui-guest-to-reader.bin").unlink())

        case(base, "forged-failure-as-pass", lambda root: (
            (root / "boot1/run/console.log").write_bytes(
                (root / "boot1/run/console.log").read_bytes().replace(
                    b"BOOK-STATE-GUEST result=pass", b"BOOK-STATE-GUEST result=fail"))))

        def hard_timeout_as_pass(root: Path) -> None:
            record = root / "boot1/run.scm"
            record.write_text(record.read_text().replace(
                "(hard-vm-owner-status . 0) (hard-vm-owner-timed-out . #f)",
                "(hard-vm-owner-status . 124) (hard-vm-owner-timed-out . #t)"))
        case(base, "hard-timeout-as-pass", hard_timeout_as_pass)

        def owner_timeout_as_pass(root: Path) -> None:
            synthetic.replace_record(root / "boot1/boot.record", {
                "timed-out": "true", "owner-timed-out": "true",
            })
            synthetic.refresh_boot_reference(root, 1)
        case(base, "owner-timeout-as-pass", owner_timeout_as_pass)

        case(base, "campaign-budget-disabled", lambda root:
             synthetic.replace_record(root / "campaign.record", {
                 "guest-cooperative-budget-seconds": "0",
             }))

        case(base, "extra-reader-marker", lambda root: (
            (root / "boot1/run/reader-ui/reader.log").write_text(
                (root / "boot1/run/reader-ui/reader.log").read_text() +
                 "BOOK_STATE_READER: synthetic-pass\n")))

        case(base, "native-ui-failure-marker", lambda root: (
            (root / "boot1/run/reader-ui/reader.log").write_text(
                (root / "boot1/run/reader-ui/reader.log").read_text() +
                "BOOK_STATE_READER: FAIL:native UI callback failed\n")))

        def duplicate_key(root: Path) -> None:
            record = root / "boot1/boot.record"
            record.write_text(record.read_text() + "status=pass\n")
            synthetic.refresh_boot_reference(root, 1)
        case(base, "duplicate-record-key", duplicate_key)

        print(
            "PASS: V8 operation/version-bound boundary records accepted in both modeled boots; "
            "fully sealed missing/wrong/swapped/reused boundary evidence and 25 inherited "
            "semantic/mode mutations rejected"
        )
        return 0
    finally:
        synthetic.thaw(base)
        shutil.rmtree(base)


if __name__ == "__main__":
    if sys.argv[1:] == ["--sealed-missing-both-only"]:
        raise SystemExit(replay_sealed_missing_both())
    if sys.argv[1:]:
        raise SystemExit(
            f"usage: {sys.argv[0]} [--sealed-missing-both-only]")
    raise SystemExit(main())
