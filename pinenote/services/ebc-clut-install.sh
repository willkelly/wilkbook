#!/bin/sh
# Compile the device's own waveform into the CLUT hrdl's direct-mode
# rockchip_ebc requires (doc/direct-mode-adoption.md D1/P1), then REBIND
# the driver so the probe that already failed in the initrd runs again
# with the CLUT in place (D7; proven by hand on glass, 2026-08-25).
#
# That driver request_firmware()s rockchip/custom_wf.bin inside
# rockchip_ebc_waveform_init() and returns -EINVAL when it is absent, which
# fails probe outright: no DRM device, no framebuffer, no display.  The file
# is DERIVED PER-DEVICE CALIBRATION -- it is compiled from that device's own
# ebc.wbf and, like the waveform itself, is never committed and never
# bundled (CLAUDE.md safety model).  So it is produced here, on the device,
# at boot.
#
#   ebc-clut-install.sh COMPILER SOURCE DESTINATION [STAMP [DRIVER_DIR DEVICE]]
#
#     COMPILER     wbf-clut from the pinenote-wbf-clut package, invoked as
#                  `wbf-clut INPUT.wbf OUTPUT.bin'
#     SOURCE       the waveform pinenote-install-waveform put in place,
#                  normally /lib/firmware/rockchip/ebc.wbf
#     DESTINATION  normally /lib/firmware/rockchip/custom_wf.bin
#     STAMP        where the freshness record goes; defaults to a dotfile
#                  beside DESTINATION (pass "" to keep the default when
#                  DRIVER_DIR and DEVICE follow)
#     DRIVER_DIR   the driver's sysfs directory, normally
#                  /sys/bus/platform/drivers/rockchip-ebc; together with
#                  DEVICE it enables the rebind stage below.  Both or
#                  neither -- one without the other is a usage error.
#     DEVICE       the platform device to (re)bind, normally fdec0000.ebc
#
# Every path is an ARGUMENT rather than a constant, for the reason
# manuals-stage.sh spells out: a script whose paths are baked in can only be
# grepped, and a gate that greps a script tests the grep.  This one is
# EXECUTED through every branch by
# pinenote/scripts/preflight/test-ebc-clut-install.py.
#
# WHY A CHECKSUM AND NOT `test ! -e'.  Upstream's unit
# (pinenote-dist/systemd/pinenote-hrdl-convert-waveform.service) gates on
#
#     ExecCondition=/usr/bin/test ! -e .../custom_wf.bin
#
# i.e. compile-once-if-absent.  That is the same shape as our own waveform
# installer's "destination exists -> exit 0", which issue #12 §7 and
# doc/direct-mode-adoption.md both flag as a hazard: a stale derived artifact
# then wins forever, silently, with nothing able to notice.  Adding a SECOND
# derived artifact under that pattern would compound the bug, so this script
# records what it compiled FROM and rebuilds when any of it moves.
#
# WHY A REBIND, AND WHY IT IS THIS SCRIPT'S JOB.  Our initrd RAW-LOADS
# rockchip_ebc from its pre-mount hook, before the root filesystem -- and
# therefore before this CLUT -- exists.  Under the direct-mode driver that
# first probe fails -EINVAL EVERY BOOT, by construction; the module stays
# registered, the device stays unbound, the panel stays dark.  The
# 2026-08-25 glass session proved the recovery by hand:
#
#     echo fdec0000.ebc > /sys/bus/platform/drivers/rockchip-ebc/bind
#
# after the CLUT is in place makes the probe pass (doc/status.md D2).  A
# CLUT install without that rebind is a file nobody reads until the next
# by-hand intervention, so the two travel together, and a rebind that fails
# FAILS THIS SCRIPT LOUDLY -- a silent skip is a blank panel nobody can
# explain from the logs.
#
# THE AUTHORITY MODEL FOR THE REBIND, because sysfs writes lie in both
# directions.  The unbind write's EXIT STATUS is trusted (a refused unbind
# means the old driver instance still owns the device, and rebinding over
# it would leave a stale-CLUT driver bound while we report success).  The
# bind write's exit status is NOT the authority -- the END STATE is: after
# the write, DRIVER_DIR/DEVICE must exist (the device bound to this
# driver), and DEVICE/drm must contain a card* minor (the probe got far
# enough to register the DRM device).  Either missing is a hard failure
# that names dmesg.
#
# UNLIKE manuals-stage.sh, THE FAILURE PATHS EXIT NON-ZERO.  A reader that
# boots without its manuals is a reader; a device that boots without a CLUT
# has no display at all, and D4 already records that -EINVAL-at-probe is
# indistinguishable from a brick for an operator installing on their own
# device.  Everything here is meant to be loud in the boot log rather than
# to keep going.
set -u

