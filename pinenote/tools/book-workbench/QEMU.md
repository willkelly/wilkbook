# Workbench text-function QEMU gate

This opt-in system exercises the existing `(workbench text)` source contract
through actual runsc and the workspace authority. It is separate from the
native source-defined editor and never deploys to a device. Current acceptance
and review disposition: `doc/reviews/2026-09-15-workbench-sandbox-and-self-authoring.md`.

The long-lived editor has a separate scenario and derivation target,
`make book-workbench-editor-qemu-drv`; see
[`../book-workbench-editor/QEMU.md`](../book-workbench-editor/QEMU.md).

**Accepted 2026-09-15:** the final v9 image passed 92 scenario assertions and
14 real sandbox executions, including syntax/exception/nontermination rejection,
recovery after each, installation, close/reopen and rollback. Action delivery
and cleanup passed for every execution. Read-only filesystem and SQLite checks
confirmed the retained final state. The final evidence base is
`/tmp/opencode/book-workbench-qemu-v9-mgppquzd/`; exact identities and all earlier
failed attempts are in the review record above. This qualifies the one-shot
composition, not general resource-limit enforcement or interactive self-authoring.

The current guest additionally runs `resource-scenario.scm` after those authoring
checks. It exercises host-path exclusion, denied source/root writes and usable scratch,
bounded guest fork refusal, memory pressure, and fresh execution after each.
Host oracle tests compile but never execute these programs. Resource results
are tracked separately in
`doc/reviews/2026-09-19-workbench-resource-qualification.md`. **Accepted runtime
result on v13 (September 19):** 92 authoring plus 20 resource/access assertions
across 20 executions, with cleanup throughout and successful recovery after host
task-limit pressure and kernel-confirmed memcg OOM. Read-only workspace/SQLite
audit passed. The retained database is byte-identical to v9. This finite result
does not cover complete support-process accounting or the interactive editor.

The access probe requires `ENOENT` for the actual host-only canary. It reports
each write's exact `EACCES`/`EROFS` result: Gofer checks DAC before mount flags,
so these non-writable fixtures establish write denial but do not isolate
read-only-mount enforcement. That needs a separate DAC-writable fixture.

The memory check requires fresh `memory.events` increments in `max`, `oom` and
`oom_kill`, with matching controls and completed cleanup. This establishes limit
pressure and an OOM kill in the observed cgroup, not exclusive kill attribution
or complete support-process accounting. Runsc may remove its leaf cgroup before
the terminal sample is read: `memory-limit-evidence-complete` then refuses the
gate as **incomplete evidence**, not proof that the limit failed. An ordinary
cleanup RPC does not manufacture OOM counters and is allowed after the failure.
The fork check distinguishes a successful fork followed by guest `EAGAIN` from
a failed runtime with a new trusted host `pids.events:max` event. Both require
completed cleanup and a successful recovery execution. The host-limit outcome
is containment, not graceful guest refusal or exclusive exit attribution. Task
and memory evidence use the fresh pre-dispatch control sample as their baseline,
so an earlier startup event cannot qualify. Network isolation
and scratch-capacity exhaustion are separate cases.

## Lower, build, stage

From the repository root, complete the host tests before lowering:

```sh
make book-workbench-check
make book-workbench-qemu-drv
```

The second command emits `IMAGE-DERIVATION`, `IMAGE-OUTPUT`, and
`IMAGE-SYSTEM-OUTPUT`. Copy those exact values from the current run; changing
runtime/scenario/helper source invalidates earlier identities. The image's
embedded system differs from the separately lowered system because its root
UUID participates in the configuration.

```sh
# Assign these from the current successful gate:
IMAGE_DRV=/gnu/store/REPLACE-disk-image.drv
IMAGE=/gnu/store/REPLACE-disk-image
IMAGE_SYSTEM=/gnu/store/REPLACE-system

guix build --no-grafts --no-substitutes --max-jobs=1 --cores=2 "$IMAGE_DRV"

# Choose a fresh name; the staging helper refuses an existing destination.
NAME=workbench-sandbox-example
sh pinenote/tools/book-execution-spike/stage-private-qemu-inputs.sh \
  "$IMAGE_SYSTEM" "$IMAGE" "$NAME"
```

The helper works on private regular files without mounting a filesystem. It
verifies the image/system relationship, copies the boot inputs and changes the
private baseline's root label to the QEMU convention. Its read-only manifest
records source identities and the hashes of the staged inputs.

## Run the staged input

These are the cached native host outputs used by this development lane. On a
different workstation, explicitly select equivalent realized native store
outputs. The launcher refuses host executables outside `/gnu/store`.

