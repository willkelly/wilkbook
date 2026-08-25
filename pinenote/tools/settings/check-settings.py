#!/usr/bin/env python3
"""settings-check -- the configuration coupling gate (issue #12, step 1).

WHAT THIS IS.  wilkbook declares the same knob in several places at once:
a Guix service-configuration record field, a Lua daemon's `opt' table, a
`.conf' key, an argv flag, a build-time module-parameter string, and a
host tool that models the shipped stack.  Nothing connects those copies,
so they drift silently -- and the drift is invisible until a device
behaves in a way no single source of truth predicts.

This gate reads the sources as TEXT (no Guix evaluation, no build, no
device, python3 stdlib only) and asserts the copies still agree.

WHY IT PASSES TODAY EVEN THOUGH THE TREE HAS DRIFTED.  Issue #12 step 1
says to expect red.  A permanently-red check is worse than no check: it
trains people to ignore it, and `make check-host' has to stay EXIT=0 for
CI to mean anything.  So the drift that exists TODAY is written down, one
row per divergence, in DEBT_REGISTER below, and a listed divergence
reports as DEBT instead of FAIL.

DEBT_REGISTER IS A DEBT REGISTER, NOT AN EXEMPTION MECHANISM.
  * Every row names a divergence that exists in the tree right now.  If a
    row stops matching -- because the drift was fixed -- this gate FAILS
    with "stale debt-register entry" and the row must be deleted.  The
    register can therefore only shrink.
  * A divergence NOT in the register is a hard FAIL.  New drift is a bug.
  * Rows are removed by #12's later steps, not by adding more rows.  Do
    NOT add a row to make a red gate green: a new divergence means a
    coupling just broke, and the fix is upstream of this file.

VACUITY.  Every extractor below is required to FIND ITS SITE.  A pattern
that matches nothing is a FAIL ("site not found"), never a silent pass --
the exact failure mode `pinenote/tools/timesync/test-timesync.lua'
records in its own cross-check ("unescaped, every one of these matches
nothing and the whole cross-check passes vacuously").  The positive
controls live in `test-check-settings.py', which mutates each site in a
scratch copy of the tree and requires this gate to reject the mutation.

Usage: check-settings.py [REPO_ROOT]
"""

import os
import re
import sys

