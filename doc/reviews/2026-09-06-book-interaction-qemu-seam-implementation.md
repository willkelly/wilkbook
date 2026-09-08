# Book interaction QEMU seam implementation record — 2026-09-06

## Disposition

The host/native-reader half of the seam designed in
`2026-09-06-book-interaction-qemu-seam-design.md` is implemented as a candidate
for independent review.

The host-only gate passes against the package-pinned KOReader v2026.03 runtime:
one action registered through the public `ReaderHighlight` seam invokes its
real callback on `nextTick`, one editable `InputDialog` remains in use across
four nonce-bearing exchanges, and each result is acknowledged only after the
retained inherited `paintTo` has returned with that exact text and the same
dialog topmost. The retained cleanup audit covers the dialog, async source,
channel/FD, stale callback, and public action removal.

The previously accepted native Guile/Python Latin/Unicode fixture and its
navigation/close choreography also pass after these changes. The private
control codec and Lua channel are byte-for-byte unchanged.

This is **implementer evidence, not an independent acceptance and not the final
joined QEMU gate**. No actual QEMU, ARM code, guest image, runsc, kernel, Bazel,
device, SSH, UART, network, commit, or push was used for this record. The QEMU
position in the new test is a trusted host Guile Unix-socket mock. In
particular, this record makes no named-virtio-port, actual-disconnect,
guest-revoke/runsc-cleanup, touch, navigation/cancel, physical-display, or
shipping claim.

## Exact handoff contract

The caller-facing contract is:

`pinenote/tools/book-interaction/qemu-coordinator-contract.md`

Its only named arguments are exactly one each of:

```text
--run-root ABSOLUTE_MODE_0700_ROOT
--socket ABSOLUTE_MODE_0700_ROOT/book-ui.sock
--koreader-package ABSOLUTE_KOREADER_2026_03_OUTPUT
--qemu ABSOLUTE_QEMU_SYSTEM_AARCH64
-- FIXED_QEMU_ARGUMENTS_WITHOUT_ARGV0
```

The fixed QEMU vector is the existing `virt`/TCG/no-NIC/no-monitor/no-defaults
shape with the private channel inserted after `console0` and before kernel:

```text
-chardev socket,id=bookui0,path=RUN_ROOT/book-ui.sock,server=on,wait=off
-device virtio-serial-pci,id=book-ui-serial
-device virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction
```

The outer remains authoritative for the exact append line, prepared image
paths, QEMU package identity, 600-second deadline, process-group guardian,
subreaping, run-root guardian, guest console checker, and final joined verdict.
The coordinator does not call `setpgid` and does not duplicate those guardians.

The coordinator:

- validates the unchanged run-root identity, ownership, 0700 mode, exact
  socket location, non-collision, QEMU argument vector, and Linux
  `sockaddr_un` length before QEMU exec;
- preserves the reviewed rule that every QEMU descriptor above stderr is
  `CLOEXEC` and makes only KOReader's already-connected FD 3 non-`CLOEXEC`;
- waits at most 30 monotonic seconds for socket publication, stats it, performs
  one connect, rechecks its identity, donates the peer, and closes its copy;
- records the two direct child PIDs plus Linux start times before releasing
  either child through a CLOEXEC launch gate;
- gives KOReader no socket path, book/language/nonce/result oracle, Book
  Protocol endpoint, or arbitrary command option;
- bounds the reader log at 128 KiB with `RLIMIT_FSIZE` and QEMU stdout/stderr
  at 4 MiB each through pipes, without applying a file-size limit to the QEMU
  disk overlay;
- requires both children to exit zero plus the fixed reader lifecycle and exec
  descriptor evidence; and
- on signal, nonzero/early exit, or failed validation, signals the whole exact
  direct-child set together, then uses one shared five-second TERM grace and
  one shared five-second KILL/reap grace. Descendants remain in the existing
  outer-owned process group.

It contains no language selector, action/nonce/result calculation, private
control parser, Book Protocol parser, TCP transport, host share, or shell/helper
option.

## Source changes

### Native fixture

