#!/usr/bin/env python3
"""Finite source/provenance checks for the non-shipping guest candidate."""

from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path


TOOL = Path(__file__).resolve().parent
REPO = TOOL.parents[2]
SYSTEM = REPO / "pinenote/systems/pinenote-book-state-reader.scm"
ACCEPTED_OCI = REPO / "pinenote/tools/book-execution-spike/oci-book-bundle.scm"
STATE_OCI = TOOL / "oci-state-book-bundle.scm"
AUTHORITY = TOOL / "book-state-guest-authority.scm"
RUNSC_ADAPTER = TOOL / "runsc-fd3-exec.scm"
FD3_EXEC_TEST = TOOL / "test-fd3-exec.py"
CONTRACT = TOOL / "CONTRACT.md"
OUTER_HANDOFF = TOOL / "outer-qemu-handoff-v1.txt"
CAPSULE_ROSTER = TOOL / "CAPSULE-ROSTER.tsv"
PINNED_GUIX = TOOL / "pinned-guix.sh"
QUERY_REQUISITES = TOOL / "query-requisites.scm"
LIVENESS_TEST = TOOL / "test-liveness-boundary.scm"
LIVENESS_FIXTURE = TOOL / "test-liveness-fixture.scm"
ACCEPTED_OUTER = REPO / "pinenote/tools/book-execution-spike/disposable-qemu.scm"
ACCEPTED_OUTER_CONSOLE = (
    REPO / "pinenote/tools/book-execution-spike/guest-console-assertions.scm"
)
JOIN_ROOT = (
    REPO
    / "pinenote/tools/book-state-reader-join"
)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)
    print(f"PASS: {message}")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    check(
        digest(REPO / "channels.scm")
        == "661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1",
        "public channel pin is exact",
    )
    check(
        digest(REPO / "pinenote/packages/gvisor-source.scm")
        == "0b35b6bfa406bc6b063e3e1d1ff6daabe26acfdff66a673b1fe315ceffc4b740",
        "public source-built gVisor package definition is exact",
    )

    accepted = ACCEPTED_OCI.read_text(encoding="utf-8")
    successor = STATE_OCI.read_text(encoding="utf-8")
    accepted_body = accepted[accepted.index("(define-module") :]
    successor_body = successor[successor.index("(define-module") :]
    normalized = successor_body.replace(
        '#("/profile/bin/python3" "-I" "-S" "-B" "-c"',
        '#("/profile/bin/python3" "-I" "-B" "-c"',
        1,
    )
    check(
        normalized == accepted_body
        and successor_body.count('"-I" "-S" "-B"') == 1,
        "OCI successor changes executable policy only by restoring Python -S",
    )
    for flag in (
        '"--platform=systrap"',
        '"--network=none"',
        '"--sidecar-usage-policy=strict"',
        '"--sidecar-release-enforcement-policy=always"',
        '"--host-uds=none"',
        '"--directfs=false"',
        '"--pass-fd=3:3"',
    ):
        check(flag in successor, f"OCI successor retains {flag}")

    authority = AUTHORITY.read_text(encoding="utf-8")
    system = SYSTEM.read_text(encoding="utf-8")
    adapter = RUNSC_ADAPTER.read_text(encoding="utf-8")
    fd3_test = FD3_EXEC_TEST.read_text(encoding="utf-8")
    contract = CONTRACT.read_text(encoding="utf-8")
    handoff = OUTER_HANDOFF.read_text(encoding="utf-8")
    liveness_test = LIVENESS_TEST.read_text(encoding="utf-8")
    liveness_fixture = LIVENESS_FIXTURE.read_text(encoding="utf-8")
    accepted_outer = ACCEPTED_OUTER.read_text(encoding="utf-8")
    check(
        digest(AUTHORITY)
        == "688b2a9dbe5d9ce983cb3e8ca5604a12f494a6a592f5cf0b6cede4fbbeb3be73"
        and digest(RUNSC_ADAPTER)
        == "15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb",
        "accepted BSG-1 authority and FD adapter bytes are unchanged",
    )
    check("(primitive-fork" not in authority, "threaded state authority never primitive-forks")
    check(
        "spawn-owned-runsc-safely" in authority and "SIGSTOP" in adapter,
        "post-worker runsc launch uses spawn plus the fixed stopped FD adapter",
    )
    check(
        adapter.index("(duplicate-to-fixed-fd! source fixed-book-fd)")
        < adapter.index("(open-stable-null O_RDONLY)")
        and "linux-f-dupfd-cloexec" in adapter
        and 'open-file "/dev/null"' not in adapter,
        "adapter reserves FD 3 before integer-owned /dev/null temporaries",
    )
    check(
        "BSG-1-reviewer-fd3-free-negative" in fd3_test
        and "book-source-already-fd3-stdin-closed" in fd3_test
        and "duplicate-book-aliases-closed" in fd3_test
        and "same_0_3" in fd3_test,
        "native exec matrix covers the BSG-1 identity counterexamples",
    )
    stop_wait = authority[
        authority.index("(define (wait-for-stopped-child!") :
        authority.index("(define (kill-and-reap-child/best-effort!")
    ]
    spawn_launch = authority[
        authority.index("(define (spawn-owned-runsc-safely") :
        authority.index("(define (plain-initialize?")
    ]
    check(
        "cooperative-deadline" in stop_wait
        and "WNOHANG" in stop_wait
        and "(waitpid pid WUNTRACED)" not in stop_wait
        and "wait-for-stopped-child! pid cooperative-deadline" in spawn_launch
        and "kill-and-reap-child/best-effort! pid" in spawn_launch,
        "non-stopping pre-exec child returns to cooperative cleanup",
    )
    check(
        not re.search(r"getenv.*(?:phase|expected|replay|state-root)", authority, re.I),
        "authority has no phase, expected-value, replay, or state-root environment input",
    )
    check(
        "state-read" in authority
        and "reader-load-completion->value" in authority
        and "reader-save-completion->decision" in authority,
        "recovery and save success require typed book-issued completions",
    )
    check(
        authority.index("reader-save-completion->decision")
        < authority.index("'commit-ok")
        < authority.index('"present-saved"'),
        "source order preserves typed receipt before commit-ok before presentation",
    )
    check(
        authority.count("operation-timeout-seconds 3.0") == 1
        and authority.count("cooperative-run-budget-seconds 300.0") == 1
        and "whole-run-timeout-seconds" not in authority
        and "whole-guest-timeout-seconds" not in system,
        "operation and guest clocks are accurately limited to cooperative polling",
    )
    check(
        authority.rindex("(sync)") < authority.rindex('(marker "result=pass')
        and authority.count('marker "result=pass') == 1
        and authority.index("close-reader-state-runtime! runtime")
        < authority.rindex('(marker "result=pass')
        and authority.index("inspect-closed-database! state-database results")
        < authority.rindex('(marker "result=pass'),
        "guest success follows writer cleanup, database close/inspection, and sync",
    )
    check(
        "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite" in authority
        and "WBBookStateV1" in system
        and '"noatime,nodev,nosuid,noexec"' in system,
        "authority and system share the exact persistent-volume contract",
    )
    check(
        "lost+found" in authority and "state-root-mode=0700" in system,
        "ext4 lost+found and private-root mode are explicit",
    )
    check(
        "334ljs8qa7ww8vlg9gpv428bh8yjd1nx" in system
        and "61ls988abhyi7lzvm19plffyv580nxc1" in system
        and "4d614" not in system,
        "system binds the accepted rebased kernel and excludes historical 4d614",
    )
    check(
        "gvisor/source" in system
        and "djgy782a5fjmsfkr6hzff3g953r60c86" in system
        and "#:use-module (pinenote packages gvisor-local-test-artifacts)" not in system
        and "gvisor-v12-control-local-test-artifact" not in system,
        "system selects the public source-built gVisor package, not historical CONTROL",
    )
    check(
        "pinenote-book-execution-protocol-control" not in system
        and "pinenote-book-execution-reader-interaction" not in system
        and "inherited-public-spike-build-manifest" not in system,
        "fresh-checkout system import graph excludes local-wrapper-dependent systems",
    )
    check(
        "guest-cooperative-polling-budget-seconds=300" in system
        and "guest-hard-cleanup-deadline=none" in system
        and "required-outer-timeout-seconds=360" in system
        and "required-outer-term-grace-seconds=5" in system
        and "actual-two-boot-runner-binding=pending-independent-proof" in system
        and "standalone-image-hard-deadline=not-provided" in system
        and digest(AUTHORITY) in system
        and digest(OUTER_HANDOFF) in system,
        "system manifest makes the cooperative/outer/standalone boundary explicit",
    )
    check(
        "0c81pri4sf9sm16578hjp7di823l5m7y" in system
        and "jcrkzfnla7pg7g07v7xsv58hwgzlin8x" in system,
        "trusted profile records exact AArch64 guile-sqlite3 and SQLite outputs",
    )
    check(
        "org.wilkbook.book-interaction" in authority
        or "open-book-ui-control!" in authority,
        "authority opens only the accepted dedicated private UI adapter",
    )
    check(
        "/build/" not in system
        and "doc/reviews" not in system
        and "recursive?" not in system,
        "system consumes no generated snapshot, live review, or recursive source tree",
    )
    check(
        digest(ACCEPTED_OUTER)
        == "0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca"
        and digest(ACCEPTED_OUTER_CONSOLE)
        == "fe9581c2dab5ea9078ae0efc0083aa11dae17fd9d0e8ee0a8768af7962f98908",
        "accepted outer guardian and its imported console module are exact",
    )
    check(
        all(
            token in accepted_outer
            for token in (
                "pr-set-child-subreaper",
                "terminate-owned-group/reaping",
                "SIGTERM",
                "SIGKILL",
                "wait-specific-child/bounded",
                "(timeout-seconds (value #t))",
                "(term-grace-seconds (value #t))",
                "guest status was not assessed",
            )
        ),
        "accepted outer exposes bounded TERM/KILL/reap and explicit timeout CLI",
    )
    check(
        "guest-cooperative-polling-budget-seconds=300" in handoff
        and "required-outer-timeout-option=--timeout-seconds" in handoff
        and "required-outer-timeout-seconds=360" in handoff
        and "required-outer-term-grace-option=--term-grace-seconds" in handoff
        and "required-outer-term-grace-seconds=5" in handoff
        and "actual-two-boot-runner-binding=pending-independent-proof" in handoff
        and "standalone-image-hard-deadline=not-provided" in handoff
        and "timeout-clean-close-sync-unmount-halt-evidence=not-claimed" in handoff,
        "machine handoff requires the hard outer boundary without claiming integration",
    )
    check(
        "(@@ (disposable-qemu) run-owned-process)" in liveness_test
        and "'(124 . #t)" in liveness_test
        and all(
            mode in liveness_test
            for mode in ("blocking-waitpid", "blocked-revoke", "blocked-join")
        )
        and "finish-book-state-session-delegate-close!" in liveness_fixture
        and "check-deadline!" in liveness_fixture
        and "SIGTERM SIG_IGN" in liveness_fixture,
        "host liveness tests exercise real cooperative and hard-owner boundaries",
    )
    check(
        "300-second cooperative budget" in contract
        and "--timeout-seconds 360 --term-grace-seconds 5" in contract
        and "no standalone hard guest cleanup" in contract
        and "physical-power-loss durability test" in contract,
        "human contract states the same non-fictional deadline boundary",
    )
    candidate_manifest = (TOOL / "SOURCE-MANIFEST.sha256").read_text(encoding="utf-8")
    candidate_paths = {
        line.split("  ", 1)[1] for line in candidate_manifest.splitlines()
    }
    capsule_roster = CAPSULE_ROSTER.read_text(encoding="utf-8")
    capsule_paths = {
        line.split("\t", 1)[0] for line in capsule_roster.splitlines()[1:]
    }
    check(
        "/build/" not in candidate_manifest
        and "doc/reviews" not in candidate_manifest
        and "gvisor-local-test-artifacts" not in candidate_manifest
        and "book-state-qemu/two-boot" not in candidate_manifest
        and "source-packets" not in candidate_manifest
        and len(candidate_paths) == len(candidate_manifest.splitlines())
        and len(candidate_paths) >= 120,
        "candidate manifest is a finite canonical project/check input roster",
    )
    check(
        capsule_paths
        == candidate_paths
        | {"pinenote/tools/book-state-guest/SOURCE-MANIFEST.sha256"}
        and "pinenote/packages/gvisor-dependencies.scm" in capsule_paths
        and "pinenote/packages/kernel.scm" in capsule_paths
        and "pinenote/systems/base.scm" in capsule_paths
        and "pinenote/patches/linux-pinenote-7.0-forward-port.patch" in capsule_paths,
        "capsule roster closes BSG-3 modules, kernel patch, and manifest binding",
    )
    pinned = PINNED_GUIX.read_text(encoding="utf-8")
    query = QUERY_REQUISITES.read_text(encoding="utf-8")
    check(
        "exec /usr/bin/env -i" in pinned
        and 'HOME="$private_root/home"' in pinned
        and 'XDG_CACHE_HOME="$private_root/cache"' in pinned
        and 'GUILE_LOAD_PATH="$module_view"' in pinned
        and 'GUILE_LOAD_COMPILED_PATH="$private_root/compiled"' in pinned
        and 'GUILE_EXTENSIONS_PATH=' in pinned
        and 'time-machine -L "$package_view"' in pinned
        and '"$subcommand" -L "$package_view"' in pinned
        and "GUIX_PACKAGE_PATH" not in pinned,
        "Guix starts after private cache/code paths with zero-Scheme nested -L",
    )
    check(
        "(requisites store (list root))" in query
        and "guix gc" not in query,
        "derivation graph query uses pinned repl store API, not ambient guix gc",
    )

    for relative, expected in (
        ("joined-note-book.scm", "b4d9fd9b459b5738fcf1da50e578c020e7c5c2d8ca3a5d1a5d09c5f3ddb90a67"),
        ("joined_note_book.py", "e9b0cebd483bae576976f8da0f6bcb5fdf877f29154ce0ce842f4325827ecb6a"),
        ("empty-action-successor/book-session.scm", "a6d904a0bc30237de4dc1ccc0e61e955e4def8e10037478505a33a5d15a934e7"),
    ):
        check(digest(JOIN_ROOT / relative) == expected, f"accepted reader-join source is exact: {relative}")

    completed = subprocess.run(
        [
            "sha256sum",
            "--check",
            "--strict",
            "pinenote/tools/book-state-guest/SOURCE-MANIFEST.sha256",
        ],
        cwd=REPO,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    check(completed.returncode == 0, "explicit candidate/dependency source manifest passes")


if __name__ == "__main__":
    main()
