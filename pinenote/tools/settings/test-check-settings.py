#!/usr/bin/env python3
"""Positive controls for `check-settings.py' (issue #12, step 1).

A coupling gate that reads sources as text has one characteristic failure
mode: a pattern stops matching, every comparison silently has nothing to
compare, and the gate reports a green it did not earn.  Three vacuous
assertions shipped in this repo in one month, so a gate of this shape is
not trustworthy until something has watched it go red for the right
reason.

This suite copies the files the gate reads into a scratch tree, breaks ONE
coupling at a time, and requires the gate to reject that tree naming that
coupling.  It also proves the two properties that make the debt register
honest:

  * an unlisted divergence is a hard FAIL, not a DEBT -- new drift cannot
    hide behind the register;
  * PAYING OFF a listed divergence also fails, with "stale debt-register
    entry" -- so the register shrinks by construction and cannot rot into
    a list of exemptions nobody rereads.

Run: python3 pinenote/tools/settings/test-check-settings.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir, os.pardir))
CHECKER = os.path.join(HERE, "check-settings.py")

# Every source the gate reads.  Listed rather than copied wholesale so
# that a gate reaching for a NEW file fails here loudly (site not found in
# the scratch tree) instead of quietly reading the real one.
SOURCES = [
    "pinenote/services/autosuspend.scm",
    "pinenote/services/ddr-boost.scm",
    "pinenote/services/dmc.scm",
    "pinenote/services/ebc.scm",
    "pinenote/services/ebc-direct.scm",
    "pinenote/services/reader-session.scm",
    "pinenote/services/timesync.scm",
    "pinenote/systems/pinenote-reader.scm",
    "pinenote/packages/firmware.scm",
    "pinenote/packages/koreader-device/frontend/device/pinenote/device.lua",
    "pinenote/packages/koreader-device/plugins/idlewasher.koplugin/main.lua",
    "pinenote/patches/linux-pinenote-7.0-forward-port.patch",
    "pinenote/scripts/qemu/run-virt-assertions.sh",
    "pinenote/tools/ebc-logic/ebc-replay.c",
    "pinenote/tools/power/autosuspend.lua",
    "pinenote/tools/power/ddr-boost.lua",
    "pinenote/tools/timesync/timesync.lua",
]

# label, file, exact text to replace, replacement, substring the gate's
# rejection must contain
MUTATIONS = [
    # --- register integrity: the two properties review found missing ----
    # Both were CLAIMED unconditionally in the commit message, the README
    # and the doc/testing.md row, and neither held.  Controlled here so the
    # claim cannot quietly become false again.
    #
    # (1) The register must own a SPECIFIC divergence, not a site.  Here
    # the site stays registered and stays divergent -- 99 is still not the
    # shipped 250 -- but the divergence has MOVED, so absorbing it as old
    # inventory would be wrong.
    ("new drift at an ALREADY-REGISTERED site is not absorbed as old debt",
     "pinenote/tools/timesync/timesync.lua",
     '    hwclock = "hwclock",',
     '    hwclock = "hwclock-somewhere-else",',
     "DIVERGENCE CHANGED at a registered site "
     "record-vs-daemon:timesync.scm:hwclock"),

    # --- gate A: a record default drifts from its daemon twin ----------
    ("a record default drifts from its daemon twin",
     "pinenote/services/autosuspend.scm",
     "(idle-seconds     pinenote-autosuspend-idle-seconds     (default 300))",
     "(idle-seconds     pinenote-autosuspend-idle-seconds     (default 301))",
     "UNKNOWN DIVERGENCE record-vs-daemon:autosuspend.scm:idle-seconds"),
    ("a daemon default drifts from its record twin",
     "pinenote/tools/power/autosuspend.lua",
     "    overlay = true,",
     "    overlay = false,",
     "UNKNOWN DIVERGENCE record-vs-daemon:autosuspend.scm:overlay?"),
    ("the negated pair is compared negated, not by luck",
     "pinenote/tools/power/autosuspend.lua",
     "    charging_inhibits = true,",
     "    charging_inhibits = false,",
     "UNKNOWN DIVERGENCE "
     "record-vs-daemon:autosuspend.scm:suspend-while-charging?"),

    # --- gate B: the shipped EBC parameter set has one site --------------
    ("a modprobe parameter copy reappears in ebc.scm",
     "pinenote/services/ebc.scm",
     '"softdep panfrost pre: rockchip_ebc\\n")',
     '"options rockchip_ebc temp_override=22\\nsoftdep panfrost pre: rockchip_ebc\\n")',
     "UNKNOWN DIVERGENCE ebc-params:modprobe-copy"),
    ("a set_parameter script reappears in firmware.scm",
     "pinenote/packages/firmware.scm",
     '(display "echo \\"installed waveform at $destination\\"\\n" port)',
     '(display "set_parameter temp_override 22\\n" port)',
     "UNKNOWN DIVERGENCE ebc-params:set_parameter-script"),
    ("the sysfs site changes shape",
     "pinenote/services/ebc-direct.scm",
     '(put "default_hint" "32")',
     '(put "default_hint_v2" "32")',
     "site not found"),

    # --- gate B2: the self-heal literals ------------------------------
    ("the autosuspend self-heal restores the wrong waveform",
     "pinenote/tools/power/autosuspend.lua",
     'local WAVEFORM_SHIPPED = "6"',
     'local WAVEFORM_SHIPPED = "4"',
     "UNKNOWN DIVERGENCE waveform-literal:autosuspend.lua WAVEFORM_SHIPPED"),
    ("the boot-wash self-heal restores the wrong waveform",
     "pinenote/services/reader-session.scm",
     "if prior == '4' then prior = '6' end",
     "if prior == '4' then prior = '2' end",
     "UNKNOWN DIVERGENCE waveform-literal:reader-session.scm"),
    ("the qemu rig asserts a shipping-driver waveform again",
     "pinenote/scripts/qemu/run-virt-assertions.sh",
     "grep -aq 'VIRTCHK-TO-22'    \"$log\" && \\",
     "grep -aq 'VIRTCHK-WF-6'     \"$log\" && \\",
     "UNKNOWN DIVERGENCE waveform-literal:run-virt-assertions.sh"),
    ("two waveform writers disagree on the GC16 transient",
     "pinenote/packages/koreader-device/plugins/idlewasher.koplugin/main.lua",
     'GC16 = "4",',
     'GC16 = "5",',
     "UNKNOWN DIVERGENCE waveform-transient:"),

    # --- gate C: the two KOReader seeds -------------------------------
    ("the host model drifts from the shipped driver parameters",
     "pinenote/tools/ebc-logic/ebc-replay.c",
     "\tp->refresh_threshold = 60;",
     "\tp->refresh_threshold = 30;",
     "UNKNOWN DIVERGENCE host-model:policy_ship:refresh_threshold"),
    ("the host model drifts from the KOReader-layer default",
     "pinenote/packages/koreader-device/frontend/device/pinenote/device.lua",
     "local flash_area_fraction = 0.98",
     "local flash_area_fraction = 0.50",
     "UNKNOWN DIVERGENCE host-model:policy_ship:flash_frac"),
    ("the modelled global waveform stops matching the shipped one",
     "pinenote/tools/ebc-logic/ebc-replay.c",
     "\tp->refresh_wf = DRM_EPD_WF_GL16;",
     "\tp->refresh_wf = DRM_EPD_WF_GC16;",
     "UNKNOWN DIVERGENCE host-model:policy_ship:refresh_wf"),

    # --- gate E/F: runtime .conf keys ---------------------------------
    ("a boolean conf key changes grammar",
     "pinenote/tools/power/autosuspend.lua",
     'runtime.enabled = not (v == "0" or v == "false" or v == "no")',
     'runtime.enabled = (v == "1" or v == "true" or v == "yes")',
     "UNKNOWN DIVERGENCE conf-grammar:autosuspend.lua:enabled"),
    ("a new runtime knob appears with nowhere declared to hold it",
     "pinenote/tools/power/ddr-boost.lua",
     '        elseif k == "enabled" then',
     '        elseif k == "brightness" then\n'
     '            runtime.hold = tonumber(v)\n'
     '        elseif k == "enabled" then',
     "undeclared runtime knob ddr-boost.lua:brightness"),
    ("a boolean conf key changes its no-file default",
     "pinenote/tools/power/ddr-boost.lua",
     "local runtime = { hold = nil, enabled = false }",
     "local runtime = { hold = nil, enabled = true }",
     "conf-key-default:enabled"),

    ("the two persistent override files drift apart",
     "pinenote/tools/power/autosuspend.lua",
     'local persistent_config = "/data/wilkbook/autosuspend.conf"',
     'local persistent_config = "/data/pinenote/autosuspend.conf"',
     "UNKNOWN DIVERGENCE override-directory"),
    ("a removed persistent override path is reported, not skipped",
     "pinenote/tools/power/autosuspend.lua",
     "local persistent_config =",
     "local persistent_conf =",
     "site not found -- autosuspend.lua no longer names a persistent"),

    # --- vacuity: a moved site must be a FAIL, never a silent pass ----
    ("a renamed record field is reported, not skipped",
     "pinenote/services/ddr-boost.scm",
     "(hold-seconds pinenote-ddr-boost-hold-seconds (default 10))",
     "(hold-secs pinenote-ddr-boost-hold-seconds (default 10))",
     "site not found -- ddr-boost.scm:hold-seconds"),
    ("a moved Lua opt table is reported, not skipped",
     "pinenote/tools/timesync/timesync.lua",
     "local opt = {",
     "local options = {",
     "site not found"),
    ("a policy_ship() that no longer zeroes is reported, not assumed",
     "pinenote/tools/ebc-logic/ebc-replay.c",
     "\tmemset(p, 0, sizeof(*p));",
     "\t/* memset removed */",
     "site not found -- policy_ship() no longer zeroes"),
    ("a moved dmc mode selector is reported, not skipped",
     "pinenote/services/dmc.scm",
     '((string-prefix? "mode=" line)',
     '((string-prefix? "MODE=" line)',
     "site not found -- dmc.scm's mode= selector"),

    # --- the register shrinks: paying off a row must fail -------------
    ("paying off a debt row makes that row stale",
     "pinenote/services/timesync.scm",
     '(default (file-append util-linux "/sbin/hwclock")))',
     '(default "hwclock"))',
     "stale debt-register entry record-vs-daemon:timesync.scm:hwclock"),
    # The host-model debt was PAID on 2026-08-24 (policy_ship now models the
    # shipped auto_refresh=0 / defio_delay_ms=250) and its rows are deleted,
    # so the old "pay it off" mutation had nothing left to pay.  The live
    # property is now the opposite one: RE-INTRODUCING the drift must be
    # caught as new drift, not silently absorbed.
    ("re-introducing the host-model drift is caught as NEW drift",
     "pinenote/tools/ebc-logic/ebc-replay.c",
     "\tp->auto_refresh = false;\t/* shipped since 2026-07-11 (b9bbc0e) */",
     "\tp->auto_refresh = true;",
     "UNKNOWN DIVERGENCE host-model:policy_ship:auto_refresh"),
    ("re-introducing the deferred-io drift is caught as NEW drift",
     "pinenote/tools/ebc-logic/ebc-replay.c",
     "\tp->defio_delay_ms = 250;\t/* shipped since 2026-07-31 (ea580b8) */",
     "\tp->defio_delay_ms = 0;",
     "UNKNOWN DIVERGENCE host-model:policy_ship:defio_delay_ms"),
]

STATE = dict(passed=0, failed=0)


def report(condition, message, detail=""):
    if condition:
        STATE["passed"] += 1
        print("PASS: " + message)
    else:
        STATE["failed"] += 1
        print("FAIL: " + message + ((" -- " + detail) if detail else ""))


def stage(destination):
    for relative in SOURCES:
        source = os.path.join(ROOT, relative)
        target = os.path.join(destination, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(source, target)


def run_checker(tree):
    process = subprocess.run([sys.executable, CHECKER, tree],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             universal_newlines=True)
    return process.returncode, process.stdout


def main():
    if not os.path.exists(CHECKER):
        print("FAIL: no check-settings.py next to this suite")
        return 1

    with tempfile.TemporaryDirectory(prefix="wilkbook-settings-") as scratch:
        pristine = os.path.join(scratch, "pristine")
        stage(pristine)

        # The baseline.  Everything below is a delta from this, so a
        # scratch tree that does not itself pass would make every
        # mutation result meaningless.
        code, output = run_checker(pristine)
        report(code == 0,
               "the unmutated scratch copy passes (exit 0)",
               "exit=%d\n%s" % (code, output))
        report("0 failed" in output,
               "the unmutated scratch copy reports no failures",
               output.strip().splitlines()[-1] if output.strip() else "")

        # A gate that reported nothing would also report no failures.
        # Require it to have actually compared things, and to have seen
        # every row of the register: a register row nobody observes is
        # exactly the "stale entry" case, and the gate must not need this
        # suite to notice it.
        summary = re.search(r"settings-check: (\d+) passed, (\d+) known "
                             r"divergences", output)
        report(summary is not None, "the gate prints a summary line")
        if summary:
            report(int(summary.group(1)) >= 25,
                   "the gate makes a substantial number of comparisons (%s)"
                   % summary.group(1))
            report(int(summary.group(2)) > 0,
                   "the gate records the drift that exists today (%s rows)"
                   % summary.group(2))

        for label, relative, old, new, expected in MUTATIONS:
            tree = os.path.join(scratch, "mutant")
            if os.path.exists(tree):
                shutil.rmtree(tree)
            stage(tree)
            path = os.path.join(tree, relative)
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
            occurrences = text.count(old)
            if occurrences != 1:
                report(False,
                       "mutation site is unique: " + label,
                       "%d occurrences of %r in %s -- the mutation, not the "
                       "gate, is stale" % (occurrences, old, relative))
                continue
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text.replace(old, new))

            code, output = run_checker(tree)
            rejected = code != 0 and expected in output
            report(rejected,
                   "the gate rejects: " + label,
                   "exit=%d, wanted %r in the output\n%s"
                   % (code, expected, output))

    print()
    print("settings-check self-test: %d passed, %d failed"
          % (STATE["passed"], STATE["failed"]))
    return 1 if STATE["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
