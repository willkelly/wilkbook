# Long-lived sandbox editor and interactive preview — 2026-09-19

## Scope

This continuation joins the source-defined editor's existing workspace grants
and trusted installation control to a long-lived sandbox execution. Interactive
preview runs the saved candidate in a second disposable workspace. The author
remains running while candidate actions are exercised; trusted completion or
cancellation closes the candidate before the author receives its result.

The implementation has a separate editor QEMU scenario. The finite authoring and
resource/access gate remains available under its original target. Neither is a
device deployment or an ARM KOReader-widget qualification.

## Implementation boundaries

- The Guile authority alone owns durable workspace state, typed grants and
  installation proposals. It accepts the backend-neutral `--workspace-authority`
  entrypoint and validates author/preview access explicitly.
- The coordinator selects an immutable sandbox command, waits for trusted owner
  readiness before forwarding source frames, and requires cleanup proof before
  accepting a preview result. Author and candidate use the same selected backend.
- The editor runner retains its separate source-defined event-loop ABI.
  Interactive actions use the existing editor/workspace protocol families;
  they do not extend the ordinary BookSession core implicitly.
- The sandbox keeps the finite policy's mounts, namespace/device exclusions,
  resource controls and bounded capture policy. Its long-lived variant removes
  the finite cumulative CPU rlimit and uses startup/action/cleanup deadlines
  rather than a total session wall clock.
- Parent loss and explicit close revoke the lifetime. Cleanup uses the dedicated
  descendant owner, never saved numeric process identifiers or force-delete.
- The copied Guix asset tree has an explicit source inventory. Source inspection
  must compare its bytes, the module union and runtime helpers with the checkout
  before an ARM run is accepted.

## Validation record

- Initial static composition check failed on an unavailable `assq-delete-all`
  binding and warned about dynamically composed relative `local-file` paths.
  Replaced the former with the existing SRFI-1 filter pattern and based the
  source roster on the package module's canonical tools directory.
- Static composition v2 passed; v3 additionally checks the exact copied asset
  roster and immutable editor command configuration. Log:
  `/tmp/opencode/workbench-editor-static-check-v3.log`.
- Existing host QEMU adapter gate passed after the scenario split:
  `/tmp/opencode/workbench-editor-qemu-adapter-check.log`.
- Complete native editor gate passed: 58 workspace-protocol, 107 delegate and
  54 surface assertions; eight runner tests; 18 integration tests and 155 Lua
  assertions. Log: `/tmp/opencode/workbench-interactive-editor-native-check.log`.
  The widget test exercises the real offscreen candidate Save/Read/Finish path.
- Project/composition review found no blocker. Its reproducibility and binding
  findings were addressed: native console-test inputs can be selected explicitly;
  static checks bind the exact scenario asset and both supervisor references;
  the runbook explicitly requires `--workspace-output` when retaining evidence.

The final native and ARM results follow; failed attempts are retained below.

### Review corrections before ARM execution

- A deterministic runtime fixture exposed a startup ordering that the finite
  runner avoided by sampling after hello: the cgroup can exist before its
  controls and membership are ready. The long-lived owner now waits within its
  original startup deadline for a complete matching populated sample. No source
  frame is forwarded meanwhile. Drift after readiness still fails immediately.
  The new test fails against the prior module (`workbench-editor-startup-before-v2.log`)
  and all ten lifecycle tests pass after the fix
  (`/tmp/opencode/workbench-editor-startup-after.log`).
- The first full Workbench host gate, including the new owner/control suites,
  passed in `/tmp/opencode/workbench-interactive-sandbox-check.log`.
- The initial full editor derivation gate passed in
  `/tmp/opencode/workbench-editor-derivation-check.log`; no image was built from
  that intermediate identity.
