#!/usr/bin/env python3
"""Reconstruct the PRE-FIX ordering of ioctl_trigger_global_refresh().

ebc-fbdev-order-test.c asserts that one GLOBAL_REFRESH ioctl costs exactly
one global refresh and zero partial refreshes.  That assertion is only
worth anything if it FAILS against the ordering commit 8665ed8 replaced,
where the deferred-io drain ran first and do_one_full_refresh was set
afterwards -- so the damage worker's atomic commit woke the refresh thread
with no wash armed and it ran a full partial pass first.

This script takes the extracted (verbatim) rockchip_ebc.c and emits a copy
whose ioctl_trigger_global_refresh() has exactly that ordering: the
CONFIG_DRM_FBDEV_EMULATION drain block moved back ahead of the barrier
checks and the arm.  Nothing else is touched.  run-tests.sh builds the
ordering test against this copy and requires it to FAIL.

Everything is anchored on exact source lines and every anchor is asserted,
so a rebase that reshapes this function makes the mutation fail loudly
rather than silently producing a copy that is no longer the pre-fix code.

Usage: mutate-prefix-order.py IN.c OUT.c
"""

import os
import sys

FUNC = "static int ioctl_trigger_global_refresh(struct drm_device *dev, void *data,"
IF_LINE = "\tif (args->trigger_global_refresh){"
PRINTK = '\t\t/* printk(KERN_INFO "[rockchip_ebc] ioctl_trigger_global_refresh"); */'
IFDEF = "#ifdef CONFIG_DRM_FBDEV_EMULATION"
ENDIF = "#endif"
TAIL = "\t\t// try to trigger the refresh immediately"

ARM = "\t\tebc->do_one_full_refresh = true;"
DRAIN = "\t\t\tflush_delayed_work("


def die(msg):
    sys.exit("mutate-prefix-order.py: %s" % msg)


def index_of(lines, needle, start, stop, what):
    for i in range(start, stop):
        if lines[i] == needle:
            return i
    die("anchor not found (%s): %r" % (what, needle))


def main():
    if len(sys.argv) != 3:
        die("usage: mutate-prefix-order.py IN.c OUT.c")
    src, dst = sys.argv[1], sys.argv[2]

    with open(src, "r") as f:
        lines = f.read().split("\n")

    fn = index_of(lines, FUNC, 0, len(lines), "function")
    end = index_of(lines, "}", fn, len(lines), "end of function")

    open_if = index_of(lines, IF_LINE, fn, end, "trigger_global_refresh guard")
    printk = index_of(lines, PRINTK, open_if, end, "leading comment")
    ifdef = index_of(lines, IFDEF, printk, end, "fbdev drain #ifdef")
    endif = index_of(lines, ENDIF, ifdef, end, "fbdev drain #endif")
    tail = index_of(lines, TAIL, endif, end, "trailing wake comment")

    head = lines[printk + 1:ifdef]   # barrier checks + the arm
    drain = lines[ifdef:endif + 1]   # the CONFIG_DRM_FBDEV_EMULATION block

    # The region must be exactly the two parts, nothing between #endif and
    # the trailing comment.
    if endif + 1 != tail:
        die("unexpected lines between #endif and the trailing wake comment")
    if not any(l == ARM for l in head):
        die("the arm (%r) is not ahead of the drain -- source already pre-fix?" % ARM)
    if not any(l.startswith(DRAIN) for l in drain):
        die("the deferred-io drain is missing from the #ifdef block")
    if any(l == IFDEF for l in head) or any(l == ARM for l in drain):
        die("anchors overlap; the function has been reshaped")

    out = lines[:printk + 1] + drain + head + lines[tail:]
    if len(out) != len(lines):
        die("line count changed (%d -> %d)" % (len(lines), len(out)))

    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    with open(dst, "w") as f:
        f.write("\n".join(out))
    print("mutate-prefix-order.py: %s -> %s (pre-fix ordering: drain, then arm)"
          % (src, dst))


if __name__ == "__main__":
    main()