# --------------------------------------------------------------------
# the debt register
# --------------------------------------------------------------------
# id      -- the divergence this row covers, exactly as the gate names it
# why     -- what diverged, and why it is still here
# retires -- the #12 step expected to delete this row
DEBT_REGISTER = [
    dict(id="record-vs-daemon:timesync.scm:hwclock",
         pinned='record \'scheme:(file-append util-linux "/sbin/hwclock")\' vs opt.hwclock \'hwclock\'',
         why="record default is the absolute store path (file-append util-linux"
             " /sbin/hwclock); the daemon's own default is the bare name"
             " 'hwclock', i.e. a PATH lookup in the empty shepherd environment"
             " the record's comment exists to avoid.  Only the service path"
             " ships, so the daemon default is reachable by hand-running only",
         retires="#12 step 4 (the serializer owns the path)"),

    dict(id="host-model:policy_ship:auto_refresh",
         pinned='policy_ship() models auto_refresh=1; the shipped parameters say 0',
         why="ebc-replay's policy_ship() says it models 'the deployed"
             " phase-A.2 stack: pinenote/services/ebc.scm params' but sets"
             " auto_refresh=1, while the shipped params have set it to 0 since"
             " 2026-07-12 (optics finding 10: threshold-triggered auto-globals"
             " corrupt panel state).  Several suites in that file build on the"
             " auto-refresh-ON baseline and switch it off explicitly, so"
             " flipping it is a test-semantics change, not a one-line edit",
         retires="#12 step 3 (<pinenote-display-configuration>)"),

    dict(id="host-model:policy_ship:defio_delay_ms",
         pinned='policy_ship() models defio_delay_ms=0; the shipped parameters say 250',
         why="policy_ship() leaves defio_delay_ms at 0 (memset), which is that"
             " tool's 'flush at trace time' sentinel rather than a modelled"
             " device value -- but it is also not the shipped 250 ms, so the"
             " shipped deferred-io window is modelled by nothing",
         retires="#12 step 3 (<pinenote-display-configuration>)"),

    dict(id="host-model:banner:defio_delay_ms",
         pinned='the usage banner says the device is ~50 ms; the shipped parameters say defio_delay_ms=250',
         why="ebc-replay's usage banner still tells the operator 'the device is"
             " ~50 ms'.  The shipped value has been 250 ms since the 2026-08-01"
             " sweep (doc/refresh-policy.md), so the banner argues for a"
             " conclusion -- 'a wash usually starts on stale content' -- from a"
             " number the device stopped carrying",
         retires="#12 step 3 (<pinenote-display-configuration>)"),

    dict(id="conf-grammar:autosuspend.lua:suspend_while_charging",
         pinned='autosuspend.lua parses suspend_while_charging with an allowlist while the reference grammar in this tree is a denylist',
         why="parsed with an ALLOWlist (1/true/yes) four lines below 'enabled',"
             " which is parsed with a DENYlist.  So suspend_while_charging=on"
             " reads as OFF while enabled=off reads as ON -- two value grammars"
             " inside one function.  A live defect; fixing it is #12's job, not"
             " this gate's",
         retires="#12 step 4 (one grammar, declared once)"),

    dict(id="conf-grammar:ddr-boost.lua:enabled",
         pinned='ddr-boost.lua parses enabled with an allowlist while the reference grammar in this tree is a denylist',
         why="the SAME key name as autosuspend's 'enabled', in a second file"
             " named *.conf in the same directory, with the opposite grammar"
             " (ALLOWlist here, DENYlist there)",
         retires="#12 step 4 (one grammar, declared once)"),

    dict(id="conf-key-default:enabled",
         pinned='the key enabled is parsed in autosuspend.lua, ddr-boost.lua with defaults False, True',
         why="'enabled' is a key in two runtime conf files with OPPOSITE"
             " defaults -- autosuspend defaults on, ddr-boost defaults off --"
             " so the same line means opposite things depending on which file"
             " it sits in.  Deliberate today (ddr-boost is opt-in until its"
             " wake-boundary behaviour is proven on glass), and unfindable",
         retires="#12 step 4 (distinct field names on distinct records)"),

    dict(id="conf-parser-whitespace:dmc.scm:mode",
         pinned='the mode= selector tests the raw line with string-prefix?, so it rejects the leading whitespace every Lua parser here accepts',
         why="the dmc selector matches with (string-prefix? \"mode=\" line) on"
             " the raw line, so a leading space makes the value unrecognised"
             " and the boot silently degrades to off.  Every Lua parser in the"
             " tree accepts leading whitespace ('^%s*').  Degrading to off is"
             " safe here, which is why this is debt and not an emergency",
         retires="#12 step 4 (a serialized record, no boot-time parse)"),

    dict(id="no-record-field:autosuspend.lua:enabled",
         pinned='enabled is settable at runtime but no Guix record field declares it, so an image cannot ship a value for it',
         why="the master pause exists only in Lua and in the runtime file, so"
             " an image cannot ship auto-suspend disabled; #12's table, 'master"
             " pause -- none -- Lua only'",
         retires="#12 step 4 (an enabled? field)"),

    dict(id="no-record-field:autosuspend.lua:power_key",
         pinned='power_key is settable at runtime but no Guix record field declares it, so an image cannot ship a value for it',
         why="press-power-to-suspend is settable at runtime and by argv"
             " (--no-power-key) but has no record field, so the service can"
             " never pass the flag the daemon already knows how to parse",
         retires="#12 step 4 (a power-key-suspends? field)"),

    dict(id="no-record-field:ddr-boost.lua:enabled",
         pinned='enabled is settable at runtime but no Guix record field declares it, so an image cannot ship a value for it',
         why="the boost opt-in exists only in Lua.  #12 removes it from the"
             " override surface entirely rather than adding a field, because"
             " both operands of the ddr-boost x dmc.mode coupling were"
             " runtime-settable and no runtime cross-check is reachable",
         retires="#12 step 4 (ddr-boost? leaves the override surface)"),

    dict(id="no-record-field:autosuspend.lua:persistent-config",
         pinned="/data/wilkbook/autosuspend.conf is read before the record's config-file and no record field declares it",
         why="the daemon reads a SECOND config file -- the one on p7 that"
             " survives a reflash, and the one CLAUDE.md, doc/device-access.md"
             " and doc/install.md all tell an operator to write -- from a bare"
             " Lua constant.  No record field names it, so the layer that"
             " actually matters to an operator is the layer an image cannot"
             " express.  On 2026-08-24 CLAUDE.md was corrected for having named"
             " the /var/lib path, which is the one the record does declare and"
             " the one that does not exist on the device",
         retires="#12 step 4 (the two-key p7 override surface)"),

    dict(id="no-record-field:dmc.scm:mode",
         pinned='mode is settable at runtime but no Guix record field declares it, so an image cannot ship a value for it',
         why="a safety-critical, three-valued, boot-time knob with NO record"
             " field at all: pinenote-dmc-service-type has default-value #f and"
             " a (_config) constructor.  'Ship with the DDR experiment armed'"
             " is unexpressible in a system declaration -- and its failure mode"
             " is silent display corruption with clean logs",
         retires="#12 step 4 (<pinenote-dmc-configuration>)"),
]

ISSUE = "issue #12 step 1"

# --------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------
STATE = dict(fails=0, passes=0, debts=0, seen=set())


def ok(msg):
    STATE["passes"] += 1
    print("PASS: " + msg)


def bad(msg):
    STATE["fails"] += 1
    print("FAIL: " + msg)


def divergence(ident, detail):
    """Report one divergence: DEBT when the register owns it, else FAIL.

    A row owns a divergence only if BOTH the site id and the observed
    detail still match what was pinned.  Matching on the id alone would
    let NEW drift at an already-registered site be absorbed as old
    inventory and still exit 0 -- which is not "pinning today's state",
    it is pinning the set of divergent sites.  Caught in review before
    this gate ever ran in CI.
    """
    STATE["seen"].add(ident)
    for row in DEBT_REGISTER:
        if row["id"] == ident:
            pinned = row.get("pinned")
            if pinned is not None and pinned != detail:
                bad("DIVERGENCE CHANGED at a registered site %s\n"
                    "        pinned : %s\n"
                    "        now    : %s" % (ident, pinned, detail))
                print("      The register owns the OLD divergence, not this "
                      "one.  Something moved.  Repair the coupling, or "
                      "re-pin deliberately with a reason.")
                return
            STATE["debts"] += 1
            print("DEBT: %s -- %s" % (ident, detail))
            print("      known (%s): %s" % (ISSUE, row["why"]))
            print("      retired by: %s" % row["retires"])
            return
    bad("UNKNOWN DIVERGENCE %s -- %s" % (ident, detail))
    print("      This is new drift, not inventory.  Repair the coupling; do")
    print("      NOT add a DEBT_REGISTER row to silence it.")


