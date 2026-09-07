# Actual-guest Book Protocol source gate

This directory's ordinary gate is Stage 2 source and host/static evidence only.
Running it does not invoke `runsc`, QEMU, an ARM payload, an image build, or
hardware. Two separately authorized Stage 2 images have historical run records:
the first failed runtime-state teardown before Python, while the V8 successor
completed both guest language exchanges and cleanup but exposed a four-literal
host-checker label defect. Both authorizations are consumed. Stage 1 remains
frozen by its reviewed source-hash roster. SHA-256
`ab164146dfe1b769dcb4bfd5dfa8b57c59ab775967d962e565d50b876653cf34`
identifies the historical review snapshot at Stage-1 acceptance; it is not the
hash of the current append-only review and is deliberately not a machine-gate
input.

Run the complete cheap gate from this directory:

```sh
make check
```

The gate verifies the clean pinned gVisor FD-import seam and null gofer-network
namespace lifecycle, frozen Stage-1 and accepted authority sources, immutable
source hashes, both exact OCI process objects, two real native books behind a
strict fake-runsc boundary, malformed / stale / truncated-close rejection,
capture overflow, whole-run TERM/KILL/reap, exact null-netns ownership/cleanup
models, and the non-realizing Guix system delta. The current aggregate is 38
host tests, 2 review-drift tests, and 18 static system checks. Two focused S2-1
regressions prove that appending to the review report leaves the source gate
valid while mutating any reviewed Stage-1 source still fails it.

The proposed non-shipping system is
`pinenote/systems/pinenote-book-execution-protocol-control.scm`. It inherits the
accepted USER_NS kernel and complete unpatched CONTROL package, keeps the exact
45-path language profile/closure, and adds `guile-gcrypt` 0.5.0 only to the
trusted supervisor profile. Each OCI root receives only its selected fixed book
and codec sources as separate read-only mounts. The runtime command remains
Systrap, `isolation-userns`, DirectFS false, no network, strict sidecars/release,
`host-uds=none`, cgroups enabled, and exactly `--pass-fd=3:3`.

On the reviewed successor guest path, the trusted authority first re-hashes
every trusted/session/codec/book source, its own separately pinned source, and
the exact accepted 45-path closure. Each language then receives two fresh
strong-random nonce-bearing inputs. A language PASS is emitted only after both
language-distinct computed results arrived through the accepted session
endpoint, the donated peer and authority endpoint closed, the exact runsc group
was reaped, the cgroup disappeared, and runtime state passed the exact owned-pin
gate. That gate permits one fixture-precreated `null-netns` placeholder only;
it requires one internally consistent `nsfs` network-namespace mount distinct
from the authority namespace and requires zero mounts at the exact state root
before touching that pin. It non-lazily unmounts only the pin, rechecks that the
root remains unmounted, re-verifies the revealed placeholder identity, then
removes that file and the unchanged empty root. Unknown entries, `.state`,
`.lock`, control sockets, symlinks, replacement objects, root mounts,
wrong/stacked pin mounts, and an already-unmounted placeholder remain fatal and
untouched. Bounded diagnostics report the root-mount count and at most two
escaped 2,048-byte mountinfo records in addition to the existing entry bounds.
Bounded captures must pass and both finite diagnostic stores must be verified
unmounted before PASS. Book stdout/stderr are diagnostics only and are never
result evidence. The two root observations enforce this controlled fixture's
ownership contract; they do not claim to prevent arbitrary concurrent
privileged mount operations on a hostile host.

## Historical first runtime: narrow Guile semantics, full gate failed

The one reviewed protocol image run failed and must not be repeated. Its exact
wrapper result was `RUN-STATUS=1 CHECKER-STATUS=1`; it did not produce
`OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS`. The frozen
control flow plus retained console prove that the actual ARM64/Systrap Guile
book received FD 3 and completed both nonce-dependent presentations before the
strict state-root assertion ran. Runsc, its gofer, and the application exited
zero and the cgroup was absent. The assertion then reported a non-empty state
root, so the Guile language PASS was never emitted and Python never started.
This is narrow Guile protocol evidence, not two-language or teardown acceptance.

