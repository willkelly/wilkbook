#!/bin/sh
# quirk: the direct-mode driver's probe leaks on a failed drm_init.
#
# hrdl's direct-mode patch replaced the probe's `goto err_stop_kthread` after
# a failed rockchip_ebc_drm_init with a bare `return ret`, and deleted the
# label.  The by-construction first probe on the direct image (no CLUT yet)
# therefore returns with runtime PM still enabled and the parked refresh
# kthread alive; the CLUT one-shot's rebind then enables runtime PM a second
# time -- "rockchip-ebc fdec0000.ebc: Unbalanced pm_runtime_enable!" on every
# boot of the direct image (root-caused 2026-09-02, doc/status.md;
# doc/upstream-register.md item 23).  Benign, but it is a driver bug and
# the driver's lineage owns the fix.  This pin asserts the INHERITED shape so
# a rebase that changes it (upstream fix, or our own port of it) goes red
# and is re-approved on purpose rather than drifting.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch="$here/../../patches/linux-pinenote-7.1-hrdl-direct-mode.patch"
[ -f "$patch" ] || { echo "FAIL: $patch missing" >&2; exit 2; }
# The hunk: drm_init failure returns bare, the kthread-stop label is removed,
# and err_disable_pm survives unreachable from that path.
awk '
  /^-[[:space:]]*goto err_stop_kthread;/ { removed_goto = 1 }
  /^\+[[:space:]]*return ret;/ && removed_goto && !bare_return { bare_return = 1 }
  /^-err_stop_kthread:/ { removed_label = 1 }
  /^-[[:space:]]*kthread_stop\(ebc->refresh_thread\);/ { removed_stop = 1 }
  /^ err_disable_pm:/ { label_kept = 1 }
  END { exit !(removed_goto && bare_return && removed_label && removed_stop && label_kept) }
' "$patch" || { echo "FAIL: the direct-mode patch no longer carries the bare-return probe error path (quirk fixed or changed? re-approve: doc/kernel-forward-port.md quirks, upstream-register 23)" >&2; exit 1; }
echo "PASS: quirk: direct-mode probe returns bare after a failed drm_init (runtime PM left enabled, refresh kthread leaked) -- inherited, pinned, reported"
