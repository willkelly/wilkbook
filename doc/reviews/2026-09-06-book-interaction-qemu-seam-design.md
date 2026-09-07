# Book interaction QEMU seam design review — 2026-09-06

## Disposition

**Proceed with one dedicated named virtio-serial port between the native
KOReader fixture and the trusted Guile authority in the ARM64 guest.** This is
the smallest next gate that joins the two already accepted facts:

1. pinned native KOReader v2026.03 can run a real registered action,
   `InputDialog`, nonblocking private source, topmost `paintTo`, and exact
   teardown under SDL/offscreen; and
2. the PineNote 7.1.8 USER_NS kernel can run both fixed nonce-dependent Guile
   and Python books through the accepted unpatched CONTROL gVisor/Systrap
   runtime under QEMU TCG with no NIC.

Keep KOReader native on the host. Keep the Book Session authority in trusted
Guile inside the guest. QEMU transports private trusted-UI bytes only. The
untrusted book continues to receive only its separately created Book Protocol
socket at donated FD 3.

This is a finite implementation recommendation, **not implementation or
runtime acceptance**. I did not run QEMU, runsc, an ARM program, Guix, Bazel,
or a build; did not inspect an active profile; and changed no implementation
file. The existing image/checker work remains untouched.

## Exact transport

Add this fixed device shape to the existing QEMU `virt` command:

```text
-chardev socket,id=bookui0,path=$PRIVATE_RUN_ROOT/book-ui.sock,server=on,wait=off
-device virtio-serial-pci,id=book-ui-serial
-device virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction
```

The exact option ordering is not semantically important, but the resulting
graph is: one extra Unix-socket chardev, one virtio-serial controller, and one
named port. Do not add a `logfile` to the UI chardev: it carries submitted and
computed text. Preserve all existing QEMU controls, especially:

```text
-no-user-config -nodefaults
-M virt -accel tcg,thread=multi -cpu max
-display none -no-reboot -nic none -monitor none
```

The trusted host coordinator waits boundedly for `book-ui.sock`, requires it
to be a socket beneath the unchanged mode-0700 identity-checked run root,
connects once, and donates that already-connected client as FD 3 to native
KOReader. KOReader receives neither the pathname nor a listener. The pathname
must be checked against the Unix `sockaddr_un` length limit before QEMU starts.

Inside the guest, the trusted service opens only:

```text
/dev/virtio-ports/org.wilkbook.book-interaction
```

It must require the guest's `udev` service, wait for the path only within the
guest whole-run bound, resolve the udev link, require a character-device
target, set `O_NONBLOCK` and `FD_CLOEXEC`, and read the effective flags back.
It must not fall back to a guessed `/dev/vportNpM` number.

### Why this is available without a kernel build

Read-only inspection of the exact installed kernel `.config`, SHA-256
`0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309`,
found all of these built in:

```text
CONFIG_USER_NS=y
CONFIG_UNIX=y
CONFIG_PCI_HOST_GENERIC=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_CONSOLE=y
```

The accepted successor system's requisite roster already contains
`/gnu/store/1vmx...-eudev-3.2.14`. Its
`lib/udev/rules.d/50-udev-default.rules`, SHA-256
`d24e847307991e0d48febb57ac95ab2878dd65af9a546d07c4793742b81ba21b`,
contains the standard named-port rule:

```text
SUBSYSTEM=="virtio-ports", KERNEL=="vport*", ATTR{name}=="?*", SYMLINK+="virtio-ports/$attr{name}"
```

The first implementation still has to prove the node appears in the actual
successor guest. The static facts justify that test; they do not substitute
for it.

### Why not an inherited QEMU pipe

Do not weaken `disposable-qemu.scm`'s existing descriptor rule. Its exec path
deliberately marks every descriptor above stderr close-on-exec because the
accepted outer has no protocol donation. Adding an exception would enlarge a
reviewed lifetime boundary and require proving QEMU's inherited-fd ownership
in addition to the UI seam. A private socket chardev keeps that rule intact.

Also reject these alternatives for this gate:

- **serial console protocol:** the console remains one-way bounded diagnostic
  evidence and the final status channel, never an input or Book/UI protocol;
- **TCP, host forwarding, tap, or a QEMU NIC:** unnecessary and contrary to
  the accepted `-nic none` shape;
- **9p, `-virtfs`, `-fsdev`, or another host share:** a much larger pathname
  capability than the one byte stream requires;
