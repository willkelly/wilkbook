# PineNote platform controls v1 (archived Phase 1 acceptance record)

> This is the historical Phase 1 hardware-validation record. The temporary
> overlay, deployment bundle, and `pinenote/validation` source tree were
> retired when the accepted implementation moved into the production package
> and service layout. Commands and paths below are retained as evidence and
> are not current deployment instructions. Production sources now live under
> `pinenote/packages/platform-controls/`; their offline tests live under
> `pinenote/tools/platform-controls/`.

## Current status — 2026-08-31

Phase 1 hardware acceptance is complete. Phase 2 production integration is
also hardware-qualified. The packaged image was written, read-back verified,
cold-booted twice, exercised through the full acceptance matrix, powered off,
and cold-booted again without rollback or manual repair. The current milestone
is therefore **Phase 2 packaged platform controls accepted on hardware**, with
one non-reproducing transient display observation retained below.

Completed Phase 2 work:

- `pinenote-platform-controls` packages the accepted broker, protocol module,
  and Wi-Fi ownership helper in the Guix store and system profile.
- Shepherd starts the broker after `udev`, loads `uinput`, supplies store paths
  for the KOReader modules and Wi-Fi helper, logs to
  `/var/log/pinenote-platform-controls.log`, and respawns the broker if it
  exits.
- `reader-session` requires `pinenote-platform-controls` and waits for both
  `/run/wilkbook-power/ready` and the immutable-identity
  `wilkbook-power-control` input device before launching KOReader.
- Loss of that required input device is fatal to KOReader, allowing Shepherd
  to restart the reader after the broker recreates it.
- The packaged PineNote driver exposes the hardware-accepted acknowledged
  suspend path directly. It no longer consumes the early
  `WILKBOOK_PINENOTE_VALIDATION` gate.
- The packaged Wi-Fi path is
  `/run/current-system/profile/bin/pinenote-wifi-control`. The packaged image
  used that path throughout hardware acceptance; the source-level Phase 1
  path is only a dormant compatibility fallback.
- The reader flavor no longer instantiates the legacy
  `pinenote-autosuspend` service, preserving the broker as the sole
  `/sys/power/state` writer. KOReader owns idle timing and screen preparation.
- The suspend preflight now requires the production driver to expose the
  accepted broker path without importing the old hard-off policy. The dormant
  `suspend_policy.lua` remains pinned to `return false` for isolated legacy
  tests.

Completed verification:

```sh
make platform-controls-check HOST_TOOLCHAIN=1
make gexp-modules-check HOST_TOOLCHAIN=1
make suspend-check
make koreader-input-check HOST_TOOLCHAIN=1
make reader-system-drv TIME_MACHINE=1
```

The complete pinned reader image was built and its extracted root filesystem
passed the image-level Phase 2 inspection on 2026-08-31.  The artifact is
`/tmp/wilkbook/pinenote-rootfs-artifacts/pinenote-reader-PNGuixRoot-20260831.ext4`
(1,786,429,440 bytes), SHA-256
`21f6c8be5bc5b4434ae73d60320d64d7afb842854367f264062954d27943279b`.
The inspection resolves the baked Guix closure rather than the checkout: it
requires the packaged broker, protocol and Wi-Fi helper, the respawning
platform-controls Shepherd service, reader-session's broker/device ordering,
the production KOReader driver hooks, and absence of the legacy autosuspend
service.  The artifact is under volatile `/tmp`; rebuild it if the host is
rebooted.

Deployment completed from stock Debian `os1`. The write preflight proved that
`/` was `/dev/mmcblk0p5`, `/dev/mmcblk0p6` was unmounted, and the staged rootfs
matched the expected hash. The complete 436140-block readback matched
`21f6c8be5bc5b4434ae73d60320d64d7afb842854367f264062954d27943279b`.
The raw disk-image intermediate was not written to the device.

The protocol, driver/frontlight, Wi-Fi ownership, broker lifecycle, manifest,
service-wiring, suspend mutation, and KOReader required-input suites passed.
The pinned system definition lowered successfully, and the complete pinned
image build realized the Phase 2 package and generated platform-controls and
reader-session Shepherd services. The supported `TIME_MACHINE=1` path passed.

Phase 2 acceptance completed all five planned items: deployment without the
early patch; broker-before-reader cold boot with singleton process/device/Wi-Fi
ownership; broker crash and reader recovery; the physical power, cover, menu
Sleep, AutoSuspend, charging-inhibit, Wi-Fi, frontlight, fallback, RTC and
Power Off matrix; and a final cold boot without rollback. The detailed device
record is in `doc/status.md` under 2026-08-31.

The first menu-Sleep resume briefly displayed garbled data before the full
refresh restored a clean screen. An immediate repeat and every other cycle
were visually clean, with no EBC error or timeout in the logs. This remains a
non-reproducing soak observation.