- Independent UI logic review reproduced malformed message-type exceptions
  escaping candidate isolation, loss of original-action correlation through
  sequential preview/confirmation steps, and synchronous transport waits that
  exceeded the remaining action clock. These were blocking review findings;
  follow-up fixes passed the native gate: 25 integration tests and 171 Lua
  assertions. Malformed candidate families now fail within the disposable
  session; continuation chains preserve the original action and edit serial;
  transport waits honor the remaining clock and retire an incomplete authority
  exchange rather than reuse an uncorrelated channel.
- Runtime review additionally identified cancellation ignored during the adapter
  startup handshake, capture-limit errors discarded during teardown, and a
  preview acceptance race that confused cleanup proof with execution success.
  The packaged owner now maps its terminal result to an exit status, checked by
  the static exact-binding gate. The coordinator consumes that status after
  candidate cleanup and refuses preview success on nonzero exit even without
  diagnostics. Runtime follow-up adds an original shared monotonic startup
  deadline, pre-exec cancellation without runsc launch, and retained late capture
  violations. Sixteen lifecycle tests, 30 editor policy/control assertions and
  both existing 265/177 sandbox/preview suites pass that intermediate follow-up.
- A further deterministic race test checks unexpected helper-observed runtime
  exits before an outer stop request is consumed. The session proof now retains
  `execution-failed?` separately from expected cleanup exits. Unexpected 0/7/137
  outcomes remain failures; the kill response to an explicit cleanup is not
  automatically treated as one. Nineteen lifecycle tests pass. The final full
  Workbench gate passes in `/tmp/opencode/workbench-interactive-sandbox-final.log`.
- Follow-up runtime/logic/performance review closes all runtime findings. Idle
  observations and helper polling are four Hz; control/output readiness still
  wakes the outer owner immediately. No measured power result is claimed.
- The corrected 25-integration/171-Lua native gate was independently rerun in
  `/tmp/opencode/workbench-interactive-editor-native-final.log`. Follow-up UI
  review closed its original findings and found one remaining terminal-backend
  UI path: after authority retirement, subsequent actions/Close/Open must stay
  handled without killing the reader or discarding unsaved text.
- That terminal UI path is fixed and independently reviewed: the bridge handles
  subsequent requests locally, suppresses stale presentations/proposals, and
  retains the editable draft across Close/Open. The full final native gate
  passes **27 integration tests and 171 Lua assertions**, with the other suite
  counts unchanged. Log:
  `/tmp/opencode/workbench-interactive-editor-native-final-v2.log`.
  All UI and runtime adversarial findings are closed at source/native scope.

### Image attempts

- **v14: build failure before QEMU.** The static graph and pinned derivation
  checks passed, but the copied asset builder serialized dotted association
  pairs without lowering their nested `local-file` objects. The generated
  builder contained unreadable `#<...>` records. Converted the inventory entries
  to proper two-element lists and adjusted the static source checks. The failed
  build and identities remain in `/tmp/opencode/workbench-editor-v14-driver.log`
  and `/tmp/opencode/book-workbench-qemu-build-v14.log`.
- **v15: first ARM boot failed before editor execution.** Image
  `/gnu/store/g51lfgjmbyzvp6lp4qhvqz3jyi9r0kjm-disk-image`, embedded system
  `/gnu/store/vv3ig7fj2r02ki1b15i3pf1d9fv6wca1-system`. Build, source inspection and
  staging passed. The guest attempted `bin/python3` in the Guile/SQLite authority
  profile, where it does not exist. It reported failure and powered down at
  17.397402 s; no editor workload ran and no workspace was published. The
  coordinator now uses the already-pinned language profile's Python, and source
  inspection additionally resolves/checks both actual interpreter executables
  before boot. Evidence: `/tmp/opencode/book-workbench-qemu-v15-run.json` and
  `/tmp/opencode/book-workbench-qemu-v15-re0bnqv8/runner.log`.

### Accepted ARM64 editor run — v16

Build, immutable-source inspection, authenticated staging, QEMU gate and the
read-only retained filesystem/SQLite audit all passed. **29 scenario assertions**
passed; the guest powered down at kernel time **163.823094 s**. The scenario
created nine editor execution domains across author/reopen/recovery and
disposable candidates, including two concurrent domains during preview.