# Shepherd start-lambdas inherit PID 1's environment, which on this device is
# a single e2fsck-static/sbin directory: mktemp, mkdir, mv, chmod, dirname and
# sha256sum are all unresolvable without this.  wifi.scm:26-28 records the
# lesson; the waveform installer in pinenote/packages/firmware.scm carries the
# same line for the same reason (first-light finding 2026-07-04: cat -> 127).
export PATH="/run/current-system/profile/bin:/run/current-system/profile/sbin${PATH:+:$PATH}"

usage='usage: ebc-clut-install.sh COMPILER SOURCE DESTINATION [STAMP [DRIVER_DIR DEVICE]]'
compiler=${1:?$usage}
source_waveform=${2:?$usage}
destination=${3:?$usage}
stamp=${4:-}
driver_dir=${5:-}
device=${6:-}

say() { echo "pinenote-ebc-clut: $*"; }
fail() { echo "pinenote-ebc-clut: $*" >&2; exit 1; }

# DRIVER_DIR and DEVICE come as a pair; catching a lone one here keeps a
# truncated service invocation from silently degrading to install-only --
# which would be exactly the "CLUT lands, nothing rebinds, panel dark"
# state the rebind stage exists to prevent.
if [ -n "$driver_dir" ] && [ -z "$device" ]; then
  fail "DRIVER_DIR given without DEVICE -- $usage"
fi
if [ -z "$driver_dir" ] && [ -n "$device" ]; then
  fail "DEVICE given without DRIVER_DIR -- $usage"
fi

directory=$(dirname "$destination")
if [ -z "$stamp" ]; then
  stamp="$directory/.$(basename "$destination").stamp"
fi

[ -x "$compiler" ] ||
  fail "no CLUT compiler at $compiler -- cannot build $destination, and
   rockchip_ebc fails probe with -EINVAL without it"

# A machine without the panel -- the QEMU rig, a bringup flavor -- has nothing
# to compile and nothing to rebind; say so and succeed, so reader-session (which
# requires this one-shot since S2) still starts there.  EBC_DEVICE lets the
# harness pick either branch.
ebc_device=${EBC_DEVICE:-/sys/bus/platform/devices/fdec0000.ebc}
if [ ! -e "$ebc_device" ]; then
  say "no EBC device at $ebc_device (no panel on this machine); nothing to compile, nothing to rebind"
  exit 0
fi

# The waveform is the input.  Its absence is the never-bundle rule working as
# intended (no generic waveform is shipped), and it must be as loud here as it
# is in pinenote-install-waveform, which is the service that should have put
# it there.
[ -f "$source_waveform" ] ||
  fail "no waveform at $source_waveform -- nothing to compile.  The EBC
   driver will fail probe with -EINVAL; check pinenote-waveform"

# Which digest tool, if any.  sha256sum is coreutils and is on the device,
# but a script that silently loses its freshness test is exactly the failure
# this file exists to prevent, so an absent tool DOWNGRADES TO RECOMPILING
# EVERY BOOT rather than to trusting whatever is on disk.  Compiling is
# cheap; a stale CLUT is a silently wrong waveform table.
digest_tool=$(command -v sha256sum 2>/dev/null || true)
digest() {
  # Prints nothing when there is no tool or no file; callers must not treat
  # an empty digest as a match (see the guard on $digest_tool below).
  [ -n "$digest_tool" ] || return 0
  [ -f "$1" ] || return 0
  "$digest_tool" "$1" 2>/dev/null | cut -d' ' -f1
}

# The freshness record: what we compiled FROM, WITH, and what we produced.
#
#   line 1  sha256 of the source waveform    -- a re-extracted or replaced
#                                               ebc.wbf must rebuild
#   line 2  the compiler's path              -- a Guix store path, so its
#                                               hash moves whenever wbf-clut
#                                               or anything under it changes
#   line 3  sha256 of the destination        -- a truncated, corrupted or
#                                               hand-edited custom_wf.bin
#                                               must rebuild
current_record() {
  printf '%s\n%s\n%s\n' "$(digest "$source_waveform")" "$compiler" \
    "$(digest "$destination")"
}

# NOT an early `exit 0': the rebind stage below must run on the is-current
# path too, because the initrd's failed probe leaves the device unbound on
# EVERY boot -- the boots on which the CLUT is already current are precisely
# the normal ones.
fresh=no
if [ -z "$digest_tool" ]; then
  say "warning: no sha256sum on PATH -- recompiling unconditionally rather
   than trusting $destination"
