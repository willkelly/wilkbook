#!/bin/sh
# Structural gate over the arm-before-drain ordering in
# ioctl_trigger_global_refresh (doc/refresh-policy.md, "one intent, one
# pass").
#
# Why this needs its own gate: the drain lives inside
# `#ifdef CONFIG_DRM_FBDEV_EMULATION`, which the ebc-logic host harness
# does NOT define -- it compiles the block away entirely, and
# ebc-replay.c's request_global() replicates only "the flag + wake" with
# no drain at all.  So the whole 472-assertion host suite goes green
# whether the flag is set before the drain or after it, and the
# difference between those two is an entire extra visible refresh pass.
# `make kernel` compiles it but cannot judge the order either.
#
# What it pins, and why:
#   1. do_one_full_refresh is set BEFORE flush_delayed_work().  The drain
#      ends in the damage worker's atomic commit, which splices damage
#      into ctx->queue and then wake_up_process()es the refresh thread.
#      With the flag still clear at that moment the thread wakes, sees no
#      pending full refresh, and runs a PARTIAL pass over that damage --
#      a complete visible repaint -- before the ioctl asks for the wash.
#      Measured on a PineNote 2026-08-04: every global intent cost 38
#      partial frames followed by 1 global IRQ, seen on glass as "render,
#      flash, render again" on rotation and on opening the menu.
#   2. The barrier checks (poison / worker_available / hardware_uncertain)
#      come BEFORE the flag is set.  An early return after arming would
#      leave do_one_full_refresh latched and fire a spurious wash later.
#   3. The drain is still present.  Removing it would fix the double pass
#      by reintroducing the bug it was added for: the wash would paint
#      whatever was in ctx->final before userspace's damage landed.
#   4. wake_up_process() still runs, for the case where there was no
#      pending damage at all and so nothing else woke the thread.
#
# Usage: validate-ebc-global-arm-order-hunk.sh [patch]  (default: repo patch)
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
patch=${1:-$repo_root/pinenote/patches/linux-pinenote-7.0-forward-port.patch}

fail() { echo "FAIL: $1" >&2; exit 1; }

section=$(awk '/^diff --git a\/drivers\/gpu\/drm\/rockchip\/rockchip_ebc.c/{f=1}
               f && /^diff --git/ && !/rockchip_ebc.c/{exit} f{print}' "$patch")
[ -n "$section" ] || fail "no rockchip_ebc.c section in $patch"

added=$(printf '%s\n' "$section" | sed -n 's/^+//p')
[ -n "$added" ] || fail "rockchip_ebc.c section adds no lines"

body=$(printf '%s\n' "$added" |
  sed -n '/^static int ioctl_trigger_global_refresh(struct drm_device \*dev, void \*data,$/,/^}/p')
[ -n "$body" ] || fail "cannot isolate ioctl_trigger_global_refresh"

line_of() {
  printf '%s\n' "$body" | grep -n -- "$1" | cut -d: -f1 | head -1
}

flag=$(line_of "ebc->do_one_full_refresh = true;")
[ -n "$flag" ] || fail "ioctl never sets do_one_full_refresh"

flush=$(line_of "flush_delayed_work(")
[ -n "$flush" ] || fail "(3) the deferred-io drain is gone: the wash could paint pre-damage content"

flushw=$(line_of "flush_work(&rockchip_ebc_defio_helper->damage_work);")
[ -n "$flushw" ] || fail "(3) damage_work flush is gone: ctx->final may not hold the caller's content"

wake=$(line_of "wake_up_process(ebc->refresh_thread);")
[ -n "$wake" ] || fail "(4) ioctl never wakes the refresh thread"

poison=$(line_of "if (ebc->barrier_poison) {")
[ -n "$poison" ] || fail "(2) barrier_poison check is gone"

nodev=$(line_of "if (!ebc->worker_available || ebc->hardware_uncertain) {")
[ -n "$nodev" ] || fail "(2) worker_available/hardware_uncertain check is gone"

# 1. arm before drain -- the whole point.
[ "$flag" -lt "$flush" ] ||
  fail "(1) do_one_full_refresh is set AFTER the drain: the commit's wake_up_process will
      catch the refresh thread with the flag clear, and it will run a full partial
      pass over the damage before the wash -- the double refresh this ordering fixes"

# 2. checks before arm -- an early return must not leave the flag latched.
[ "$poison" -lt "$flag" ] ||
  fail "(2) barrier_poison check runs after arming: an early return latches do_one_full_refresh"
[ "$nodev" -lt "$flag" ] ||
  fail "(2) worker/hardware check runs after arming: an early return latches do_one_full_refresh"

# 4. the belt-and-braces wake stays last.
[ "$wake" -gt "$flush" ] ||
  fail "(4) wake_up_process precedes the drain: with no pending damage nothing would start the wash"

echo "PASS: ioctl_trigger_global_refresh arms the wash before draining deferred-io"
echo "PASS: barrier checks precede the arm (no latched flag on an error return)"
echo "PASS: the deferred-io drain and the fallback wake are both still present"
