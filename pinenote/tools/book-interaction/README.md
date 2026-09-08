# book-interaction — trusted native interaction fixtures

This host-only check joins the accepted Guile Book Session authority to a real
pinned KOReader `InputDialog` and to two small fixture books. It runs Latin and
Unicode inputs through both the Guile and Python books, using the same Guile
host for all four interactions.

```sh
make -C pinenote/tools/book-interaction check
```

An explicit bundle may avoid canonical output lookup, but its `git-rev` must
still match the repository package version:

```sh
make -C pinenote/tools/book-interaction check \
  KOREADER_BUNDLE=/gnu/store/...-koreader-bin-2026.03
```

The reader/QEMU seam has a separate host-only gate. It uses a trusted Guile
Unix-socket mock in the QEMU position and does **not** start a VM, ARM code, or
runsc:

```sh
make -C pinenote/tools/book-interaction qemu-mode-check \
  KOREADER_BUNDLE=/gnu/store/...-koreader-bin-2026.03
```

The exact caller-facing coordinator boundary is frozen in
[`qemu-coordinator-contract.md`](qemu-coordinator-contract.md).

## Trust and scope

This is an explicit **trusted-native fixture mode**. It is not gVisor, a
sandbox, a production broker, a shipping plugin, or a fallback for any of
those. Ordinary runs launch only the two fixture-book sources in this
directory. Negative controls launch exact disposable mutations of reviewed
fixture host/plugin sources. The temporary `.txt` document only enters
KOReader's real ReaderUI; document or EPUB content is never executed.

Python is a fixture **book language** here. Guile remains the only host/session
authority, and there is no Python production broker or fallback. The host's
only language-specific decision selects the reviewed Guile or Python fixture
entrypoint. Both books receive the same wire messages, implement the same book
behavior, and use the accepted Book Protocol codecs.

No device, actual VM/QEMU, ARM execution, gVisor, network, deployment, durable
save, reader package change, or persistent-data design is involved in either
host gate. The observed paint is an actual KOReader `InputDialog:paintTo` call
on SDL's offscreen framebuffer; it is not an optical, device-display,
refresh-settled, or user-perception result. Automatic request timers remain
future integration work; the short sleeps in the native fixture books only
stage deterministic stale replies.

## Concrete interaction

For each language, `run-tests.sh` creates a mode-0700 directory below
`/tmp/opencode`, scopes `HOME`, `KO_HOME`, XDG paths, and `TMPDIR` beneath it,
copies `bookinteractionprobe.koplugin` into that temporary KO_HOME, and starts
the bundle's actual LuaJIT and `reader.lua` with `SDL_VIDEODRIVER=offscreen`.
KOReader's ordinary profile/cache writes remain inside that disposable tree.

The fixture then proves this path over real Unix sockets:

1. The book sends `hello`; the Guile authority returns `initialize`.
2. The trusted plugin dismisses the two allowlisted clean-profile startup
   overlays, shows a real editable and topmost `InputDialog`, places the
   selected input in it, and invokes the dialog's generated Save callback as
   fixture user automation. Any other overlay fails the fixture.
3. The callback sends the dialog's current input over a private reader channel.
   The host calls `host-action!` and queues the returned `action` to the book.
4. Book-defined behavior uppercases the submitted text and returns it in
   `present`. The Guile endpoint pump first commits a `<presented-text>`. The
   generic host relay then sends its value unchanged to the plugin. A separate
   observer wraps the exact dialog's real `paintTo`, records the exact topmost
   text after the paint call, and only then permits the next action.
5. A second action is followed by `navigate!`. The delayed book reply reaches
   the real endpoint and is rejected as stale. A KOReader task scheduled for
   100 ms must execute while the 350 ms reply is still pending and find the
   dialog topmost with unchanged text.
6. A third action is delivered before `close-session!`. The delayed peer write
   is rejected by socket shutdown. KOReader, on its separate channel, still
   executes another 100 ms task during the peer's 350 ms delay and updates the
   dialog with the closed status.

The Save callback returns `(false, false)`: the pinned InputDialog's explicit
pending/rejected result plus its no-message sentinel. It neither shows the
default `Saving failed.` modal nor writes application state. A successful
fixture presentation is not a durability or display-settled acknowledgement.

The test-only oracle derives results outside the Guile host. Both book
languages process `Ada` → `Book result: ADA` and `élan λ` →
`Book result: ÉLAN Λ`. A disposable mutation that replaces the generic host
relay with the literal `Book result: ADA` must fail the Unicode paint oracle.
Python's use in that oracle and as one fixture book language does not make it a
host, broker, or fallback authority.

