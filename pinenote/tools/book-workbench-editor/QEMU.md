# Long-lived sandboxed editor gate

This is the opt-in ARM64 integration of the source-defined editor, workspace
authority and interactive disposable preview. The QEMU scenario uses the same
`EditorSession` coordinator as the KOReader launcher and supplies trusted UI
actions programmatically. Native widget tests cover the separate renderer
boundary. This system is not a reader flavor to deploy.

**Accepted 2026-09-19, v16:** all **29 ARM64 scenario assertions** pass, including
interactive disposable save/read, installation/reopen, busy cancellation,
timeout and owner-failure refusal, and fresh-coordinator recovery. Final cleanup
checks and read-only filesystem/SQLite audit pass. Source identities, hashes,
review corrections and the v14/v15 failed attempts are retained in
[`doc/reviews/2026-09-19-workbench-interactive-editor.md`](../../../doc/reviews/2026-09-19-workbench-interactive-editor.md).

## Build and run

Complete the host gates, then lower the exact image:

```sh
make book-workbench-check
make book-workbench-editor-check
make book-workbench-editor-qemu-drv
```

The derivation gate retains the pinned USER_NS kernel and source-built gVisor
outputs. It checks the exact source inventory, editor runner, supervisor,
language closure and service graph. The editor system differs from the finite
resource system only in its trusted scenario selection.

Use the emitted `IMAGE-DERIVATION`, `IMAGE-OUTPUT` and `IMAGE-SYSTEM-OUTPUT`
with the build, source-inspection, staging and run procedure in
[`../book-workbench/QEMU.md`](../book-workbench/QEMU.md). Select a fresh staging
name and run directory. The existing `run-qemu.sh` owns QEMU and the private
64 MiB ext4 workspace and enforces its 360-second deadline. Add
`--workspace-output "$RUN_BASE/workspace.raw"` to retain the workspace for the
read-only filesystem/SQLite audit; publication requires the trusted gate and
clean power-down.

The static gate includes a native console-routing check. Its cached defaults
are the same supervisor used by the native tests and coreutils
`/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1/bin/timeout`.
On another workstation, set `BOOK_WORKBENCH_SUPERVISOR` to its realized native
profile and `BOOK_WORKBENCH_TIMEOUT` to a realized native store executable.
The derivation target does not provision these test dependencies.

Before boot, compare the installed `wilkbook-book-workbench-editor-assets`
tree, the module union, editor runner and runtime owner against the checkout.
Also resolve and check the actual interpreter paths: Python comes from
`wilkbook-book-execution-languages/bin/python3`; Guile for the authority comes
from `wilkbook-book-state-device-supervisor/bin/guile`. The latter profile does
not contain Python.
The asset tree deliberately copies its explicit source roster: symlinking
individual Python files would break their resolved sibling paths. It excludes
the trusted-native process owner and all tests except the fixed guest scenario.

The guest runs `sandbox-scenario.py`; it cannot select the native backend.
`BOOK_WORKBENCH_EDITOR_CHECK` records each accepted predicate, and
`BOOK_WORKBENCH_EDITOR` reports the count and retained workspace name.
`BOOK_WORKBENCH_GUEST: status=pass` is emitted only after the editor scenario
exits successfully. Authored stdout/stderr never produces those markers.

## Lifetime and authority

The trusted immutable `wilkbook-book-workbench-editor-sandbox` command receives
a cleanup-channel descriptor and a private source-snapshot filename; stdin is
the donated BookProtocol socket. Its configuration is embedded in the Guix
program. The source cannot select an interpreter, store path, runtime, mount,
language closure, or persistent workspace.

Each editor execution gets a dedicated runtime owner and runsc domain. An
interactive preview keeps the author execution alive and starts a second domain
with a separate disposable SQLite store and a preview-only grant. Candidate
read/save operations affect only that store. Trusted Finish preview/Cancel
controls are distinct from authored actions. The author receives a successful
preview result only after the candidate execution and disposable store have
been cleaned up. Installation still requires a separate trusted confirmation.

The coordinator waits for the owner's `ready` acknowledgement before forwarding
any authored frame to the authority. Readiness requires a complete live sample
matching `memory.max=268435456`, `cpu.max=50000 100000` and `pids.max=256`.
Readiness alone is not action-delivery evidence; the scenario also requires
correlated editor forms and real workspace operations.

Startup and action clocks are bounded; human think time is not an action. The
editor policy retains CPU quota but removes the finite preview's cumulative
10-second `RLIMIT_CPU`, which would otherwise kill a healthy editor after
enough use. This does not establish low idle power, complete support-process
accounting, or per-action CPU accounting.

Close, cancellation, timeout and parent loss must terminate the owned execution.
The private `clean` acknowledgement follows descendant cleanup and owned
filesystem/cgroup/mount cleanup. Missing proof is fatal; it cannot become a
failed-preview receipt or an installation ticket. Native fallback is never
selected on sandbox failure.

Cleanup proof and execution success are separate. After `clean`, the coordinator
waits for the immutable owner's exit status: zero requires both execution
success and complete cleanup. Finish must inspect that terminal outcome before
issuing a successful preview result, including failures first observed during
shutdown. A bounded `.sandbox-error` sidecar provides diagnostics, not authority.

## Scenario scope

The fixed scenario checks:

- repeated source-defined actions and saves in one long-lived author domain;
- two simultaneous domains with matching live controls;
- candidate actions, disposable save/read, and unchanged author state;
- human idle without an action timeout;
- cleanup before preview success, proposal without activation, and trusted
  confirmation of the exact saved successor;
- execution of the installed successor after close/reopen;
- cancelled preview without an installation ticket, including cancellation while
  a candidate action is outstanding;
- a candidate action loop, timeout cleanup, and successful recovery;
- a trusted quota change in the candidate's own cgroup, requiring contained
  execution failure and refusal of preview success;
- trusted seed recovery preserving the saved draft;
- recovery of that state through a fresh coordinator and authority process;
- no remaining owned cgroups, runtime mounts, or coordinator children.

The finite resource qualification remains separately reproducible with
`make book-workbench-qemu-drv`. Its task-pressure and OOM results do not prove
all resource/access policies for this long-lived composition. Network isolation,
scratch exhaustion, isolated read-only-mount enforcement, CPU-limit attribution,
graceful guest fork refusal and complete support-process accounting remain
separate qualifications.
