# Book State PR #79 follow-up publication

Author-run publication checks, 2026-09-08. This is a release handoff, not a
new independent review of the retained packets.

## Scope

- Publish the canonical two-boot guest/coordinator and their retained review
  packets and failures. The accepted clean two-boot runtime evidence remains
  identified in `pinenote/tools/book-state-qemu/two-boot/RUNTIME-NOTE-20260907.md`.
- Publish the opt-in `book-state-device-reader` flavor, activation instructions,
  Guile authority, real KOReader plugin and focused tests.
- Include the fixes exercised as generation-20 source overrides: plugin owner
  separation, native saved baseline, disconnect feedback, authority nesting,
  language identity and local edit-status handling.
- Search `/data/fonts` in every reader, alongside optional build-time fonts.
  Font bytes stay private and are not part of this publication.

## Checks

All of the following completed successfully from the canonical working tree
or its freshly exported source view:

| Gate | Evidence log under `/tmp/opencode/` |
| --- | --- |
| Device `run-tests.sh`: real KOReader widgets including disconnect; actual generated OCI/launch validation; controlled-native Guile/Python lifecycle; service/system checks | `book-state-device-publication-tests-v3.log` |
| Fresh export + `make check-source` native aggregate | `book-state-pr79-source-check-v2.log` |
| Four public execution system graph checks | `book-state-pr79-public-graphs.log` |
| Guest capsule/source/derivation checks | `book-state-pr79-guest-tests-v2.log` |
| Two-boot host graph/evidence/checker tests, without new VM boots | `book-state-pr79-two-boot-host.log` |
| Exact ARM system derivation and clean build | `book-state-release-system-derivation.log`, `book-state-release-system-build.log` |

The clean ARM system is
`/gnu/store/h6flx5n3rbrn08k0fg1i0xmfkx37pyc9-system`, derivation
`/gnu/store/ncvbfiir77dy27cmlhyfmk80gzqsg21m-system.drv`.
Its device-only closure check passes. Kernel `334ljs8q…` and source gVisor
`djgy782a…` were reused; the build used `--cores=2 --max-jobs=1`.
**This clean system has not been deployed or booted.** Hardware evidence is
generation 20 plus explicitly recorded source overrides, not this store path.

Preserved failed publication commands exposed test/publication issues:
the new launch-reader regression used the wrong profile accessor; the native
test tried applying the ARM-only 46-path pin to a 25-path native closure; the
accepted native baseline saw the newer QEMU fixture manifest; and live source
manifests needed the new reusable kernel definition. Successor fixes correct
those joins without changing historical review identities or device pins.
The native baseline now explicitly imports its two historical UI files from
`book-source-check/frozen-source-metadata/ui-v1`; current QEMU and device
adapters have their own gates.

## Hardware and remaining limits

On wkelly's PineNote, the user saved versions 2 and 3 and confirmed recovery
after both services restarted. The trusted scripted sandbox test separately
proved receipt/presentation/close/fresh-reopen. Full chronology, failures,
hotfix hashes and source-override cleanup instructions are in `doc/status.md`
and the device README. Normal suspend was restored at session end.

Book Computer is dormant without explicit activation and is not default-on.
Only the fixed Guile note is menu-visible. The schema has a 64-commit quota;
sessions have a 300-second cooperative deadline. A pre-launch failure can still
leave a runtime directory requiring inspection. Clean-generation boot,
suspend/wake qualification, physical-power-loss durability, general book
loading, retention redesign and Workbench are not claimed by this PR.
