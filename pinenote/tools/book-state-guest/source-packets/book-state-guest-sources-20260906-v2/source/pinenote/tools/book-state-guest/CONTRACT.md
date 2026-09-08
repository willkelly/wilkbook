# Persistent Book State guest contract

Status: **non-shipping source candidate**. Reader-join v2 and the rebased
15-patch USER_NS kernel source gate are independently accepted prerequisites;
this guest/system join is not yet accepted or booted. The reviewed v1 packet is
blocked by BSG-1; this distinct successor repairs that descriptor finding and
awaits continuation of the independent source review.

## Frozen inputs

- Repository base: `549dded816e5f73d2c11557ffcd3130a018b82a8`.
- Accepted reader-join v2 source root: `6fcbb5b7…`; its exact functional
  Guile/Python files are machine-gated individually from canonical non-build
  paths. The review packet (`87ae3ac2…`) and evidence (`f0128637…`) are recorded
  in the versioned `accepted-prerequisites-v1.txt` attestation.
- Exact kernel derivation/output: `61ls988…drv` / `334ljs8…`; Image
  SHA-256 `5435c84efda8fbed092ac22becfde2cb1a3d82298a3549cfbdfebf6d4cbca2f9`.
- Runtime package: public `gvisor/source`, pinned to
  `release-20260831.0` / `fd2f6b2674208086e324c2f739155eb7e1b48ff2`; accepted
  AArch64 output `/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`.

The system references every required functional file at its canonical
non-build path and verifies the accepted literal hash. It imports the public
execution-spike base directly, not the historical CONTROL/reader systems whose
graph contains `gvisor-local-test-artifacts.scm`. It never imports a mutable
`build/` tree, public runner hash, live review, `/tmp` wrapper, or recursive
source directory. `SOURCE-MANIFEST.sha256` is the executable source roster;
live append-only reviews are informative links only.

The source-built runtime changes the executable identity from the older
accepted CONTROL demonstration. That historical runtime remains evidence for
its own package only; it does **not** prove this source-built package. The later
QEMU gate must explicitly validate the new gVisor package together with this
guest, the accepted USER_NS kernel, and persistent state image. This source
packet makes no such runtime claim.

## Authority and channels

Guile is the sole authority. The fixed Guile and Python namespaces, access,
text A/B, and language identity are source constants. Each fresh language
instance receives one fresh Book Session endpoint in one fresh owned runsc
container. Its sole application capability is the connected Unix socket at FD
3, donated only through `--pass-fd=3:3`. Books receive no state root, database,
namespace, grant, nonce, phase, expected value, replay text, or store handle in
argv, environment, or another FD. Python remains isolated with `-I -S` and the
accepted 45-path language profile; SQLite exists only in the trusted profile.

The native KOReader peer receives only the separate CLOEXEC virtio channel
`org.wilkbook.book-interaction`. Its accepted state-text codec permits 0–4096
UTF-8 bytes while all predecessor constructors retain their prior policy. This
first two-boot gate uses two nonempty multilingual namespaces; empty persistence
remains a later gate.

Only this success order can paint **Saved**:

1. real UI Save callback emits `submit`;
2. trusted `host-action!` creates the exact action;
3. fixed book issues `state-commit` with its restart-safe CSPRNG-surface-derived
   operation ID;
4. accepted adapter/backend returns through the endpoint-owned typed observer;
5. the bridge validates session, surface, grant, request, action, sequence,
   operation, expected version, text, and typed response;
6. authority sends correlated `commit-ok`;
7. fixed book receives a separate `present-saved` action; and
8. UI emits `applied` after paint.

`present` and `applied` are never storage evidence. Recovery is accepted only
from a real fixed-book `state-read` and its typed completion.

## Persistent volume and shutdown

The sole data device is a mandatory 64 MiB ext4 filesystem labeled
`WBBookStateV1`, mounted at `/var/lib/wilkbook-book-state-demo` with
`noatime,nodev,nosuid,noexec`. A one-shot service requires the exact generated
filesystem service, verifies that live mount, and sets/verifies its root as
root-owned mode `0700` before authority startup. There is no fallback library.

