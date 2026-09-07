# Book interaction QEMU coordinator EINTR fix — 2026-09-06

## Disposition

The narrow `getpeername` EINTR return-type bug reported by the finite
coordinator recheck has a focused implementation and source-copy fault tests.
This candidate is frozen for an independent EINTR-only recheck. It is not an
independent acceptance or authorization for the final guest/outer join.

The reviewed finding is the appended recheck in
`2026-09-06-book-interaction-qemu-native-adversarial.md`, SHA-256
`944205000134f43ae1b364dcc93bff2cdd3346899ea157c66d71d86e9cdf1b02`.
Its preserved private manifest is SHA-256
`ddbe0c2694016139196af695bdd1b6eafd6c49be3d3d20a946d8f848215a5c95`.

## Correction

`qemu-coordinator.scm` now separates raw peer retrieval from peer validation:

- `fetch-unix-peer` retries only `getpeername`, returning an address vector or
  the intentional `ENOTCONN` result to its caller;
- the outer `connected-unix-peer?` validator therefore validates the eventual
  address once and can never receive the recursive predicate's boolean result;
- every `getpeername` EINTR returns through `wait-one-turn!`, which checks the
  original monotonic connection deadline, signal state, exact QEMU status, and
  run-root identity, drains captures, and sleeps for at most 10 ms;
- `socket-pending-error` uses the same bounded turn for `SO_ERROR` EINTR rather
  than recursing in an auxiliary syscall-only loop; and
- ordinary EAGAIN/backlog connection state, exact peer-path validation, one
  client, descriptor donation, and failure cleanup are otherwise unchanged.

There is no production fault-injection hook, timeout argument, environment
switch, or general transport abstraction. The tests inject only copied
coordinator sources. `BOOK_INTERACTION_QEMU_CONNECT_RECHECK_ONLY` is a test-
runner-only switch that stops after the focused connection cases.

## Focused results

The package-pinned KOReader v2026.03 focused gate passed all of these cases:

1. The original full-backlog negative retained the exact Linux
   `EAGAIN; writable; SO_ERROR=0; peer=ENOTCONN` condition and failed under its
   copied 0.25-second deadline in **0.314773 seconds**, without starting
   KOReader.
2. The listener then drained that same backlog in a positive case; the
   coordinator retried its same client and completed four real topmost KOReader
   paints.
3. One injected `getpeername` EINTR was followed by the real successful address
   fetch, exact pathname validation, four real paints, and coordinator success.
4. Repeated injected `getpeername` EINTR reached the original copied deadline in
   **0.313030 seconds**, without a reader, live child, or open Unix socket.
5. Repeated injected `SO_ERROR` EINTR while the real backlog remained full
   reached that deadline in **0.314116 seconds**, with the same clean lifetime
   result.
6. An injected, structurally valid AF_UNIX address for the wrong pathname was
   rejected before reader launch.

All eight focused PID/start-time records were checked dead. `/proc/net/unix`
contained no focused run socket after completion. Four inert pathname entries
remain in failed run roots; this is the accepted outer run-root guardian
ownership recorded in the contract, not a new coordinator cleanup claim.

The complete host gate also passed against the same final sources, including
the prior backlog cases, four-paint positive, descriptor/lifecycle checks,
protocol and UI mutations, graph/path failures, coordinator signal cleanup, and
modeled outer-owner cleanup. This preserves host-native evidence only.

## Frozen sources

The focused patch is an exact diff from independently reviewed coordinator
SHA-256 `d677d0c0e4d78c68b210789bab18344459e42baaa07b70f85228d6a594dc01d1`
to this candidate:

| Source | SHA-256 |
|---|---|
| `qemu-coordinator.scm` | `ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde` |
| `qemu-coordinator-contract.md` | `18adc5dabd5561f723eb80e728730b62997ea5d30094662c46c9b143c5ddbac4` |
| `test-qemu-mode-guest.scm` | `5e2918e2ce38f3d32058230f59f19364dbda71f2da77ca52d4008c242bf3ce74` |
| `run-qemu-mode-tests.sh` | `3142afaec5baf01b5c6a1661cf3790085090d13b518134bce8951b40fc5f216f` |
| `README.md` | `ac5ed5c735efa91c7817e9b12d36f5838f21308a3fc3e6ba55a1db87c53d476d` |

Frozen incremental coordinator patch:

```text
287f80f6086eb25f10bf2440ab2b4cf94c20a0f3b3a69bde4e4c9c351de6c317  qemu-eintr-fix.patch
```

The private codec and visible-reader sources were not changed:

| Unchanged source | SHA-256 |
|---|---|
| `private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `fixture/.../private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| `fixture/.../main.lua` | `8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125` |
| `fixture/.../ui_audit.lua` | `cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a` |

No core Book Protocol/Session, guest authority/adapter, system, outer runner, or
graph-checker source was changed.

## Finite recheck packet

Private mode-0700 packet:

```text
/tmp/opencode/bie2.WLgj7y
```

| Evidence | SHA-256 |
|---|---|
| `packet-manifest.json` | `36082469ea505c330889a8d6ce47af42c30839f9a60220a987f07fb4274c80c5` |
| `qemu-eintr-fix.patch` | `287f80f6086eb25f10bf2440ab2b4cf94c20a0f3b3a69bde4e4c9c351de6c317` |
| `source-hashes.txt` | `df9ed8df6e21c8162f1cff3f9e29b693f9248ade41ecbe22f28e2d6057a1a37a` |
| `focused-connect-recheck.log` | `c3819c42ccb2482ba672c786d239e353c0f09b1067a4c0c9433e3ce919691288` |
| `full-host-regression.log` | `9e7ead81a221b669625aa4ad642d3272a9b95f91d8a9825a43e10650bea65765` |
| `pid-fd-audit.txt` | `3434d131a9029aa4567bd22b43ccebce845871dac32906aea5cd1eb30dc32c78` |
| `detailed-evidence-hashes.txt` | `688b01b64777ce8325986af9589c5621cecf96af407c21f657608ded60300553` |

Detailed focused artifacts:

```text
/tmp/opencode/bie2.WLgj7y/book-interaction-qemu-host.0VpSUs
```

An independent focused rerun is:

```sh
cd pinenote/tools/book-interaction
review_root=$(mktemp -d /tmp/opencode/bier.XXXXXX)
chmod 700 "$review_root"
umask 077
BOOK_INTERACTION_QEMU_CONNECT_RECHECK_ONLY=1 \
BOOK_INTERACTION_TMPDIR="$review_root" KEEP_ARTIFACTS=1 \
  timeout --foreground --signal=TERM --kill-after=10s 120s \
  ./run-qemu-mode-tests.sh \
  /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

Despite fixture naming, this command invokes no actual QEMU or runsc. No actual
QEMU, runsc, ARM execution, image/kernel/package build, hardware, mount,
network, deployment, staging, commit, or push was used for this implementation
record.

## Remaining boundary

Independent review should now inspect/apply the incremental patch and run only
the focused command above. Final acceptance remains conditional on the separate
guest/outer join retaining its reviewed process/root guardians, exact socket-
tree cleanup, and finish-delivery handshake. Actual virtio disconnect behavior
still requires its separately authorized QEMU loss injection.