The retired validation directory was the reversible hardware implementation
used to establish the Phase 1 evidence. Before Phase 2 it did not alter
Shepherd or Guix image generation, and the packaged device stayed
suspend-disabled unless the early patch set `WILKBOOK_PINENOTE_VALIDATION`.
That patch is now historical: the production image packages and supervises the
accepted implementation. The durable checks now run through
`make platform-controls-check`.

The following deployment command is for the **Phase 1 validation overlay**, not
the Phase 2 production image. Deployment is explicit and separate from builds:

```sh
./deploy.sh root@PINENOTE
```

The deployer stages `/data/wilkbook/validation/platform-controls-v1`, verifies
its manifest, stops stock `pinenote-autosuspend`, installs the early patch,
starts the broker (FIFO and named uinput must be ready), and only then restarts
`reader-session`. It never edits the Guix store.

The protocol accepts exactly `ready REQUEST-ID`. Physical power taps and cover
close emit `KEY_SLEEP`; KOReader then checkpoints, paints its configured sleep
screen, disables Wi-Fi, and quarantines input through its ordinary suspend
path. A menu or AutoSuspend request reaches the same path directly. The broker
coalesces pending physical triggers, rejects duplicate IDs, waits ten seconds
for preparation, and uses the logged fallback sleep frame on timeout. It alone
writes `/sys/power/state`, surrounding that write with the EBC barrier, USB
gadget quiesce, RTC backstop, dual-channel light save/restore, sync, deep-mode
check, GC16 resume repair, and `KEY_WAKEUP`. KOReader remains the sole owner of
Wi-Fi restore policy: its `auto_restore_wifi` setting decides whether the radio
returns automatically after the Resume event.

`idle=` in either legacy config is logged once and ignored. `enabled=0` remains
a global inhibit. Charging remains an inhibit unless
`suspend_while_charging=1`. The broker checks these inhibits before notifying
KOReader, so a blocked physical or unattended request leaves the display and
reader state untouched. It checks again after acknowledgement in case power or
configuration changes during preparation. KOReader therefore owns the default
15-minute idle timeout and retains its upstream three-day automatic shutdown
default.

Rollback on the device is:

```sh
/data/wilkbook/validation/platform-controls-v1/bin/rollback-device.sh
```

It first writes a runtime inhibit, signals only a PID whose command line matches
this versioned broker, disables (renames) the early patch, starts stock
`pinenote-autosuspend`, and restarts `reader-session`. It preserves the bundle,
manifest, and logs. Phase 1 hardware acceptance, including the frontlight
toggle follow-up, was completed on 2026-08-31. The runtime-overlay reboot
caveat below remains true for this validation deployer; the Phase 2 service
eliminates it, as confirmed by the cold-boot acceptance listed above.

## Phase 1 hardware acceptance — 2026-08-31

The target was `pinenote-os2`, confirmed booted from `/dev/mmcblk0p6`, running
kernel 7.1.8 and KOReader v2026.03. The final deployed bundle was built from
source revision
`3497fdfdf35aca4a651b025f22f2459fc08ff8b8` with tracked-worktree digest
`48ab6d2f5557f4dd3ecb516b78fc6f73f8e0ee6d0bb12829f84cc4f4f6346749` at
`2026-08-31T05:52:04Z`. Its on-device manifest passed in full after the Power
Off cold-boot recovery and redeployment.

At final inspection the validation overlay and early patch were active, the
validated broker and reader were stable, stock `pinenote-autosuspend` was
stopped, exactly one adopted and validated supplicant was running, KOReader
AutoSuspend was persistently disabled, `no_off_screen` was `N`, and the RTC
wakealarm was empty. PIDs are observational only; use the validated launcher
status command for identity.

### Accepted matrix

- Physical power, cover close, KOReader menu Sleep, and KOReader AutoSuspend
  each entered deep suspend exactly once through the acknowledged path. The
  white-background requests were `1788152294-1`, `1788152416-2`,
  `1788153159-2`, and `1788153374-3`.
- A custom image with black fill passed the same four-trigger matrix as
  requests `1788154654-1`, `1788154685-2`, `1788154727-3`, and
  `1788154885-4`. Every sleep and resume screen was visually clean.
- Charging with `rk817-charger/online=1` rejected a physical tap before
  `KEY_SLEEP`; KOReader and the display did not change.
- With KOReader AutoSuspend disabled, the reader stayed awake for over eight
  minutes—beyond the stopped daemon's 300-second timeout—with no broker request.
- Nonzero cool and warm frontlight channels (`128/128`) restored exactly, and
  their reconstructed brightness and warmth survived a reader restart.
- Disabled and enabled `auto_restore_wifi` behavior passed. Three repeated
  manual off/on cycles left one supplicant with matching validated ownership.
