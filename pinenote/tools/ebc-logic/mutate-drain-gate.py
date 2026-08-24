#!/usr/bin/env python3
"""Reconstruct the driver WITHOUT the issue-#22 work-item drain gate.

rockchip_ebc_partial_refresh() used to splice ctx->queue into its local
`areas` list unconditionally, every frame, and its only exit was
`list_empty(&areas)`.  A damage supply arriving at least once per area
lifetime therefore kept the list permanently non-empty and the refresh
thread never got back to the top of its inner loop: a queued global
refresh never launched and a kthread_park() never completed.  That is the
2026-07-29 hardware failure, and it is still how the m-weigand -> hrdl
lineage's published trees behave (hrdl fixed it in v6.19_ebc_custom).

This script takes the extracted (verbatim) rockchip_ebc.c and emits a copy
with exactly that behaviour restored: the `if (!work_item_pending)` guard
on the mid-frame splice dropped, and the per-frame gate read and its
helper removed.  Nothing else is touched.  Two binaries are built against
the result:

  * ebc-refresh-starvation-test -- the pinned `quirk:` reproduction of the
    inherited defect, which the shipping driver no longer exhibits;
  * ebc-drain-gate-test-nogate -- the same source as the positive
    drain-gate test, which run-tests.sh requires to FAIL.  A liveness
    test that passes with and without the gate proves nothing.

Every anchor is asserted, so a rebase that reshapes the partial-refresh
loop makes the mutation fail loudly rather than silently producing a copy
that is no longer the pre-fix code.

Usage: mutate-drain-gate.py IN.c OUT.c
"""

import os
import sys

FUNC = "static int rockchip_ebc_partial_refresh(struct rockchip_ebc *ebc,"
HELPER = "static bool rockchip_ebc_work_item_pending(struct rockchip_ebc *ebc)"
LOOP = "\tfor (frame = 0;; frame++) {"
GATE_READ = "\t\tbool work_item_pending = rockchip_ebc_work_item_pending(ebc);"
GATE_COMMENT_A = "\t\t/* The drain gate.  Re-read every frame: a work item can be"
GATE_COMMENT_LAST = "\t\t * chose a partial over a global. */"

# frame == 0's splice is NOT gated (it is this refresh's own starting set).
SPLICE0 = "\t\t\tlist_splice_tail_init(&ctx->queue, &areas);"

# The gated one: mid-frame, inside the spin_trylock retry loop.
GUARD1 = "\t\t\t\tif (!work_item_pending)"
SPLICE1 = "\t\t\t\t\tlist_splice_tail_init(&ctx->queue, &areas);"
SPLICE1_OUT = "\t\t\t\tlist_splice_tail_init(&ctx->queue, &areas);"


def die(msg):
    sys.exit("mutate-drain-gate.py: %s" % msg)


def index_of(lines, needle, start, stop, what):
    for i in range(start, stop):
        if lines[i] == needle:
            return i
    die("anchor not found (%s): %r" % (what, needle))


def main():
    if len(sys.argv) != 3:
        die("usage: mutate-drain-gate.py IN.c OUT.c")
    src, dst = sys.argv[1], sys.argv[2]

    with open(src, "r") as f:
        lines = f.read().split("\n")

    fn = index_of(lines, FUNC, 0, len(lines), "partial-refresh function")

    # The helper and its explanatory block sit immediately ahead of the
    # function they serve; remove them whole so the ungated copy carries
    # no dead code (and no unused-function warning).
    helper = index_of(lines, HELPER, 0, fn, "work-item helper")
    if lines[helper + 1] != "{":
        die("the work-item helper is not followed by its opening brace")
    helper_end = index_of(lines, "}", helper, fn, "end of the work-item helper")
    if helper_end + 1 != fn - 1 or lines[fn - 1] != "":
        die("the helper is not immediately followed by a blank line and %r"
            % FUNC)
    if lines[helper - 1] != " */":
        die("the helper is not preceded by its comment block")
    comment = helper - 1
    while comment >= 0 and lines[comment] != "/*":
        comment -= 1
    if comment < 0:
        die("could not find the opening of the helper's comment block")

    loop = index_of(lines, LOOP, fn, len(lines), "frame loop")
    # The loop body ends at the next function-scope closing brace.
    end = index_of(lines, "}", loop, len(lines), "end of function")

    read = index_of(lines, GATE_READ, loop, end, "per-frame gate read")
    if lines[read - 1] != GATE_COMMENT_LAST:
        die("the gate read is not preceded by its comment block")
    comment_first = read - 1
    while comment_first >= loop and lines[comment_first] != GATE_COMMENT_A:
        comment_first -= 1
    if comment_first < loop:
        die("could not find the opening of the gate read's comment")

    s0 = index_of(lines, SPLICE0, read, end, "frame-0 splice (ungated)")
    g1 = index_of(lines, GUARD1, s0 + 1, end, "mid-frame guard")
    if lines[g1 + 1] != SPLICE1:
        die("the mid-frame guard does not wrap the queue splice")

    # Exactly two splices in the loop, and no third one hiding in it.
    extra = [i for i in range(loop, end)
             if lines[i].strip() == "list_splice_tail_init(&ctx->queue, &areas);"
             and i not in (s0, g1 + 1)]
    if extra:
        die("unexpected extra ctx->queue splice in the frame loop at %r"
            % (extra,))

    # comment block + helper + the blank line after it
    dropped = set(range(comment, helper_end + 2))
    dropped |= set(range(comment_first, read + 1))   # the per-frame read
    dropped.add(g1)                                  # the mid-frame guard

    out = []
    for i, line in enumerate(lines):
        if i in dropped:
            continue
        if i == g1 + 1:
            out.append(SPLICE1_OUT)     # unindent back under the trylock
        else:
            out.append(line)

    if len(out) != len(lines) - len(dropped):
        die("dropped %d lines, expected %d"
            % (len(lines) - len(out), len(dropped)))
    for remnant in ("work_item_pending", "rockchip_ebc_work_item_pending"):
        if any(remnant in l for l in out):
            die("a gate remnant survived the mutation: %r" % remnant)

    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    with open(dst, "w") as f:
        f.write("\n".join(out))
    print("mutate-drain-gate.py: %s -> %s (work-item drain gate removed)"
          % (src, dst))


if __name__ == "__main__":
    main()