| Identity | Value |
| --- | --- |
| Image derivation | `/gnu/store/y0qvci2jyi5i28wqihdm2gvxwl1lkqlb-disk-image.drv` |
| Image | `/gnu/store/siqsg354gk7fdz92lwr1walvpn1g95ch-disk-image` |
| Embedded system | `/gnu/store/qdmlr7m9l6bxa8xjk19j10h05lx1f0xs-system` |
| Immutable owner | `/gnu/store/nladwi5q2v7bva5mcpbwrq3024s7jhyd-wilkbook-book-workbench-editor-sandbox` |
| Authenticated run record | `/tmp/opencode/book-workbench-qemu-v16-run.json` |
| Evidence directory | `/tmp/opencode/book-workbench-qemu-v16-41p9cd1l/` |
| Console SHA-256 | `364fa5614e0bca9bb35741fd59179298e75f76a822c25b9c8a66065b82197e28` |
| Retained workspace SHA-256 | `aac1d410392b142d1f6f0286b7f617e8ce7a0c24407df46f3ef467c5147c4e14` |
| Extracted SQLite SHA-256 | `e9e99f02e8cd9646940cc670f29861b91c22a4027448224b3f1b447814e55c9c` |

The accepted scenario demonstrates:

- Multiple author and candidate actions reuse their respective live execution
  owners; both domains have matching observed memory/CPU/task controls.
- Candidate Save/Read writes only its disposable workspace. The live author's
  saved draft and installation remain unchanged until trusted confirmation.
- Preview human idle has no action deadline. Finish requires candidate cleanup
  and terminal execution success before returning a usable preview result.
- Confirmation installs the exact saved successor, which runs after reopening.
  Cancellation does not grant an installation ticket, including cancellation
  while a candidate action is looping.
- A trusted test tightens only the candidate cgroup's CPU quota. The owner
  rejects the changed controls, completes cleanup, exits 1, and Finish refuses
  success. This tests drift handling, not CPU-enforcement attribution.
- A hung candidate action times out and is disposed before the failure is
  dismissed. The author remains usable; trusted seed recovery preserves the
  saved draft. A fresh coordinator/authority recovers the same durable state.
- Final checks find no owned execution cgroups, coordinator children, runtime
  tree entries or runtime mounts.

`editor-readonly-audit.json` records `e2fsck -f -n`, read-only debugfs extraction,
SQLite integrity/foreign-key checks and exact source/revision digest checks.
The artifact stays mode `0400` and its hash is unchanged by the audit. Final
state is draft version **2**, activation epoch **2**, seed active, **Sandbox R1**
as previous revision, and the looping candidate retained as the saved draft.
Exactly two immutable revisions exist. The workspace environment binds the
canonical immutable owner command through its SHA-256.

### Final independent audit

The read-only final audit accepted the stated scope without blockers. It checked
all **18 copied assets, 17 module-union files and seven standalone helpers**
against the current source bytes, the selected scenario and interpreter paths,
and staged input hashes against the launch record. It independently matched
all 29 log checks to their actual source predicates, in order and exactly once,
and verified the success markers, outer verdict and shutdown. Fresh read-only
debugfs extraction matched the audited SQLite bytes; integrity, foreign keys,
source digests and exact final state were independently checked. Source inventory:
`/tmp/opencode/book-workbench-qemu-source-inspection-v16.log`.

Acceptance distinguishes native/offscreen KOReader widget evidence from ARM
coordinator/sandbox evidence. The short human-idle check is neither an endurance
run nor a power measurement, and sampled controls plus drift rejection do not
prove complete resource accounting or enforcement.

## Remaining qualification scope

The editor scenario checks repeated operations, disposable state, human idle,
trusted installation, action-timeout cleanup and recovery. It does not qualify
network isolation, scratch exhaustion, isolated read-only-mount enforcement,
CPU-limit attribution, graceful guest fork refusal, or complete support-process
accounting. The earlier finite workload results retain their exact narrower
scope. No physical-device result is added by this work.
