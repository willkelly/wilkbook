#!/bin/sh
# quirk: hrdl's RECT_HINTS ioctl is unbounded; our patch bounds it.
#
# In the inherited direct-mode driver an inverted rectangle's unsigned
# x2 - x1 wraps and memset() writes a whole pitch from x1 (past the hint
# plane on the last row), a short copy_from_user() counts the copied bytes
# MODULO the record size and walks that many records, and a failed
# kmalloc_array() returns -EFAULT.  linux-pinenote-7.1-rect-hints-bounds.patch
# fixes all three on top (doc/upstream-register.md item 24).  This pin asserts
# BOTH halves: the inherited shape is still in hrdl's patch (so a rebase over
# an upstream fix goes red and our patch is dropped on purpose), and our fix
# is present and applied after it.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
direct="$here/../../patches/linux-pinenote-7.1-hrdl-direct-mode.patch"
fix="$here/../../patches/linux-pinenote-7.1-rect-hints-bounds.patch"
kernel="$here/../../packages/kernel.scm"
grep -q 'to_process = (copy_size - remain) % sizeof(\*rect_hints);' "$direct" || { echo "FAIL: the direct-mode patch no longer carries the modulo count -- upstream fixed RECT_HINTS? drop our patch and re-approve (register 24)" >&2; exit 1; }
grep -q 'unsigned int width = min(ebc->pixel_pitch, x2 - x1);' "$direct" || { echo "FAIL: the direct-mode patch's rectangle arithmetic changed -- re-approve register 24" >&2; exit 1; }
[ -f "$fix" ] || { echo "FAIL: $fix missing" >&2; exit 2; }
grep -q '^+[[:space:]]*break;' "$fix" && grep -q '^-.*to_process = (copy_size - remain) % sizeof' "$fix" || { echo "FAIL: the fix no longer rejects a short copy" >&2; exit 1; }
grep -q '^+.*if (x2 <= x1 || y2 <= y1)' "$fix" || { echo "FAIL: the fix no longer rejects inverted/empty rectangles" >&2; exit 1; }
grep -q '^+.*return -ENOMEM;' "$fix" || { echo "FAIL: the fix no longer returns -ENOMEM" >&2; exit 1; }
! grep -q '^+.*% sizeof(\*rect_hints)' "$fix"
# applied after the direct-mode patch, in the direct kernel's list
d=$(grep -n 'linux-pinenote-7.1-hrdl-direct-mode.patch' "$kernel" | head -1 | cut -d: -f1)
f=$(grep -n 'linux-pinenote-7.1-rect-hints-bounds.patch' "$kernel" | head -1 | cut -d: -f1)
[ -n "$d" ] && [ -n "$f" ] && [ "$f" -gt "$d" ] || { echo "FAIL: the bounds patch is not listed after the direct-mode patch in kernel.scm" >&2; exit 1; }
# our parallel-advance patch checks queue_work's return
grep -q 'if (!queue_work(system_unbound_wq, &w->work))' "$here/../../patches/linux-pinenote-7.1-ebc-parallel-advance.patch" || { echo "FAIL: parallel-advance ignores queue_work's return again" >&2; exit 1; }
echo "PASS: quirk: hrdl's RECT_HINTS is unbounded (inherited, pinned); our bounds patch is present, after it; queue_work's return is checked"
