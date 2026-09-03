#!/usr/bin/env python3
"""Gate the two rockchip_ebc modprobe option sets against the two drivers.

Offline ladder rung 1 (`doc/testing.md`): text analysis of the patches
and the service sources, python3 stdlib only, no device.  ONE step is
not text -- it runs `guix repl` to load the new Scheme module, because
nothing in the tree imports it yet and no build would compile it.  That
step SKIPS, loudly, where guix is absent (CI), and a run without it has
evaluated no Scheme at all.

WHY THIS EXISTS
===============
We now carry two `rockchip_ebc` drivers:

  * ours -- `pinenote/patches/linux-pinenote-7.0-forward-port.patch`, the
    m-weigand lineage, shipping;
  * hrdl's direct-mode driver -- the same file rewritten by
    `pinenote/patches/linux-pinenote-7.1-hrdl-direct-mode.patch`, built
    only as `linux-pinenote-hrdl-direct` and reaching no image.

Their module parameters barely overlap, and the kernel does NOT protect
you from that.  `unknown_module_param_cb()` (7.1.8,
`kernel/module/main.c:3366`) `pr_warn`s "unknown parameter '%s' ignored"
and **returns 0**: an options line naming parameters a module does not
register loads FINE, minus every intent it encoded.  A silent partial
application is worse than a refusal, and nothing else in the tree would
catch it.

WHAT IT ASSERTS
===============
  1. the shipping options text is byte-for-byte what it was (a sha256
     pin, so a deliberate change has to be re-verified against the
     reader system derivation rather than drift in);
  2. every parameter the shipping options name is registered by OUR
     driver;
  3. every parameter the direct-mode options name is registered by
     HRDL's driver;
  4. POSITIVE CONTROL for 3: the shipping options, checked against
     hrdl's driver, must be REJECTED -- because the direct-mode options
     currently name no parameters at all, and a check over an empty set
     passes whether or not it works;
  5. the derived parameter sets are non-empty and have the exact
     membership the derivation predicts, including two traps described
     below;
  6. no shipping flavor imports the direct-mode module;
  7. that module actually loads, and the values Guile sees are the ones
     this gate parsed out of the text (needs guix; skips without it).

THE TWO TRAPS THE DERIVATION HAS TO GET RIGHT
=============================================
  * `modinfo -p` is the WRONG oracle.  It prints `parm` modinfo tags,
    which come from `MODULE_PARM_DESC`, and hrdl's driver has
    `MODULE_PARM_DESC(split_area_limit, ...)` sitting on top of
    `module_param(limit_fb_blits, ...)` -- a stale description left over
    from a rename.  So `modinfo -p` advertises a `split_area_limit` the
    module does not accept and hides the `limit_fb_blits` it does.  The
    parameters a module actually takes are the `module_param*()`
    registrations, which is what this gate reads.
  * `module_param_cb()` does NOT emit a `parmtype` tag either, and our
    `defio_delay_ms` -- the hardware-proven 250 ms deferred-io window --
    is registered exactly that way.  A `parmtype`-based derivation would
    call our own shipping options invalid.

Both are pinned as membership assertions below, so a future rewrite of
the extractor that reintroduces either goes red.
"""

import hashlib
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

FORWARD_PORT = "pinenote/patches/linux-pinenote-7.0-forward-port.patch"
DIRECT_MODE = "pinenote/patches/linux-pinenote-7.1-hrdl-direct-mode.patch"
DRIVER_PATH = "drivers/gpu/drm/rockchip/rockchip_ebc.c"
DEFCONFIG_PATH = "arch/arm64/configs/pinenote_defconfig"
EBC_SCM = "pinenote/services/ebc.scm"
EBC_DIRECT_SCM = "pinenote/services/ebc-direct.scm"