- `fixture/bookinteractionprobe.koplugin/main.lua` adds only an explicitly
  selected `BOOK_INTERACTION_QEMU_MODE=1` path. It rejects host input/result
  oracle variables in that mode, retains generation 1 and the existing frame
  kinds, registers/removes one public action, invokes the registered factory's
  callback, and uses one dialog for four exchanges. A scheduled pending tick is
  required before every presentation. Repeated dirty requests are bounded to a
  one-second offscreen observation window, and `applied` is impossible until an
  actual exact topmost paint has been observed.
- `fixture/bookinteractionprobe.koplugin/ui_audit.lua` retains the exact action
  key/factory and wraps the public add/remove methods. Final cleanup requires
  add count 1, remove count 1, and registry absence in addition to all prior
  dialog/source/channel/FD/stale-callback checks.
- `private-control.scm` and `private_channel.lua` were not changed. QEMU mode
  uses only authority-to-Lua `input-update`, `present`, `finish` and Lua-to-
  authority `ready`, `submit`, `tick`, `applied`, `done`.

### Host lifetime coordinator and checks

- `qemu-coordinator.scm` is the fixed lifetime-only coordinator described
  above.
- `test-qemu-mode-guest.scm` is a host-only trusted Guile mock of the guest UI
  authority. It is not a Book Session substitute or production authority.
- `run-qemu-mode-tests.sh` joins the mock to real package-pinned KOReader and
  supplies Python only as an independent reviewer-side paint oracle.
- `qemu-coordinator-contract.md` freezes the early integration boundary for the
  guest/outer implementer.
- `README.md` and `Makefile` document/expose the separate
  `qemu-mode-check`; the accepted native `check` remains separate.

## Host-only evidence

Final private evidence root (mode 0700):

```text
/tmp/opencode/bi-final.Ryzk3B
```

Bounded transcripts:

| Evidence | SHA-256 |
|---|---|
| `qemu-host-gate.log` | `b9bb4d930eefce1b0353cb3c10ebf4065dc98564649fa258cf0c50ed5724e2e9` |
| `native-regression.log` | `ff1a688abfe1c2fc3fa9707aef7b64577a67018879017441a3a409356570b5dd` |

The QEMU-mode artifact tree is:

```text
/tmp/opencode/bi-final.Ryzk3B/book-interaction-qemu-host.0CcKwL
```

Its positive evidence includes:

| Evidence | SHA-256 |
|---|---|
| `positive/coordinator.log` | `d389cf6c983eb071374ad49a863285a3d5817e001d918c988511f512aad4f8a4` |
| `positive/reader-ui/reader.log` | `0b54a5326612dd6d827ca2feb185b9c6617e8aa71b92650165f4fe4672233329` |
| `positive/reader-ui/qemu.stdout` | `fe1bf85f980f1eccc0ccd094cfab2cac34881adc00554f939c209118f187298c` |
| `positive/reader-ui/qemu.stderr` (empty) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

The exact four retained topmost paint observations were:

```text
GUILE[28]:ADA|NONCE=G-AB3DE5FG7HJ9KL2M
GUILE[31]:ÉLAN Λ|NONCE=G-N4PQ6RS8TV0XY2ZA
PYTHON[30]:q2Nm0Kj8Hg6Fe4Cb-p=ecnon|ecarG
PYTHON[27]:Ed3Ba1Zy9Xw7Ut5R-p=ecnon|京東
```

All evidence files named above are mode 0600. No PID/start-time identity
recorded anywhere in the final artifact tree still matched a process after the
gate.

The host-only gate passed all of these independent controls:

1. exact package-source hashes for KOReader v2026.03;
2. four distinct Guile-mock-computed, Python-oracle-checked nonce/Unicode
   topmost paints in one real dialog;
3. wrong private generation, wrong state routing, malformed framing, and early
   EOF rejected by actual KOReader;
4. existing Lua channel nonblocking read and never-read-peer backpressure;
5. constant authority relay rejected by the joined semantic oracle despite
   satisfying the deliberately semantic-free coordinator lifecycle check;
