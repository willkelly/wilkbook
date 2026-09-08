#!/usr/bin/env python3
"""Finite source/provenance checks for the non-shipping guest candidate."""

from __future__ import annotations

import ast
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
CAPTURE_RELAY_FIXTURE = TOOL / "test-capture-relay-fixture.scm"
GUILE_BOUNDARY_PROBE = TOOL / "sandbox-storage-boundary-guile.scm"
PYTHON_BOUNDARY_PROBE = TOOL / "sandbox_storage_boundary.py"
ACCEPTED_PREREQUISITES = TOOL / "accepted-prerequisites-v1.txt"
QUERY_DERIVATION_OUTPUTS = TOOL / "query-derivation-outputs.scm"
ACCEPTED_OUTER = REPO / "pinenote/tools/book-execution-spike/disposable-qemu.scm"
ACCEPTED_OUTER_CONSOLE = (
    REPO / "pinenote/tools/book-execution-spike/guest-console-assertions.scm"
)
JOIN_ROOT = (
    REPO
    / "pinenote/tools/book-state-reader-join"
)
UI_MAIN = (
    REPO
    / "pinenote/tools/book-state-reader/fixture/bookstatereader.koplugin/main.lua"
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
    check(
        digest(ACCEPTED_OCI)
        == "c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7",
        "accepted protocol OCI source remains exact",
    )
    check(
        successor.count('"-I" "-S" "-B"') == 1
        and '"-l" "/book/storage-boundary.scm"' in successor
        and successor.index("/book/storage_boundary.py")
        < successor.index("/book/entry.py"),
        "OCI successor runs each fixed boundary probe before its accepted book",
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
    check(
        "/var/lib/wilkbook-book-state-demo" not in successor
        and "/dev/virtio-ports/org.wilkbook.book-interaction" not in successor
        and '"capabilities" . ,empty-capabilities' in successor
        and '"noNewPrivileges" . #t' in successor,
        "OCI mount/process source grants no authority storage or private UI transport",
    )

    authority = AUTHORITY.read_text(encoding="utf-8")
    system = SYSTEM.read_text(encoding="utf-8")
    adapter = RUNSC_ADAPTER.read_text(encoding="utf-8")
    fd3_test = FD3_EXEC_TEST.read_text(encoding="utf-8")
    contract = CONTRACT.read_text(encoding="utf-8")
    handoff = OUTER_HANDOFF.read_text(encoding="utf-8")
    liveness_test = LIVENESS_TEST.read_text(encoding="utf-8")
    liveness_fixture = LIVENESS_FIXTURE.read_text(encoding="utf-8")
    accepted_outer = ACCEPTED_OUTER.read_text(encoding="utf-8")
    guile_probe = GUILE_BOUNDARY_PROBE.read_text(encoding="utf-8")
    python_probe = PYTHON_BOUNDARY_PROBE.read_text(encoding="utf-8")
    ui_main = UI_MAIN.read_text(encoding="utf-8")
    ast.parse(python_probe, filename=str(PYTHON_BOUNDARY_PROBE))
    check(
        "candidate-repository-baseline=399764fa53d4e54bdcfaf84c362d4d1debf35f4c"
        in system
        and "guest-source-successor=v9-generic-state-mount-flags"
        in system
        and "post-v9-startup-fix=volume-ready-compiled-module-bindings-unrealized"
        in system
        and "post-v9-startup-fix-runtime=not-executed" in system
        and "399764fa53d4e54bdcfaf84c362d4d1debf35f4c" in contract
        and "549dded816e5f73d2c11557ffcd3130a018b82a8" in contract
        and digest(ACCEPTED_PREREQUISITES)
        == "b7ccb1d47d823de8b88c345b506ba8c4c865ee146c8fa7cad7ce0fd5561d99a5",
        "v9 names the current candidate baseline without rewriting prerequisite history",
    )
    check(
        digest(RUNSC_ADAPTER)
        == "15f8ec5c2eae9e99595e26e492b77a11a18ac10e4da6da9aa4f69a515b10bbeb",
        "accepted BSG-1 FD adapter bytes are unchanged",
    )
    check(
        authority.count("completed-book-result-boundary-suffix!") == 2
        and "book-state-wire-operation-id? operation-id" in authority
        and 'format #f "operation=~a resulting-state-version=~a"' in authority
        and '"read-version=2 no-new-commit=true"' in authority
        and "result completed-book-result" in authority
        and "result scenario)" in authority,
        "v8 relay consumes the same completed book invocation's closed result",
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
    join = authority[
        authority.index("(define (run-one-sandbox-book!") :
        authority.index("(define (query-rows")
    ]
    check(
        join.index("(drive-fixed-language! world language)")
        < join.index("(base-private 'release-peer!)")
        < join.index("(base-private 'capture-result)")
        < join.index("runsc/capture result was not bounded success")
        < join.index("(validate-and-publish-sandbox-boundary!")
        < join.index("(cleanup-runtime-once!)", join.index("(validate-and-publish")),
        "real completed book result reaches publication only after reap/drain and before cleanup",
    )
    relay = authority[
        authority.index(";;; BEGIN V8 BOOK-RESULT-BOUND") :
        authority.index(";;; END V8 BOOK-RESULT-BOUND")
    ]
    check(
        all(
            token in relay
            for token in (
                'string-append bundle "/runsc.stdout"',
                "owned-runsc-finalized?",
                "owned-runsc-status",
                "protocol-command-result-status",
                "capture-overflow?",
                "O_NOFOLLOW",
                "expected-bytes",
                "same-capture-identity?",
                "substring-count text boundary-marker-stem",
                "publication=next-line-after-child-drain",
                "capture-sha256",
                "marker-sha256",
                "operation=~a resulting-state-version=~a",
                "read-version=2 no-new-commit=true",
                "(emit-line source-record)",
                "(emit-line captured-marker)",
            )
        )
        and relay.index("(emit-line source-record)")
        < relay.index("(emit-line captured-marker)")
        and "sandbox-boundary-relay=pass" not in relay
        and "(emit-line expected" not in relay
        and "emit-bounded-file-diagnostic" not in relay,
        "relay binds the completed operation/version and emits the actual validated record",
    )
    check(
        relay.count("BOOK_STATE_SANDBOX_BOUNDARY") == 2
        and "result=pass storage-mount=absent storage-fd=absent "
        "ui-transport=absent book-session-fd=3" in relay,
        "authority closes the complete per-language boundary marker grammar",
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
        and authority.index("(validate-and-publish-sandbox-boundary!")
        < authority.index("(finish-ui! control 2 cooperative-deadline)")
        and authority.index("close-reader-state-runtime! runtime")
        < authority.rindex('(marker "result=pass')
        and authority.index("inspect-closed-database! state-database results")
        < authority.rindex('(marker "result=pass'),
        "guest success follows boundary publication, writer cleanup, database close/inspection, and sync",
    )
    check(
        "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite" in authority
        and "/var/lib/wilkbook-book-state-demo/.sandbox-boundary-sentinel-v1" in system
        and "WBBookStateV1" in system
        and "(flags '(no-atime no-dev no-suid no-exec))" in system
        and '(options "noatime,nodev,nosuid,noexec")' not in system,
        "authority and system share the exact persistent-volume contract with generic mount flags",
    )
    check(
        "lost+found" in authority and "state-root-mode=0700" in system,
        "ext4 lost+found and private-root mode are explicit",
    )
    reader_ready = ui_main[
        ui_main.index("function Probe:onReaderReady()") :
        ui_main.index("function Probe:onCloseDocument()")
    ]
    first_dialog = ui_main[
        ui_main.index('marker("dialog-shown:generation="') :
        ui_main.index("function Probe:_invoke_action")
    ]
    check(
        "while top and dismissed < 2 do" in ui_main
        and "if top and top.modal and top ~= self.ui then" in ui_main
        and "unexpected additional startup overlay" in ui_main
        and reader_ready.index("self:_dismiss_startup_overlays(false)")
        < reader_ready.index('self:_send("channel-ready", 1, "")')
        and first_dialog.index("self:_dismiss_startup_overlays(true)")
        < first_dialog.index("self:_announce_ready"),
        "UI consumes exactly two pinned startup notices before channel-ready while retaining marker order",
    )
    volume_service = system[
        system.index("(define (book-state-volume-ready-shepherd-service") :
        system.index("(define book-state-volume-ready-service-type")
    ]
    check(
        "(modules" in volume_service
        and "(ice-9 textual-ports)" in volume_service
        and "(srfi srfi-1)" in volume_service
        and "(srfi srfi-13)" in volume_service
        and "%default-modules" in volume_service
        and "(use-modules" not in volume_service,
        "compiled volume gate declares module bindings outside its start procedure",
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
        all(
            value in system
            for value in (
                "language-closure-sqlite-version=3.39.3-present-nonauthority",
                "cy2qjbj9akbc2c3n6cjribi4alkqqzkc-sqlite-3.39.3",
                "b769xis704c3h67y764hlnq0j3lb6asg-sqlite-3.39.3",
                "language-closure-sqlite-cli=sqlite3-present",
                "language-closure-python-sqlite3=package-and-_sqlite3-extension-present",
                "book-authority-storage-mount=absent",
                "book-authority-storage-fd=absent",
                "book-private-ui-transport=absent",
                "book-storage-boundary-probe=required-before-accepted-book",
            )
        )
        and "SQLite exists only in the trusted profile" not in contract,
        "canonical claims admit book SQLite while excluding authority storage capabilities",
    )
    forbidden_paths = (
        "/var/lib/wilkbook-book-state-demo",
        "/var/lib/wilkbook-book-state-demo/.sandbox-boundary-sentinel-v1",
        "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite",
        "/dev/virtio-ports/org.wilkbook.book-interaction",
    )
    check(
        all(path in guile_probe and path in python_probe for path in forbidden_paths)
        and "open-fdes path flags" in guile_probe
        and "os.open(path, flags)" in python_probe
        and "O_RDONLY" in guile_probe
        and "O_WRONLY" in guile_probe
        and "os.O_RDONLY" in python_probe
        and "os.O_WRONLY" in python_probe
        and "/proc/self/mountinfo" in guile_probe
        and "/proc/self/mountinfo" in python_probe
        and "'(0 1 2 3)" in guile_probe
        and "{0, 1, 2, 3}" in python_probe
        and "FD_CLOEXEC" in guile_probe
        and "FD_CLOEXEC" in python_probe
        and "stat:type info) 'socket" in guile_probe
        and "stat.S_ISSOCK(mode)" in python_probe
        and "stat:type info) 'char-special" in guile_probe
        and "stat.S_ISCHR(mode)" in python_probe
        and "readlink" in guile_probe
        and "os.readlink" in python_probe
        and '(require-stat-denied "state-sentinel-stat" state-sentinel)'
        in guile_probe
        and 'require_stat_denied("state-sentinel-stat", STATE_SENTINEL)'
        in python_probe
        and "(sqlite3)" not in guile_probe
        and not re.search(r"^\s*(?:from|import)\s+sqlite", python_probe, re.M),
        "both runtime probes use OS denial, mount, and UI-capability-FD checks rather than SQLite import failure",
    )
    exact_guile_boundary = (
        "BOOK_STATE_SANDBOX_BOUNDARY: language=guile result=pass "
        "storage-mount=absent storage-fd=absent ui-transport=absent "
        "book-session-fd=3"
    )
    exact_python_boundary = exact_guile_boundary.replace(
        "language=guile", "language=python"
    )
    python_constants = "".join(
        node.value
        for node in ast.walk(ast.parse(python_probe))
        if isinstance(node, ast.Constant) and isinstance(node.value, str)
    )
    check(
        exact_guile_boundary in guile_probe
        and exact_python_boundary in python_constants
        and "language=~a result=pass storage-mount=absent storage-fd=absent "
        "ui-transport=absent book-session-fd=3" in authority,
        "probe emitters and authority validator share the exact closed record grammar",
    )
    check(
        "guile-boundary-probe" in authority
        and "python-boundary-probe" in authority
        and "guile-boundary-probe" in system
        and "python-boundary-probe" in system
        and "native-fallback" not in successor
        and "optional" not in successor,
        "both accepted books require their probe in the same gVisor launch path",
    )
    relay_fixture = CAPTURE_RELAY_FIXTURE.read_text(encoding="utf-8")
    check(
        all(
            scenario in relay_fixture
            for scenario in (
                '"valid"',
                '"missing"',
                '"wrong-language"',
                '"duplicate"',
                '"extra"',
                '"failure-record"',
                '"malformed"',
                '"truncated"',
                '"invalid-utf8"',
                '"overflow"',
                '"stderr-overflow"',
                '"nonzero"',
            )
        )
        and "spawn-owned-runsc" in (TOOL / "test-guest-modules.scm").read_text(
            encoding="utf-8"
        )
        and "validate-and-publish-sandbox-boundary!" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8")
        and "emit-source-failure" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8")
        and "emit-marker-failure" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8")
        and "wrong-container" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8")
        and "missing-completed-book-result" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8")
        and "wrong-result-version" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8")
        and "missing-save-operation-in-save-phase" in (
            TOOL / "test-guest-modules.scm"
        ).read_text(encoding="utf-8"),
        "host relay matrix drives owned captures with valid and invalid completed results",
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
    output_query = QUERY_DERIVATION_OUTPUTS.read_text(encoding="utf-8")
    check(
        "derivation-path->output-paths" in output_query
        and 'string=? name "out"' in output_query
        and "expected one derivation output" in output_query
        and "realize" not in output_query.replace("without realizing", ""),
        "post-freeze output query reads one declared derivation output without realization",
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