# The shipping options string, as a tripwire rather than a fourth copy of
# the value (`doc/configuration.md` sec. 7: one setting, one declaration
# site).  Changing the shipping options is allowed -- it is a deliberate
# act that has to update this pin AND re-verify that the reader system
# derivation moved for a reason.
SHIPPING_OPTIONS_SHA256 = \
    "6a348e86210480d097601d24a2b42d968734cba02b816e6ba6c061693534e3e6"

# Config symbols that guard a module_param in either driver.  A guard
# symbol that is NOT in the relevant table is a hard failure, never a
# silent "assume off": that is the whole point of gating on this rather
# than grepping.
#
# CONFIG_DRM_FBDEV_EMULATION -- `default y` in mainline's drm/Kconfig and
#   never disabled in pinenote_defconfig (asserted below).  The device
#   proof is stronger than the config proof: defio_delay_ms=250 is read
#   back from sysfs on every boot by pinenote-apply-ebc-params, and the
#   2026-08-01 page-turn result depended on it taking effect.
#
# CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE -- exists only in hrdl's tree, is a
#   `bool` with no `default` line, and appears in no defconfig, so
#   olddefconfig lands it OFF (both facts asserted below; the P2 build
#   log agrees).  It is also the config whose `#ifdef` body does not
#   compile at all -- an unbalanced paren in rockchip_ebc_blit_neon.c,
#   `doc/upstream-register.md` item 15 -- so OFF is the only buildable
#   answer, not merely the default one.
OUR_CONFIG = {
    "CONFIG_DRM_FBDEV_EMULATION": True,
}
HRDL_CONFIG = {
    "CONFIG_DRM_FBDEV_EMULATION": True,
    "CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE": False,
}

FAILURES = []
CHECKS = 0


def ok(message):
    global CHECKS
    CHECKS += 1
    print("PASS: %s" % message)


def bad(message):
    global CHECKS
    CHECKS += 1
    FAILURES.append(message)
    print("FAIL: %s" % message)


def read(relative):
    return (ROOT / relative).read_text()