- **a host Unix-socket pathname inside either OCI root:** forbidden; the book
  receives a donated connected endpoint, not a name it can reopen;
- **the existing KOReader ZeroMQ/TCP helper:** its transport and blocking
  properties do not match this private seam; and
- **KOReader inside ARM QEMU:** it would add the large ARM64 reader/runtime
  closure and a second offscreen/display problem without improving this seam's
  visible native-widget evidence.

## Authority and ownership

The ownership split must remain explicit:

| Component | Owns | Must not own or decide |
|---|---|---|
| Outer Guile runner and its guardians | private run root, bounded host lifetime, coordinator process group, final joined verdict | Book Protocol semantics or a book result |
| Fixed trusted host coordinator | exact QEMU and KOReader child identities, connection of the private Unix socket, child reaping | language choice, action IDs, nonces, or result acceptance |
| Native trusted Lua bridge | registered KOReader action, one dialog, UI source, connected FD 3, paint and teardown acknowledgements | Book Session endpoint, runsc, an OCI path, or book identity |
| Guest trusted Guile authority | UI-control state machine, language order, nonce inputs, Book Session host/endpoints, result commit, runsc groups and runtime cleanup | rendering or a claim that a console marker is a result |
| QEMU virtio serial | byte-stream carriage between its host chardev and named guest port | framing or semantic acceptance |
| Sandboxed Guile/Python book | its selected immutable entrypoint and its own donated Book Protocol FD 3 | UI channel/device, host socket path, sibling endpoint, console, or authority identity |

The host coordinator is a **lifetime owner**, not a second session authority.
The guest Guile process is the only component allowed to turn a UI submit into
`host-action!`, commit `<presented-text>`, navigate, revoke, cancel, or close a
Book Session.

The guest UI descriptor must remain `FD_CLOEXEC`. The existing runsc child
path still closes every unrelated descriptor and asserts FDs 0–3 only, with
FD 3 the selected Unix stream Book Session peer. Add an identity assertion
that the UI character device is absent at runsc exec. Do not add the device to
an OCI mount. Thus `--host-uds=none`, `--network=none`,
`--character-device-policy=emulated-only`, `--directfs=false`, strict
sidecars, and `--pass-fd=3:3` remain unchanged.

## Keep one fixed interaction

The first gate needs one registered KOReader action and one active dialog, not
a generic multi-session broker. Use one private-control generation (`1`) and
the existing three-field lowercase-hex/UTF-8 framing. No JSON crosses the
virtio port.

The existing direction allowlists are sufficient. The QEMU mode needs only:

```text
guest authority -> Lua: input-update, present, finish
Lua -> guest authority: ready, submit, tick, applied, done
```

Leave the existing `input-navigation`, `input-close`, `stale-navigation`, and
`closed` kinds in place for the accepted native fixture. Do not add a language,
PID, claimed identity, socket path, surface handle, or arbitrary method name to
private control.

The fixed sequence should be:

1. On real `ReaderReady`, the plugin registers exactly one action through
   `ReaderHighlight:addToHighlightDialog()`. Fixture automation obtains the
   registered button factory and invokes its real callback on `nextTick`.
   This proves the registered KOReader action callback, not a synthetic touch,
   selection gesture, or highlight-menu layout.
2. The callback shows one actual editable `InputDialog`. Only after the exact
   dialog is topmost does Lua send `ready(1, "dialog")`.
3. Guest Guile starts the fixed Guile runsc book and completes
   `hello -> initialize`. It chooses both strong nonce-bearing action texts.
   For each action it sends `input-update`, requires Lua's `submit` to echo the
   exact text, calls `host-action!`, and queues only that returned Book Protocol
   `action` to the book.
4. The book's `present` must first commit through the accepted Book Session
   pump and match the authority's action ID, request, sequence, surface,
   generation, and independently computed nonce-dependent value. Only then
   does Guile relay the committed value unchanged as private `present`.
5. Lua sets the real dialog text, dirties it, and sends `applied` only after the
   retained observer has called the inherited packaged `paintTo` and observed
   that exact text with this dialog topmost. Before applying a result, retain
   the accepted scheduled UI-task check and require its `tick`; this is a UI
   responsiveness observation, not a request timer or lease.
6. Repeat steps 3–5 for the Guile book's second nonce action. Then require book
   EOF, endpoint release, exact runsc group reap, capture drain, cgroup
   absence, `null-netns` cleanup, state-root removal, and diagnostic-store
   unmount before selecting Python.