6. hardcoded Lua paint unable to produce `applied` for the authority value;
7. omitted public action removal exposed by the retained registry audit before
   UIManager quit;
8. nonzero QEMU after valid reader cleanup and QEMU exit before socket both
   rejected;
9. socket collision, socket path outside the run root, overlong Unix path, and
   QEMU graph drift rejected before QEMU exec;
10. reader command line/environment lacked the socket path and result oracle,
    reader FD 3 was a connected socket capability, and the coordinator retained
    no socket after donation;
11. coordinator/QEMU/KOReader shared one pre-existing dedicated process group;
12. coordinator signal reaped real KOReader and a TERM-resistant fake QEMU; and
13. modeled outer-owner SIGKILL followed by exact group TERM/KILL left no
    recorded child alive.

Separately, the unchanged native gate passed its private-channel unit,
owner-loss/identity-recorder controls, pending modal mutation, three cleanup
omissions, hardcoded relay mutation, and Guile/Python × Latin/Unicode real
KOReader matrix.

## Current source identities

| Source | SHA-256 |
|---|---|
| `fixture/bookinteractionprobe.koplugin/main.lua` | `8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125` |
| `fixture/bookinteractionprobe.koplugin/ui_audit.lua` | `cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a` |
| unchanged `fixture/bookinteractionprobe.koplugin/private_channel.lua` | `4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832` |
| unchanged `private-control.scm` | `1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d` |
| `qemu-coordinator.scm` | `dc7bb40005ff2e2105cc5e34005851190cc693c5870a12462ef823913147ba7d` |
| `qemu-coordinator-contract.md` | `94bbb0226d9975bd5c5d0066becfe2545d1b717634d6a106e7076e55c142091d` |
| `test-qemu-mode-guest.scm` | `90098c62a7f7559a6907b8fbce2f1dcbf46162761565678f4ca9deaf65d408c1` |
| `run-qemu-mode-tests.sh` | `3b3322adc629a353df0adb6d6d7690004cc66d0e5e9ccf981b95264891b14cab` |
| `README.md` | `9cd3c9d6c55dbc17145400b5c454cb793cd1662506ea6eb19ff566b268f87b11` |
| `Makefile` | `14195c0100c7e1c2ff3ac964359cc4265463bf22f293d6fe8f4029994a8da5a5` |

Pinned packaged KOReader identities checked by the new gate remain:

| Packaged input | SHA-256 |
|---|---|
| `git-rev` | `846aed94948bfa1c155325770bf4df8673850a14395ec585c3d594c859d5b2d5` |
| `reader.lua` | `a189ca83623153f2a1b048c7bc04eba1fca76068bd9705dc71296d26292613cc` |
| `frontend/ui/uimanager.lua` | `f74b56b1885647770da9596e753990dd065032b6f85777260c841c19b1999464` |
| `frontend/ui/widget/inputdialog.lua` | `a03bdd3827a3108d313a19407c7e2db6176e20c3066595356f4c86e3a50930b4` |
| `frontend/ui/widget/inputtext.lua` | `1431c5cb7f5e42c5494c9f7ebc570d74627c9299e6d00f9c54762b4abded0f66` |
| `frontend/apps/reader/modules/readerhighlight.lua` | `1f6bde433c349ef8e07f2ca8f2d24b209127ca9d1a80e1a89b710a27d403e711` |

## Review notes

The host gate caught and prevented two implementation mistakes during this
work:

- a continuation initially used to leave the socket retry loop crossed the
  coordinator's outer `dynamic-wind` and invoked child cleanup immediately
  after connect; it was removed in favor of an ordinary tail-recursive return;
  and
- SDL/offscreen can coalesce a dirty request with the preceding dialog edit;
  the fixture now retries dirtying the same retained widget within a finite
  one-second window but still refuses `applied` until inherited `paintTo`
  actually observes the exact text topmost.

These fixes are included in the source hashes above. The next valid step is a
focused independent source review joined with the guest/outer implementer's
candidate. Only after that review should the parent consider the separately
authorized one-use actual QEMU gate described by the design report.