# ====================================================================
# patch -> driver source
# ====================================================================
def load_extractor():
    """Reuse the wbf tool's new-file extractor rather than copying it."""
    path = ROOT / "pinenote/tools/wbf/extract-from-patch.py"
    if not path.exists():
        raise SystemExit("extract-from-patch.py is missing at %s -- this "
                         "gate reuses it deliberately; do not re-implement "
                         "it here" % path)
    spec = importlib.util.spec_from_file_location("extract_from_patch", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def section_hunks(patch_text, path):
    """Every hunk of `patch_text' that targets `path', in order.

    Hunk bodies are consumed by their advertised line counts rather than
    by looking for the next header, so a removed line that happens to
    start with `---' cannot end the section early.
    """
    marker = "+++ b/" + path
    if marker not in patch_text:
        raise ValueError("%s: no `%s' in the patch" % (path, marker))
    lines = patch_text[patch_text.index(marker):].splitlines()[1:]
    hunks = []
    index = 0
    while index < len(lines):
        match = HUNK_RE.match(lines[index])
        if match is None:
            break
        old_start = int(match.group(1))
        old_count = int(match.group(2)) if match.group(2) else 1
        new_count = int(match.group(4)) if match.group(4) else 1
        index += 1
        body = []
        seen_old = seen_new = 0
        while index < len(lines) and (seen_old < old_count
                                      or seen_new < new_count):
            line = lines[index]
            index += 1
            if line.startswith("\\"):
                continue            # "\ No newline at end of file"
            if line.startswith("-"):
                seen_old += 1
            elif line.startswith("+"):
                seen_new += 1
            elif line.startswith(" ") or line == "":
                seen_old += 1
                seen_new += 1
            else:
                raise ValueError("%s: unparsable hunk line %r" % (path, line))
            body.append(line)
        if seen_old != old_count or seen_new != new_count:
            raise ValueError("%s: hunk @@ -%d advertises %d/%d lines, got "
                             "%d/%d" % (path, old_start, old_count,
                                        new_count, seen_old, seen_new))
        hunks.append((old_start, body))
    if not hunks:
        raise ValueError("%s: no hunks after %r" % (path, marker))
    return hunks


def apply_hunks(pre_lines, hunks, path):
    """Apply `hunks' to `pre_lines', verifying every context line.

    A context mismatch means the direct-mode patch no longer applies to
    the forward-ported file, which is a rebase break worth failing on.
    """
    out = []
    cursor = 0
    for old_start, body in hunks:
        start = old_start - 1
        if start < cursor:
            raise ValueError("%s: hunks are out of order at line %d"
                             % (path, old_start))
        out.extend(pre_lines[cursor:start])
        cursor = start
        for line in body:
            kind, text = (line[0], line[1:]) if line else (" ", "")
            if kind in (" ", "-"):
                if cursor >= len(pre_lines) or pre_lines[cursor] != text:
                    have = pre_lines[cursor] if cursor < len(pre_lines) \
                        else "<eof>"
                    raise ValueError(
                        "%s: hunk at %d does not apply: expected %r, "
                        "found %r" % (path, old_start, text, have))
                cursor += 1
                if kind == " ":
                    out.append(text)
            else:
                out.append(text)
    out.extend(pre_lines[cursor:])
    return out


# ====================================================================
# driver source -> registered parameter names
# ====================================================================
PARAM_RE = re.compile(
    r"^\s*module_param(?:_named|_cb|_array|_string|_hw|_hw_named|_call)?"
    r"\s*\(\s*(\w+)")
IFDEF_RE = re.compile(r"^\s*#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)$")
DEFINED_RE = re.compile(
    r"^\s*(!)?\s*defined\s*(?:\(\s*(\w+)\s*\)|(\w+))\s*$")


class UnsupportedGuard(Exception):
    pass


def parse_condition(directive, rest):
    """(symbol, wanted) for the guard forms we accept; None means bare."""
    rest = rest.split("/*")[0].split("//")[0].strip()
    if directive == "ifdef":
        return (rest, True)
    if directive == "ifndef":
        return (rest, False)
    match = DEFINED_RE.match(rest)
    if match is None:
        raise UnsupportedGuard("#%s %s" % (directive, rest))
    symbol = match.group(2) or match.group(3)
    return (symbol, match.group(1) is None)


def registered_params(source, config, label):
    """Parameter names a build with `config' actually registers.

    Guard resolution is fail-closed in both directions: an unsupported
    `#if' expression or an unknown CONFIG symbol around a module_param
    raises rather than being assumed true or false.
    """
    stack = []          # list of (active: bool|None, unsupported: str|None)
    found = []
    for line in source.splitlines():
        directive = IFDEF_RE.match(line)
        if directive is not None:
            name, rest = directive.group(1), directive.group(2)
            if name == "endif":
                if stack:
                    stack.pop()
                continue
            if name == "else":
                if stack:
                    active, unsupported = stack[-1]
                    stack[-1] = (None if active is None else not active,
                                 unsupported)
                continue
            if name == "elif":
                if stack:
                    stack[-1] = (None, "#elif")
                continue
            try:
                symbol, wanted = parse_condition(name, rest)
            except UnsupportedGuard as exc:
                stack.append((None, str(exc)))
                continue
            if not symbol.startswith("CONFIG_") or symbol not in config:
                stack.append((None, symbol))
                continue
            stack.append((config[symbol] == wanted, None))
            continue

        param = PARAM_RE.match(line)
        if param is None:
            continue
        for active, unsupported in stack:
            if unsupported is not None:
                raise UnsupportedGuard(
                    "%s: module_param(%s) sits under a guard this gate "
                    "cannot resolve (%s).  Teach it the symbol or the "
                    "form -- do not assume."
                    % (label, param.group(1), unsupported))
        if all(active for active, _ in stack):
            found.append(param.group(1))
    if len(found) != len(set(found)):
        raise ValueError("%s: duplicate module_param registrations: %s"
                         % (label, sorted(found)))
    return set(found)


# ====================================================================
# service sources -> options strings
# ====================================================================
def scheme_string(source, define_name, path_for_errors):
    """The one string literal bound by `(define <define_name> "...")'."""
    anchor = "(define %s\n" % define_name
    if source.count(anchor) != 1:
        raise ValueError("%s: expected exactly one `%s' definition, found %d"
                         % (path_for_errors, define_name,
                            source.count(anchor)))
    index = source.index(anchor)
    index = source.index('"', index)
    out = []
    index += 1
    escapes = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}
    while True:
        char = source[index]
        if char == "\\":
            following = source[index + 1]
            if following not in escapes:
                raise ValueError("%s: unsupported escape \\%s in %s"
                                 % (path_for_errors, following, define_name))
            out.append(escapes[following])
            index += 2
            continue
        if char == '"':
            return "".join(out)
        out.append(char)
        index += 1


