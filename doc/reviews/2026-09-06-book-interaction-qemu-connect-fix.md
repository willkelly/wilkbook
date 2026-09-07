# Book interaction QEMU native connect-bound fix — 2026-09-06

## Disposition

The one blocking native finding in
`2026-09-06-book-interaction-qemu-native-adversarial.md` (SHA-256
`7ff140ef2ed66535b5f81674f1bfbcad91fe88d6a34455e74c5617c849c7670f`)
has a targeted implementation and host regression candidate. The coordinator's
30-second monotonic deadline now covers both pathname publication and the whole
connection operation; no blocking `connect(2)` remains.

This is an implementer record for finite independent recheck, not independent
acceptance and not authorization for the joined image or an actual QEMU run.
The separate outer run-root cleanup obligation remains open at join review.

## Exact fix

`qemu-coordinator.scm` now:

1. starts the one existing deadline before waiting for socket publication;
2. creates one client with `SOCK_NONBLOCK|SOCK_CLOEXEC` and verifies both flags
   before the first `connect(2)` call;
3. handles `EAGAIN`/`EWOULDBLOCK`, `EINTR`, `EINPROGRESS`, and `EALREADY` on that
   same client under the original deadline, consulting `SO_ERROR` where the
   connection may still be pending;
4. never interprets writability or `SO_ERROR=0` as connection success;
5. requires `getpeername` to report the exact expected AF_UNIX pathname before
   donation, then rechecks the socket inode and run-root identity;
6. drains the two bounded QEMU capture pipes, reaps the exact QEMU PID, and
   sleeps for at most 10 ms on each pending turn rather than busy-spinning; and
7. closes every undonated client on failure before the existing exact-child
   TERM/KILL/reap cleanup runs.

There is no timeout CLI or environment override. Production remains fixed at
`30.0` seconds. The test copies the coordinator and changes that one source
constant to `0.25`, leaving production source unchanged.

The coordinator still does not call `setpgid`, parse either protocol, acquire
language/result/nonce authority, open a second probe connection, unlink QEMU's
listener, or duplicate the outer process/run-root guardians. Its invocation
interface is unchanged. The clarified caller contract is
`pinenote/tools/book-interaction/qemu-coordinator-contract.md`.

## Exact full-backlog regression

The trusted host fake-QEMU mode now creates a real Linux AF_UNIX listener with
backlog zero and holds one connected filler without accepting. Before holding,
an independent nonblocking probe verifies the review's exact misleading state:

```text
EAGAIN; writable; SO_ERROR=0; peer=ENOTCONN
```

The coordinator then faces that still-full listener. With only the copied
0.25-second source deadline, it failed in **0.309421 seconds** including child
teardown. The accepted interval was 0.15–2.0 seconds under a separate four-
second outer backstop. KOReader never started, the exact fake-QEMU PID was dead,
and `/proc/net/unix` had no open entry for the path after return. The listener
pathname itself remained, intentionally: removing it is the existing outer
run-root guardian's join-time responsibility, not a new coordinator behavior.

The same gate then passed its existing normal-connect, descriptor donation,
early/nonzero child, graph/path, same-process-group, coordinator-signal, and
modeled owner-loss regressions. It also re-exercised the package-pinned KOReader
v2026.03 four-paint path and existing QEMU-mode native mutations. That preserves
prior host evidence; it does not establish actual virtio disconnect behavior.

## Frozen sources and patch

The focused patch is an exact unified diff from blocked coordinator SHA-256
`dc7bb40005ff2e2105cc5e34005851190cc693c5870a12462ef823913147ba7d`
to the candidate below:

| Source | SHA-256 |
|---|---|
| `qemu-coordinator.scm` | `d677d0c0e4d78c68b210789bab18344459e42baaa07b70f85228d6a594dc01d1` |
| `qemu-coordinator-contract.md` | `1dcffa8da3a0dabfffff1694b3159e6748cacb931c807af13e583314e1f1942c` |
| `test-qemu-mode-guest.scm` | `3ef68a844f0517df2ef3a933ae350ffa6f5a10f6482bdafd81a70714f57b427b` |
| `run-qemu-mode-tests.sh` | `d5775b05e50d3be072ce4602188097f1c162c4458a09fd030f36e09a1dd0c14a` |
| `README.md` | `d394e29ceaafea6681426075379988a1ea4573057c9407f0bb6bb6f265b1acde` |

Frozen focused patch:

```text
50522d4aa65351943bcbdbc4d456cd5ff69a48c550792132296225cb8d112267  qemu-connect-fix.patch
```

The authority and visible-reader sources were not changed:

| Unchanged source | SHA-256 |
|---|---|
| `private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `fixture/.../private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| `fixture/.../main.lua` | `8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125` |
| `fixture/.../ui_audit.lua` | `cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a` |

## Finite host test packet

Private mode-0700 packet:

```text
/tmp/opencode/bic2.5rNNeb
```

| Evidence | SHA-256 |
|---|---|
| `qemu-connect-fix.patch` | `50522d4aa65351943bcbdbc4d456cd5ff69a48c550792132296225cb8d112267` |
| `source-hashes.txt` | `c6d760495407231a705e76f62a459e006cf2c72ab7fe79c5b11bf28e78c1afdc` |
| `qemu-mode-host-gate.log` | `74097986f3d2a508264ddb0c941730b615c8113f3e43370e824be3e7e7be304e` |
| `pid-fd-audit.txt` | `e2e5cb5db3a5b786441f247c927c3cc716aa00785ff91ff4262d728f12bb33ea` |
| `detailed-evidence-hashes.txt` | `fa3c4d2c16176e340bea382a57e62fa331be2b073fed8857ce9a44c14b593655` |

Detailed artifact tree:

```text
/tmp/opencode/bic2.5rNNeb/book-interaction-qemu-host.oRP1q1
```

The targeted evidence is:

| Evidence | SHA-256 |
|---|---|
| `full-backlog-timeout/coordinator.log` | `c28989815fd9ff3b2580593302d49ddd22b6146a92c4b9549989ac191816780b` |
| `full-backlog-timeout/reader-ui/qemu.stdout` | `4430c97d65dc66a061cbd0ee7d57285f169a68493178697611c1dd8634a4907b` |
| `full-backlog-timeout/reader-ui/qemu.stderr` (empty) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

All 24 recorded PID/start-time identities in this packet were checked dead;
the backlog run has no `reader.pid`. The source and host checks used no actual
QEMU, runsc, ARM execution, image/kernel/Bazel build, device, SSH, UART,
network, deployment, staging, commit, or push.

A finite independent rerun against the already-present pinned package is:

```sh
cd pinenote/tools/book-interaction
review_root=$(mktemp -d /tmp/opencode/bicr.XXXXXX)
chmod 700 "$review_root"
umask 077
BOOK_INTERACTION_TMPDIR="$review_root" KEEP_ARTIFACTS=1 \
  timeout --foreground --signal=TERM --kill-after=10s 180s \
  ./run-qemu-mode-tests.sh \
  /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

Despite the fixture's fake-QEMU naming, that command starts only host Guile,
Python reviewer checks, and package-pinned native KOReader; it does not invoke
QEMU or runsc.

## Remaining join gates

- Independent review must apply or inspect the frozen coordinator patch and
  rerun the finite host packet.
- The guest/outer join must prove identity-checked removal of retained private
  socket paths through the already-owned run-root guardian. This coordinator
  deliberately does not unlink them.
- Actual virtio disconnect-to-guest-EOF/cleanup remains a separate authorized
  QEMU loss-injection gate.
