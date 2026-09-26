# Workbench preview contract (offline milestone)

`workbench-preview.scm` exports:

```scheme
(preview-native source text
  #:guile "/absolute/trusted/supervisor/bin/guile"
  #:runner "/absolute/trusted/workbench-runner.scm"
  #:protocol-directory "/absolute/trusted/book-protocol"
  #:timeout-seconds 3)
;; => ((status . ok|failed) (text . STRING) (diagnostic . STRING)
;;     (execution-started? . BOOLEAN) (cleanup-complete? . BOOLEAN))
```

Source is a Scheme string or UTF-8 bytevector, 1–16384 bytes, without NUL.
It defines `(workbench text)` returning 1–4096 UTF-8 bytes without NUL. Input
is **1–2048 bytes**, also without NUL: the unchanged ordinary Book Session
does not admit an empty action text. `seed.scm` is the initial editable source.
Every call gets a fresh ordinary session, one `workbench-preview` action, and
one correlated `present`. No state grant is issued. Success requires the
presentation, protocol EOF, exit zero, bounded stdout/stderr EOF and process
group reap. Stdout is never result authority.

The two evidence booleans come from the trusted runner: host-observed delivery
of the ordinary initialize/action frames, and completion of all owned cleanup.
`execution-started?` requires both frames to have been queued and an accepted
nonterminal output-pump result followed immediately by an active, open endpoint
snapshot with zero outbound frames and bytes. In the sandbox, fresh matching
live controls are required before either frame is queued. Hello, initialization
state, queueing, and partial writes alone do not count. A final send may return
`budget` rather than `drained` because Book Session checks its pump budget before
queue emptiness; an empty live snapshot after that send counts. Closed/error
results and queues cleared by endpoint release never count. This is evidence of
delivery to the socket, **not proof that the source body ran or finished**; no
new guest acknowledgement or protocol message is introduced. A preflight,
post-hello control refusal, or pre-delivery transport failure therefore does
not count as an executed failure. `sandbox-scenario.scm` requires
both observations on every execution, including expected broken-source cases,
so incomplete cleanup cannot pass merely because a later launch succeeds.

## Explicitly trusted native fixture

The native function is for **trusted offline fixtures**. Authored source executes
in a separate process with the caller's filesystem and network privileges. It
is not a sandbox and must not become a device/native fallback. There is no host
evaluation of source in the broker. All source `read`/`eval` occurs in the runner
child after its ordinary protocol handshake.

The default walltime is three seconds, with part of that interval reserved for
SIGKILL/group reap and runtime-file deletion. A caller may lower it, not raise
it. Deletion traverses directories incrementally and checks the original
absolute deadline around directory reads and before filesystem operations.
If time runs out, it closes opened directory streams and returns failed with
`cleanup-incomplete; retained-root=...`, leaving the root and its remaining
entries for inspection. Files already deleted are not restored. Individual
kernel filesystem calls cannot be preempted by this cooperative check.
Each output stream is
limited to 16 KiB; returned diagnostics are capped at 1024 characters. Calls
are serialized by rejection: a concurrent call fails. The fixture temporarily
enables Linux child-subreaper status and restores its previous setting; it reaps
only its own process group. Normal descendants, including TERM-resistant ones,
are killed and reaped. A deliberately hostile native child escaping its group
with `setsid`, external side effects, kernel-blocked tasks and inherited caller
resources are outside this fixture contract. Use actual sandbox execution for
untrusted programs. Failed cleanup reports failure and preserves its run root.
Every successful capture-pipe acquisition is owned immediately. Failed pipe
configuration closes both new ends, and failure to acquire the second pair
closes the first pair without relying on garbage collection.

## New-source OCI preparation

```scheme
(generate-workbench-preview-bundle
  #:source source
  #:profile-input pinned-language-profile
  #:runner-input immutable-runner-store-file
  #:protocol-input immutable-codec-store-file
  #:blocking-input immutable-blocking-io-store-file
  #:bundle-input absent-private-bundle-path
  #:container-id broker-selected-container-id
  #:requisites-runner trusted-closure-reader
  #:cleanup-deadline original-caller-deadline) ; optional for standalone preparation
;; => bundle path, containing config.json, launch.json and program.scm
```