def options_parameters(text):
    """{name: value} from every `options rockchip_ebc ...' line."""
    params = {}
    for line in text.splitlines():
        if not line.startswith("options rockchip_ebc "):
            continue
        for name, value in re.findall(r"(\w+)=(\S+)",
                                      line[len("options rockchip_ebc "):]):
            params[name] = value
    return params


# ====================================================================
# the gate
# ====================================================================
def build_driver_sources():
    extractor = load_extractor()
    forward_port = read(FORWARD_PORT)
    ours = extractor.extract(forward_port, DRIVER_PATH)
    direct = read(DIRECT_MODE)
    hunks = section_hunks(direct, DRIVER_PATH)
    hrdl = "\n".join(apply_hunks(ours.splitlines(), hunks, DRIVER_PATH)) + "\n"
    return ours, hrdl, extractor.extract(forward_port, DEFCONFIG_PATH), direct


def gate_config_derivation(defconfig, direct_patch):
    """Derive the two config answers instead of only asserting them."""
    if re.search(r"^CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE=y",
                 defconfig, re.MULTILINE):
        bad("pinenote_defconfig enables CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE, "
            "which does not compile (unbalanced paren in "
            "rockchip_ebc_blit_neon.c, upstream-register item 15)")
    else:
        ok("CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE is absent from "
           "pinenote_defconfig")

    block = re.search(
        r"^\+config DRM_ROCKCHIP_EBC_3WIN_MODE\n((?:^\+.*\n)+)",
        direct_patch, re.MULTILINE)
    if block is None:
        bad("the direct-mode patch no longer adds a "
            "DRM_ROCKCHIP_EBC_3WIN_MODE Kconfig entry -- the derivation "
            "that it defaults to n has lost its subject")
    elif re.search(r"^\+\s*default\b", block.group(1), re.MULTILINE):
        bad("DRM_ROCKCHIP_EBC_3WIN_MODE now carries a `default' line, so "
            "absence from the defconfig no longer means off")
    else:
        ok("DRM_ROCKCHIP_EBC_3WIN_MODE is a bool with no `default', so "
           "olddefconfig lands it off")

    if re.search(r"^# CONFIG_DRM_FBDEV_EMULATION is not set|"
                 r"^CONFIG_DRM_FBDEV_EMULATION=n",
                 defconfig, re.MULTILINE):
        bad("pinenote_defconfig disables CONFIG_DRM_FBDEV_EMULATION, so "
            "defio_delay_ms is not registered and the shipping options "
            "name a parameter that does not exist")
    else:
        ok("pinenote_defconfig does not disable CONFIG_DRM_FBDEV_EMULATION "
           "(mainline default y), so defio_delay_ms is registered")