- A missing acknowledgement used the fallback frame. A second tap was
  coalesced, the device suspended once, Wi-Fi returned, and banner cleanup left
  the display and RTC state clean.
- A 30-second backstop woke request `1788154225-1`; after the 20-second settle
  period, unattended request `1788154285-2` re-suspended exactly once. A button
  woke the second sleep and the alarm was cleared.
- Reversible EBC-busy injection made request `1788155160-1` abort before any PM
  suspend entry. KOReader recovered without a stale image or state leakage;
  the shim was removed and the normal manifest reverified.
- Power Off completed after correcting the Shepherd command. Its cold boot
  reproduced the documented runtime-only broker caveat; rollback and final
  redeployment restored a healthy validation activation.
- The broker remained the sole `/sys/power/state` writer. No tested path caused
  panel corruption, stale banners, immediate unintended re-suspend, duplicate
  supplicants, or retained RTC alarms.

### Integration issues fixed during Phase 1

- Existing stock `wpa_supplicant` is adopted only when exactly one process
  matches both `wlan0` and `/data/wifi/wlan0.conf`; ambiguous ownership is
  refused.
- The on-device rollback command is included in the checksummed bundle.
- KOReader's omitted `lj-wpaclient` module is no longer required; this target
  exposes the radio toggle without claiming AP-list manager support.
- Broker Sleep/Wakeup keys use event adapters so awake KOReader receives direct
  `Suspend`/`Resume` actions instead of ordinary keypress wrappers.
- The Wi-Fi helper uses absolute Guix paths for `rfkill` and
  `wpa_supplicant`, and failed helpers do not report successful callbacks.
- No platform override forces Wi-Fi back on; KOReader's `auto_restore_wifi`
  preference is authoritative.
- PineNote's validation suspend delay is three seconds, allowing KOReader to
  acknowledge before the broker's ten-second preparation deadline.
- The standalone broker prepends the staged overlay paths and can load the EBC
  barrier outside KOReader's Lua environment.
- Button-wake resume clears the still-armed RTC backstop.
- Frontlight state is reconstructed from both cool and warm PWM channels.
  KOReader's remembered restore intensity is kept separate from the level
  currently applied to hardware, so an off toggle does not replace the next
  on level with zero.
- Power Off invokes Shepherd's absolute `halt` command without the unsupported
  util-linux/systemd `-p` option.

The final offline gate passed:

```sh
make -C pinenote/validation/platform-controls-v1 check bundle-check
```

Logs retained on the device are `/var/log/pinenote-validation-broker.log`,
`/var/log/reader-session.log`, `/var/log/messages`, and the staged manifest.
Earlier failed attempts remain in those append-only logs; identify the passing
cycles with the request IDs in the accepted matrix. The intentional injected
EBC failure is also retained as request `1788155160-1`.

### Phase 1 overlay reboot caveat and resumption

The Phase 1 broker is runtime-only and is not supervised across reboot. The
early patch is persistent, so rebooting while validation is active starts
KOReader without its required virtual power device and causes a reader respawn
loop. Stock Wi-Fi still starts, permitting SSH recovery. Prefer running the
rollback command before any planned reboot.

To inspect an activation that has not rebooted:

```sh
ssh pinenote-os2 \
  /data/wilkbook/validation/platform-controls-v1/bin/platform-controls status
ssh pinenote-os2 'herd status reader-session; herd status pinenote-autosuspend'
```

After a reboot, or whenever activation state is uncertain, normalize to stock
and then redeploy from this checkout:

```sh
ssh pinenote-os2 \
  /data/wilkbook/validation/platform-controls-v1/bin/rollback-device.sh
./pinenote/validation/platform-controls-v1/deploy.sh pinenote-os2
```

### Frontlight toggle follow-up

The post-acceptance defect was that the first toggle turned the frontlight off,
but also replaced KOReader's remembered nonzero intensity with zero. KOReader
then rejected every on toggle as unchanged. The driver now tracks applied
hardware intensity separately, and the offline regression test proves an
off/on cycle preserves and restores the prior mixed-channel level.

The rebuilt bundle and manifest passed on `pinenote-os2`, and KOReader loaded
the updated validation overlay. Four consecutive menu-toggle cycles alternated
the expected `Frontlight disabled.` and `Frontlight enabled.` notifications.
Remote observation showed both PWM channels returning exactly from `0/0` to
their prior `92/92` level each time. The reader and broker remained healthy.

Phase 1 hardware validation is explicitly confirmed complete. Phase 2 has
implemented its first integration requirement: the broker is supervised and
ordered ahead of the production reader, so no persistent early patch is
required. Hardware proof that this eliminates the reboot caveat is the next
acceptance milestone; it is not yet claimed by this document.