```sh
QEMU=/gnu/store/sazv1aajlkjnvdhbgqspp8yb49ia2iwp-qemu-10.2.1
CORE=/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1
E2FS=/gnu/store/2hg18b4ifvq5d6rp6fpmyxppx5q82zgq-e2fsprogs-1.47.2
STAGED="$PWD/pinenote/tools/book-execution-spike/build/artifacts/$NAME"
RUN_BASE=$(mktemp -d /tmp/opencode/workbench-qemu-runs.XXXXXX)

# Read a hash as data, never source the manifest as shell code.
hash_for() {
  python3 - "$STAGED/manifest.txt" "$1" <<'PY'
import re
import sys
from pathlib import Path
prefix = f"sha256[{sys.argv[2]}]="
matches = [line[len(prefix):] for line in Path(sys.argv[1]).read_text().splitlines()
           if line.startswith(prefix)]
if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{64}", matches[0]):
    raise SystemExit("missing or malformed staged hash")
print(matches[0])
PY
}

# Before the first boot, use these same production arguments with
# test-real-qemu-preparation.scm, omitting --run-base and --workspace-output.
# Invoke it with the cached Guile named below; it owns fresh test directories.
sh pinenote/tools/book-workbench/run-qemu.sh \
  --boot-bundle "$STAGED/boot-bundle" \
  --baseline "$STAGED/baseline.raw" --dedicated-baseline \
  --kernel-sha256 "$(hash_for boot-bundle/extlinux/Image)" \
  --initrd-sha256 "$(hash_for boot-bundle/extlinux/initrd.cpio.gz)" \
  --config-sha256 "$(hash_for boot-bundle/extlinux/extlinux.conf)" \
  --baseline-sha256 "$(hash_for baseline.raw)" \
  --run-base "$RUN_BASE" \
  --qemu "$QEMU/bin/qemu-system-aarch64" --qemu-img "$QEMU/bin/qemu-img" \
  --cp "$CORE/bin/cp" --sha256sum "$CORE/bin/sha256sum" \
  --mke2fs "$E2FS/sbin/mke2fs" >"$RUN_BASE/runner.log" 2>&1
```

The adapter fixes 512 MiB RAM, two vCPUs, a 360-second QEMU deadline and a
five-second TERM grace. It uses the existing process/directory guardians and
prints console/failure diagnostics before deleting its owned run directory.
The command above retains that output in `RUN_BASE/runner.log`; the private
run-base itself survives. Success requires the trusted scenario result and
clean guest power-down.

The opt-in full preparation check runs with:

```sh
GUILE=/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile
"$GUILE" --no-auto-compile \
  pinenote/tools/book-workbench/test-real-qemu-preparation.scm --help
```

Pass the production arguments from the command above, excluding `--run-base`
and `--workspace-output`. It executes real private copies, hashing, `qemu-img`,
`mke2fs` and both guardian layers, substituting only the final QEMU launch. This
checks host composition after the image has been staged; it is not a guest
result and does not build an image. Its fake console and workspace are test
artifacts, not authoring evidence.

An optional `--workspace-output NEW-PRIVATE-PATH` publishes a mode-0400 64 MiB
workspace image only after that success. Its destination must be a new absolute
filename in an existing caller-owned private directory; for example add
`--workspace-output "$RUN_BASE/workspace.raw"` before the log redirection.
A later run can supply it with
`--workspace-input PATH --workspace-sha256 SHA`; QEMU modifies a private copy.
Each guest invocation creates a new scenario directory. That retained disk is
useful for inspection, but this command is not a two-boot recovery test of the
same workspace.

## Evidence scope

The scenario tests save, preview, activation, close/reopen and rollback, plus
broken-source rejection and installed-source availability afterward. Every
execution requires trusted action-delivery and cleanup observations; a generic
failure message cannot substitute for a delivered execution request. The guest records
bounded cgroup samples without printing source, input or child output as trusted
success markers. Requested settings and sampled counters do not alone establish
all resource-limit enforcement or complete support-process accounting.

After a successful run publishes `workspace.raw`, it can be checked without
mounting it: run the selected e2fsprogs `e2fsck -fn`, inspect it with read-only
`debugfs`, and copy its SQLite file into a private audit directory. Open that
copy with SQLite's read-only mode to inspect integrity and the final draft,
installed revision and activation epoch. That audits the retained single-boot
artifact; a second fresh boot recovering the same workspace is a separate test.

This launcher is a trusted developer bootstrap over the authenticated QEMU
engine. It does not implement the historical sealed source-capsule procedure,
an interactive sandboxed editor, a general book loader, or a hardware trial.
