#!/usr/bin/env python3
"""Non-realizing inventory gate for the fixed actual-guest protocol sources."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SYSTEM = REPO / "pinenote/systems/pinenote-book-execution-protocol-control.scm"

SOURCES = {
    "guest-smoke.scm": HERE / "guest-smoke.scm",
    "oci-bundle.scm": HERE / "oci-bundle.scm",
    "book-protocol.scm": REPO / "pinenote/tools/book-protocol/book-protocol.scm",
    "blocking-io.scm": REPO
    / "pinenote/tools/book-protocol/book-protocol/blocking-io.scm",
    "book_protocol.py": REPO / "pinenote/tools/book-protocol/book_protocol.py",
    "book-session.scm": REPO / "pinenote/tools/book-session/book-session.scm",
    "oci-book-bundle.scm": HERE / "oci-book-bundle.scm",
    "guest-book-protocol.scm": HERE / "guest-book-protocol.scm",
    "guest-protocol-book.scm": HERE / "guest-protocol-book.scm",
    "guest_protocol_book.py": HERE / "guest_protocol_book.py",
}

FROZEN = {
    "guest-smoke.scm": "74491a0fe4761eec08a17c4d907fc4c2ef3a4f9ce5fd13a9a4835429e17086aa",
    "oci-bundle.scm": "a3a4c4e6e43ac80de2831ec398346b143ed5b4e7b666f8cb2362216ae90d3b5c",
    "book-protocol.scm": "91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44",
    "blocking-io.scm": "543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd",
    "book_protocol.py": "4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735",
    "book-session.scm": "f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668",
}

FROZEN_SYSTEMS = {
    REPO / "pinenote/systems/pinenote-book-execution-spike.scm": (
        "b56fafc9c64cf3ba816de85d6766b562fe1e62aac9956bfc2506af49c8336c09"
    ),
    REPO / "pinenote/systems/pinenote-book-execution-source-control.scm": (
        "341ca90202c24a2144087bf7f8e070880c0d27f08ad2240525ff303c1ea6a5c6"
    ),
}

STAGE1_FILES = {
    HERE / "protocol-fixture/protocol-host.scm": (
        "8efd2469b84853d1477e6a21928e3ca55a97decc409c1c1f92c4c0b81c050a0b"
    ),
    HERE / "protocol-fixture/fixture-book.scm": (
        "f08dda9db6c4b0b5ff7579e17a7ba9d3cde6b538f56a1f28ad000781a7ee80a2"
    ),
    HERE / "protocol-fixture/fixture_book.py": (
        "47f0a60052dd95feee4c3078c6e300d62870e20c9e5ea4b73c2113666143afe3"
    ),
    HERE / "protocol-fixture/test_protocol_fixture.py": (
        "fea596135d838460c2dfb665a6f77752fd2a6d384b558c3320555d6955c2c723"
    ),
    HERE / "protocol-fixture/check_pinned_gvisor_fd_seam.py": (
        "1d79ff9ab661a7ab699e22cd1e2de7c02a95028ac6dbef883a322ae17960b4be"
    ),
    HERE / "protocol-fixture/Makefile": (
        "fd8ffed245d6e527213bb3353d441b37a0edcf50f9640756b545f2be9a454e7c"
    ),
    HERE / "protocol-fixture/README.md": (
        "47ec222af598393bd7fdd75685a6b732923385cc9c8fd72b5cd07a677d08fd6a"
    ),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"PASS: {message}")


def source_hashes(system_source: str) -> dict[str, str]:
    return dict(
        re.findall(
            r'\("([A-Za-z0-9_.-]+)"\s*\.\s*"([0-9a-f]{64})"\)',
            system_source,
        )
    )


def require_all(text: str, values: tuple[str, ...], label: str) -> None:
    missing = [value for value in values if value not in text]
    check(not missing, f"{label} includes every fixed value" + (f": {missing}" if missing else ""))


def verify_hash_roster(roster: dict[Path, str], label: str) -> None:
    """Verify immutable reviewed inputs, never an append-only review report."""
    for path, expected in roster.items():
        check(sha256(path) == expected, f"{label}: {path.name}")


def main() -> int:
    system = SYSTEM.read_text(encoding="utf-8")
    pinned = source_hashes(system)
    check(set(pinned) == set(SOURCES), "system hash manifest enumerates exact source set")
    for name, path in SOURCES.items():
        check(sha256(path) == pinned[name], f"source hash pinned: {name}")
    for name, expected in FROZEN.items():
        check(pinned[name] == expected, f"accepted source remains frozen: {name}")
    verify_hash_roster(FROZEN_SYSTEMS, "accepted system remains frozen")
    verify_hash_roster(STAGE1_FILES, "accepted Stage-1 fixture remains frozen")

    oci = SOURCES["oci-book-bundle.scm"].read_text(encoding="utf-8")
    adapter = SOURCES["guest-book-protocol.scm"].read_text(encoding="utf-8")
    guile_book = SOURCES["guest-protocol-book.scm"].read_text(encoding="utf-8")
    python_book = SOURCES["guest_protocol_book.py"].read_text(encoding="utf-8")
    runtime_pinned = source_hashes(adapter)
    check(
        runtime_pinned
        == {name: expected for name, expected in pinned.items()
            if name != "guest-book-protocol.scm"},
        "guest runtime rechecks every external source hash",
    )
    check(
        system.count(pinned["guest-book-protocol.scm"]) >= 2,
        "system pins and passes the guest adapter self-hash",
    )

    require_all(
        oci,
        (
            '"--platform=systrap"',
            '"--network=none"',
            '"--sidecar-usage-policy=strict"',
            '"--sidecar-release-enforcement-policy=always"',
            '"--ignore-cgroups=false"',
            '"--host-uds=none"',
            '"--host-fifo=none"',
            '"--directfs=false"',
            '"--pass-fd=3:3"',
            '"BOOK_SESSION_FD=3"',
            '"type" . "RLIMIT_FSIZE"',
            '("hard" . 1048576)',
            "/runsc-panic/runsc.panic.%COMMAND%.log",
        ),
        "OCI policy",
    )
    check(oci.count('"--pass-fd=3:3"') == 1, "one fixed public pass-FD mapping")
    check('"--directfs=true"' not in oci, "no DirectFS policy fallback")
    check("getopt-long" not in oci and "command-line" not in oci, "no protocol OCI CLI")
    check("program-input" not in oci, "no arbitrary program input")

    require_all(
        adapter,
        (
            "whole-run-timeout-seconds 360.0",
            "max-capture-bytes (* 4 1024 1024)",
            "open-session-endpoint!",
            "endpoint-pump-input!",
            "endpoint-pump-output!",
            "presented-text-value",
            "finalize-owned-runsc!",
            "assert-parent-authority-only!",
            "assert-runtime-state-clean!",
            "emit-runtime-state-diagnostics",
            "prepare-owned-runtime-state!",
            "cleanup-owned-runtime-state!",
            "max-runtime-state-diagnostic-entries 4",
            "max-runtime-state-diagnostic-mounts-per-entry 2",
            "max-runtime-state-diagnostic-root-mounts 2",
            '"null-netns"',
            '"nsfs"',
            "action=nonlazy-unmount",
            "network-namespace-root-inode",
            "mountinfo-device-number",
            "(= (length mounts) 1)",
            "(equal? (directory-entry-names root) '(\"null-netns\"))",
            "(not (same-file-identity? mounted-info authority-netns-identity))",
            "(list (smoke-private 'umount-program) \"-n\" pin)",
            "(null? (mountinfo-at pin))",
            "runtime state root became mounted before pin cleanup",
            "runtime state root became mounted before placeholder removal",
            "BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-ROOT-MOUNT",
            "runtime-mountinfo-mount-id",
            "runtime-mountinfo-parent-mount-id",
            "owned-null-netns-placeholder?",
            "(delete-file pin)",
            "(rmdir root)",
            "assert-diagnostic-stores-unmounted!",
            "assert-source-provenance!",
            "accepted-language-closure-sha256",
            "guest-runsc evidence requires checked source/profile provenance",
            "random-token 12 'strong",
            "BOOKEXEC-PROTOCOL-FAIL",
        ),
        "guest authority adapter",
    )
    check("expire-request!" not in adapter, "request timers remain deferred")
    check("call-with-new-thread" not in adapter and "make-thread" not in adapter,
          "no detached protocol worker")
    check("setrlimit" not in adapter and "RLIMIT_FSIZE" not in adapter,
          "no process-wide supervisor file-size limit")
    check("(post-store-check bundle)" in adapter, "post-unmount gate is explicit")
    check("MNT_DETACH" not in adapter, "null-netns cleanup is not lazy")
    check("delete-recursively" not in adapter, "runtime state has no recursive cleanup")
    check(
        '"--gofer-network-namespace' not in oci,
        "pinned null gofer-network namespace default remains unchanged",
    )
    check(
        "(set! source-provenance-checked? #t)" in adapter,
        "successful source/profile verification gates guest evidence mode",
    )
    check(
        adapter.index(
            "(assert-source-provenance!\n"
            "             profile closure-file guest-smoke base-oci-source"
        )
        < adapter.index("(primitive-load base-oci-source)"),
        "source/profile provenance check precedes OCI generation and runsc",
    )
    check(
        adapter.index("(post-store-check bundle)")
        < adapter.index("(marker-emitter marker)"),
        "verified store unmount precedes language PASS",
    )
    check(
        adapter.index("(release-peer! peer)")
        < adapter.index("(set! result (capture-result"),
        "endpoint/group cleanup precedes result acceptance",
    )
    run_one = adapter[
        adapter.index("(define* (run-one-book!") : adapter.index(
            "(define (send-raw-frame!"
        )
    ]
    check(
        run_one.index("(prepare-owned-runtime-state! bundle container-id)")
        < run_one.index("(open-session-endpoint! host label)"),
        "fixture owns runtime root and placeholder before endpoint/runsc launch",
    )
    check(
        run_one.index("(release-peer! peer)")
        < run_one.index("(emit-runtime-state-diagnostics bundle container-id)")
        < run_one.index("(cleanup-owned-runtime-state!"),
        "endpoint/group/capture cleanup and bounded roster precede state cleanup",
    )
    check(
        adapter.index("(cleanup-owned-runtime-state!\n                   runtime-state-owner container-id)")
        < adapter.index("(post-store-check bundle)"),
        "owned null-netns/cgroup/state cleanup precedes store-unmount gate",
    )
    cleanup = adapter[
        adapter.index("(define (cleanup-owned-runtime-state!") : adapter.index(
            "(define (emit-runtime-state-diagnostics"
        )
    ]
    first_root_mount_check = cleanup.index("(unless (null? (mountinfo-at root))")
    pin_unmount = cleanup.index(
        "(list (smoke-private 'umount-program) \"-n\" pin)"
    )
    second_root_mount_check = cleanup.index(
        "(unless (null? (mountinfo-at root))", first_root_mount_check + 1
    )
    check(
        first_root_mount_check
        < pin_unmount
        < second_root_mount_check
        < cleanup.index("(delete-file pin)"),
        "root mounts are rejected before pin unmount and rechecked before unlink",
    )

    check("format #t" not in guile_book and "display" not in guile_book,
          "Guile book has no stdout result path")
    check("print(" not in python_book and "sys.stdout" not in python_book,
          "Python book has no stdout result path")
    check("identity" not in guile_book.lower() and "identity" not in python_book.lower(),
          "books send no self-asserted identity")
    require_all(guile_book, ("GUILE[", '"|nonce=g-"', "string-upcase input"),
                "Guile computed-response fixture")
    require_all(python_book, ("PYTHON[", '"|nonce=p-"', "value[::-1]"),
                "Python computed-response fixture")

    require_all(
        system,
        (
            'specification->package "guile-gcrypt@0.5.0"',
            "spike-private '%book-execution-language-profile",
            "spike-private '%book-execution-language-closure",
            "gvisor-v12-control-local-test-artifact",
            "runsc-pass-fd=3:3",
            "language-closure-expected-paths=45",
            "supervisor-only-delta=guile-gcrypt@0.5.0",
            "directfs=false",
            "network=none",
            "host-uds=none",
            "sidecar-usage-policy=strict",
            "sidecar-release-enforcement-policy=always",
            "payload-rlimit-fsize=1048576",
            "supervisor-rlimit-fsize=unlimited-by-this-fixture",
            "runtime-state-residual-policy=fail-preserve-no-recursive-delete",
            "gofer-network-namespace=null-default-unchanged",
            "runtime-state-expected-entry=null-netns",
            "runtime-state-expected-mount=single-nsfs-net-namespace-not-authority-netns",
            "runtime-state-root-mount-policy=forbidden-before-pin-cleanup-and-before-placeholder-unlink",
            "runtime-state-cleanup=identity-checked-nonlazy-unmount-owned-placeholder-only",
            "runtime-state-diagnostic-entry-limit=4",
            "runtime-state-diagnostic-mount-limit-per-entry=2",
            "runtime-state-diagnostic-root-mount-limit=2",
            "runtime-state-diagnostic-content=metadata-and-escaped-name-only",
            "debug-store-nr-inodes=11",
            "panic-store-nr-inodes=3",
        ),
        "protocol-control system manifest",
    )
    combined = "\n".join((oci, adapter, guile_book, python_book, system))
    check("--preserve-fds" not in combined, "no invented preserve-FD seam")
    check("--host-uds=open" not in combined, "host-filesystem UDS remains denied")
    check("--network=host" not in combined and "--network=sandbox" not in combined,
          "no network-policy relaxation")
    check("virtiofs" not in combined and '"9p"' not in combined,
          "no host filesystem transport")
    check("/data/" not in combined, "no device data mount")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
