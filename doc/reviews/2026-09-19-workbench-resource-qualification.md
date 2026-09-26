# Workbench resource qualification — 2026-09-19

Continuation from the accepted v9 authoring result in
[`2026-09-15-workbench-sandbox-and-self-authoring.md`](2026-09-15-workbench-sandbox-and-self-authoring.md).
The existing Workbench sources, native editor, note fixes and generation-21
records were already uncommitted when this session began.

**Current result:** v13 passes **112 assertions across 20 actual sandbox
executions** (92 authoring + 20 resource/access assertions). File exclusion and
write denial, host task-limit pressure, memcg OOM, complete cleanup and fresh
execution after each pressure case are observed. The retained filesystem and
SQLite audit pass. This is the one-shot QEMU composition; interactive sandboxed
editing and complete support-process accounting remain open.

## Scope

The next offline gate exercises fixed hostile programs through the existing
one-shot sandbox callback, after the durable authoring scenario:

- Read the mounted source and read/write scratch successfully, while rejecting
  access to a real host-only canary and writes to source and root. Exact write
  errors are reported; permission denial does not isolate mount enforcement.
- Retain and touch more memory than the configured 256 MiB limit. A pass needs
  trusted per-invocation `memory.events` increments in `max`, `oom` and
  `oom_kill`, delivered action and complete cleanup. This establishes limit
  pressure and an OOM kill in the observed group. It does not exclusively
  attribute that kill or establish complete support-process accounting.
- Attempt at most 48 guest forks. Accept and distinguish successful child
  creation followed by guest `EAGAIN`, or a failed runtime with a fresh trusted
  host `pids.events:max` increment. Both require complete cleanup and recovery.
  The latter is host task-limit pressure with containment, not graceful guest
  refusal or exclusive attribution of the runtime's exit.
- Run a fresh ordinary program after each probe to check runtime availability.

Host oracle tests inject evidence and compile the probe source without calling
the resulting program. They never
execute allocation/fork/access probes natively. The resource limits, lifecycle
owner and cleanup rules are unchanged. General network isolation, complete
support-process accounting, interactive sandboxed editing and device authoring
remain separate gates.

## Execution record

The first full native gate passed after correcting two test-source errors.
Independent logic, project-fit and performance/lifetime review then found:

- `EACCES` could be ordinary permissions rather than mount enforcement. The
  probe now requires `ENOENT` for the excluded canary and `EROFS` for writes.
- `oom_kill` includes global OOM. Require `max` and `oom` increments too.
- A normal cleanup RPC can race natural OOM teardown. It cannot manufacture
  those kernel counters, so complete cleanup is required without demanding a
  particular RPC count.
- Terminal counters can disappear when runsc removes its cgroup. Missing
  samples refuse the gate as incomplete evidence; they do not establish that
  the memory limit failed. The observer is unchanged.
- The exact package-union gate needed the new module, and negative oracle
  cases needed independent mutations so an unrelated missing field could not
  satisfy them.

The corrected resource oracle passes **18 assertions**, including compilation
of all three programs without execution. The independent logic reviewer reran
the suite and closed the evidence blockers for this narrow experiment. The
existing full native gate passed in
`/tmp/opencode/workbench-resource-host-check-v2.log`; the later changes affect
the resource scenario/oracle, package roster and documentation. Sandbox,
preview and lifetime-owner SHA-256 identities still exactly match the accepted
v9 inputs (`2a2cec7d…`, `85d93054…`, `1f4f0bbc…`).

Project-fit and performance/lifetime re-review also closed the design findings
for the narrowed experiment. A missing memory sample stops before the final
recovery check, so such an attempt cannot claim post-memory reuse. The fixed
360-second outer deadline remains unchanged: a slow run may exhaust it before
all twenty individually bounded executions complete, which is an incomplete
experiment rather than evidence that a resource limit failed.

### v10 candidate

Pinned lowering, the exact system/package gate, build, source inspection and
staging passed:

- Derivation: `/gnu/store/ahvghrav80qcg8pa3hg8as3vwy0qcqm5-disk-image.drv`.
- Image: `/gnu/store/8z9v3fmz42yw3c1rcz6iqp1zdr87hibm-disk-image`.
- Embedded system: `/gnu/store/s14zq1x39255zzy0bk0spyvjn3wyabzd-system`.
- Resource scenario SHA-256:
  `43a4a04c4e6f7294f45aaf6b96d8e4a915c781826a44964c4c61079803f63d6d`.
- Exact argv and staged hashes: `/tmp/opencode/book-workbench-qemu-v10-run.json`.
- Source inspection: `/tmp/opencode/book-workbench-qemu-source-inspection-v10.log`.

### ARM attempt 1 — authoring passes, filesystem oracle refuses

The v10 run completed the existing 92 authoring assertions and fourteen sandbox
executions with delivery and cleanup. Execution 15, the filesystem probe,
delivered its action and completed cleanup but returned a failure. The guest
stopped at `filesystem-access`, before any resource-pressure workload, then
powered down at kernel time 159.722835 seconds. No workspace was published.

Evidence: `/tmp/opencode/book-workbench-qemu-v10-k8bcmzdy/runner.log`, SHA-256
`d8208e860dab7571605b83713d2787adbd58f5fe6a2679440dfcf20c36b9b9e5`.
The retained stderr says `filesystem access policy failed`; the combined
assertion did not identify the operation or errno.

Source inspection explains why exact `EROFS` is too strong for these existing
fixtures: pinned gVisor's `pkg/sentry/fsimpl/gofer/filesystem.go` checks DAC
permissions in `dentry.open` (1092–1094) and `createAndOpenChildLocked`
(1315–1317) before the read-only mount check. Source is mode 0444 and root is
0755, so UID 65534 has no write permission. This identifies an oracle problem;
the failed aggregate assertion alone does not prove which access check refused.

The successor adds operation-specific errno diagnostics, still requires exact
`ENOENT` for the host canary, and reports exact source/root write-denial errors
from a closed `EACCES`/`EROFS` enum. Its claim is **write denial**, not isolated
read-only-mount enforcement. The latter needs a DAC-writable fixture on a
read-only mount; changing production permissions merely to pass this probe is
not part of the correction. The updated 18-check native oracle passes.
Independent logic re-review accepted that narrower scope, verified the Gofer
ordering and reran the oracle. Its earlier exact-`EROFS` recommendation removed
an overclaim but was unsuitable for these permission-restricted fixtures.

### ARM attempt 2 — successful runtime, observer retirement race

The revised access probe built as v11:

- Derivation: `/gnu/store/k95fpbr4x92gahz3pf2a7h1pdmdzqm7m-disk-image.drv`.
- Image: `/gnu/store/2i429c5i04l87wa0ln3lblb27pwhyyq3-disk-image`.
- Embedded system: `/gnu/store/jcfhsxzfrk9vyy1bjgg9dd2c9b8f4l8x-system`.

The existing 92 authoring checks passed again. Access invocation 15 delivered
its action and completed cleanup, and runsc exited with status zero. However,
the callback refused `fport_read: No such device` (`ENODEV`) during observation,
so the resource gate correctly stopped without accepting the access result.
Task and memory probes were not reached. The guest powered down at kernel time
156.448225 seconds; no workspace was published.

Evidence: `/tmp/opencode/book-workbench-qemu-v11-5_kkdnyh/runner.log`, SHA-256
`980c767d33e6b24936d0757db9164ba6ba0f9193bb153651c4f9227f77467279`.
Exact argv: `/tmp/opencode/book-workbench-qemu-v11-run.json`. The read-only
host summaries for v10 and v11 are `resource-audit-v3.json` in their run bases;
the first two v10 scratch summaries were invalid because they had not decoded
the outer engine's escaped console export and normalized its CRLF lines.

