# Book Protocol through runsc: bounded host-only seam fixture

This directory is the smallest next increment after the accepted ARM64 gVisor
compatibility run. It does **not** run gVisor, QEMU, an ARM payload, an image
build, or hardware. It leaves the accepted Book Protocol and Book Session
sources unchanged.

## Exact FD seam

Read-only inspection of pinned gVisor commit
`fd2f6b2674208086e324c2f739155eb7e1b48ff2` establishes the public CLI:

```text
runsc ... run --pass-fd=HOST_FD:GUEST_FD --bundle=BUNDLE CONTAINER_ID
```

For this fixture the mapping is exactly `--pass-fd=3:3`. `runsc/cmd/run.go`
opens the caller's host FD and keys `PassFiles` by the requested guest number;
`runsc/donation/donation.go` transfers that file to Sentry while preserving the
guest mapping; `runsc/boot/loader.go` imports it into the application FD table.
There is no public `--preserve-fds` path at this pin. Do not substitute an OCI
runtime convention or infer a different flag.

The Guile host creates two `SOCK_CLOEXEC` Book Session socketpairs. Each child
gets only its own peer, duplicated to host FD 3 with CLOEXEC explicitly cleared
for the one exec into runsc. Every other descriptor above stderr is closed and
the child asserts that only FDs 0–3 remain. The two runsc invocations use
separate state roots, bundles, container IDs, process groups, and PID/start-time
records. The parent retains both opaque Guile endpoint objects and reaps or
TERM/KILL-cleans the exact owned groups. Neither book receives its sibling's
peer or any future reader-private channel.

The protocol is the only result transport. Child stdout and stderr go to
`/dev/null`; no sentinel, book result, trusted identity, or control message is
accepted from them. The Guile authority pumps the accepted session module and
requires, independently for both books:

```text
hello -> initialize -> action -> present
```

The Guile and Python books return distinct fixed text, so crossing the two
endpoints cannot pass. There is one synchronous 15-second whole-fixture guard,
no detached worker/thread, and no call to `expire-request!`; request deadlines
and their identity-capturing timer design remain deferred.

## Minimal future profile and bundle delta

Do not mutate the accepted corrected image or its 45-path language closure.
For a separately reviewed next image:

1. Keep the sandbox language profile's Guile 3.0.9, guile-json 4.7.3, and
   Python 3.12.12. The Guile book needs the accepted protocol codec and blocking
   adapter; the Python book needs the accepted Python codec. Neither needs
   `guile-gcrypt`.
2. Add `guile-gcrypt` 0.5.0 to the **trusted supervisor** profile. The accepted
   Guile Book Session authority imports `(gcrypt random)`; the current
   supervisor profile has only Guile and guile-json.
3. Produce immutable, hash-pinned module/source outputs for the accepted Guile
   protocol/session code and the two fixed book entrypoints. Compile any Guile
   modules with the same Guile/guile-json/guile-gcrypt profile identities used
   at runtime, and keep auto-compilation disabled.
4. Mount only each selected book's fixed entrypoint and required codec modules
   read-only in its own OCI root. Set `BOOK_SESSION_FD=3` in that bundle's
   process environment. Do not mount the repository, `/gnu/store`, a host share,
   a filesystem socket, or the other book.
5. Extend a new OCI generator/launcher rather than editing the frozen
   `oci-bundle.scm` (`a3a4c4e…`) or `guest-smoke.scm` (`74491a0f…`). Preserve
   Systrap, USER_NS, `isolation-userns`, `--directfs=false`, no network, strict
   sidecars/release enforcement, cgroups, payload rlimits, and bounded
   parent-owned diagnostics.

The language closure remains 45 paths until the source mounts are deliberately
added and recomputed; the supervisor's gcrypt delta is separate and must not be
silently counted as sandbox exposure.

## Host-only checks

```sh
make -C pinenote/tools/book-execution-spike/protocol-fixture check
```

`source-check` reads the clean pinned checkout and verifies the exact commit,
five source hashes, CLI registration, M:N parse, internal transfer, and guest FD
table import. It never executes runsc. `host-check` uses a strict fake executable
at the runsc boundary. The fake accepts only the complete unchanged runtime
policy and `--pass-fd=3:3`, proves it inherited exactly FDs 0–3 with FD 3 a
non-CLOEXEC socket, records that test observation, and then execs one native
fixture book. Python is only this test oracle and one untrusted book language;
the Guile process remains the sole Book Session authority.

Before any actual runsc/QEMU work, focused review should cover this host, the
new immutable source outputs, exact OCI process objects and mounts, the
gcrypt/profile closure diff, bounded diagnostics, and owned process-group
cleanup. The first authorized runtime should be one attended corrected-CONTROL
QEMU run of these two fixed bundles. Reader transport remains later work: it
needs an explicit reviewed private virtio-serial channel, never TCP, host 9p, or
console protocol traffic.