The old checker retained only `runtime-state=present`; it did not retain the
entry roster, and the private overlay is gone. Pinned source shows that default
`--gofer-network-namespace=null` bind-mounts `null-netns` under the shared root
(which defaults to `--root`) and ordinary `run` destruction does not remove
that shared pin, while `.state`, `.lock`, and the control socket are removed.
`null-netns` is therefore the strongly supported source explanation, not a
measured filename; no claim is made that an additional entry was absent. The
immutable analysis is
`build/protocol-control-runtime-failure-analysis-v1.txt` (SHA-256
`768dc48020fde6ba0e1272ad0449790dfa24daa49b345b8d5469abd9b9dcd730`).

## Successor runtime: both guest chains passed; host checker fix pending

The accepted V8 image subsequently ran once. That authorization is consumed and
the launcher must not be reused. The immutable original result remains
`RUN-STATUS=1 CHECKER-STATUS=1`; there is no outer status-zero line. The retained
failure evidence is
`build/protocol-control-root-mount-runtime-evidence-v2.OMSobe.log`, SHA-256
`5bfcd98425f0d3e554a343e89775d2ba2f56212ac21753bc15a6542c5818e378`.

The accepted outer retained one complete, non-elided console frame declaring
25,120 source/content bytes. Exact one-pass inverse decoding followed by exact
re-encoding recovered raw console SHA-256
`171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3`.
That console proves both fixed FD-3 nonce exchanges and their complete accepted
cleanup path. Guile and Python each report one mode-0444 `null-netns`, one
internally consistent `nsfs` network-namespace mount, zero exact-root mounts,
and a non-lazy cleanup action before bounded non-overflowing `runsc-debug` and
`runsc-panic` summaries and the language PASS. Python PASS is followed by
cgroup teardown, overall protocol PASS, and clean power-down. For this successor
run, `null-netns` is observed rather than inferred.

The sole observed host-oracle defect is exact: the run's immutable checker
expected shortened `debug`/`panic` labels in four string literals, while the
frozen FINAL2 emitter and actual console use `runsc-debug`/`runsc-panic`.
Changing exactly those four literals makes the unchanged console pass the
semantic checker and clean-power-down bridge. The proposed correction's tests
derive their positive labels from the actual emitter and reject missing,
reordered, duplicate, overflowing, wrong-limit, and shortened-label summaries.
A separate bounded extractor regression checks the independently recovered raw
hash and canonical decode/re-encode grammar. Author-side offline replay passes;
focused review of that checker/extractor packet remains required before closing
the host checker gate. Offline success does not relabel the original 1/1 result,
and no QEMU rerun is authorized or needed.

Independent image/runtime attribution is in
`doc/reviews/2026-09-06-book-protocol-successor-image-adversarial.md`, SHA-256
`2e60bd2fc0a792dcf03f18ee33b47525b299f885f86955a39c700715429f8e71`.
The result is limited to the exact trusted Guile/Python fixtures; hostile books,
general transport/output import, persistence, cancellation, timers, and reader
integration remain outside this gate.

Historical launchers and images are immutable records. V1 incorrectly hashed
the mutable whole review report. V2's authorized attempt stopped before any
derivation or realization because broad build-command `-L .` exposed every
repository `.scm` to package discovery. V3 and v4 established the split
discovery boundary; v4 built the historical image that later failed at runtime.
The consumed runtime launcher remains
`first-protocol-control-after-image-review-v1.command`.