The existing observer tolerated a deactivated kernfs attribute only when the
directory was already absent. This attempt encountered the interval before
directory unlink. The correction permits a **maximum 50 ms wait per failed
observation**, bounded by the original work deadline, checking only the retained
directory identity and disappearance. It never rereads counters within that
incomplete observation. Persistent, replaced or inaccessible directories still
refuse; disappearance discards the whole sample. The existing exception handler
may make another observation, still within the same work deadline. No valid
pre-action sample still means no action delivery.

The delayed-unlink regression fails against the v10 immutable module and passes
against the correction. The updated sandbox suite passes **265 assertions**;
the full native aggregate passes in
`/tmp/opencode/workbench-resource-retirement-full-check.log`. Before/after
evidence: `/tmp/opencode/workbench-retirement-{before,after}.log`. Independent
review exercised five additional helper cases: delayed unlink, replacement,
expired deadline, persistent directory and earlier absolute deadline. No blocker
remained for the next run. Runtime-owner and resource budgets are unchanged.

### ARM attempt 3 — access accepted, host task limit hit

The reviewed observer correction built and ran as v12:

- Derivation: `/gnu/store/rcn7jbvjj6qwia72096nf9h9lzqgmizm-disk-image.drv`.
- Image: `/gnu/store/zb0wwp5wrjbwqjcrc9qfdzf34sw8bdy7-disk-image`.
- Embedded system: `/gnu/store/0sm3dwrb7g6w4k0an19ln235c52fb80w-system`.

The 92 authoring checks and fourteen executions passed. **Access invocation 15
passed:** source read, scratch write/read, host-canary `ENOENT`, and source/root
writes both denied with `EACCES`. The authority's canary was unchanged. A fresh
execution (16) then succeeded. Both invocations proved delivery and cleanup.

Task-pressure invocation 17 delivered its action and cleaned completely, but
the runtime exited with code 2 rather than returning guest `EAGAIN`. The kernel
reported `fork rejected by pids controller` in this exact invocation's cgroup;
the trusted `pids.events:max` sample increased from zero to one. The original
oracle required a graceful guest refusal and correctly stopped there. No
post-task recovery or memory test ran. The guest powered down at kernel time
176.500488 seconds; no workspace was published.

Evidence: `/tmp/opencode/book-workbench-qemu-v12-w68zco6c/runner.log`, SHA-256
`75f331569545c697fb9e5a99f15d30b58fc1eaffcc8c6c3aa651407c83d36174`.
Exact argv: `/tmp/opencode/book-workbench-qemu-v12-run.json`. The decoded audit
is `resource-audit-v3.json` in that run base.

The successor distinguishes **guest fork refusal** from **host task-limit hit**.
A failed runtime is accepted only with matching live controls and a new trusted
`pids.events:max` increment; generic failure remains rejected. Complete cleanup
and successful subsequent execution are required in either case. This changes
the goal to containment rather than requiring guest-level error recovery. It
does not make v12 a full pass: its post-task availability check was never run.

To exclude earlier startup pressure from the new evidence, the runtime retains
the complete control sample it already reads immediately before queuing the
action as `dispatch`. Task and memory oracles use that baseline, not the earliest
startup sample. This adds no counter reads. The guest projects it alongside
first/latest samples. It is a pre-dispatch baseline, not acknowledgment that
authored code started. Resource budgets and the process owner are unchanged.

The full native aggregate passes in
`/tmp/opencode/workbench-resource-dispatch-check.log`. Independent logic review
reran all **23 resource-oracle assertions** and accepted this explicitly revised
containment scope. The next ARM run remains pending.

### ARM attempt 4 — full resource/access and recovery pass

The v13 pinned gate, build, exact source inspection and staging passed:

- Derivation: `/gnu/store/gf3q19cp33gn3f55z78d5if4cm03pp01-disk-image.drv`.
- Image: `/gnu/store/brpzl6pl0ivi9mpxans9y6kjafklqn37-disk-image`.
- Embedded system: `/gnu/store/d734iyahn38cd18bmqrz560xvv5zzh40-system`.
- Sandbox SHA-256: `9e4a8813e96c9296da0185ad97fe3d433fbc6408bef81d09fcad78ca10f2d799`.
- Resource scenario SHA-256: `f0e0dc7b850d5fb5a878518c536e6b16b29a62754e8148e994f1441af90262f3`.