def gate_membership(ours, hrdl, hrdl_3win):
    """The derivation's own predictions, as assertions that can fail."""
    if len(ours) < 20:
        bad("our driver yielded only %d module_param registrations; the "
            "extractor is broken, not the tree" % len(ours))
    else:
        ok("our driver registers %d parameters" % len(ours))

    if "defio_delay_ms" not in ours:
        bad("defio_delay_ms is missing from our derived set -- the "
            "extractor has stopped seeing module_param_cb(), which is the "
            "only way that parameter is registered")
    else:
        ok("defio_delay_ms is derived (module_param_cb is handled)")

    if len(hrdl) < 10:
        bad("hrdl's driver yielded only %d module_param registrations; the "
            "extractor is broken" % len(hrdl))
    else:
        ok("hrdl's driver registers %d parameters" % len(hrdl))

    if "limit_fb_blits" not in hrdl:
        bad("limit_fb_blits is missing from hrdl's derived set")
    elif "split_area_limit" in hrdl:
        bad("split_area_limit is in hrdl's derived set -- the extractor is "
            "reading MODULE_PARM_DESC, which carries a stale name here; "
            "the module does not accept split_area_limit")
    else:
        ok("quirk:stale-parm-desc -- hrdl's driver registers "
           "limit_fb_blits and NOT the split_area_limit its "
           "MODULE_PARM_DESC advertises")

    if "direct_mode" in hrdl:
        bad("direct_mode is in hrdl's derived set with 3WIN off -- the "
            "#ifdef guard is not being applied")
    elif "direct_mode" not in hrdl_3win:
        bad("direct_mode is absent even with 3WIN forced on -- the guard "
            "control proves nothing, so its absence above proves nothing "
            "either")
    elif hrdl_3win - hrdl != {"direct_mode"}:
        bad("forcing 3WIN on changes the derived set by %s, not exactly "
            "{direct_mode}" % sorted(hrdl_3win - hrdl))
    else:
        ok("positive control -- direct_mode appears only when "
           "CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE is on, and it is off")


# The nine-parameter line the SHIPPING driver used to take.  Retired by the
# embrace sweep (2026-09-03): the direct driver is the shipping driver, module
# parameters cannot reach an initrd-loaded module anyway, and the two that
# matter go through sysfs.  It survives here as the POSITIVE CONTROL -- the
# string this gate must still be able to REJECT against hrdl's driver, which is
# what says the comparison works.
RETIRED_SHIPPING_OPTIONS = (
    "options rockchip_ebc direct_mode=0 auto_refresh=0 refresh_threshold=60 "
    "split_area_limit=0 panel_reflection=1 prepare_prev_before_a2=0 "
    "dclk_select=0 refresh_waveform=6 defio_delay_ms=250\n"
    "softdep panfrost pre: rockchip_ebc\n")

SYSFS_PUT_RE = re.compile(r'\(put "(\w+)" "([^"]*)"\)')