## Endpoint and process ownership

`open-session-endpoint!` creates the Book Session socketpair. The Guile host
retains only its opaque endpoint object and never obtains or reconstructs the
private authority FD. The returned peer end is intentionally donated as FD 3
to the selected book. A separately created socketpair donates its peer as FD 3
to KOReader. The book therefore has no descriptor for the private reader
channel and cannot send UI lifecycle commands.

Each child waits behind a one-byte launch gate until the parent has written its
PID plus Linux start time to a mode-0600 record. Before `exec`, trusted spawn
code redirects standard streams, duplicates only the selected donation to FD
3, closes every other inherited descriptor reported by `/proc/self/fd`, and
asserts that only FDs 0–3 remain. No fixture book code runs before that check.

The host has a 15-second internal whole-fixture deadline. The reused reviewed
`book-reader/timeout-owner.sh` adds a 20-second outer deadline and bounded
TERM-to-KILL escalation. Normal completion requires the Guile parent to reap
both exact children at exit status zero. The outer owner must publish distinct,
currently-live command and timeout PID/start-time records before either language
run can count. A separate regression kills the parent after both children are
recorded and proves exact cleanup removes both survivors; unrelated processes
are never selected by name. An isolated no-op `record-exec.sh` mutation is
required to fail because those two records are absent. Closing and reaping the
book peer does not release or close KOReader's sibling channel.

Before successful KOReader exit, a separate audit object retains the exact
dialog and channel references. It requires the dialog to be absent from the
window stack, the channel to be absent from `UIManager._zeromqs`, exactly one
public `insertZMQ` and `removeZMQ` call for that source, `channel.closed`, and
`fcntl(F_GETFD)` returning `EBADF`. One stale post-cleanup poll must invoke no
callback. Disposable omissions of dialog close, source removal, and channel
stop must each fail this audit before `UIManager:quit`; process exit and
UIManager's global teardown cannot satisfy it afterward.

The Guile owner uses explicit records, `dynamic-wind`, CLOEXEC socketpairs, and
bounded readiness pumps in the style of the repository-pinned Guix and
Shepherd sources. It imports neither Fibers nor a service/event framework.

Child stdout/stderr goes to per-child files with a 128 KiB `RLIMIT_FSIZE`; the
host rejects a log that reaches the cap. That process limit also bounds each
incidental regular file KOReader writes in its disposable profile. Book Session
retains its accepted eight-frame/524,320-byte output bound. The private control
channel has one nonblocking owner, 4,096-byte read/write work per scheduler
turn, at most four completed writes per turn, and an
eight-frame/65,800-byte output queue.

## Private reader control

The KOReader bridge is intentionally private and narrower than Book Protocol.
It uses exactly three line fields: an allowlisted direction-specific kind, a
canonical integer generation from 1 through 1,000,000, and lowercase-hex UTF-8
content. Values are limited to 4,096 bytes and lines to 8,224 bytes. Input and
output pumps are nonblocking and bounded. This schema exists only for the
trusted test plugin; it is not an SDK or a proposed production control plane.

The Linux LuaJIT adapter explicitly casts the variadic `F_SETFL` argument to C
`int`, checks the call result, reads the flags back, and requires effective
`O_NONBLOCK`. Its exact-runtime regression first performs an empty read, then
fills a socket whose peer never reads until `write(2)` returns `EAGAIN` and the
bounded queue reports backpressure. Every pump call must return under a
five-second outer watchdog with pending frames and bytes still within bounds.

The book endpoint continues to use the accepted `hello`, `initialize`,
`action`, and `present` schemas unchanged. No parser or session transition is
duplicated in the host fixture.

The four ordinary runs and five negative controls all retain the same
15-second internal and 20-second outer deadlines. The controls cover the
InputDialog no-message sentinel, each of the three cleanup operations, and a
hardcoded host presentation relay. Every control runs actual pinned KOReader
offscreen and must leave no recorded child alive.

This fixture exercises navigation and close invalidation, but it does **not**
exercise `cancel-request!`. Cancellation remains core-only evidence and this
directory must not be cited as an integrated cancellation-route test.

## Reader/QEMU seam mode

