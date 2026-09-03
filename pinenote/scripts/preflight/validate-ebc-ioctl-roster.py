#!/usr/bin/env python3
"""EBC ioctl roster preflight (offline ladder rung 1, `doc/testing.md`).

The two rockchip_ebc drivers this tree carries do not share an ioctl
table: wilkbook's SHIPPING driver adds REFRESH_BARRIER at DRM command
0x03; hrdl's DIRECT driver never had it and registers RECT_HINTS at 0x03
instead.  DRM dispatches on the command number, so a userspace tool
built for one driver can land in a *different* handler on the other --
which is exactly how the suspend broker's barrier SUBMIT became an
EFAULT inside ioctl_rect_hints and no suspend could complete on the
direct image (issue #42, glass 2026-09-02).  `unknown_module_param_cb`
has a preflight for parameters; this is the same gate one layer down.

What it does, from the patches alone (no kernel build, no device):

  1. reconstructs `include/uapi/drm/rockchip_ebc_drm.h` for BOTH drivers
     (the shipping header is a new file in the forward-port patch; the
     direct header is that file with the direct-mode patch's hunks
     applied, every context line verified);
  2. computes every DRM_IOCTL_ROCKCHIP_EBC_* number the way the kernel's
     _IOC() macro does, laying the request structs out with the C ABI
     rules for the fixed-width types they use (identical on aarch64 and
     the host), and proves the calculator against the constants this
     repo has driven on glass;
  3. checks every hardcoded EBC ioctl in the on-device userspace roster
     against the driver(s) that code is declared to run on, and reports
     what the same command number means on the OTHER driver;
  4. requires the suspend broker to reach the shipping-only barrier only
     through its driver probe;
  5. carries a positive control: the barrier literal, declared for both
     drivers, MUST be rejected -- otherwise the checker is not looking.

Passing proves the numbers and the declarations agree.  It does not
prove a struct's field semantics, nor that a tool is never copied to the
wrong image; the declarations below are the contract.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FORWARD_PORT = "pinenote/patches/linux-pinenote-7.0-forward-port.patch"
DIRECT_MODE = "pinenote/patches/linux-pinenote-7.1-hrdl-direct-mode.patch"
HEADER = "include/uapi/drm/rockchip_ebc_drm.h"

DRM_IOCTL_BASE = ord("d")
DRM_COMMAND_BASE = 0x40
DIRS = {"DRM_IO": 0, "DRM_IOW": 1, "DRM_IOR": 2, "DRM_IOWR": 3}

# Constants this repo has driven on hardware; the calculator must reproduce
# them or nothing below is trustworthy.
PROVEN = {
    ("shipping", "GLOBAL_REFRESH"): 0xC0016440,   # every wash since 2026-07
    ("direct", "GLOBAL_REFRESH"): 0xC0016440,     # ABI-identical, D4 on glass
    ("shipping", "REFRESH_BARRIER"): 0xC0286443,  # sleep-frame-test _Static_assert
    ("direct", "RECT_HINTS"): 0x40106443,         # ebc-lab / pen pins, glass 2026-08-26
    ("direct", "MODE"): 0xC0086444,
    ("direct", "EXTRACT_FBS"): 0xC0286442,        # belief-grab, glass 2026-08-26
    ("direct", "PHASE_SEQUENCE"): 0x77906446,     # 14224-byte program, glass 2026-08-27
}

# The on-device roster: (path, regex with groups (literal[, name]), name or
# None when the regex yields it, drivers this code runs on).
ROSTER = [
    ("pinenote/packages/koreader-device/frontend/device/pinenote/ebc_barrier.lua",
     r"local REQUEST = (0x[0-9A-Fa-f]+)", "REFRESH_BARRIER", {"shipping"}),
    ("pinenote/packages/koreader-device/frontend/device/pinenote/device.lua",
     r"local DRM_GLOBAL_REFRESH = (0x[0-9A-Fa-f]+)", "GLOBAL_REFRESH", {"shipping", "direct"}),
    ("pinenote/services/reader-session.scm",
     r"C\.ioctl\(card, (0x[0-9A-Fa-f]+), arg\)", "GLOBAL_REFRESH", {"shipping", "direct"}),
    ("pinenote/tools/ebc-lab/test-ebc-lab.lua",
     r"lib\.(?P<name>GLOBAL_REFRESH|EXTRACT_FBS)_IOCTL == (?P<lit>0x[0-9A-Fa-f]+)", None, {"shipping", "direct"}),
    ("pinenote/tools/ebc-lab/test-ebc-lab.lua",
     r"lib\.(?P<name>MODE|RECT_HINTS|PHASE_SEQUENCE|ZERO_WAVEFORM)_IOCTL == (?P<lit>0x[0-9A-Fa-f]+)", None, {"direct"}),
]
BROKER = "pinenote/packages/platform-controls/pinenote-power-broker.lua"

failures = 0


def ok(msg):
    print("PASS: " + msg)


def bad(msg):
    global failures
    failures += 1
    print("FAIL: " + msg)


def read(rel):
    return (ROOT / rel).read_text()


# ---------------------------------------------------------------------------
# patch -> header (the extractor/applier mirror validate-ebc-modprobe-options)
# ---------------------------------------------------------------------------
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def new_file_lines(patch_text, path):
    marker = "+++ b/" + path
    if marker not in patch_text:
        raise ValueError("no `%s' in the patch" % marker)
    lines = patch_text[patch_text.index(marker):].splitlines()[1:]
    out, index = [], 0
    if not lines or not HUNK_RE.match(lines[0]):
        raise ValueError("%s: expected a hunk header" % path)
    index = 1
    while index < len(lines) and not lines[index].startswith(("diff ", "--- ")):
        line = lines[index]
        index += 1
        if line.startswith("+"):
            out.append(line[1:])
        elif line.startswith("\\"):
            continue
        elif line.startswith(("-", " ")) or line == "":
            raise ValueError("%s: not a pure new-file hunk: %r" % (path, line))
        else:
            break
    return out


def section_hunks(patch_text, path):
    marker = "+++ b/" + path
    if marker not in patch_text:
        raise ValueError("no `%s' in the patch" % marker)
    lines = patch_text[patch_text.index(marker):].splitlines()[1:]
    hunks, index = [], 0
    while index < len(lines):
        m = HUNK_RE.match(lines[index])
        if m is None:
            break
        old_start = int(m.group(1))
        old_count = int(m.group(2)) if m.group(2) else 1
        new_count = int(m.group(4)) if m.group(4) else 1
        index += 1
        body, seen_old, seen_new = [], 0, 0
        while index < len(lines) and (seen_old < old_count or seen_new < new_count):
            line = lines[index]
            index += 1
            if line.startswith("\\"):
                continue
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
            raise ValueError("%s: hunk @@ -%d line counts disagree" % (path, old_start))
        hunks.append((old_start, body))
    if not hunks:
        raise ValueError("%s: no hunks" % path)
    return hunks


def apply_hunks(pre, hunks, path):
    out, cursor = [], 0
    for old_start, body in hunks:
        start = old_start - 1
        if start < cursor:
            raise ValueError("%s: hunks out of order at %d" % (path, old_start))
        out.extend(pre[cursor:start])
        cursor = start
        for line in body:
            kind, text = (line[0], line[1:]) if line else (" ", "")
            if kind in (" ", "-"):
                if cursor >= len(pre) or pre[cursor] != text:
                    have = pre[cursor] if cursor < len(pre) else "<eof>"
                    raise ValueError("%s: hunk at %d does not apply: expected %r, found %r"
                                     % (path, old_start, text, have))
                cursor += 1
                if kind == " ":
                    out.append(text)
            else:
                out.append(text)
    out.extend(pre[cursor:])
    return out


# ---------------------------------------------------------------------------
# header -> ioctl numbers (a C layout engine for the types these structs use)
# ---------------------------------------------------------------------------
SCALARS = {"__u8": (1, 1), "__s8": (1, 1), "__u16": (2, 2), "__s16": (2, 2),
           "__u32": (4, 4), "__s32": (4, 4), "__u64": (8, 8), "__s64": (8, 8),
           "bool": (1, 1), "_Bool": (1, 1)}
# Userspace pointers in the request structs (aarch64 LP64: 8 bytes).  These
# headers are consumed by an arm64-only driver; the pointer width is the
# device's, not the host's.
POINTER = (8, 8)
# Structs the headers borrow from the kernel's own UAPI (<drm/drm_mode.h>),
# by (size, alignment).  drm_mode_rect is four __s32: x1, y1, x2, y2.
EXTERNAL = {"drm_mode_rect": (16, 4)}


def parse_header(text):
    defines = {}
    for m in re.finditer(r"^#define\s+(\w+)\s+(0x[0-9A-Fa-f]+|\d+)\s*$", text, re.M):
        defines[m.group(1)] = int(m.group(2), 0)
    structs = {}
    for m in re.finditer(r"^struct\s+(\w+)\s*\{(.*?)^\};", text, re.M | re.S):
        fields = []
        body = re.sub(r"/\*.*?\*/", "", m.group(2), flags=re.S)
        for f in re.finditer(
                r"(struct\s+\w+|__[us]\d+|_?[Bb]ool|void|char|unsigned\s+\w+|\w+_t)\s*(\*+)?\s*(\w+)((?:\[[^\]]+\])*)\s*;",
                body):
            dims = [d.strip() for d in re.findall(r"\[([^\]]+)\]", f.group(4))]
            ftype = "pointer" if f.group(2) else re.sub(r"\s+", " ", f.group(1)).replace("struct ", "struct:")
            fields.append((ftype, f.group(3), dims))
        structs[m.group(1)] = fields
    ioctls = {}
    for m in re.finditer(
            r"^#define\s+DRM_IOCTL_ROCKCHIP_EBC_(\w+)\s+(DRM_IOWR|DRM_IOW|DRM_IOR|DRM_IO)\s*\(\s*DRM_COMMAND_BASE\s*\+\s*(0x[0-9A-Fa-f]+|\w+)\s*,\s*struct\s+(\w+)\s*\)",
            text, re.M):
        nr_text = m.group(3)
        nr = int(nr_text, 0) if nr_text.startswith("0x") or nr_text.isdigit() else defines[nr_text]
        ioctls[m.group(1)] = (m.group(2), nr, m.group(4))
    return defines, structs, ioctls


def layout(structs, defines, name, seen=()):
    if name in seen:
        raise ValueError("recursive struct " + name)
    size, align = 0, 1
    for ftype, fname, dims in structs[name]:
        if ftype.startswith("struct:"):
            inner = ftype[7:]
            if inner in structs:
                fsize, falign = layout(structs, defines, inner, seen + (name,))
            elif inner in EXTERNAL:
                fsize, falign = EXTERNAL[inner]
            else:
                raise ValueError("struct %s: unknown embedded struct %s" % (name, inner))
        elif ftype == "pointer":
            fsize, falign = POINTER
        elif ftype in SCALARS:
            fsize, falign = SCALARS[ftype]
        else:
            raise ValueError("struct %s: field %s has unsupported type %s" % (name, fname, ftype))
        count = 1
        for d in dims:
            count *= int(d, 0) if (d.startswith("0x") or d.isdigit()) else defines[d]
        size = (size + falign - 1) // falign * falign
        size += fsize * count
        align = max(align, falign)
    size = (size + align - 1) // align * align
    return size, align


def ioctl_numbers(text):
    defines, structs, ioctls = parse_header(text)
    numbers = {}
    for name, (direction, nr, stype) in ioctls.items():
        size, _ = layout(structs, defines, stype)
        numbers[name] = (DIRS[direction] << 30) | (size << 16) | (DRM_IOCTL_BASE << 8) | (DRM_COMMAND_BASE + nr)
    return numbers


# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------
def check_entry(rosters, path, literal, name, drivers, quiet=False):
    """True when `literal` is `name` on every driver in `drivers`."""
    good = True
    for driver in sorted(drivers):
        want = rosters[driver].get(name)
        if want is None:
            good = False
            if not quiet:
                bad("%s: %s is not an ioctl of the %s driver at all" % (path, name, driver))
        elif want != literal:
            good = False
            if not quiet:
                bad("%s: 0x%08X is not %s on the %s driver (which is 0x%08X)"
                    % (path, literal, name, driver, want))
    if good and not quiet:
        ok("%s: 0x%08X is %s on %s" % (path, literal, name, "+".join(sorted(drivers))))
        for other in sorted(set(rosters) - set(drivers)):
            nr = literal & 0xFF
            same_nr = [(n, v) for n, v in rosters[other].items() if (v & 0xFF) == nr]
            if same_nr:
                n, v = same_nr[0]
                print("      note: on the %s driver command 0x%02X is %s (0x%08X)%s -- this code must not run there"
                      % (other, nr - DRM_COMMAND_BASE, n, v, "" if v != literal else " with the SAME number"))
    return good


def main():
    forward = read(FORWARD_PORT)
    direct = read(DIRECT_MODE)
    shipping_lines = new_file_lines(forward, HEADER)
    direct_lines = apply_hunks(shipping_lines, section_hunks(direct, HEADER), HEADER)
    ok("reconstructed %s for both drivers (%d / %d lines; every direct-mode context line matched)"
       % (HEADER, len(shipping_lines), len(direct_lines)))
    rosters = {"shipping": ioctl_numbers("\n".join(shipping_lines)),
               "direct": ioctl_numbers("\n".join(direct_lines))}
    for driver in ("shipping", "direct"):
        print("      %s: %s" % (driver, ", ".join("%s=0x%08X" % kv for kv in sorted(rosters[driver].items(), key=lambda kv: kv[1] & 0xFF))))

    # 2. the calculator against glass-proven constants
    for (driver, name), want in sorted(PROVEN.items()):
        have = rosters[driver].get(name)
        if have == want:
            ok("calculator: %s %s = 0x%08X (hardware-proven)" % (driver, name, want))
        else:
            bad("calculator: %s %s = %s, hardware says 0x%08X" % (driver, name, "0x%08X" % have if have else "absent", want))
    if "REFRESH_BARRIER" in rosters["direct"]:
        bad("the direct driver now registers REFRESH_BARRIER: re-examine the broker's driver probe")
    else:
        ok("the direct driver registers no REFRESH_BARRIER (the #42 premise still holds)")

    # 3. the roster
    for path, pattern, name, drivers in ROSTER:
        text = read(path)
        matches = list(re.finditer(pattern, text))
        if not matches:
            bad("%s: pattern %r matched nothing (moved? update this script)" % (path, pattern))
            continue
        for m in matches:
            lit = int(m.group("lit") if "lit" in m.groupdict() else m.group(1), 0)
            nm = m.group("name") if "name" in m.groupdict() else name
            check_entry(rosters, path, lit, nm, drivers)

    # 4. the broker reaches the barrier only through its driver probe
    broker = read(BROKER)
    if ("driver_has_barrier = driver_has_barrier, barrier = ebc_barrier" in broker
            and "= ebc_barrier()" not in broker
            and 'read_line("/sys/module/rockchip_ebc/parameters/refresh_waveform")' in broker):
        ok("%s: the shipping-only barrier is reachable only through the driver probe" % BROKER)
    else:
        bad("%s: the barrier must be reachable only via broker_quiesce's driver_has_barrier" % BROKER)

    # 4b. the fingerprint parameter must be registered by the shipping driver
    #     and NOT by the direct driver -- from module_param() in each driver's
    #     reconstructed source (the modprobe-options preflight's own extractor).
    #     no_off_screen is registered by BOTH, which is how the first fix of
    #     #42 still took the barrier path on glass.
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "modprobe_preflight", ROOT / "pinenote/scripts/preflight/validate-ebc-modprobe-options.py")
    modprobe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modprobe)
    ours, hrdl, defconfig, _ = modprobe.build_driver_sources()
    shipping_params = set(modprobe.registered_params(ours, modprobe.OUR_CONFIG, "shipping"))
    direct_params = set(modprobe.registered_params(hrdl, modprobe.HRDL_CONFIG, "direct"))
    probe = re.search(r'read_line\("/sys/module/rockchip_ebc/parameters/(\w+)"\) ~= nil', broker)
    probe = probe.group(1) if probe else None
    if probe in shipping_params and probe not in direct_params:
        ok("%s: fingerprint parameter `%s' is registered by the shipping driver only" % (BROKER, probe))
    else:
        bad("%s: fingerprint parameter %r must be shipping-only (shipping: %s, direct: %s)"
            % (BROKER, probe, probe in shipping_params, probe in direct_params))
    if "no_off_screen" in shipping_params and "no_off_screen" in direct_params:
        ok("no_off_screen is registered by BOTH drivers (not a fingerprint; the 2026-09-02 trap)")
    else:
        bad("no_off_screen registration changed; re-read the fingerprint argument")

    # 5. positive control
    barrier = rosters["shipping"]["REFRESH_BARRIER"]
    if check_entry(rosters, "<positive control>", barrier, "REFRESH_BARRIER", {"shipping", "direct"}, quiet=True):
        bad("positive control: the barrier literal declared for both drivers was ACCEPTED -- the checker is blind")
    else:
        ok("positive control: the barrier literal declared for both drivers is REJECTED (direct has %s at that command)"
           % [n for n, v in rosters["direct"].items() if (v & 0xFF) == (barrier & 0xFF)][0])

    print("RESULT: %s" % ("ok" if failures == 0 else "failed (%d)" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError) as error:
        print("FAIL: " + str(error))
        sys.exit(1)