# --------------------------------------------------------------------
# source access
# --------------------------------------------------------------------
ROOT = None


def read(rel):
    path = os.path.join(ROOT, rel)
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


# --------------------------------------------------------------------
# a very small Scheme reader: enough to find (field ... (default X))
# --------------------------------------------------------------------
def scheme_strip_comments(text):
    """Blank `;' comments, preserving every byte offset.

    Record fields carry long comment blocks that themselves contain
    parentheses and the word `default', so scanning the raw text finds
    prose instead of code."""
    if "#|" in text:
        raise ValueError("block comment (#|) present; this reader cannot "
                         "handle it -- extend it before trusting the gate")
    out = []
    i, n, in_string = 0, len(text), False
    while i < n:
        char = text[i]
        if in_string:
            if char == "\\" and i + 1 < n:
                out.append(text[i:i + 2])
                i += 2
                continue
            if char == '"':
                in_string = False
            out.append(char)
            i += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            i += 1
            continue
        if char == "#" and text[i:i + 2] == "#\\":
            out.append(text[i:i + 3])
            i += 3
            continue
        if char == ";":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        out.append(char)
        i += 1
    return "".join(out)


def sexp_at(text, start):
    """The balanced parenthesised form beginning at `start'."""
    depth, i, n, in_string = 0, start, len(text), False
    while i < n:
        char = text[i]
        if in_string:
            if char == "\\":
                i += 2
                continue
            if char == '"':
                in_string = False
            i += 1
            continue
        if char == '"':
            in_string = True
            i += 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    raise ValueError("unbalanced form at offset %d" % start)


def record_default(source, field):
    """The literal default of record field `field', or None if absent.

    Raises when the field is declared more than once with a default: an
    ambiguous site is a broken extractor, and a broken extractor must not
    look like agreement."""
    text = scheme_strip_comments(source)
    hits = []
    for match in re.finditer(r"\(\s*" + re.escape(field) + r"(?=[\s)])", text):
        form = sexp_at(text, match.start())
        inner = re.search(r"\(\s*default(?=[\s)])", form)
        if inner:
            hits.append(sexp_at(form, inner.start())[len("(default"):-1].strip())
    if len(hits) > 1:
        raise ValueError("field %s has %d defaults" % (field, len(hits)))
    return hits[0] if hits else None


def scheme_value(raw):
    """Normalise a Scheme literal to something comparable with Lua's."""
    if raw is None:
        return None
    text = " ".join(raw.split())
    if text == "#t":
        return True
    if text == "#f":
        return False
    if text == "'()":
        return []
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1].replace('\\"', '"')
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d+\.\d+", text):
        return float(text)
    return "scheme:" + text


# --------------------------------------------------------------------
# Lua `opt' tables
# --------------------------------------------------------------------
def lua_opt_defaults(source, path_for_errors):
    """The `local opt = { ... }' build-time defaults of a daemon."""
    lines = source.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(r"^local opt = \{\s*$", line):
            start = index
            break
    if start is None:
        raise ValueError("no `local opt = {' table in " + path_for_errors)
    values = {}
    for line in lines[start + 1:]:
        if line.strip() == "}":
            return values
        body = line.strip()
        if body.startswith("--"):
            continue
        for key, raw in re.findall(
                r"([A-Za-z_]\w*)\s*=\s*([^,]+?)\s*(?:,|$)", body):
            values[key] = lua_value(raw)
    raise ValueError("unterminated `opt' table in " + path_for_errors)


def lua_runtime_defaults(source, path_for_errors):
    """The `local runtime = { ... }' table: what a key means with no file.

    This is the twin of the record default for a knob that has no record
    field, and it is where "the same key name means opposite things in
    two conf files" becomes visible."""
    index = source.find("local runtime = {")
    if index < 0:
        raise ValueError("no `local runtime = {' table in " + path_for_errors)
    start = source.index("{", index)
    depth, end = 0, None
    for offset in range(start, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if depth == 0:
                end = offset
                break
    if end is None:
        raise ValueError("unterminated `runtime' table in " + path_for_errors)
    body = source[start + 1:end]
    return dict((key, lua_value(raw)) for key, raw in
                re.findall(r"([A-Za-z_]\w*)\s*=\s*([^,}]+)", body))


def lua_value(raw):
    text = raw.strip()
    if text == "true":
        return True
    if text == "false":
        return False
    if text == "nil":
        return None
    if text == "{}":
        return []
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1]
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d+\.\d+", text):
        return float(text)
    return "lua:" + text