The optional `#:store-root` exists for synthetic-store unit tests. The production
default is `/gnu/store`. Every path, the closure reader, and the selected
container identity are **trusted broker inputs**, not program or UI selectors.
The runner/codec inputs retain the fixed-source rule: distinct, nonwritable,
top-level store files outside the language closure. Only source *bytes* are new;
the generator exclusively creates their read-only snapshot under the private
bundle and binds that file at `/book/program.scm`. It never mounts a live draft,
database, UI socket or whole store. Bundle creation is not durable revision
storage; the parent workspace authority owns revision identity and activation.
The sandbox caller passes its original deadline into preparation failure
cleanup. Standalone, never-executed preparation may omit the deadline, as may
final removal of trusted test artifacts. Native execution cleanup always
supplies its own original deadline.

The generator reuses `(oci-bundle)` validators, read-only root, selected closure,
namespace/device/scratch policy and `isolation-userns` runtime argv, adding the
ordinary socket donation `--pass-fd=3:3`. Its fixed runner is
`/profile/bin/guile ... /book/runner.scm --sandbox`. The successor requests
256 MiB memory, half of one CPU and 256 host tasks through OCI resources, plus
guest `RLIMIT_CPU=10` and `RLIMIT_NPROC=32` (both soft and hard). These are generated configuration,
**not tested gVisor enforcement**. The separate owned runtime below supplies
deadlines, capture bounds and descendant cleanup. Actual enforcement and complete
support-process accounting require runtime evidence.

**Host-task sizing (ARM v5 startup failure, 2026-09-15).** The previous 64-task
cap rejected a host fork before ordinary initialization: the kernel reported
`fork rejected by pids controller`, and the last sample had `pids.events: max 1`,
`pids.current: 0`, no memory OOM events, and 13 CPU-throttled periods. This proves
a PID ceiling hit in that run; the subsequent client-sync EOF does not identify
the failing clone or rule out another startup failure.

The pinned gVisor source (`fd2f6b2674208086e324c2f739155eb7e1b48ff2`)
explains why counting authored guest processes is inadequate:

- `runsc/cmd/gofer.go` starts one LisaFS connection per served mount;
  `pkg/lisafs/server.go` starts its service goroutine, and
  `pkg/unet/unet_unsafe.go` waits in a blocking host `ppoll` syscall.
- Non-DirectFS clients call `StartChannels` (`pkg/sentry/fsimpl/gofer/gofer.go`).
  `pkg/lisafs/channel.go` clamps channels per connection to 2–4; the fixed
  half-CPU quota gives two sentry CPUs with the default `cpu-num-from-quota`
  (`runsc/config/flags.go`, `runsc/sandbox/sandbox.go`). Each channel adds a gofer
  service waiting in a host futex (`pkg/lisafs/handlers.go`,
  `pkg/flipcall/futex_linux.go`). Each client also has a sentry watchdog waiting
  in `ppoll` (`pkg/lisafs/client.go`). Blocking syscalls occupy host threads even
  when their Go goroutines are idle.
- The realized ARM closure `8a8c36ikjvgw0xfhwax1m5jl050g3akz-…-language-closure`
  contains 46 paths. Those binds, the root filesystem and four source/module
  binds imply 51 connections: roughly `51 × (1 + 2 + 1) = 204` host tasks for
  socket services, channels and watchdogs once initialized, before other Go
  runtime, control and Systrap work. Gofer socket services already consume task
  slots during startup, before sentry client-sync completes. Systrap itself
  sets its per-subprocess maximum to `GOMAXPROCS + 1`, not a fixed ARM minimum
  of 64 (`pkg/sentry/platform/systrap/systrap.go`).

