# Book State on the PineNote (experimental device flavor)

This is the first human-driven device integration of the strict two-boot Book
State result. It is deliberately **not** the default reader. The entrypoint is:

```text
pinenote/systems/pinenote-book-state-device-reader.scm
```

It inherits `pinenote-reader-operating-system`, including the real direct-mode
EBC/waveform/VCOM path, native KOReader, orientation, frontlight, platform
controls, suspend, `/data`, Wi-Fi, SSH and generation update path. It changes
only what the experiment needs: the already-realized USER_NS kernel, the
source-built gVisor runtime, cgroup2, a KOReader package containing one dormant
plugin, and two Book State services. It has no QEMU devices, synthetic state
volume, scripted A/B values, automatic shutdown, or test UI driver.

## Offline gates and build

Run from the repository root. These commands do not contact the PineNote:

```sh
pinenote/tools/book-state-device/run-tests.sh

guix repl -L . pinenote/tools/book-state-device/derive-system.scm

system_drv=$(guix repl -L . \
  pinenote/tools/book-state-device/derive-system.scm \
  | sed -n 's/^SYSTEM-DERIVATION //p')
system=$(guix build --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
  "$system_drv" | tail -n 1)
pinenote/tools/book-state-device/check-system-closure.sh "$system"
```

The derivation gate refuses unless lowering resolves exactly:

- kernel: `/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote`
- gVisor: `/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`

The full build writes only to the Guix store. It does not build an image and
does not deploy anything. The derivation-first form also avoids Guix recursively
treating retained `.scm` evidence programs below tool artifact directories as
channel modules; the deployment helper uses this same pin-gated path for this
flavor only.

## Explicit activation on an installed experimental generation

Installing or booting this flavor is not activation. With no marker:

- the plugin returns `disabled = true` before registering a menu item;
- the authority exits without opening SQLite or a socket;
- the ordinary reader remains the whole user experience.

After an attended trial has booted this flavor and the operator has confirmed
the expected generation, opt in from the root console:

```sh
printf 'enabled\n' > /data/wilkbook/book-state/enabled
chmod 0600 /data/wilkbook/book-state/enabled
herd enable pinenote-book-state-device
herd start pinenote-book-state-device
herd restart reader-session
```

The explicit `herd enable` is needed when the unactivated service has already
exited and Shepherd disabled it (observed on generation 20). The service accepts
the marker only when it is a root-owned, single-link,
mode-0600 regular file with exactly that content. Restarting KOReader is needed
because disabled plugins are discovered at process startup. Then open
**More tools → Persistent note (experimental)**. The menu names one compile-fixed
Guile BookInstance; neither UI nor book can choose another namespace, program,
socket, mount, or host descriptor.

Type ordinary text, press the real `InputDialog` Save button, close the dialog,
and reopen it. Repeat after restarting `reader-session` to exercise
durability. The root-owned database is:

```text
/data/wilkbook/book-state/book-state-v1.sqlite
```

Its directory is mode 0700 and SQLite files are mode 0600. A book receives only
its connected Book Session socket at FD 3. gVisor remains fixed to systrap,
`directfs=false`, `network=none`, and `host-uds=none`; the separate UI Unix
socket is accepted only from the exact root KOReader LuaJIT process and is
never donated to the book.

## Stop, disable, and rollback

Close the dialog first when possible, then:

```sh
herd stop pinenote-book-state-device
rm /data/wilkbook/book-state/enabled
herd restart reader-session
```

The 12-second service stop window allows endpoint release, state-worker join,
the verified bounded natural runsc exit, and SQLite close. A KOReader restart
or dialog close invalidates that connection and its Book Session generation;
the next open receives a fresh endpoint. The idle authority blocks in
`accept(2)` and has no timer or periodic poll. Suspend/wake with the experimental
feature still needs qualification; an active note session has a deadline.

To leave the experimental system, use the ordinary generation rollback flow in
`doc/hardware-deploy.md`; for an already-installed generation `N`, the exact
parent-operated command is:

```sh
WILKBOOK_UART=/dev/ttyUSB0 \
  pinenote/tools/deploy/deploy.sh pinenote-os2 --rollback N
```

Removing the marker disables use but intentionally does not delete the private
database. Do not delete it as part of rollback.

For the parent-operated attended generation trial (not for this agent):

```sh
WILKBOOK_UART=/dev/ttyUSB0 make deploy \
  DEVICE=pinenote-os2 FLAVOR=book-state-device-reader KEEP=5
```

That command performs SSH, kexec and promotion; it must be run only by the
authorized operator following the update-path runbook. The implementation and
offline build never invoke it.

## Prototype bounds

- Only the fixed Guile note is exposed in the menu. The fixed Python book and
  boundary probe are also wired through the authority's compile-fixed Python
  OCI runner, but the deployed service selects Guile and accepts no language
  selector from argv, environment, UI, or a book. Focused native tests execute
  both fixed runners through FD 3 and generate both OCI bundles; the accepted
  QEMU campaign remains the ARM64/gVisor proof. A second device menu is deferred.
- The current-channel device language profile has a separately pinned 46-path
  closure. The immutable QEMU evidence keeps its original 45-path/134-input
  capsule unchanged; this integration does not re-pin or reinterpret it.
- Schema v1 allows at most 64 state versions/receipts for this namespace. On
  exhaustion the UI reports a failed save and retains the draft. There is no
  pruning or retention redesign in this step.
- One active UI connection and one sandbox are allowed. An interaction has the
  inherited 300-second cooperative bound; the authority otherwise sleeps in a
  blocking accept and does no background work.
- Human saves and recovery after restarting both services passed on wkelly's
  PineNote, generation 20 with temporary source overrides, on 2026-09-08.
  Canonical sources include those fixes and real KOReader widget regressions.
  A clean-generation boot, suspend/wake qualification and release certification
  remain separate gates; see `doc/status.md` for the exact evidence.

Generation-20 operators must remove the temporary note userpatch
`/root/.config/koreader/patches/2-wilkbook-book-state-dialog.lua` and its
`book-state-dialog-fix/` directory when moving to a fixed generation, so it
does not shadow that generation's plugin. The temporary authority override
under `/run/wilkbook-book-state-hotfix/` disappears on reboot. The font-path
patch `1-wilkbook-persistent-fonts.lua` is redundant in new builds because the
reader service now searches `/data/fonts` directly. Keep the actual font files
on `/data`; they are private persistent data.