# ====================================================================
# gate A -- a Guix record default equals its Lua `opt' twin
# ====================================================================
# (scm file, record field, lua file, opt key, transform)
# transform "same"    -- the two literals must be equal
#           "negated" -- the Lua twin states the opposite proposition
#                        (suspend-while-charging? vs charging_inhibits)
RECORD_DAEMON_PAIRS = [
    ("pinenote/services/autosuspend.scm", "idle-seconds",
     "pinenote/tools/power/autosuspend.lua", "idle", "same"),
    ("pinenote/services/autosuspend.scm", "backstop-seconds",
     "pinenote/tools/power/autosuspend.lua", "backstop", "same"),
    ("pinenote/services/autosuspend.scm", "overlay?",
     "pinenote/tools/power/autosuspend.lua", "overlay", "same"),
    ("pinenote/services/autosuspend.scm", "suspend-while-charging?",
     "pinenote/tools/power/autosuspend.lua", "charging_inhibits", "negated"),
    ("pinenote/services/autosuspend.scm", "config-file",
     "pinenote/tools/power/autosuspend.lua", "config", "same"),

    ("pinenote/services/ddr-boost.scm", "hold-seconds",
     "pinenote/tools/power/ddr-boost.lua", "hold", "same"),
    ("pinenote/services/ddr-boost.scm", "config-file",
     "pinenote/tools/power/ddr-boost.lua", "config", "same"),

    ("pinenote/services/timesync.scm", "servers",
     "pinenote/tools/timesync/timesync.lua", "servers", "same"),
    ("pinenote/services/timesync.scm", "poll-seconds",
     "pinenote/tools/timesync/timesync.lua", "poll", "same"),
    ("pinenote/services/timesync.scm", "refresh-seconds",
     "pinenote/tools/timesync/timesync.lua", "refresh", "same"),
    ("pinenote/services/timesync.scm", "timeout-seconds",
     "pinenote/tools/timesync/timesync.lua", "timeout", "same"),
    ("pinenote/services/timesync.scm", "max-backoff-seconds",
     "pinenote/tools/timesync/timesync.lua", "max_backoff", "same"),
    ("pinenote/services/timesync.scm", "not-before",
     "pinenote/tools/timesync/timesync.lua", "not_before", "same"),
    ("pinenote/services/timesync.scm", "horizon-seconds",
     "pinenote/tools/timesync/timesync.lua", "horizon", "same"),
    ("pinenote/services/timesync.scm", "hwclock",
     "pinenote/tools/timesync/timesync.lua", "hwclock", "same"),
]


def gate_record_vs_daemon():
    lua_cache = {}
    for scm_path, field, lua_path, key, transform in RECORD_DAEMON_PAIRS:
        name = "%s:%s" % (os.path.basename(scm_path), field)
        try:
            raw = record_default(read(scm_path), field)
        except ValueError as exc:
            bad("site not found -- %s: %s" % (name, exc))
            continue
        if raw is None:
            bad("site not found -- %s declares no (default ...); the pair "
                "table in this gate is stale" % name)
            continue
        if lua_path not in lua_cache:
            try:
                lua_cache[lua_path] = lua_opt_defaults(read(lua_path), lua_path)
            except ValueError as exc:
                bad("site not found -- %s" % exc)
                lua_cache[lua_path] = {}
        opts = lua_cache[lua_path]
        if key not in opts:
            bad("site not found -- %s has no opt.%s; the pair table in this "
                "gate is stale" % (os.path.basename(lua_path), key))
            continue
        scm_val = scheme_value(raw)
        lua_val = opts[key]
        want = (not lua_val) if transform == "negated" else lua_val
        if scm_val == want:
            ok("%s == opt.%s (%r%s)"
               % (name, key, scm_val,
                  ", via the negated twin" if transform == "negated" else ""))
        else:
            divergence("record-vs-daemon:%s" % name,
                       "record %r vs opt.%s %r%s"
                       % (scm_val, key, lua_val,
                          " (compared negated)"
                          if transform == "negated" else ""))


# ====================================================================
# gate B -- the shipped rockchip_ebc parameter set has three copies
# ====================================================================
EBC_PARAM_SITES = [
    ("ebc.scm modprobe options", "pinenote/services/ebc.scm"),
    ("firmware.scm set_parameter script", "pinenote/packages/firmware.scm"),
    ("firmware.scm modprobe options", "pinenote/packages/firmware.scm"),
]


def modprobe_options(source, path_for_errors):
    """Every `options rockchip_ebc k=v ...' line, as one dict per line."""
    found = []
    for match in re.finditer(r"options rockchip_ebc ([^\\\"\n]+)", source):
        found.append(dict(
            (k, v) for k, v in re.findall(r"(\w+)=(\S+)", match.group(1))))
    if not found:
        raise ValueError("no `options rockchip_ebc' line in "
                         + path_for_errors)
    return found


def set_parameter_options(source, path_for_errors):
    found = dict(re.findall(r'set_parameter (\w+) (\S+?)\\n', source))
    if not found:
        raise ValueError("no `set_parameter' lines in " + path_for_errors)
    return found