The guest passed all **92 authoring + 20 resource/access assertions** across
**20 real runsc executions**, with action delivery and complete cleanup on every
invocation. The new part was:

| Invocation | Observed result |
| --- | --- |
| 15 | Host canary absent in the sandbox (`ENOENT`), source readable, scratch writable/readable, source/root writes denied (`EACCES/EACCES`), host canary unchanged. |
| 16 | Fresh ordinary execution succeeded after the access probe. |
| 17 | Runtime failed while host `pids.events:max` increased from zero at dispatch to a positive value; cleanup completed. Outcome is `host-pids-limit-hit`, not graceful guest `EAGAIN`. |
| 18 | Fresh ordinary execution succeeded after task pressure. |
| 19 | Memory pressure increased `memory.events` from all zero at dispatch to `max=27`, `oom=1`, `oom_kill=1`, with matching controls and complete cleanup. |
| 20 | Fresh ordinary execution succeeded after memory pressure. |

The kernel independently attributes invocation 19's kill to
`constraint=CONSTRAINT_MEMCG`, with both `oom_memcg` and `task_memcg` naming its
`workbench-preview.hnjm55` cgroup. This supplies stronger attribution for this
specific run than the generic counter-only oracle. The owner made one cleanup
RPC and no forced host termination; that RPC did not prevent cleanup or recovery.
The guest powered down at kernel time **223.173523 seconds**. Both outer and
guest checkers returned zero.

Evidence base: `/tmp/opencode/book-workbench-qemu-v13-8upc61g0/`.
Exact argv and input identities: `/tmp/opencode/book-workbench-qemu-v13-run.json`.
Source inspection: `/tmp/opencode/book-workbench-qemu-source-inspection-v13.log`.

| Artifact | SHA-256 |
| --- | --- |
| `runner.log` | `725c2e559e2378315b05013055c93723b677a8559538adf949d33cb61e74630d` |
| `workspace.raw` (64 MiB) | `a1a8590aeba37003f08e46d563a9c42692033a351b2c0de97773432e1893ac97` |
| Extracted SQLite file | `3dc8102db441b8a2dd9041ba968e035e5f4b97240b3c4d1b75ce6d8b2035be02` |

The decoded audit is `resource-audit-v3.json`. Read-only `e2fsck -fn` passed;
read-only `debugfs` extracted `/exercise.M5lkej/book-workspace-v1.sqlite` and
the unchanged host canary into `audit/`. SQLite opened with
`mode=ro&immutable=1`: integrity was `ok`, foreign-key checks were empty, draft
version was 4, activation epoch 2, the installed revision was the seed and the
saved draft still looped. The entire database has the same hash as accepted
v8/v9. The workspace hash stayed unchanged throughout the audit. This remains
single-boot close/reopen persistence, not same-workspace recovery across boots.

The general runtime evidence flags remain false: these finite workloads do not
prove every resource policy or complete support-process accounting. Network
isolation, scratch exhaustion, isolated read-only-mount enforcement, CPU-limit
attribution, graceful guest fork refusal and the long-lived sandboxed editor
are not established by this run. No device deployment occurred.

**Final independent evidence audit accepted the narrow v13 result.** The reviewer
verified the image/system/boot/service chain, all staged manifest hashes, all
16 canonical module-union bindings plus standalone inputs and adapters, the
354-path system closure, exact assertion/invocation counts, delivered actions,
cleanup and the task/memory counter and kernel records. It confirmed that the
only sandbox changes from v9 are the bounded retirement wait and retained
pre-dispatch sample; the accepted owner, runner, preview generator, authoring
scenario and workspace backend identities remain intact. No concrete blocker
was found. The filesystem/SQLite audit above was performed by the parent, not
repeated by this reviewer.