elif [ -f "$destination" ] && [ -f "$stamp" ] &&
     [ "$(cat "$stamp" 2>/dev/null)" = "$(current_record)" ]; then
  say "$destination is current -- unchanged"
  fresh=yes
fi

if [ "$fresh" = no ]; then
  if [ -e "$destination" ] || [ -f "$stamp" ]; then
    say "recompiling $destination: its source, its compiler or the file itself
   has changed"
  fi

  if [ -L "$directory" ]; then
    fail "$directory is a symlink -- refusing to write the CLUT through it"
  fi
  mkdir -p -- "$directory" ||
    fail "cannot create $directory"
  if [ ! -d "$directory" ] || [ -L "$directory" ]; then
    fail "$directory is not a real directory"
  fi

  # Compile to a sibling and rename.  wbf-clut writes atomically itself, but
  # the guarantee that a FAILED compile never replaces a good custom_wf.bin
  # has to be this script's, not a property of a program it happens to call.
  temporary=$(mktemp "$directory/.custom_wf.XXXXXX" 2>/dev/null) ||
    fail "cannot create a temporary file in $directory -- is it writable?"
  trap 'rm -f -- "$temporary"' EXIT HUP INT TERM

  say "compiling $destination from $source_waveform"
  if ! "$compiler" "$source_waveform" "$temporary"; then
    fail "the CLUT compiler failed on $source_waveform -- $destination
   is unchanged and rockchip_ebc will fail probe with -EINVAL"
  fi
  [ -s "$temporary" ] ||
    fail "the CLUT compiler produced an empty file from $source_waveform"

  chmod -- 0644 "$temporary" 2>/dev/null || true
  mv -- "$temporary" "$destination" ||
    fail "cannot install $destination"
  trap - EXIT HUP INT TERM

  # Bookkeeping only.  A stamp we cannot write means the next boot
  # recompiles, which is correct but slower -- not a reason to leave the
  # device without a display, so this warns and continues with the CLUT in
  # place.
  if ! current_record > "$stamp" 2>/dev/null; then
    say "warning: cannot write the freshness record $stamp -- $destination
   will be recompiled on every boot"
  fi

  say "installed $destination"
fi

# ---------------------------------------------------------------------
# The rebind stage (D2, 2026-08-25): make the driver probe AGAINST the
# CLUT that is now in place.  Only reached with the CLUT installed and
# verified above; skipped entirely -- and only -- when the caller passed
# no DRIVER_DIR/DEVICE (the install-only invocation the host suite uses
# for the compile branches).
# ---------------------------------------------------------------------
if [ -n "$driver_dir" ]; then
  [ -d "$driver_dir" ] ||
    fail "no driver directory at $driver_dir -- rockchip_ebc never
   registered (the initrd raw-load is missing?).  Cannot rebind $device;
   the panel stays dark.  See dmesg"

  bound() { [ -e "$driver_dir/$device" ]; }
  drm_minor_present() {
    # A card* entry under the bound device's drm/ directory is the probe
    # having got far enough to register the DRM device -- the sysfs
    # evidence the 2026-08-25 session used.  The glob stays literal when
    # nothing matches, which -e correctly rejects.
    for entry in "$driver_dir/$device/drm"/card*; do
      [ -e "$entry" ] && return 0
    done
    return 1
  }

  if [ "$fresh" = yes ] && bound && drm_minor_present; then
    # A service restart with nothing changed: the bound driver read this
    # exact CLUT when it probed, so tearing the display down to re-read an
    # identical file would be a visible blank for nothing.
    say "$device is already bound with a DRM minor and the CLUT is
   unchanged -- not rebinding"
  else
    if bound; then
      # Trust the WRITE STATUS here: a refused unbind means the old driver
      # instance still owns the device, and binding over it would leave a
      # driver holding a stale CLUT while this script reports success.
      say "unbinding $device to re-probe against $destination"
      printf '%s' "$device" > "$driver_dir/unbind" ||
        fail "cannot unbind $device from $driver_dir -- refusing to leave
   a driver bound against a stale CLUT.  See dmesg"
    fi
    say "binding $device"
    # The write's status is NOT the authority for bind -- the end state
    # is, checked below -- but a write error is still worth a line.
    printf '%s' "$device" > "$driver_dir/bind" ||
      say "the bind write reported an error -- checking the end state anyway"
    bound ||
      fail "$device did not bind -- the probe failed even with $destination
   in place.  The panel is dark; see dmesg for the probe error"
    drm_minor_present ||
      fail "$device is bound but exposes no DRM minor under
   $driver_dir/$device/drm -- the probe did not finish.  See dmesg"
    say "$device bound; DRM minor present"
  fi
fi