def gate_ebc_params():
    copies = {}
    try:
        ebc = modprobe_options(read("pinenote/services/ebc.scm"),
                               "pinenote/services/ebc.scm")
        if len(ebc) != 1:
            bad("site not found -- ebc.scm carries %d `options rockchip_ebc' "
                "lines, expected exactly 1" % len(ebc))
        copies["ebc.scm modprobe options"] = ebc[0]
        firmware = read("pinenote/packages/firmware.scm")
        fw_modprobe = modprobe_options(firmware,
                                       "pinenote/packages/firmware.scm")
        if len(fw_modprobe) != 1:
            bad("site not found -- firmware.scm carries %d `options "
                "rockchip_ebc' lines, expected exactly 1" % len(fw_modprobe))
        copies["firmware.scm modprobe options"] = fw_modprobe[0]
        copies["firmware.scm set_parameter script"] = set_parameter_options(
            firmware, "pinenote/packages/firmware.scm")
    except ValueError as exc:
        bad("site not found -- %s" % exc)
        return None

    # A floor, not the count: a dropped parameter is a real divergence the
    # key-set comparison below must be allowed to report.  Two or fewer
    # means the extractor stopped working, which is a different failure.
    for label, values in copies.items():
        if len(values) < 3:
            bad("site not found -- %s yielded only %d parameters; the "
                "extractor is broken, not the tree" % (label, len(values)))
            return None

    reference_label = "ebc.scm modprobe options"
    reference = copies[reference_label]
    agreed = True
    for label, values in copies.items():
        if label == reference_label:
            continue
        if set(values) != set(reference):
            agreed = False
            divergence("ebc-params:keyset",
                       "%s has keys %s; %s has %s"
                       % (label, sorted(values), reference_label,
                          sorted(reference)))
            continue
        for key in sorted(reference):
            if values[key] != reference[key]:
                agreed = False
                divergence("ebc-params:%s" % key,
                           "%s says %s=%s; %s says %s=%s"
                           % (label, key, values[key], reference_label,
                              key, reference[key]))
    if agreed:
        ok("all %d shipped rockchip_ebc parameters agree across the %d "
           "build-time copies (%s)"
           % (len(reference), len(copies), ", ".join(sorted(copies))))
    return reference


# ====================================================================
# gate B2 -- the shipped waveform value, and the GC16 wash transient,
#            are literals in several runtime self-heal paths
# ====================================================================
def gate_waveform_literals(shipped):
    if shipped is None:
        bad("site not found -- no shipped parameter set, so the waveform "
            "literals cannot be checked")
        return
    want = shipped.get("refresh_waveform")
    if want is None:
        bad("site not found -- the shipped parameter set has no "
            "refresh_waveform")
        return

    sites = []

    match = re.search(r'local WAVEFORM_SHIPPED = "(\d+)"',
                      read("pinenote/tools/power/autosuspend.lua"))
    sites.append(("autosuspend.lua WAVEFORM_SHIPPED",
                  match.group(1) if match else None))

    match = re.search(r"if prior == '4' then prior = '(\d+)' end",
                      read("pinenote/services/reader-session.scm"))
    sites.append(("reader-session.scm %panel-blank-lua self-heal",
                  match.group(1) if match else None))

    # TWO assertions in that script encode the shipped value -- the boot
    # milestone grep and the named requirement.  Checking only the first
    # would leave the other free to drift.
    virtchk = re.findall(r"VIRTCHK-WF-(\d+)'",
                         read("pinenote/scripts/qemu/run-virt-assertions.sh"))
    if len(virtchk) != 2:
        bad("site not found -- run-virt-assertions.sh carries %d shipped-"
            "waveform assertions, expected 2" % len(virtchk))
    for index, value in enumerate(virtchk):
        sites.append(("run-virt-assertions.sh boot assertion %d" % (index + 1),
                      value))

    for label, value in sites:
        if value is None:
            bad("site not found -- %s: the shipped-waveform literal moved or "
                "changed shape" % label)
        elif value != want:
            divergence("waveform-literal:%s" % label,
                       "%s says %s; the shipped parameter set says "
                       "refresh_waveform=%s" % (label, value, want))
        else:
            ok("%s restores the shipped refresh_waveform=%s" % (label, want))

    # The GC16 wash transient: three processes flip the waveform to it and
    # back, coordinated by nothing but this constant agreeing.
    transients = [
        ("autosuspend.lua cleanup_wash",
         re.search(r'if saved == "(\d+)" then saved = WAVEFORM_SHIPPED',
                   read("pinenote/tools/power/autosuspend.lua"))),
        ("reader-session.scm %panel-blank-lua",
         re.search(r"if prior == '(\d+)' then prior = '\d+' end",
                   read("pinenote/services/reader-session.scm"))),
        ("idlewasher.koplugin deep clean",
         re.search(r'GC16 = "(\d+)"',
                   read("pinenote/packages/koreader-device/plugins/"
                        "idlewasher.koplugin/main.lua"))),
    ]
    values = {}
    for label, match in transients:
        if match is None:
            bad("site not found -- %s: the GC16 transient literal moved or "
                "changed shape" % label)
        else:
            values[label] = match.group(1)
    if len(values) == len(transients):
        distinct = set(values.values())
        if len(distinct) == 1:
            ok("the three concurrent refresh_waveform writers agree that the "
               "GC16 wash transient is %s (%s)"
               % (distinct.pop(), ", ".join(sorted(values))))
        else:
            for label, value in sorted(values.items()):
                divergence("waveform-transient:%s" % label,
                           "%s uses GC16=%s" % (label, value))