7. Repeat steps 3–6 for the exact Python book and its two nonce actions, using
   the same dialog and private generation. Lua does not select or announce the
   language. The guest's fixed order and currently owned endpoint bind routing.
8. Only after Python cleanup may Guile send `finish`. Lua sends `done`, closes
   the exact dialog, removes and stops the source, closes FD 3, removes the
   registered action through `removeFromHighlightDialog()`, verifies no stale
   callback, and exits KOReader zero. Guest Guile requires `done` followed by
   control EOF and no active book owner before emitting its final pass and
   halting.

This retains all four already proven nonce computations while adding no new
book behavior. A result cannot be accepted merely because Lua names a language
or prints a marker: language, request, and endpoint selection are guest-owned,
and final success is after both trusted-side state machines and cleanup.

## Loss and teardown

Normal teardown and loss teardown are different transitions.

### Normal completion

Each book endpoint is released after its second committed result and before
the next book starts. After the final `done`/EOF handshake, the guest has no
live endpoint or runsc group. The coordinator must reap both native KOReader
and QEMU at status zero before logs are assessed. The run-root guardian then
performs its existing identity-checked removal.

### Host UI or channel loss while work is pending

An unexpected KOReader exit, document close, source failure, socket EOF, or
virtio-port hangup is an owner-loss event, not a successful close and not a
cancel request. Guest Guile must:

1. invalidate the private UI channel and discard its bounded output queue;
2. call `revoke-surface!` on the currently owned Book Session endpoint;
3. release the endpoint and donation;
4. TERM, then KILL if necessary, and reap the exact owned runsc group using the
   existing bounded three-second graces;
5. perform the same identity-checked cgroup, runtime-state, capture, and
   diagnostic-store cleanup; and
6. emit failure and halt, never a language or overall pass.

The guest's existing 360-second monotonic whole-run deadline covers UI waits,
both books, and guest cleanup. Retain the existing 600-second outer QEMU
deadline and five-second host TERM/KILL grace. Boot and connection setup are
therefore host-bounded even before the guest service begins. The outer process
guardian remains the final fallback if the guest never observes the chardev
disconnect.

For reader mode, make one fixed coordinator the direct process under the
existing outer process guardian. Its QEMU and KOReader children must remain in
that guardian's process group; do **not** reuse `integration-host.scm`'s
per-child `setpgid` split. The guardian is already a child subreaper and can
TERM/KILL/reap resistant descendants on owner loss. The coordinator still
records and normally reaps the exact direct child PIDs plus Linux start times.
This preserves both process and run-root guardians rather than layering an
unowned KOReader sibling beside the accepted QEMU runner.

Actual virtio disconnect-to-guest-EOF behavior must be demonstrated before it
is claimed. A positive run plus host-only teardown models may establish the
requested visible success path, but not that cross-boundary failure path.

## Navigation, close, cancellation, and timers

Do not expand the first QEMU success gate to repeat the accepted native
`update -> present -> navigation -> close` choreography. That would require
changing the fixed nonce books or adding another sandbox fixture merely to
re-prove behavior already covered by `book-interaction`.

Preserve these distinctions in code and claims:

| Event | Authority operation | Meaning |
|---|---|---|
| Reader navigation | `navigate!` | increment surface generation and retire all pending requests as navigation-stale |
| Unexpected UI/channel loss | `revoke-surface!` | revoke the active surface, then tear down its owned runtime |
| Orderly session end | `close-session!` / `release-session-endpoint!` | close and unregister after the fixed interaction |
| Explicit user cancel | `cancel-request!` for one authority-owned request ID | not navigation, close, or owner loss |
| External deadline decision | `expire-request!` for one captured request ID | no timer implementation exists in this gate |

The accepted native interaction gate remains the evidence for real UI
navigation/close invalidation and for a live UI task during a delayed reply. It
explicitly did not integrate cancellation. The accepted Book Session core
remains the only cancellation evidence. This successor may claim neither
integrated cancel nor automatic request expiry, timer identity capture,
ongoing leases, durability, or recovery.

## Minimal file-level implementation plan

### Native reader side

- `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/main.lua`
  — add an explicitly selected QEMU-success mode. Keep the accepted native
  mode unchanged. In QEMU mode, register/remove one public selection action,
  invoke its registered callback as fixture automation, retain one dialog for
  four submitted/presented values, and remove the independent expected-result
  environment oracle. It must remain language-agnostic.