The accepted backend requires a canonical mode-0700 root, not an empty root.
Therefore ext4's normal `lost+found` is harmless and no subdirectory is added;
the fixed database remains exactly
`/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite` (mode `0600`). The
post-close inspector opens that same path read-only on every boot and checks the
two exact namespaces, receipt/version relation, `quick_check`, foreign keys,
and absence of journal/WAL/SHM sidecars.

Each endpoint release closes/revokes and joins its delegate worker, then the
accepted owner joins runsc and verifies cgroup, null-netns, runtime-state, debug,
and panic-store cleanup. Only after both language lifetimes are gone does the
authority close SQLite, inspect, finish/close the UI, and `sync`. The service
then requests shutdown; Shepherd's dependency order stops it and the volume
preparation service before the filesystem service unmounts the state volume.

Because Book State starts a worker thread when an endpoint opens, this successor
does not call `primitive-fork` afterward. It uses Guile's accepted `spawn` path
to start a fixed adapter that stops before runsc, records PID/start-time/process
group, maps selected stdin to sole application FD 3, closes unrelated FDs, and
executes the already validated CONTROL argv.

The BSG-1 successor reserves the connected endpoint on FD 3 before opening
`/dev/null`. Temporary null descriptors are integer-owned, moved above FD 3
with Linux `F_DUPFD_CLOEXEC` when a standard descriptor began closed, and
closed without Scheme-port finalizers. Existing bounded stdout/stderr pipes are
preserved. Before exec, the adapter requires the exact roster `(0 1 2 3)`, exact
endpoint identity only on socket FD 3, `/dev/null` EOF on FD 0, non-socket
stdout/stderr, and cleared close-on-exec flags. Any inherited endpoint alias or
other descriptor is closed.

## Two-boot state machine

No phase or expected value enters from outside:

| Actual typed reads at boot start | Required behavior | Final state |
|---|---|---|
| both absent/version 0 | paint absent, automate real edit/save A | A/version 1 |
| both A/version 1 | paint recovered A before any edit, then save fresh B | B/version 2 |
| both B/version 2 | paint B; do not create another save | B/version 2 |
| mixed or anything else | fail closed; no fallback | diagnostic preservation |

The A→B save uses a fresh session/surface and therefore a new operation ID.
Same-operation retries, when used by the accepted book, retain operation ID,
expected version, and text. Every operation wait is bounded to three seconds;
the complete guest is bounded to 360 seconds.

## Source-only check

Run `./run-tests.sh`. It authenticates the explicit source roster, proves the
OCI successor is exactly the accepted file plus Python `-S`, compiles with
warnings enabled, exercises actual accepted Guile backend/bridge modules with
an ext4-shaped `lost+found`, executes the post-close inspector through A→B,
tests the real private codec/virtio owner over a mock socket, and compares the
static Guix OS graph. It also rejects the historical local gVisor wrapper and
generated/live-review inputs. It does not build or boot an image and does not
execute runsc, ARM code, QEMU, networking, hardware, or a device.

Before those broader checks, the suite executes the real Scheme FD adapter and
a harmless native Python exec fixture. Its bounded matrix reproduces BSG-1's
FD-3-free precondition, then covers occupied FD 3, endpoint already on FD 3,
open/closed stdin, duplicate endpoint aliases, closed output descriptors, and
preservation of live stdout/stderr capture identities. The fixture proves FD 0
is EOF and not the Book Session socket while bidirectional traffic succeeds
only through FD 3. It never invokes runsc.

After that gate is green, the optional derivation-only check is:

```sh
env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
  -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH -u GUIX_LOCPATH \
  -u GUIX_PROFILE \
  guix time-machine -C channels.scm --no-substitutes -- \
  repl -q -L . -- pinenote/tools/book-state-guest/derive-system.scm
```

It establishes the AArch64 target before resolving `gvisor/source`, disables
grafts and substitutes, sets one job/two cores, asserts the accepted kernel and
source-built gVisor output paths, and prints only the computed system derivation.
It does not realize that derivation.