def gate_options(ours, hrdl):
    live_source = read(EBC_SCM)
    live = scheme_string(live_source, "pinenote-ebc-modprobe-options", EBC_SCM)
    digest = hashlib.sha256(live.encode()).hexdigest()
    if digest != SHIPPING_OPTIONS_SHA256:
        bad("the shipping options text changed (sha256 %s, pinned %s).\n"
            "      now: %r\n"
            "      If that is deliberate: update SHIPPING_OPTIONS_SHA256 "
            "and re-verify the reader system derivation moved for a reason."
            % (digest, SHIPPING_OPTIONS_SHA256, live))
    else:
        ok("the shipping options text is unchanged (sha256 pin)")

    # 1. The live string names NO parameter: the initrd raw-loads the
    #    module, so an `options rockchip_ebc' line is an intent the kernel
    #    never sees.  The two that matter go through sysfs (below).
    live_params = options_parameters(live)
    if live_params:
        bad("the shipping options name %d parameter(s) (%s) -- modprobe.d "
            "cannot reach the initrd-loaded module; put them in the "
            "pinenote-ebc-direct-params one-shot"
            % (len(live_params), ", ".join(sorted(live_params))))
    else:
        ok("the shipping options carry no module parameters (they would be inert)")
    if "softdep panfrost pre: rockchip_ebc" not in live:
        bad("the shipping options dropped the panfrost softdep, the "
            "module-ordering guard both postmarketOS and PNDeb ship")
    else:
        ok("the shipping options keep the panfrost softdep")

    # 2. POSITIVE CONTROL over the retired nine-parameter line: the old
    #    driver registered every name (the extractor works over the
    #    forward-port source) and hrdl's driver rejects most of them (the
    #    comparison can go red).
    retired = options_parameters(RETIRED_SHIPPING_OPTIONS)
    if len(retired) < 3:
        bad("only %d retired parameters parsed; the extractor is broken"
            % len(retired))
    unknown = sorted(name for name in retired if name not in ours)
    if unknown:
        bad("the retired shipping options name %d parameter(s) the "
            "forward-port driver does not register: %s -- the extractor "
            "over our own source is broken" % (len(unknown), ", ".join(unknown)))
    else:
        ok("control: all %d retired shipping parameters are registered by the "
           "forward-port driver" % len(retired))
    would_break = sorted(name for name in retired if name not in hrdl)
    if len(would_break) < 7:
        bad("positive control failed: the retired shipping options should be "
            "rejected against hrdl's driver, but only %d of %d names are "
            "unknown to it (%s)"
            % (len(would_break), len(retired), ", ".join(would_break)))
    else:
        ok("positive control -- the retired shipping options are REJECTED "
           "against hrdl's driver: %d of %d names unknown (%s).  The kernel "
           "would not refuse this: it warns and ignores"
           % (len(would_break), len(retired), ", ".join(would_break)))

    # 3. What actually ships: the sysfs pair the direct params one-shot
    #    writes must be parameters hrdl's driver registers.
    direct_source = read(EBC_DIRECT_SCM)
    sysfs = dict(SYSFS_PUT_RE.findall(direct_source))
    if set(sysfs) != {"temp_override", "default_hint"}:
        bad("the direct params one-shot writes %s; expected exactly "
            "temp_override and default_hint (re-approve if deliberate)"
            % sorted(sysfs))
    unknown = sorted(name for name in sysfs if name not in hrdl)
    if unknown:
        bad("the direct params one-shot writes %d sysfs parameter(s) hrdl's "
            "driver does not register: %s" % (len(unknown), ", ".join(unknown)))
    else:
        ok("the direct params one-shot's %d sysfs parameters (%s) are "
           "registered by hrdl's driver"
           % (len(sysfs), ", ".join("%s=%s" % kv for kv in sorted(sysfs.items()))))

    # 4. The alias (pinenote services ebc-direct) exports is the same
    #    binding, not a second string that could drift.
    if not re.search(r"\(define %pinenote-ebc-direct-modprobe-options\n"
                     r"(?:\s*;;[^\n]*\n)*\s*pinenote-ebc-modprobe-options\)",
                     direct_source):
        bad("%%pinenote-ebc-direct-modprobe-options is no longer an alias of "
            "pinenote-ebc-modprobe-options (a second string could drift)")
    else:
        ok("%pinenote-ebc-direct-modprobe-options aliases the shipping string")

    # dclk_select is the trap this gate was written around: it is a real
    # parameter of his driver, it accepts our shipped value, it shows up
    # in sysfs -- and rockchip_ebc_set_dclk() returns before reading it
    # whenever direct_mode is true, which it always is for us.  #23's
    # 250 MHz / 79.68 Hz measurement does not transfer.
    if "dclk_select" in sysfs or "dclk_select" in live_params:
        bad("dclk_select is set, which rockchip_ebc_set_dclk() never reads "
            "in direct mode (it returns after clamping cpll_333m to "
            "33.33 MHz and dclk to 34 MHz).  Setting it is a knob that does "
            "nothing.")
    else:
        ok("nothing sets dclk_select (dead code in direct mode)")

    return live, sysfs