- `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/ui_audit.lua`
  — extend the retained-reference audit with exact public highlight add/remove
  counts and registry presence/absence, following the already accepted
  `book-reader/public_seam_probe.lua` pattern. Preserve inherited `paintTo`,
  topmost, dialog/source/channel/FD, and stale-callback checks.
- `pinenote/tools/book-interaction/fixture/bookinteractionprobe.koplugin/private_channel.lua`
  and `pinenote/tools/book-interaction/private-control.scm` — no schema or
  bound change is needed. Reuse their exact nonblocking pumps and framing.
- Add one narrowly named host coordinator under
  `pinenote/tools/book-interaction/` for the QEMU gate. It owns connection and
  child lifetimes, not semantics. Do not turn `integration-host.scm` into a
  generic launcher or disturb its accepted native path.

### Guest authority and system

- `pinenote/tools/book-execution-spike/guest-book-protocol.scm` — add one fixed
  reader-driven entry path alongside, not in place of, the accepted automatic
  protocol pair. It uses the same nonce action specifications, session
  functions, runsc ownership, diagnostics, and cleanup, but advances each
  action only after the private UI `submit` and waits for `tick` plus `applied`.
- Add one small trusted Guile character-device adapter beside that file. It
  reuses `(private-control)` for encoding/decoding and supplies bounded
  nonblocking `read(2)`/`write(2)` queues for the named virtio port. It is not a
  book-visible module or a generic IPC framework.
- Add a successor system file inheriting
  `pinenote-book-execution-protocol-control.scm`. Replace only the one-shot
  guest service/entrypoint, require `udev`, and add immutable trusted copies of
  the private-control codec and guest adapter. Do not mutate the accepted
  protocol-control system in place.
- `pinenote/tools/book-execution-spike/oci-book-bundle.scm`,
  `guest-protocol-book.scm`, and `guest_protocol_book.py` — leave unchanged.

### Outer runner and checks

- Add a reader-specific entry path to the existing disposable-QEMU ownership
  implementation so the guarded direct child is the fixed coordinator. Keep
  the existing non-reader `disposable-qemu-main`, QEMU argv, descriptor rule,
  checker hook, and launcher behavior unchanged. Do not copy the 1,300-line
  guardian into a divergent runner and do not add a general callback/plugin
  framework to it.
- Extend the QEMU graph checker to permit exactly the three device arguments
  above and continue forbidding every NIC/share/monitor alternative.
- Add a joined checker that requires both the native KOReader lifecycle/paint
  evidence and the guest semantic/cleanup chain. Console remains only the
  latter's bounded diagnostic/status evidence.
- Put any actual QEMU launch behind a new, one-use, hash-bound authorization.
  The current accepted image and its already consumed authorization are not a
  mutable development runner.

## Closure delta

The intended guest delta is only immutable trusted Scheme/Lua-adjacent control
sources, a service gexp, and its system/image references:

- kernel and initrd: unchanged;
- accepted unpatched CONTROL runtime: unchanged;
- gVisor source-package outputs: remain separately accepted artifacts and do
  **not** replace CONTROL in this runtime;
- sandbox language profile/closure: unchanged at exactly 45 paths, SHA-256
  `48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc`;
- trusted supervisor package profile: unchanged (Guile, guile-json,
  guile-gcrypt); the control adapter uses Guile core facilities;
- fixed Guile/Python books and OCI roots: unchanged;
- no KOReader, SDL, Python authority, network utility, `socat`, ZeroMQ, Guix
  daemon, host share, or durable-state package in the guest.

If the computed successor diff contains a new package rather than only the
expected local source/service/system objects, stop and explain it before any
image or QEMU run.

## Critical review oracles

Run cheap gates first in isolated `/tmp/opencode` copies.

1. **Kernel/system static:** bind the exact `.config`; require the symbols
   above, the selected eudev rule, one named-port service dependency, unchanged
   kernel/initrd/CONTROL identities, and the exact 45-path language closure.
2. **QEMU graph:** require one and only one `bookui0`, controller, and port;
   private run-root socket path; no UI chardev log; unchanged CPU/TCG/NIC/share
   controls. Mutations dropping or duplicating any device, changing the port
   name, adding TCP/9p, or reusing the console must fail.
3. **Guest adapter host test:** on disposable pipes/PTYs or sockets, prove
   fragmented/coalesced frames, partial writes, `EINTR`, `EAGAIN`, EOF,
   malformed hex/UTF-8/generation/kind, 4,096-byte value and queue bounds, and
   bounded work per pump. Guile remains the test authority; Python may only be
   reviewer-side tooling.