**256 is a bounded candidate**, leaving about 52 tasks beyond that mount-related
estimate; 128 would not cover it. This is source-derived sizing, not a measured
minimum or proof that 256 suffices. Changes to the closure/mount layout or CPU
selection require revisiting it. The generator, independent exact validator and
live-control observer all require 256. Actual ARM startup, cleanup and resource
qualification remain the integration gate; enforcement and complete-accounting
claim flags remain false.

**Guest CPU sizing (ARM v6 pre-hello SIGKILL, 2026-09-15).** With the 256-task
cap, v6 observed 226 host tasks, zero PID-limit events, 73,732,096 bytes of
memory and no OOM events. It completed owner, namespace, cgroup and root cleanup
after failing before ordinary initialization: the first actual complete-cleanup
result, not successful protocol execution. The last host CPU sample was
3,788,153 microseconds across 76 periods, 75 throttled. These samples establish
that this attempt advanced beyond v5; they do not establish full resource
acceptance or a startup peak.

The pinned source distinguishes the observed signal from its likely cause:

- `runsc/cli/cli.go:317–323` prints the **raw guest wait status**. Its
  `Exiting with status: 9` means guest SIGKILL, not guest exit code 9. The host
  runsc process then exits `128 + 9 = 137`.
- `pkg/sentry/kernel/task_acct.go:96–111,150–161` arms the CPU soft/hard timers
  at the requested limits and sends SIGXCPU/SIGKILL respectively.
  `thread_group.go` attaches those timers to `appSysCPUClock`; `task_start.go`
  initializes them when the task starts, before the interpreter's imports or
  Book Session hello.
- `task_sched.go:253–269,303–317` explicitly approximates CPU time: at each
  timer tick it selects runnable tasks and charges a full tick, including
  sentry execution. It does not know actual Go/host scheduling. Under ARM QEMU
  and half-CPU throttling, this synthetic guest clock is not the host cgroup
  `usage_usec` counter. The latter also includes support work. Neither counter
  yields an exact Guile startup CPU cost from the retained log.
- `workbench-runner.scm` imports its protocol and other modules before `run`
  emits hello; authored source is loaded only after initialization and action.
  Thus a two-second guest CPU cap applies to interpreter startup, not just
  the authored computation.

This confirms the SIGKILL/CPU-limit mechanism and strongly supports premature
CPU exhaustion, but the old stderr tail does not uniquely identify the sender.
**10 seconds is a bounded diagnostic candidate**, allowing five times the
synthetic CPU startup budget. It is not a measured requirement or a confirmed
fix. The service's existing **20-second wall budget**, including cleanup, is
unchanged (the API default remains ten, maximum thirty). The host half-CPU
quota, memory/PID limits and guest NPROC limit remain in force. No cancellation,
cleanup or enforcement-evidence rule is relaxed.

`workbench-preview-launch-argv bundle container-id` regenerates the exact launch
argv. `launch.json` has a distinct `workbench-preview-preparation-only` claim,
source byte count and SHA-256; it intentionally does not satisfy the old fixed
note's `read-launch-record`. `workbench-sandbox.scm` validates this new contract
and source snapshot and donates its no-state endpoint through the existing
FD adapter. The preparation module itself neither
launches runsc nor falls back to native execution. A successful unit generation
is not an ARM/QEMU/device result or the Phase 4 self-hosting gate.

## Owned sandbox callback

The long-lived source-defined editor uses a separate process API,
`(workbench-editor-sandbox)` / `run-editor-sandbox`, documented in
[`../book-workbench-editor/QEMU.md`](../book-workbench-editor/QEMU.md).
Its explicit `#:editor? #t` bundle/validation variant retains this namespace,
mount and cgroup policy but omits cumulative `RLIMIT_CPU`; startup, individual
actions and cleanup have separate clocks, with no total human-idle deadline.
The one-shot callback below retains its finite policy and contract.

```scheme
;; Initialize the Guile signal thread before loading guest-book-protocol through
;; workbench-sandbox, avoiding the inherited module-loader/signal-thread deadlock.
(sigaction SIGPIPE SIG_IGN)
(use-modules (workbench-sandbox))
(define execute-preview (make-sandbox-preview trusted-config))
(execute-preview source text)
```

