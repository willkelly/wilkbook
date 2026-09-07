# Native-reader QEMU coordinator contract

Status: fixed host-side source contract for the reader-seam implementation.
It is not a QEMU authorization, guest protocol, or production launcher.

## Invocation

The guest/outer implementation invokes exactly:

```text
guile --no-auto-compile \
  -L pinenote/tools/book-interaction \
  pinenote/tools/book-interaction/qemu-coordinator.scm \
  --run-root ABSOLUTE_PRIVATE_RUN_ROOT \
  --socket ABSOLUTE_PRIVATE_RUN_ROOT/book-ui.sock \
  --koreader-package ABSOLUTE_KOREADER_OUTPUT \
  --qemu ABSOLUTE_QEMU_SYSTEM_AARCH64 \
  -- QEMU_ARGUMENTS_WITHOUT_ARGV0
```

There are four named options, each exactly once, followed by one `--` and the
complete QEMU argument vector without `argv[0]`. There are no book, language,
input, result, nonce, expected-revision, timeout, shell-command, environment,
or arbitrary-helper options.

The coordinator accepts the QEMU vector only when it has the reader gate's
fixed shape. In particular, it requires the existing `-no-user-config`,
`-nodefaults`, `-M virt`, TCG/CPU, headless, no-reboot, no-NIC and no-monitor
settings; one kernel, initrd, append string, two blockdevs, and one virtio block
device; and exactly this additional private channel:

```text
-chardev socket,id=bookui0,path=RUN_ROOT/book-ui.sock,server=on,wait=off
-device virtio-serial-pci,id=book-ui-serial
-device virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction
```

The existing `console0` socket chardev remains distinct. The coordinator
rejects a UI chardev logfile, TCP endpoint, second `bookui0`, 9p/virtfs/fsdev,
host forwarding, tap, or any socket path other than the exact option above.
The outer graph checker remains authoritative for its stricter complete QEMU
recipe.

## Caller-owned inputs

- `RUN_ROOT` already exists, is a real directory owned by the invoking uid,
  has no group/other mode bits, and is identity-stable for the invocation.
- `SOCKET` is exactly `RUN_ROOT/book-ui.sock`, is short enough for Linux
  `sockaddr_un.sun_path`, and does not exist before QEMU starts.
- `KOREADER_OUTPUT` is a real immutable `...-koreader-bin-2026.03` output with
  `lib/koreader/{git-rev,reader.lua,luajit}` and exactly `git-rev=v2026.03`.
- `QEMU_SYSTEM_AARCH64` is a canonical executable regular file. The outer owns
  its package/hash provenance.
- Every QEMU path below the private run root has already been prepared and
  validated by the outer. The coordinator neither builds nor selects an image.

The caller supplies the existing sanitized outer environment. The coordinator
does not treat environment values as protocol or semantic evidence.

## Coordinator-owned outputs

The coordinator creates only this fixed subtree and files beneath `RUN_ROOT`:

```text
reader-ui/
  home/
  ko/plugins/bookinteractionprobe.koplugin/
  tmp/
  fixture-book.txt
  qemu.stdout
  qemu.stderr
  reader.log
  qemu.pid
  reader.pid
```

The subtree is mode 0700; regular evidence and identity records are mode 0600.
KOReader regular-file output is bounded with `RLIMIT_FSIZE`. QEMU stdout and
stderr instead cross bounded coordinator-owned pipes (4 MiB each), so the
limit cannot affect its writable disk overlay. The QEMU console log continues
to be selected by the outer's QEMU vector and assessed by the outer, not copied
into coordinator stdout.

The KOReader child receives an empty, fixed environment containing only:

```text
HOME=RUN_ROOT/reader-ui/home
KO_HOME=RUN_ROOT/reader-ui/ko
XDG_CONFIG_HOME=RUN_ROOT/reader-ui/home/.config
XDG_CACHE_HOME=RUN_ROOT/reader-ui/home/.cache
XDG_DATA_HOME=RUN_ROOT/reader-ui/home/.local/share
TMPDIR=RUN_ROOT/reader-ui/tmp
PATH=<the caller's already-sanitized PATH>
LC_ALL=C
BOOK_INTERACTION_ROOT=RUN_ROOT/reader-ui
BOOK_INTERACTION_TRUSTED_NATIVE_FIXTURE=1
BOOK_INTERACTION_QEMU_MODE=1
BOOK_INTERACTION_CONTROL_FD=3
SDL_VIDEODRIVER=offscreen
SDL_AUDIODRIVER=dummy
```

It receives only stdio and the connected private-control peer at FD 3. It does
not receive `BOOK_INTERACTION_UPDATE_INPUT`,
`BOOK_INTERACTION_EXPECTED_RESULT`, a language, book endpoint, socket pathname,
or QEMU path.

## Process and socket lifetime

The coordinator is the direct process inside the existing outer process
guardian's owned process group. It never calls `setpgid`. QEMU and KOReader are
its direct children and must inherit that same group. Before either child is
released to exec, the coordinator records its PID plus Linux start time.

Immediately before exec, the QEMU child retains the existing reviewed rule that
every descriptor above stderr is `CLOEXEC`; the KOReader child makes only its
donated FD 3 non-`CLOEXEC`. Both exec gates validate these effective flags.

The coordinator starts QEMU first and gives the **entire socket-publication and
connection operation** one 30-second monotonic deadline. Once the exact path is
an identity-stable Unix socket, it creates one `SOCK_NONBLOCK|SOCK_CLOEXEC`
client and establishes exactly one client connection. Linux AF_UNIX
full-backlog `EAGAIN`, `EINTR`, `EINPROGRESS`, and `EALREADY` may retry on that
same client within the original deadline while QEMU output is drained and its
exact PID is reaped fairly. Writability and `SO_ERROR=0` are never treated as
connection proof: the coordinator donates the client only after `getpeername`
reports the exact expected Unix pathname and after it rechecks both socket and
run-root identity. An interrupted `getpeername` retries only the raw address
fetch and validates the eventual address once; interrupted `getpeername` and
`SO_ERROR` queries both return through the same bounded deadline turn rather
than recursing outside it. The coordinator then donates the connected client to
KOReader FD 3 and closes its own copy. QEMU receives no inherited protocol
descriptor. No listener or pathname is passed to KOReader.

Normal success requires both direct children to exit zero, no matching recorded
identity to remain, and the bounded reader log to satisfy the fixed lifecycle
checker. Only then may the coordinator print its single payload-free success
line and exit zero.

If either child exits early/nonzero, socket setup fails, the coordinator is
signalled, or any check fails, it TERM/KILL/reaps both exact direct-child
identities within five-second graces and exits nonzero. Descendants remain in
the same outer-owned process group; the existing outer subreaper/guardian is
the final owner-loss backstop and is not copied into this coordinator.
The coordinator closes an undonated client on every connection failure but
does not unlink QEMU's listener pathname. Identity-checked removal of that
pathname and the run-root tree remains the existing outer guardian's job.

## Semantic boundary

The coordinator connects bytes and owns lifetimes only. It never parses the
private-control stream, Book Protocol JSON, inputs, results, nonces, action IDs,
language labels, or guest console semantics. Guest Guile chooses and validates
all four nonce-dependent book exchanges. Native Lua is language-agnostic and
acknowledges only actual UI lifecycle and paint observations.

The coordinator's reader-log check counts required lifecycle observations but
does not calculate or approve result text. Final acceptance is a joined outer
decision: coordinator/native-UI success plus guest authority/cleanup and clean
power-down evidence.