# ====================================================================
# gate C -- the two KOReader seeds
# ====================================================================
# The two-KOReader-seed comparison that used to live here is GONE, not
# broken.  #12 step 2 collapsed the two seeds into one record-generated
# service, so its subject no longer exists -- and the successor property
# (exactly one writer of settings.reader.lua) is pinned better by
# `make koreader-profile-check', whose writer scan carries a positive
# control: it finds 2 planted writers and 0 in a clean tree.  Repointing
# this gate at the record would have duplicated that with no control.
#
# It failed loudly on removal ("site not found") rather than passing
# vacuously, which is the behaviour this file's VACUITY note promises.

def waveform_enum():
    """DRM_EPD_WF_* -> integer, read out of the forward-port patch."""
    patch = read("pinenote/patches/linux-pinenote-7.0-forward-port.patch")
    match = re.search(r"\+enum drm_epd_waveform \{\n((?:\+\s*DRM_EPD_WF_\w+,\n)+)",
                      patch)
    if not match:
        raise ValueError("no `enum drm_epd_waveform' in the forward-port patch")
    names = re.findall(r"DRM_EPD_WF_(\w+)", match.group(1))
    return dict((name, index) for index, name in enumerate(names))


def gate_host_model(shipped):
    if shipped is None:
        bad("site not found -- no shipped parameter set to compare the host "
            "model against")
        return
    try:
        enum = waveform_enum()
    except ValueError as exc:
        bad("site not found -- %s" % exc)
        return
    if enum.get("GC16") is None or enum.get("GL16") is None:
        bad("site not found -- the waveform enum lacks GC16/GL16")
        return
    ok("the waveform enum decodes from the forward-port patch (GC16=%d, "
       "GL16=%d)" % (enum["GC16"], enum["GL16"]))

    replay = read("pinenote/tools/ebc-logic/ebc-replay.c")
    body = re.search(r"static void policy_ship\(struct policy \*p\)\n\{(.*?)\n\}",
                     replay, re.S)
    if not body:
        bad("site not found -- no policy_ship() in ebc-replay.c")
        return
    assigned = dict(re.findall(r"p->(\w+)\s*=\s*([^;]+);", body.group(1)))
    if "memset(p, 0, sizeof(*p))" not in body.group(1):
        bad("site not found -- policy_ship() no longer zeroes the policy, so "
            "an unassigned field is not 0 and this gate would lie")
        return
    if len(assigned) < 6:
        bad("site not found -- policy_ship() yielded %d assignments; the "
            "extractor is broken, not the tree" % len(assigned))
        return

    def modelled(field, default="0"):
        return assigned.get(field, default).strip()

    # (id suffix, what the model says, what the tree ships, human label)
    comparisons = [
        ("auto_refresh",
         "1" if modelled("auto_refresh") == "true" else "0",
         shipped.get("auto_refresh"),
         "driver auto-wash"),
        ("refresh_threshold", modelled("refresh_threshold"),
         shipped.get("refresh_threshold"), "driver accumulator threshold"),
        ("split_area_limit", modelled("split_area_limit"),
         shipped.get("split_area_limit"), "scheduler splits per call"),
        ("refresh_wf",
         str(enum.get(modelled("refresh_wf").replace("DRM_EPD_WF_", ""), "?")),
         shipped.get("refresh_waveform"), "global waveform"),
        ("defio_delay_ms", modelled("defio_delay_ms"),
         shipped.get("defio_delay_ms"), "deferred-io flush window"),
    ]
    for field, model_value, shipped_value, label in comparisons:
        if shipped_value is None:
            bad("site not found -- the shipped parameter set has no twin for "
                "policy_ship()'s %s" % field)
            continue
        if model_value == shipped_value:
            ok("policy_ship() models the shipped %s (%s=%s)"
               % (label, field, shipped_value))
        else:
            divergence("host-model:policy_ship:%s" % field,
                       "policy_ship() models %s=%s; the shipped parameters say "
                       "%s" % (field, model_value, shipped_value))

    # The same file TELLS the operator what the device does.  A stale
    # number in the usage banner misleads exactly the person reaching for
    # the tool to reason about the device.
    banner = re.search(r"the device is\s+\*?\s*~(\d+) ms", replay)
    if not banner:
        bad("site not found -- ebc-replay.c's usage banner no longer states a "
            "device deferred-io delay")
    elif banner.group(1) != shipped.get("defio_delay_ms"):
        divergence("host-model:banner:defio_delay_ms",
                   "the usage banner says the device is ~%s ms; the shipped "
                   "parameters say defio_delay_ms=%s"
                   % (banner.group(1), shipped.get("defio_delay_ms")))
    else:
        ok("ebc-replay.c's usage banner quotes the shipped defio_delay_ms")

    # flash_area_fraction: KOReader-layer default, mirrored by the model.
    device_lua = re.search(r"local flash_area_fraction = ([\d.]+)",
                           read("pinenote/packages/koreader-device/frontend/"
                                "device/pinenote/device.lua"))
    model_frac = modelled("flash_frac", "")
    if not device_lua:
        bad("site not found -- device.lua no longer declares "
            "flash_area_fraction")
    elif not model_frac:
        bad("site not found -- policy_ship() no longer sets flash_frac")
    elif float(device_lua.group(1)) != float(model_frac):
        divergence("host-model:policy_ship:flash_frac",
                   "policy_ship() models flash_frac=%s; device.lua defaults to "
                   "%s" % (model_frac, device_lua.group(1)))
    else:
        ok("policy_ship() models device.lua's flash_area_fraction (%s)"
           % model_frac)