The service composition supplies these trusted configuration keys:
`language-profile`, `language-closure` (a path list or immutable store file),
`runner`, `guile-protocol`, `blocking-protocol`, `supervisor-guile`,
`runsc-fd3-adapter`, `runtime-owner`, `runtime-parent`, and `timeout-seconds`.
No program/UI request supplies them. The timeout defaults to ten seconds and
may not exceed thirty; preparation, execution and cleanup share one deadline,
with up to three seconds reserved for cleanup. The fixed runsc policy alias is
resolved once to its immutable store target, as are the interpreter and helpers.

The closure file uses the inherited `%book-execution-language-closure` format:
**exactly one Scheme list of path strings**, for example
`("/gnu/store/…-language-profile" "/gnu/store/…-guile")`. It is UTF-8 data,
bounded to 262144 bytes; malformed lists, non-string entries and additional forms
are rejected. The reader retains the canonical immutable target across reading,
and the requisite paths are validated against the selected profile before
preparation. Line-oriented `guix gc --requisites` output is not this file format.

The caller must provide a canonical root-owned 0700 runtime parent with trusted
ancestry and enable the root cgroup2 `cpu`, `memory` and `pids` controllers.
The QEMU composition performs those explicit guest preflights. Live controls
must match the requested values before the ordinary action is dispatched.

Cgroup sampling races normal runsc teardown. Linux kernfs `kernfs_seq_start`
and `kernfs_file_read_iter` (`fs/kernfs/file.c`, inspected in Linux v6.19)
return `ENODEV` when an already-open attribute loses its active node reference.
Pinned runsc's `cgroupV2.Uninstall` removes the directory during Destroy
(`runsc/cgroup/cgroup_v2.go`). The ARM v7 recovery call exposed this as
`fport_read: No such device` despite runtime status zero and complete cleanup.
The observer discards an incomplete sample on `ENODEV` **only during its fixed
cgroup-file read stage and only after confirming the cgroup directory is absent**.
A still-present directory, inability to confirm absence, other read errors, and
malformed data remain failures. Since the September 19 v11 retirement race,
the observer permits at most 50 ms per failed observation for the directory
unlink, bounded by the original work deadline. It checks directory identity
and disappearance only, without rereading counters within that observation;
replacement refuses. The error handler may make a later observation, under the
same deadline. These are cooperative bounds around filesystem calls. The last valid
sample is retained; a missing sample before dispatch cannot authorize an action,
and missing observational data never substitutes for the independent cleanup
checks. The host regressions inject the error after opening a fixture attribute,
exercise actual directory removal, and cover successful native completion after
dispatch alongside failure-closed cases; they do not execute kernfs or runsc.

The callback returns `status`, `text`, `diagnostic`, `execution-started?`,
`cleanup-complete?` and bounded `resource-observations`. Captures are limited to
256 KiB per stream. A valid presentation alone is insufficient: successful
execution requires protocol EOF, zero runtime/owner exit, capture EOF and owned
cleanup. Cgroup samples include timestamps and explicit limits on their evidence.
The first, pre-dispatch and latest complete samples are retained; `dispatch` is
the existing fresh control check before the action is queued, not an extra read.
Resource qualification uses it to distinguish subsequent pressure from startup.
Failed execution diagnostics reserve separate space for the first execution
failure and first cleanup failure, followed by the end of stderr. The public
limit remains 1024 characters including its prefix; individual failure fields
are capped at 200 characters and the retained-root field at 320, with `[...]`
marking truncation. This prevents verbose stderr or a later cleanup error from
erasing the original failure, while reporting why cleanup proof was withheld.