`qemu-coordinator.scm` is deliberately only a lifetime coordinator. Its fixed
CLI accepts one identity-checked mode-0700 run root, exactly
`RUN_ROOT/book-ui.sock`, the pinned KOReader package output, the exact QEMU
executable, and the existing fixed QEMU argument shape plus one named
virtio-serial port. It rejects TCP/NIC changes, host shares, a UI logfile,
socket escape/collision, and an overlong `sockaddr_un` path. QEMU gets no
inherited protocol descriptor. Native KOReader gets only stdio and an
already-connected FD 3; it receives no socket name, language, nonce, expected
result, or Book Session endpoint.

In `BOOK_INTERACTION_QEMU_MODE=1`, the same plugin uses public
`ReaderHighlight:addToHighlightDialog()`/`removeFromHighlightDialog()` calls to
register one action. Fixture automation invokes that registered factory's real
callback on `nextTick`; the callback opens one editable `InputDialog`. The
dialog is retained across four sequential `input-update`/`submit`/`tick`/
`present`/`applied` exchanges at private generation 1. `applied` is sent only
after inherited packaged `paintTo` returned with the exact result text and that
same dialog topmost. `finish` then requires four paints before `done` and the
retained dialog/source/channel/FD/action audit.

Lua remains language-agnostic. The actual guest Guile authority is responsible
for selecting Guile then Python, generating nonces, committing Book Session
results, and cleaning runsc; none of that authority exists in this directory's
coordinator. `test-qemu-mode-guest.scm` is only a trusted host mock. It computes
four varying Unicode/nonce-bearing fixture results so real native presentation
can be tested, while a separate Python reviewer oracle verifies the exact paint
lines. A constant mock relay can pass the coordinator's intentionally semantic-
free lifecycle check but is required to fail that joined oracle.

The host-only gate also requires wrong generation/routing/frame and early EOF
to fail in real KOReader; exercises the existing nonblocking/backpressure unit;
mutates Lua result painting and public action removal; rejects QEMU early/nonzero
status and graph/path drift; and checks connected-FD donation, same outer-owned
process group, coordinator-signal cleanup, and a modeled outer-owner SIGKILL.
An exact Linux full-AF_UNIX-backlog regression also requires the single
publication-and-connect deadline to expire without starting KOReader or
mistaking writable plus `SO_ERROR=0` for a connected peer. A draining-backlog
positive reaches all four paints on that same client. Source-copy-only fault
injections require one interrupted peer lookup to validate the eventual exact
address, repeated peer/`SO_ERROR` interruptions to remain under the original
deadline, and a wrong peer pathname to fail without donation. The QEMU and
KOReader exec children publish exact PID/start-time records and remain in the
caller's existing process group—this coordinator never calls `setpgid`, does
not unlink QEMU's listener, and does not copy the outer subreaper or run-root
guardian.

For a finite coordinator-only recheck of the full/draining backlog and the
peer/`SO_ERROR` EINTR cases, set
`BOOK_INTERACTION_QEMU_CONNECT_RECHECK_ONLY=1` when invoking
`run-qemu-mode-tests.sh`. This is only a host-test runner switch; the production
coordinator has no corresponding option or environment seam.

These host checks do not prove named virtio-port behavior, actual guest EOF on
disconnect, guest revoke/runsc cleanup, ARM execution, or the final joined
QEMU result. Those require the separately reviewed guest/outer implementation
and an independently authorized actual-QEMU run.

## Source trace

`run-tests.sh` reuses the accepted book-reader package oracle to evaluate the
canonical native KOReader derivation without building it. It checks the output
is already present, verifies its deriver when package-pinned, requires one
`git-rev` equal to `v2026.03`, and the host requires the official KOReader
version line before accepting either run.

The inputs consumed by this directory at implementation time were:

- Accepted `book-session/book-session.scm`:
  `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668`
- Accepted Guile `book-protocol.scm`:
  `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44`
- Accepted Python `book_protocol.py`:
  `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735`
- Accepted Guile blocking adapter:
  `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd`
- KOReader canonical-output oracle:
  `9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239`
- Reused timeout owner:
  `e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e`
- Reused PID/start-time helpers:
  `97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354`
- Reused identity recorder:
  `fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c`
- Pinned `channels.scm`:
  `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1`
- Final Book Session review report:
  `223c2f5272071a43e02069b2feb49370f81cc084c0909df9e09faa639009939a`

The report accepts only the untimed Book Session authority. This new integrated
fixture, its descriptor donation, private control schema, process lifecycle,
and executable behavior require a fresh independent adversarial review before
they can support any broader integration claim.