# ====================================================================
# gate E/F -- runtime .conf keys: grammar, defaults, and whether a Guix
#             record can express them at all
# ====================================================================
# The canonical boolean grammar.  This is NOT a decision about which
# grammar should win -- #12 decides that.  It is a fixed reference point
# so the register names the same keys on every run instead of flipping
# with whichever grammar happens to be in the majority.
CANONICAL_BOOL_GRAMMAR = "denylist"

DENYLIST = 'not (v == "0" or v == "false" or v == "no")'
ALLOWLIST = '(v == "1" or v == "true" or v == "yes")'

# conf key -> the record field that declares its default, or None when
# the knob is unexpressible in a system declaration.  A key parsed by a
# daemon and absent from this table is a FAIL: a new runtime knob has to
# say where its default lives.
EXPECT_ABSENT = "expect-absent"

CONF_KEY_FIELDS = {
    ("autosuspend.lua", "idle"):
        ("pinenote/services/autosuspend.scm", "idle-seconds"),
    ("autosuspend.lua", "backstop"):
        ("pinenote/services/autosuspend.scm", "backstop-seconds"),
    ("autosuspend.lua", "suspend_while_charging"):
        ("pinenote/services/autosuspend.scm", "suspend-while-charging?"),
    # EXPECT_ABSENT: the knob has no record field TODAY.  Naming the file
    # and the field #12 step 4 is expected to add makes this an
    # observation instead of a restatement -- when the field appears, the
    # row retires itself with "stale debt-register entry" instead of the
    # gate going on printing a sentence that has become false.
    ("autosuspend.lua", "enabled"):
        ("pinenote/services/autosuspend.scm", "enabled?", EXPECT_ABSENT),
    ("autosuspend.lua", "power_key"):
        ("pinenote/services/autosuspend.scm", "power-key-suspends?",
         EXPECT_ABSENT),
    ("ddr-boost.lua", "hold"):
        ("pinenote/services/ddr-boost.scm", "hold-seconds"),
    ("ddr-boost.lua", "enabled"):
        ("pinenote/services/ddr-boost.scm", "enabled?", EXPECT_ABSENT),
    ("dmc.scm", "mode"):
        ("pinenote/services/dmc.scm", "mode", EXPECT_ABSENT),
}

LUA_CONF_PARSERS = [
    ("autosuspend.lua", "pinenote/tools/power/autosuspend.lua",
     r"local function parse_config\(path\)(.*?)\n    f:close\(\)"),
    ("ddr-boost.lua", "pinenote/tools/power/ddr-boost.lua",
     r"local function reload_config\(\)(.*?)\n    f:close\(\)"),
]