Failures additionally return `stderr-evidence`: the first **256 KiB** of stderr
is retained as chunks, with O(bytes) work and bounded storage on the pump path.
After cleanup, one O(bytes) pass decodes UTF-8 with replacement for invalid
sequences and removes lines matching the runsc debug severity/date prefix.
This is a display heuristic on **untrusted data**, never a verdict. If no usable
non-debug lines remain, it falls back to all lines. The selected text keeps the
first and last portions within **8192 characters**, with explicit capture and
selection truncation fields. Early loader errors can therefore survive a long
Destroy debug sequence. Failed cleanup retains this evidence too; successful
results do not publish it. Any final pipe harvest is immediate, bounded and
within the original deadline, without waiting for diagnostic EOF.

The QEMU guest emits one extra failure-only `BOOK_WORKBENCH_PREVIEW_STDERR`
record, correlated by invocation number. It projects the selected stderr and
existing owner proof's raw **host runsc** wait status, stopped/forced flags and
control count. Zero controls distinguishes an owner that issued no kill RPC;
neither an exit status nor stderr alone identifies a CPU-limit signal. All
data is Scheme-escaped via `~s`, and the serialized record has a **32768-byte
UTF-8 bound**; exceeding that replaces the text with an explicit notice while
retaining the small owner/counter fields. Authored newlines, console escapes
and forged success markers cannot become standalone console records. The
ordinary 1024-character diagnostic and resource evidence remain separate.

`workbench-runtime-owner.scm` is a dedicated subreaper for one execution, owning
detached Sentry/Gofer descendants through pidfds and exact child reaping. Normal
cancellation uses bounded `runsc kill --all ID KILL` and lets attached runsc
perform Destroy. It does **not** call `delete --force` after releasing process
identities: that command can signal stale numeric PIDs from runtime metadata.
If forced pidfd termination is needed, the owner reaps its children but withholds
complete-cleanup proof. The parent preserves the root/resources and reports
incomplete cleanup; an expected bad-program result cannot count as a successful
cleanup test in that case.

The offline tests use controlled native process seams for this lifecycle.
[`QEMU.md`](QEMU.md) gives the separate actual-runtime command; the current
execution/review record is `doc/reviews/2026-09-15-workbench-sandbox-and-self-authoring.md`.

**Final ARM qualification (2026-09-15, v9):** the stated profile and resource
settings passed 14 actual runsc executions and 92 authoring assertions with
delivered actions and complete cleanup throughout. Syntax errors and exceptions
were rejected after delivery; nontermination was stopped by the wall deadline
through the bounded owner control path, followed by successful installed-source
execution. That timeout is not evidence that RLIMIT_CPU fired. The retained
workspace also passed read-only filesystem/SQLite audit. These results establish
this profile's tested startup/authoring/cleanup path; the earlier sizing estimates
remain estimates.

**Resource continuation (2026-09-19, v13):** 112 assertions across 20 executions
passed, including file exclusion/write denial, host task-limit pressure and
memcg OOM, complete cleanup and successful fresh execution after each pressure
case. The task workload hit the host PID limit and the runtime failed; graceful
guest `EAGAIN` was not observed. The kernel identified the memory kill as
`CONSTRAINT_MEMCG`, corroborating the dispatch-to-last `max/oom/oom_kill`
increments. Complete support accounting, the remaining policies and interactive
editor composition remain open. Exact scope, artifacts and failed attempts:
`doc/reviews/2026-09-19-workbench-resource-qualification.md`.

## Focused test entry

Use the native supervisor profile from `derive-inputs.scm`, retaining its site
and compiled-module paths. Add project load directories `book-workbench`,
`book-session`, `book-protocol`, and `book-execution-spike`, then run
`test-preview.scm` with `BOOK_WORKBENCH_GUILE` (or `GUILE_TEST`) naming that
profile's `bin/guile`.
The test labels its executable native proofs separately from synthetic-store
OCI policy tests. It covers changed behavior, source/text byte bounds, malformed
source/result/protocol, output overflow, missing/nonzero result, loops,
descendants, deterministic mid-traversal deadline expiry and retained roots,
second-pipe acquisition and every pipe-fcntl failure without GC masking,
exact source mounting and immutable-input rejection. No gVisor,
QEMU, hardware, package resolution or build is performed by this test.