4. **FD separation:** mutate runsc exec to retain the UI character descriptor,
   donate it as book FD 3, or give KOReader the book peer; each must fail before
   book code or paint success. The positive requires book FDs 0–3 only and
   KOReader stdio plus its distinct control FD 3 only.
5. **Routing:** require fixed Guile then Python ownership and all four fresh
   nonce actions. Cross an endpoint, swap language order, accept a Lua language
   label, relay before Book Session commit, or hardcode one presentation; each
   must fail. The Unicode and fresh nonce cases remain essential.
6. **Real reader:** against package-pinned v2026.03, independently retain the
   inherited packaged `InputDialog.paintTo`, require each exact committed value
   to be topmost after that method returns, and require the scheduled UI task
   while work is pending. No marker alone satisfies this oracle.
7. **Reader teardown:** separately omit dialog close, source removal, channel
   stop/FD close, action removal, and stale-poll suppression. Each must expose
   the retained live state before `UIManager:quit`, as in the accepted gate.
8. **Guest teardown:** omit revoke/release, runsc TERM/KILL/reap, cgroup check,
   `null-netns` cleanup, or diagnostic-store unmount. No language/final pass may
   precede these checks.
9. **Host ownership:** fake QEMU and KOReader children must prove normal reap,
   early exit in either direction, timeout, coordinator signal, and outer-owner
   SIGKILL. Exact PID/start-time records and the existing process/root guardians
   must leave no matching process or private socket tree.
10. **One actual positive:** only after 1–9 pass and an independent source/image
    review, authorize one QEMU invocation. Acceptance requires the four guest
    Book Session commits, four real native topmost paints, both language cleanup
    chains, KOReader action/source/dialog/channel cleanup, clean guest powerdown,
    and outer status zero.

A separate actual-QEMU KOReader-loss injection is required before claiming that
virtio disconnect itself propagates promptly through guest revoke and runsc
cleanup. It is not required merely to establish the positive visible-computed-
result seam, provided that narrower scope is stated.

## Maximum justified claim after that gate

If the exact candidate passes independent review and its separately authorized
run, the claim is:

> One action registered through pinned native KOReader v2026.03 opened a real
> topmost offscreen `InputDialog`; one trusted Guile authority in an actual
> PineNote-7.1.8 ARM64 QEMU guest routed four fresh nonce-dependent actions over
> authority-owned Book Session endpoints to the fixed Guile and Python books
> running under the accepted gVisor/Systrap policy, then relayed and visibly
> painted each committed computed result before bounded cleanup.

It is not a hostile-book isolation qualification, production broker, shipping
plugin, ARM64 KOReader result, touch/menu-layout test, pixel or optical proof,
physical-display result, durability/recovery result, ongoing-lease or timer
result, actual disconnect-cleanup result, power result, or hardware acceptance.

## Read-only design basis

The principal exact inputs inspected for this recommendation were:

| Input | SHA-256 |
|---|---|
| `book-interaction/.../main.lua` | `eb15a63999f7c4821d8b8c187fc80fb938ba175ff93430c6721c66d090d29daf` |
| `book-interaction/.../private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| `book-interaction/.../ui_audit.lua` | `ebcfcb14c1f5151b4d23bc820fb16b42db74cd1bf3fa1783cd0c29ebc6d4b7a3` |
| `book-interaction/private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `book-interaction/integration-host.scm` | `72e044abd38b33df81a2eeda9e2316f75479f0943b435cb1c72d25a426f22e0d` |
| `guest-book-protocol.scm` | `eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d` |
| `oci-book-bundle.scm` | `c5f737301a113c4fb35df568b6ac59cb6b0369bb3bfa66b830f3eba1760743d7` |
| `disposable-qemu.scm` | `0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca` |
| fixed Guile book | `9d18f28a3a2fdacb8b84ee5f3b9b454cb74e28a53661f0ffd61b8a2427bfcc6a` |
| fixed Python book | `b862ec83cbe93538e6e8a285df66f1438b3125adf2431a107f9810d771a830e0` |
| protocol-control system | `81276943c553efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047` |
| installed kernel `.config` | `0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309` |

The accepted core remains the previously reviewed Book Session and Book
Protocol codecs. Packaged KOReader and QEMU documentation were used only as
read-only oracles. No conclusion here changes the accepted native reader gate,
the accepted native book-interaction gate, or the exact runtime attribution in
`2026-09-06-book-protocol-successor-image-adversarial.md`.