def scheme_literal(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"') \
                        .replace("\n", "\\n")


RUNNER_TEMPLATE = r"""(use-modules (gnu services)
             (pinenote services ebc)
             (pinenote services ebc-direct))

(define failures 0)

(define (check name got want)
  (if (equal? got want)
      (format #t "PASS: guix repl: ~a~%" name)
      (begin
        (set! failures (+ failures 1))
        (format #t "FAIL: guix repl: ~a: got ~s want ~s~%" name got want))))

(check "the record default is the shipping text this gate parsed"
       (pinenote-ebc-modprobe-configuration-options
        (pinenote-ebc-modprobe-configuration))
       @SHIPPING@)

(check "the direct alias is the same string"
       %pinenote-ebc-direct-modprobe-options @SHIPPING@)

(exit failures)
"""


def gate_scheme_evaluates(shipping):
    """Actually LOAD the Scheme, when guix is available to load it with.

    This cross-checks the text parser above against the real values, which
    is the only thing that says the regex reading of the sources is honest.
    CI has guile but no guix, so this SKIPS there and says so: a green run
    without it has not evaluated a line of Scheme.
    """
    if shutil.which("guix") is None:
        print("SKIP: the Scheme was NOT evaluated -- no guix on PATH.")
        print("      Everything above is text analysis.  Run locally:")
        print("      make ebc-modprobe-options-check")
        return
    runner = RUNNER_TEMPLATE.replace("@SHIPPING@", scheme_literal(shipping))
    # The runner lives OUTSIDE the tree: `guix build -L .' evaluates every
    # .scm it walks, and a file with top-level side effects would run
    # inside unrelated builds (the 2026-08-24 sentinel finding in
    # validate-koreader-profile.sh).
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "run-ebc-direct-checks.scm"
        path.write_text(runner)
        result = subprocess.run(["guix", "repl", "-L", str(ROOT), str(path)],
                                capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        bad("guix repl refused the Scheme (exit %d): %s"
            % (result.returncode, result.stderr.strip().splitlines()[-1]
               if result.stderr.strip() else "no stderr"))
    else:
        ok("(pinenote services ebc) and (pinenote services ebc-direct) load, "
           "and their values match the text this gate parsed")


def gate_reader_consumer():
    """Rule (since S2): the reader instantiates the direct-mode services; the
    bringup flavors (base) do not -- the panel is their console."""
    reader = read("pinenote/systems/pinenote-reader.scm")
    missing = [name for name in ("pinenote-ebc-direct-params-service-type",
                                 "pinenote-ebc-clut-service-type",
                                 "pinenote-ebc-splash-service-type")
               if "(service %s)" % name not in reader]
    if "ebc-direct" not in reader or missing:
        bad("pinenote-reader.scm no longer instantiates the direct-mode "
            "services (missing: %s) -- the reader would boot the direct "
            "driver with no CLUT and never light the panel"
            % (", ".join(missing) or "the module import"))
    else:
        ok("the reader instantiates the three direct-mode services")
    if "ebc-direct" in read("pinenote/systems/base.scm"):
        bad("base.scm references the direct-mode module; the bringup "
            "flavors keep their on-panel console and need no CLUT")
    else:
        ok("base.scm does not reference (pinenote services ebc-direct)")


# ====================================================================
# self-test: a text gate is worthless without one
# ====================================================================
SELF_TEST_SOURCE = """
module_param(always, int, 0644);
#ifdef CONFIG_KNOWN_ON
module_param(when_on, int, 0644);
#else
module_param(when_off, int, 0644);
#endif
#ifdef CONFIG_KNOWN_OFF
module_param(never, int, 0644);
#endif
module_param_cb(via_cb, &ops, &x, 0644);
module_param_named(visible_name, internal, int, 0644);
"""

SELF_TEST_CONFIG = {"CONFIG_KNOWN_ON": True, "CONFIG_KNOWN_OFF": False}


def self_test():
    """Each case must be REJECTED (or accepted) for a stated reason.

    `FAIL:' lines below are the expected output of a working gate when a
    case is deliberately broken -- read the summary, not the lines.
    """
    print("--- self-test (mutation controls; judge by the summary) ---")
    got = registered_params(SELF_TEST_SOURCE, SELF_TEST_CONFIG, "self-test")
    want = {"always", "when_on", "via_cb", "visible_name"}
    if got != want:
        bad("self-test: guard resolution yielded %s, wanted %s"
            % (sorted(got), sorted(want)))
    else:
        ok("self-test: #ifdef/#else/#endif, module_param_cb and "
           "module_param_named all resolve as intended")

    for label, source in (
            ("unknown CONFIG symbol",
             "#ifdef CONFIG_NOT_IN_TABLE\nmodule_param(x, int, 0644);\n"
             "#endif\n"),
            ("unsupported #if expression",
             "#if CONFIG_A > 3\nmodule_param(x, int, 0644);\n#endif\n"),
            ("#elif branch",
             "#ifdef CONFIG_KNOWN_OFF\n#elif defined(CONFIG_KNOWN_ON)\n"
             "module_param(x, int, 0644);\n#endif\n"),
            ("non-CONFIG guard",
             "#ifdef SOME_LOCAL_DEBUG_MACRO\nmodule_param(x, int, 0644);\n"
             "#endif\n")):
        try:
            registered_params(source, SELF_TEST_CONFIG, "self-test")
        except UnsupportedGuard:
            ok("self-test: a module_param under a(n) %s is refused, not "
               "assumed" % label)
        else:
            bad("self-test: a module_param under a(n) %s was silently "
                "accepted" % label)

    known = {"real_one"}
    if options_parameters("options rockchip_ebc real_one=1 bogus=2") \
            .keys() - known != {"bogus"}:
        bad("self-test: the options comparison did not flag a bogus name")
    else:
        ok("self-test: an options line naming an unregistered parameter is "
           "flagged")

    drifted = "options rockchip_ebc direct_mode=0\n"
    if hashlib.sha256(drifted.encode()).hexdigest() \
            == SHIPPING_OPTIONS_SHA256:
        bad("self-test: the shipping pin matches a drifted string")
    else:
        ok("self-test: the shipping pin rejects a drifted string")

    try:
        section_hunks("+++ b/nothing/here\n", DRIVER_PATH)
    except ValueError:
        ok("self-test: a patch without the driver section is an error, not "
           "an empty set")
    else:
        bad("self-test: a patch without the driver section yielded no error")

    try:
        apply_hunks(["a"], [(1, [" b"])], "self-test")
    except ValueError:
        ok("self-test: a context mismatch refuses to apply")
    else:
        bad("self-test: a context mismatch applied anyway")


def main():
    print("rockchip_ebc modprobe options gate (rung 1, text only)")
    print()
    ours_source, hrdl_source, defconfig, direct_patch = build_driver_sources()
    try:
        ours = registered_params(ours_source, OUR_CONFIG, "our driver")
        hrdl = registered_params(hrdl_source, HRDL_CONFIG, "hrdl's driver")
        hrdl_3win = registered_params(
            hrdl_source,
            dict(HRDL_CONFIG, CONFIG_DRM_ROCKCHIP_EBC_3WIN_MODE=True),
            "hrdl's driver (3WIN forced on)")
    except UnsupportedGuard as exc:
        bad(str(exc))
        print()
        print("SUMMARY: %d checks, %d failed" % (CHECKS, len(FAILURES)))
        return 1

    gate_config_derivation(defconfig, direct_patch)
    gate_membership(ours, hrdl, hrdl_3win)
    shipping, _sysfs = gate_options(ours, hrdl)
    gate_reader_consumer()
    gate_scheme_evaluates(shipping)
    print()
    self_test()

    print()
    print("SUMMARY: %d checks, %d failed" % (CHECKS, len(FAILURES)))
    for failure in FAILURES:
        print("  - %s" % failure.splitlines()[0])
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
