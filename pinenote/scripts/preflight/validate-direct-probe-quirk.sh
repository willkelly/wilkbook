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
#
# Correction from glass, 2026-09-04 (doc/status.md): the boot's first probe
# fails EARLIER than drm_init, at rockchip_ebc_waveform_init (no
# custom_wf.bin yet), whose own bare return the unwind patch never reaches
# -- so it also leaked the two plain vmallocs (~10 MB) and the phase DMA
# maps on every boot, and a successful probe's lut_custom.luts (228 kB) was
# never freed at all (the audit's item 2).  The probe-lifetime patch is the
# resource-lifetime pass on top of the unwind; this pin asserts both, in
# order, after hrdl's shape.
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
# ...and our fix on top, applied after hrdl's patch.
fix="$here/../../patches/linux-pinenote-7.1-probe-unwind.patch"
kernel="$here/../../packages/kernel.scm"
[ -f "$fix" ] || { echo "FAIL: $fix missing" >&2; exit 2; }
grep -q '^+[[:space:]]*goto err_stop_kthread;' "$fix" && grep -q '^+err_stop_kthread:' "$fix" && grep -q '^+[[:space:]]*kthread_stop(ebc->refresh_thread);' "$fix" || { echo "FAIL: the probe-unwind fix no longer restores the label and the goto" >&2; exit 1; }
d=$(grep -n 'linux-pinenote-7.1-hrdl-direct-mode.patch' "$kernel" | head -1 | cut -d: -f1); f=$(grep -n 'linux-pinenote-7.1-probe-unwind.patch' "$kernel" | head -1 | cut -d: -f1)
[ -n "$d" ] && [ -n "$f" ] && [ "$f" -gt "$d" ] || { echo "FAIL: the probe-unwind patch is not listed after the direct-mode patch in kernel.scm" >&2; exit 1; }
# ...and the resource-lifetime pass on top of the unwind: the buffers and
# the LUT get labels of their own, the LUT is freed in probe's chain AND in
# remove (two added vfree lines), and the unwind's err_stop_kthread label is
# kept as context rather than re-added.
life="$here/../../patches/linux-pinenote-7.1-probe-lifetime.patch"
[ -f "$life" ] || { echo "FAIL: $life missing" >&2; exit 2; }
grep -q '^+err_free_lut:' "$life" && grep -q '^+err_free_buffers:' "$life" && grep -q '^ err_stop_kthread:' "$life" && [ "$(grep -c '^+[[:space:]]*vfree(ebc->lut_custom.luts);' "$life")" -eq 2 ] || { echo "FAIL: the probe-lifetime patch no longer frees the LUT (probe and remove) and the buffers on top of the unwind label" >&2; exit 1; }
# The boot path: a failed waveform_init must enter the chain, not return bare.
awk '/rockchip_ebc_waveform_init\(ebc\);/ { seen = 1 } seen && /^\+[[:space:]]*goto err_disable_pm;/ { ok = 1; exit } END { exit !ok }' "$life" || { echo "FAIL: the probe-lifetime patch no longer routes a failed waveform_init through the unwind" >&2; exit 1; }
l=$(grep -n 'linux-pinenote-7.1-probe-lifetime.patch' "$kernel" | head -1 | cut -d: -f1)
[ -n "$l" ] && [ "$l" -gt "$f" ] || { echo "FAIL: the probe-lifetime patch is not listed after the probe-unwind patch in kernel.scm" >&2; exit 1; }
echo "PASS: quirk: direct-mode probe returns bare after a failed drm_init (inherited, pinned, reported); our unwind fix is present after it, and the probe-lifetime pass after that (waveform_init routed, LUT freed in probe and remove)"