The independently reviewed v7 recipe is preserved but blocked: its adapter
rejected an unexpected state-root self-bind only after unmounting the pin and
unlinking the owned placeholder. The accepted and consumed successor recipe is
`build/protocol-control-next-image-build-v8.command`. Pinned Guix adds
build-command `-L` to both `%load-path` and `%package-module-path`; package
lookup then recursively discovers and executes every `.scm` there. Therefore
the two paths stay distinct:

- `build/protocol-control-guix-module-view-v4/` contains exactly 19 hash-pinned
  Guix modules as symlinks to their original sources and is supplied only as
  `GUILE_LOAD_PATH`;
- `build/protocol-control-guix-package-view-v4/` is positively checked to
  contain only its non-Scheme `EMPTY` marker and is the sole `-L` argument.

Individual module symlinks preserve each original source directory, so
relative `local-file` declarations still resolve the original protocol files,
CONTROL/diagnostic release inputs, firmware tool sources, and all 14 kernel
patches. `GUILE_LOAD_COMPILED_PATH` remains empty at the caller boundary. A
focused check then found that Guile can still consult its per-user auto-compile
cache by source filename with that variable empty, so every v8 Guix invocation
also fixes `HOME=/nonexistent` and `XDG_CACHE_HOME=/nonexistent`. The strict v4
module-view log contains no user-cache lookup. The standalone shape is:

```sh
module_view=/tmp/opencode/wilkbook-book-computer/pinenote/tools/book-execution-spike/build/protocol-control-guix-module-view-v4
package_view=/tmp/opencode/wilkbook-book-computer/pinenote/tools/book-execution-spike/build/protocol-control-guix-package-view-v4

env HOME=/nonexistent XDG_CACHE_HOME=/nonexistent GUILE_AUTO_COMPILE=0 \
  GUILE_LOAD_PATH="$module_view" GUILE_LOAD_COMPILED_PATH= \
  guix time-machine -C channels.scm -- repl -L "$package_view" -q \
  pinenote/tools/book-execution-spike/check-protocol-control-module-view.scm

env HOME=/nonexistent XDG_CACHE_HOME=/nonexistent GUILE_AUTO_COMPILE=0 \
  GUILE_LOAD_PATH="$module_view" GUILE_LOAD_COMPILED_PATH= \
  guix time-machine -C channels.scm -- system image --dry-run \
  --no-grafts --no-substitutes --no-offload --cores=2 --max-jobs=1 \
  -t raw-with-offset -L "$package_view" --target=aarch64-linux-gnu \
  pinenote/systems/pinenote-book-execution-protocol-control.scm
```

Never replace the empty package view with the module view or repository root.
V5 and v6 are preserved superseded drafts; v7 is preserved as the rejected
root-mount-check proposal. V8's source, image build, and one-run authorizations
were separately reviewed and are now consumed. None authorizes a retry.

## Reader-driven source successor

The next candidate is
`pinenote-book-execution-reader-interaction.scm`. It inherits this accepted V8
system and leaves the automatic protocol adapter available here unchanged. It
replaces only the one-shot service and its source/build manifests with a fixed
reader-driven authority over
`/dev/virtio-ports/org.wilkbook.book-interaction`; the service waits for both
`user-processes` and `udev`. The kernel, CONTROL runtime, exact 45-path language
closure, Guile/JSON/gcrypt supervisor profile, OCI generators, and fixed Guile
and Python books remain inherited objects.

Its Guix view is a separate 20-module view: the 19 accepted v4 modules plus
only the reader successor system. The package-discovery view still contains no
Scheme source. Static checks confirm original `local-file` authority for the
accepted inputs and the three added trusted files. Derivation-only evaluation
found different protocol and reader system derivations but one shared
`89md…-raw-initrd.drv`; the compared 2,549/2,558-path rosters are derivation
build closures, not realized system runtime closures.

The host-only checker stack has not started QEMU, runsc, ARM code, an image, or
hardware. It cannot claim that a real named virtio port appears or that host
disconnect propagates to guest EOF. Those remain later, separately authorized
runtime gates after independent source and image review.