def gate_conf_keys():
    parsed = {}          # (file, key) -> grammar or "value"
    defaults = {}        # (file, key) -> default, for boolean keys

    for label, path, pattern in LUA_CONF_PARSERS:
        source = read(path)
        body = re.search(pattern, source, re.S)
        if not body:
            bad("site not found -- no runtime config parser in %s" % label)
            continue
        keys = re.findall(r'k == "(\w+)" (?:and .*?)?then\s*\n?\s*'
                          r'runtime\.\w+ = ([^\n]+)', body.group(1))
        if not keys:
            bad("site not found -- %s's parser yielded no keys" % label)
            continue
        if '^%s*' not in body.group(1):
            bad("site not found -- %s's parser no longer skips leading "
                "whitespace, so the dmc comparison below is meaningless"
                % label)
        for key, expression in keys:
            text = " ".join(expression.split())
            if text.startswith(DENYLIST):
                parsed[(label, key)] = "denylist"
            elif text.startswith(ALLOWLIST):
                parsed[(label, key)] = "allowlist"
            else:
                parsed[(label, key)] = "value"
        try:
            runtime_defaults = lua_runtime_defaults(source, label)
        except ValueError as exc:
            bad("site not found -- %s" % exc)
            runtime_defaults = {}
        for key, value in runtime_defaults.items():
            if (label, key) in parsed:
                defaults[(label, key)] = value

    # The persistent override layer.  autosuspend reads /data FIRST and
    # /var/lib second (so the volatile file wins for same-boot changes);
    # dmc reads /data only.  Both paths are bare constants, and the /data
    # one is the layer every operator-facing document points at.
    persistent = re.search(r'local persistent_config = "([^"]+)"',
                           read("pinenote/tools/power/autosuspend.lua"))
    mode_file = re.search(r'\(define %mode-file "([^"]+)"\)',
                          read("pinenote/services/dmc.scm"))
    if not persistent:
        bad("site not found -- autosuspend.lua no longer names a persistent "
            "config path")
    elif not mode_file:
        bad("site not found -- dmc.scm no longer names its %mode-file")
    else:
        directories = set(os.path.dirname(match.group(1))
                          for match in (persistent, mode_file))
        if len(directories) == 1:
            ok("the persistent override files share one directory (%s)"
               % directories.pop())
        else:
            divergence("override-directory",
                       "the persistent override files live in %s"
                       % ", ".join(sorted(directories)))
        divergence("no-record-field:autosuspend.lua:persistent-config",
                   "%s is read before the record's config-file and no record "
                   "field declares it" % persistent.group(1))

    # dmc's selector is Scheme, not Lua, and is a third grammar again.
    dmc = read("pinenote/services/dmc.scm")
    if '(string-prefix? "mode=" line)' in dmc:
        parsed[("dmc.scm", "mode")] = "value"
        divergence("conf-parser-whitespace:dmc.scm:mode",
                   "the mode= selector tests the raw line with string-prefix?, "
                   "so it rejects the leading whitespace every Lua parser here "
                   "accepts")
    else:
        bad("site not found -- dmc.scm's mode= selector moved or changed "
            "shape; re-derive its grammar before trusting this gate")

    if len(parsed) < 6:
        bad("site not found -- only %d runtime conf keys located; the "
            "extractor is broken, not the tree" % len(parsed))
        return

    # E: one grammar for booleans
    for (label, key), grammar in sorted(parsed.items()):
        if grammar == "value":
            continue
        if grammar != CANONICAL_BOOL_GRAMMAR:
            divergence("conf-grammar:%s:%s" % (label, key),
                       "%s parses %s with an %s while the reference grammar in "
                       "this tree is a %s" % (label, key, grammar,
                                              CANONICAL_BOOL_GRAMMAR))
        else:
            ok("%s parses %s with the reference %s grammar"
               % (label, key, grammar))

    # E2: one key name must not mean two things
    by_key = {}
    for (label, key) in parsed:
        by_key.setdefault(key, []).append(label)
    for key, labels in sorted(by_key.items()):
        if len(labels) < 2:
            continue
        seen_defaults = set(defaults.get((label, key)) for label in labels)
        if len(seen_defaults) > 1 or None in seen_defaults:
            divergence("conf-key-default:%s" % key,
                       "the key %s is parsed in %s with defaults %s"
                       % (key, ", ".join(sorted(labels)),
                          ", ".join(sorted(str(d) for d in seen_defaults))))
        else:
            ok("the key %s means the same thing in %s"
               % (key, ", ".join(sorted(labels))))

    # F: can a system declaration express this knob at all?
    for (label, key) in sorted(parsed):
        if (label, key) not in CONF_KEY_FIELDS:
            bad("undeclared runtime knob %s:%s -- a new .conf key must say "
                "where its default is declared (add it to CONF_KEY_FIELDS)"
                % (label, key))
            continue
        target = CONF_KEY_FIELDS[(label, key)]
        if len(target) == 3 and target[2] is EXPECT_ABSENT:
            # OBSERVED, not restated.  Look for the field #12 step 4 is
            # expected to add.  Absent -> the divergence is real, report it
            # as debt.  PRESENT -> the debt was paid and the row is stale,
            # which must FAIL: otherwise the gate keeps printing "no record
            # field declares it" after one does.
            scm_path, field, _ = target
            try:
                raw = record_default(read(scm_path), field)
            except ValueError as exc:
                bad("site not found -- %s: %s" % (field, exc))
                continue
            if raw is None:
                divergence("no-record-field:%s:%s" % (label, key),
                           "%s is settable at runtime but no Guix record "
                           "field declares it, so an image cannot ship a "
                           "value for it" % key)
            else:
                bad("stale debt-register entry: no-record-field:%s:%s -- %s "
                    "now declares %s (%s).  The debt is paid; delete the "
                    "DEBT_REGISTER row and the EXPECT_ABSENT marker."
                    % (label, key, scm_path, field, " ".join(raw.split())))
            continue
        scm_path, field = target
        try:
            raw = record_default(read(scm_path), field)
        except ValueError as exc:
            bad("site not found -- %s: %s" % (field, exc))
            continue
        if raw is None:
            bad("site not found -- %s:%s claims to be declared by %s, which "
                "has no such field" % (label, key, field))
        else:
            ok("%s:%s has its default declared by %s (%s)"
               % (label, key, field, " ".join(raw.split())))


# ====================================================================
def main():
    global ROOT
    ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     os.pardir, os.pardir, os.pardir))
    print("settings-check: %s" % ROOT)
    print()

    gate_record_vs_daemon()
    shipped = gate_ebc_params()
    gate_waveform_literals(shipped)
    gate_host_model(shipped)
    gate_conf_keys()

    # The register can only shrink: a row that no longer describes the
    # tree is a row somebody paid off and forgot to delete.
    for row in DEBT_REGISTER:
        if row["id"] not in STATE["seen"]:
            bad("stale debt-register entry %s -- that divergence is gone from "
                "the tree.  Delete the row; the register is inventory, not "
                "configuration" % row["id"])

    print()
    print("settings-check: %d passed, %d known divergences (%s), %d failed"
          % (STATE["passes"], STATE["debts"], ISSUE, STATE["fails"]))
    if STATE["debts"]:
        print("settings-check: the %d divergences above are pinned inventory, "
              "not approval -- each one is a #12 step that has not landed"
              % STATE["debts"])
    return 1 if STATE["fails"] else 0


if __name__ == "__main__":
    sys.exit(main())
