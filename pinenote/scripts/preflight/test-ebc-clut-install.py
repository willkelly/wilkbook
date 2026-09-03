#!/usr/bin/env python3
"""Execute the direct-mode CLUT installer through every branch.

    test-ebc-clut-install.py [REPO_ROOT]

The subject is pinenote/services/ebc-clut-install.sh -- the exact file
(pinenote services ebc-direct) hands to shepherd, not a copy of it.  It is
RUN here, against a fake firmware tree and a stub compiler, because a gate
that greps a shell script tests the grep: that is the manuals-stage.sh
precedent, and it is why both scripts take their paths as arguments instead
of baking /lib/firmware into themselves.

What this does NOT cover.  No waveform is committed (per-device calibration,
CLAUDE.md safety model), so the compiler here is a stub: what is proven is
the installer's contract -- when it compiles, when it refuses, what it
leaves behind on failure -- and nothing about the CLUT's contents.  Those
are `make clut-check''s job, and it is byte-identical-or-fail.  The rebind
stage runs against a FAKE sysfs (see FakeSysfs for exactly what a static
fixture can and cannot re-enact); the real bind transition was proven by
hand on glass 2026-08-25 (doc/status.md D2), and the wired service
reproducing it has not itself booted.

Python 3 standard library only; no Guix, no store, no device.  The one
optional step is `guix repl', which compiles (pinenote services ebc-direct)
so a typo in the service cannot wait for an image build; without guix on
PATH that step says SKIP out loud.
"""

import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile

FAILURES = [0]
CHECKS = [0]


def check(label, ok, detail=""):
    CHECKS[0] += 1
    if ok:
        print("PASS: %s" % label)
    else:
        FAILURES[0] += 1
        print("FAIL: %s%s" % (label, (" -- " + detail) if detail else ""))
    return ok


def skip(label, why):
    print("SKIP: %s -- %s" % (label, why))


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


# --------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------

STUB = """#!/bin/sh
# Stand-in for wbf-clut.  Records every invocation and derives its output
# from its input, so the suite can tell a real recompile from a no-op.
printf '%s\\n' "$*" >> {log}
mode=$(cat {mode} 2>/dev/null || echo ok)
case "$mode" in
  fail)  echo "stub-wbf-clut: refusing" >&2; exit 1 ;;
  empty) : > "$2"; exit 0 ;;
esac
printf 'CLUT-OF-' > "$2"
cat "$1" >> "$2"
"""


class Fixture:
    """A fake /lib/firmware/rockchip plus a stub compiler."""

    def __init__(self, tmp, name="fx"):
        self.root = os.path.join(tmp, name)
        self.firmware = os.path.join(self.root, "lib", "firmware", "rockchip")
        os.makedirs(self.firmware)
        self.log = os.path.join(self.root, "invocations")
        self.mode = os.path.join(self.root, "mode")
        self.compiler = os.path.join(self.root, "wbf-clut")
        with open(self.compiler, "w") as fh:
            fh.write(STUB.format(log=self.log, mode=self.mode))
        os.chmod(self.compiler, 0o755)
        self.source = os.path.join(self.firmware, "ebc.wbf")
        self.destination = os.path.join(self.firmware, "custom_wf.bin")
        self.stamp = os.path.join(self.firmware, ".custom_wf.bin.stamp")
        self.write_source("waveform-rev-1")

    def write_source(self, text):
        with open(self.source, "w") as fh:
            fh.write(text)

    def set_mode(self, mode):
        with open(self.mode, "w") as fh:
            fh.write(mode)

    @property
    def calls(self):
        try:
            with open(self.log) as fh:
                return [line for line in fh.read().splitlines() if line]
        except FileNotFoundError:
            return []

    def read(self, path):
        try:
            with open(path) as fh:
                return fh.read()
        except (FileNotFoundError, NotADirectoryError):
            return None


class FakeSysfs:
    """A fake driver sysfs directory for the rebind stage.

    A static tree cannot re-enact sysfs's side effects: writing a device
    name into `bind' creates no bound-device entry here, and writing
    `unbind' removes none.  What IS provable is the script's observable
    contract -- which files it writes, what it writes into them, that it
    trusts the unbind WRITE's status but judges bind by the END STATE
    (device entry present plus a drm/card* minor), and that every failed
    outcome is loud.  The state transition itself was proven on glass
    2026-08-25 (doc/status.md D2).  bind/unbind start as `sentinel' so a
    test can positively assert an untouched file.
    """

    DEVICE = "fdec0000.ebc"

    def __init__(self, root, name="sysfs"):
        base = os.path.join(root, name)
        self.driver_dir = os.path.join(base, "bus", "platform", "drivers",
                                       "rockchip-ebc")
        self.devices = os.path.join(base, "devices")
        os.makedirs(self.driver_dir)
        os.makedirs(self.devices)
        self.device = self.DEVICE
        self.bind_file = os.path.join(self.driver_dir, "bind")
        self.unbind_file = os.path.join(self.driver_dir, "unbind")
        self.reset_sentinels()

    def reset_sentinels(self):
        for path in (self.bind_file, self.unbind_file):
            with open(path, "w") as fh:
                fh.write("sentinel")

    def bind(self, minor=True):
        """Pre-bind the device: driver_dir/DEVICE -> a device dir, with or
        without a drm/card* minor under it (as real sysfs lays it out)."""
        devdir = os.path.join(self.devices, self.device)
        os.makedirs(os.path.join(devdir, "drm"), exist_ok=True)
        if minor:
            with open(os.path.join(devdir, "drm", "card1"), "w"):
                pass
        link = os.path.join(self.driver_dir, self.device)
        if not os.path.lexists(link):
            os.symlink(devdir, link)

    def wrote(self, path):
        with open(path) as fh:
            return fh.read()


def run(script, compiler, source, destination, stamp=None, env=None,
        sysfs=None):
    argv = ["sh", script, compiler, source, destination]
    if sysfs is not None:
        # STAMP is positional before the rebind pair; "" keeps its default.
        argv.append(stamp if stamp is not None else "")
        argv += [sysfs.driver_dir, sysfs.device]
    elif stamp is not None:
        argv.append(stamp)
    environ = dict(os.environ)
    if env is not None:
        environ = env
    # The installer does nothing on a machine without the EBC device (the
    # QEMU rig); the branches below want the PineNote behaviour, so point it
    # at something that exists unless a case says otherwise.
    environ.setdefault("EBC_DEVICE", os.path.dirname(os.path.abspath(script)))
    proc = subprocess.run(argv, capture_output=True, env=environ)
    out = (proc.stdout + proc.stderr).decode("utf-8", "replace")
    return proc.returncode, out


# --------------------------------------------------------------------------
# the branches
# --------------------------------------------------------------------------

def branch_tests(script, tmp, label="", strict=True):
    """Drive the installer through every branch.

    Returns a dict of observations so the mutation control can require the
    freshness branches to behave DIFFERENTLY for a compile-once-if-absent
    variant.  With strict=False nothing is reported as PASS/FAIL; only the
    observations come back.
    """
    obs = {}

    def note(name, ok, detail=""):
        obs[name] = ok
        if strict:
            check(label + name, ok, detail)

    fx = Fixture(tmp, "first")

    # 1. First run: nothing exists yet.
    rc, out = run(script, fx.compiler, fx.source, fx.destination)
    note("a first run compiles the CLUT",
         rc == 0 and fx.read(fx.destination) == "CLUT-OF-waveform-rev-1"
         and len(fx.calls) == 1, out)
    note("the compiler is called with INPUT then OUTPUT",
         len(fx.calls) == 1 and fx.calls[0].split()[0] == fx.source,
         str(fx.calls))

    # The freshness record is what it claims to be -- recomputed here from
    # the files themselves.  Without this the stamp could be any constant
    # and every "is current" branch below would still pass.
    if strict:
        want = "%s\n%s\n%s\n" % (sha256(fx.source), fx.compiler,
                                 sha256(fx.destination))
        check(label + "the stamp records source digest, compiler, output digest",
              fx.read(fx.stamp) == want, repr(fx.read(fx.stamp)))

    # 2. Nothing changed: no recompile, and the file is not even rewritten.
    before = os.stat(fx.destination).st_mtime_ns
    rc, out = run(script, fx.compiler, fx.source, fx.destination)
    note("a second run with everything unchanged does not recompile",
         rc == 0 and len(fx.calls) == 1 and "is current" in out
         and os.stat(fx.destination).st_mtime_ns == before, out)

    # 3. The waveform changed -- the hazard the checksum exists for.  Upstream's
    #    ExecCondition=test ! -e can never notice this.
    fx.write_source("waveform-rev-2")
    rc, out = run(script, fx.compiler, fx.source, fx.destination)
    note("a changed waveform forces a recompile",
         rc == 0 and len(fx.calls) == 2
         and fx.read(fx.destination) == "CLUT-OF-waveform-rev-2", out)

    # 4. The compiler changed.  On the device this is a store path, so its
    #    hash moves whenever wbf-clut or anything under it is rebuilt.
    moved = fx.compiler + "-v2"
    shutil.copy(fx.compiler, moved)
    os.chmod(moved, 0o755)
    rc, out = run(script, moved, fx.source, fx.destination)
    note("a changed compiler forces a recompile",
         rc == 0 and len(fx.calls) == 3, out)
    rc, out = run(script, moved, fx.source, fx.destination)
    note("and then settles back to a no-op",
         rc == 0 and len(fx.calls) == 3 and "is current" in out, out)

    # 5. The installed file was corrupted while the stamp still says current.
    with open(fx.destination, "w") as fh:
        fh.write("truncated")
    rc, out = run(script, moved, fx.source, fx.destination)
    note("a corrupted custom_wf.bin is rebuilt, not trusted",
         rc == 0 and len(fx.calls) == 4
         and fx.read(fx.destination) == "CLUT-OF-waveform-rev-2", out)

    # 6. The file was deleted but the stamp survived.
    os.unlink(fx.destination)
    rc, out = run(script, moved, fx.source, fx.destination)
    note("a deleted custom_wf.bin is rebuilt",
         rc == 0 and len(fx.calls) == 5 and os.path.exists(fx.destination),
         out)

    if not strict:
        return obs

    # ---- failure paths: loud and non-zero, unlike manuals-stage.sh --------

    # 7. No waveform.  This is the never-bundle rule working as intended, and
    #    it must not look like success.
    fx2 = Fixture(tmp, "no-source")
    os.unlink(fx2.source)
    rc, out = run(script, fx2.compiler, fx2.source, fx2.destination)
    check(label + "a missing waveform fails loudly and creates nothing",
          rc != 0 and not os.path.exists(fx2.destination)
          and "no waveform" in out and "-EINVAL" in out and len(fx2.calls) == 0,
          out)

    # 7b. No EBC device at all: the rig, or a bringup flavor.  Nothing to
    #     compile, nothing to rebind, and it must SUCCEED -- reader-session
    #     requires this one-shot since S2, so a failure here would keep the
    #     reader from starting on the rig.
    fx2b = Fixture(tmp, "no-device")
    env = dict(os.environ)
    env["EBC_DEVICE"] = os.path.join(tmp, "no-such-device")
    rc, out = run(script, fx2b.compiler, fx2b.source, fx2b.destination, env=env)
    check(label + "no EBC device: succeeds, compiles nothing, creates nothing",
          rc == 0 and not os.path.exists(fx2b.destination)
          and "no EBC device" in out and len(fx2b.calls) == 0, out)

    # 8. No compiler.
    fx3 = Fixture(tmp, "no-compiler")
    rc, out = run(script, fx3.compiler + "-absent", fx3.source, fx3.destination)
    check(label + "a missing compiler fails loudly",
          rc != 0 and not os.path.exists(fx3.destination)
          and "no CLUT compiler" in out, out)

    # 9. The compiler fails.  A previously good CLUT must survive, the stamp
    #    must not advance, and no temporary file may be left behind.
    fx4 = Fixture(tmp, "compiler-fails")
    run(script, fx4.compiler, fx4.source, fx4.destination)
    good = fx4.read(fx4.destination)
    good_stamp = fx4.read(fx4.stamp)
    fx4.set_mode("fail")
    fx4.write_source("waveform-rev-2")
    rc, out = run(script, fx4.compiler, fx4.source, fx4.destination)
    leftovers = [f for f in os.listdir(fx4.firmware)
                 if f.startswith(".custom_wf.") and not f.endswith(".stamp")]
    check(label + "a failed compile keeps the previous CLUT and its stamp",
          rc != 0 and fx4.read(fx4.destination) == good
          and fx4.read(fx4.stamp) == good_stamp and not leftovers,
          out + " leftovers=%s" % leftovers)

    # 10. The compiler "succeeds" with an empty file.  hrdl's driver would
    #     reject that at probe with a length error; catch it here instead.
    fx5 = Fixture(tmp, "compiler-empty")
    fx5.set_mode("empty")
    rc, out = run(script, fx5.compiler, fx5.source, fx5.destination)
    check(label + "an empty compiler output is refused",
          rc != 0 and not os.path.exists(fx5.destination)
          and "empty file" in out, out)

    # 11. An unwritable firmware directory.
    fx6 = Fixture(tmp, "unwritable")
    if os.geteuid() == 0:
        skip(label + "an unwritable destination fails loudly",
             "running as root: mode bits do not deny writes")
    else:
        os.chmod(fx6.firmware, stat.S_IRUSR | stat.S_IXUSR)
        try:
            rc, out = run(script, fx6.compiler, fx6.source, fx6.destination)
            check(label + "an unwritable destination fails loudly",
                  rc != 0 and "writable" in out, out)
        finally:
            os.chmod(fx6.firmware, 0o755)

    # 12. A symlinked firmware directory -- the guard pinenote-install-waveform
    #     already carries, for the same reason.
    fx7 = Fixture(tmp, "symlinked")
    elsewhere = os.path.join(fx7.root, "elsewhere")
    os.makedirs(elsewhere)
    link = os.path.join(fx7.root, "link")
    os.symlink(elsewhere, link)
    rc, out = run(script, fx7.compiler, fx7.source,
                  os.path.join(link, "custom_wf.bin"))
    check(label + "a symlinked firmware directory is refused",
          rc != 0 and "symlink" in out
          and not os.path.exists(os.path.join(elsewhere, "custom_wf.bin")),
          out)

    # 13. No sha256sum on PATH.  The freshness test cannot run, and the
    #     script must fall back to RECOMPILING rather than to trusting the
    #     file on disk -- the direction that cannot ship a stale CLUT.
    #     The tool list is deliberately exhaustive: a new external command in
    #     the installer breaks this branch instead of passing silently.
    needed = ["sh", "dirname", "basename", "cat", "cut", "mkdir", "mktemp",
              "chmod", "mv", "rm"]
    found = {c: shutil.which(c) for c in needed}
    missing = [c for c, p in found.items() if not p]
    if missing:
        skip(label + "a missing sha256sum recompiles instead of trusting",
             "no %s on this host" % ", ".join(missing))
    else:
        fx8 = Fixture(tmp, "no-sha256sum")
        shim = os.path.join(fx8.root, "bin")
        os.makedirs(shim)
        for cmd, path in found.items():
            os.symlink(path, os.path.join(shim, cmd))
        env = dict(os.environ)
        env["PATH"] = shim
        rc, out = run(script, fx8.compiler, fx8.source, fx8.destination,
                      env=env)
        first_ok = rc == 0 and len(fx8.calls) == 1
        rc, out2 = run(script, fx8.compiler, fx8.source, fx8.destination,
                       env=env)
        check(label + "a missing sha256sum recompiles instead of trusting",
              first_ok and rc == 0 and len(fx8.calls) == 2
              and "no sha256sum" in out2, out + out2)

    # 14. A custom stamp path, and a stamp that cannot be written: the CLUT
    #     still lands, because bookkeeping is not worth a blank screen.
    fx9 = Fixture(tmp, "stamp-elsewhere")
    stamp = os.path.join(fx9.root, "state", "clut.stamp")
    rc, out = run(script, fx9.compiler, fx9.source, fx9.destination, stamp)
    check(label + "a stamp in a missing directory warns but still installs",
          rc == 0 and os.path.exists(fx9.destination)
          and not os.path.exists(stamp)
          and "cannot write the freshness record" in out, out)

    return obs


# --------------------------------------------------------------------------
# the mutation control
# --------------------------------------------------------------------------

FRESHNESS_SITE = """elif [ -f "$destination" ] && [ -f "$stamp" ] &&
     [ "$(cat "$stamp" 2>/dev/null)" = "$(current_record)" ]; then"""

UPSTREAM_SHAPE = """elif [ -f "$destination" ]; then"""


def mutation_control(script, tmp):
    """Replace the checksum with upstream's compile-once-if-absent shape.

    hrdl's unit gates on `ExecCondition=/usr/bin/test ! -e custom_wf.bin'.
    If the branch tests above would pass for THAT too, they are testing
    nothing that matters, because it is precisely the stale-artifact hazard
    doc/direct-mode-adoption.md and issue #12 §7 name.  A moved site is a
    hard failure, not a skip.
    """
    with open(script) as fh:
        text = fh.read()
    if FRESHNESS_SITE not in text:
        check("mutation: the freshness test is where the control expects it",
              False, "the site moved; update FRESHNESS_SITE in this file")
        return
    check("mutation: the freshness test is where the control expects it", True)

    mutant = os.path.join(tmp, "mutant-install.sh")
    with open(mutant, "w") as fh:
        fh.write(text.replace(FRESHNESS_SITE, UPSTREAM_SHAPE))

    obs = branch_tests(mutant, os.path.join(tmp, "mutant-tree"),
                       label="", strict=False)

    must_break = ["a changed waveform forces a recompile",
                  "a changed compiler forces a recompile",
                  "a corrupted custom_wf.bin is rebuilt, not trusted"]
    still_true = [name for name in must_break if obs.get(name)]
    check("mutation: compile-once-if-absent fails the freshness branches",
          not still_true,
          "these passed for the mutant too: %s" % still_true)
    check("mutation: compile-once-if-absent still passes the first run",
          obs.get("a first run compiles the CLUT"),
          "the mutant is broken for unrelated reasons, so it controls nothing")


# --------------------------------------------------------------------------
# the rebind stage (D2, 2026-08-25)
# --------------------------------------------------------------------------

def rebind_tests(script, tmp):
    """The per-boot rebind: install alone is a file nobody reads.

    The initrd raw-loads rockchip_ebc before the rootfs exists, so under
    the direct-mode driver the first probe fails -EINVAL EVERY boot and
    the device sits unbound until something writes it back into the
    driver's `bind' file (hand-proven on glass 2026-08-25).  These cases
    drive the real script against FakeSysfs; see its docstring for what a
    static fixture can honestly claim.
    """
    # 1. Full cycle on a fresh compile: the device name lands in `unbind'
    #    then `bind', and the pre-wired good end state reads as success.
    fx = Fixture(tmp, "rb-cycle")
    sysfs = FakeSysfs(fx.root)
    sysfs.bind(minor=True)
    rc, out = run(script, fx.compiler, fx.source, fx.destination, sysfs=sysfs)
    check("rebind: a compile run unbinds and rebinds the device",
          rc == 0 and sysfs.wrote(sysfs.unbind_file) == sysfs.device
          and sysfs.wrote(sysfs.bind_file) == sysfs.device
          and "DRM minor present" in out, out)

    # 2. Nothing changed and the device is already bound with a minor: the
    #    script says so and touches NEITHER sysfs file (the sentinels
    #    survive) -- rebinding here would tear down a live display to
    #    re-read an identical CLUT.
    sysfs.reset_sentinels()
    rc, out = run(script, fx.compiler, fx.source, fx.destination, sysfs=sysfs)
    check("rebind: current CLUT on a bound device is a said-out-loud no-op",
          rc == 0 and "not rebinding" in out
          and sysfs.wrote(sysfs.bind_file) == "sentinel"
          and sysfs.wrote(sysfs.unbind_file) == "sentinel", out)

    # 3. Current CLUT, device NOT bound -- the NORMAL boot: the CLUT
    #    persisted on disk, the initrd probe failed again, and the rebind
    #    is the whole reason the service ran.  The script must attempt the
    #    bind even though nothing was compiled; and since a static fixture
    #    can never BECOME bound, the same run proves the end-state rule:
    #    still-unbound after the write is a loud failure, never a quiet
    #    green (a green service over a dark panel is the exact state this
    #    stage exists to prevent).  The installed CLUT must survive.
    fx2 = Fixture(tmp, "rb-boot")
    run(script, fx2.compiler, fx2.source, fx2.destination)  # install only
    sysfs2 = FakeSysfs(fx2.root)  # driver registered, device unbound
    rc, out = run(script, fx2.compiler, fx2.source, fx2.destination,
                  sysfs=sysfs2)
    check("rebind: a current CLUT still attempts the per-boot bind",
          "is current" in out
          and sysfs2.wrote(sysfs2.bind_file) == sysfs2.device
          and sysfs2.wrote(sysfs2.unbind_file) == "sentinel", out)
    check("rebind: a device that stays unbound is loud, with the CLUT intact",
          rc != 0 and "did not bind" in out and "dmesg" in out
          and os.path.exists(fx2.destination), out)

    # 4. No driver directory (the initrd never registered the driver):
    #    loud, names the directory -- and the CLUT still lands, because the
    #    install half succeeded before the rebind half could not.
    fx3 = Fixture(tmp, "rb-nodriver")
    sysfs3 = FakeSysfs(fx3.root)
    shutil.rmtree(sysfs3.driver_dir)
    rc, out = run(script, fx3.compiler, fx3.source, fx3.destination,
                  sysfs=sysfs3)
    check("rebind: a missing driver directory is loud; the CLUT still lands",
          rc != 0 and "no driver directory" in out
          and os.path.exists(fx3.destination), out)

    # 5. Bound but no DRM minor: bind is judged by the END STATE, and the
    #    bound link alone is not it -- a probe that binds without
    #    registering DRM is a dark panel that would otherwise read green.
    fx4 = Fixture(tmp, "rb-nominor")
    sysfs4 = FakeSysfs(fx4.root)
    sysfs4.bind(minor=False)
    rc, out = run(script, fx4.compiler, fx4.source, fx4.destination,
                  sysfs=sysfs4)
    check("rebind: bound without a DRM minor is a loud failure",
          rc != 0 and "no DRM minor" in out, out)

    # 6. A refused unbind: the WRITE status is the authority on that side
    #    -- proceeding would leave a driver bound against a stale CLUT
    #    while the service reports success.
    fx5 = Fixture(tmp, "rb-nounbind")
    sysfs5 = FakeSysfs(fx5.root)
    sysfs5.bind(minor=True)
    run(script, fx5.compiler, fx5.source, fx5.destination, sysfs=sysfs5)
    fx5.write_source("waveform-rev-2")  # force a recompile: no no-op path
    if os.geteuid() == 0:
        skip("rebind: a refused unbind is a loud failure",
             "running as root: mode bits do not deny writes")
    else:
        os.chmod(sysfs5.unbind_file, 0o444)
        try:
            rc, out = run(script, fx5.compiler, fx5.source, fx5.destination,
                          sysfs=sysfs5)
            check("rebind: a refused unbind is a loud failure",
                  rc != 0 and "cannot unbind" in out, out)
        finally:
            os.chmod(sysfs5.unbind_file, 0o644)

    # 7. Half a rebind target is a usage error, not a silent downgrade to
    #    install-only -- a truncated service invocation must not produce a
    #    green service over a dark panel.
    fx6 = Fixture(tmp, "rb-half")
    proc = subprocess.run(["sh", script, fx6.compiler, fx6.source,
                           fx6.destination, "", "/half/a/target"],
                          capture_output=True)
    out = (proc.stdout + proc.stderr).decode("utf-8", "replace")
    check("rebind: DRIVER_DIR without DEVICE is refused",
          proc.returncode != 0 and "usage" in out, out)

    #    ... and the mirror half.  The script guards both orders; a suite
    #    that pins only one is the exact "every branch" gap class this
    #    file's failure_guards docstring records.
    fx6b = Fixture(tmp, "rb-half-b")
    proc = subprocess.run(["sh", script, fx6b.compiler, fx6b.source,
                           fx6b.destination, "", "", "fdec0000.ebc"],
                          capture_output=True)
    out = (proc.stdout + proc.stderr).decode("utf-8", "replace")
    check("rebind: DEVICE without DRIVER_DIR is refused",
          proc.returncode != 0 and "usage" in out, out)


# --------------------------------------------------------------------------
# structural: who is allowed to instantiate this, and the ordering premise
# --------------------------------------------------------------------------

def failure_guards(script, tmp):
    """The three guards review found UNEXECUTED (2026-08-25).

    Each was deleted from a copy of the script and the suite stayed green,
    so "every branch" was false.  The most important is the mv guard: it
    prevents exactly the stale-artifact state the checksum design closes.
    Each case here exercises one guard through the real script.
    """
    # 1. The destination's parent is a regular FILE -> `mkdir -p || fail`.
    fx = Fixture(tmp, "guard-mkdir")
    blocked = os.path.join(fx.root, "blocked")
    with open(blocked, "w") as fh:
        fh.write("i am a file, not a directory")
    rc, out = run(script, fx.compiler, fx.source,
                  os.path.join(blocked, "rockchip", "custom_wf.bin"))
    check("guard: a file where the firmware directory should be is a hard "
          "failure", rc != 0, out[-300:])

    # 2. The destination directory is a SYMLINK -> the not-a-real-directory
    # guard (a symlinked firmware dir means we no longer know what we are
    # overwriting).
    fx = Fixture(tmp, "guard-symlink")
    real = os.path.join(fx.root, "elsewhere")
    os.makedirs(real)
    link = os.path.join(fx.root, "linkdir")
    os.symlink(real, link)
    rc, out = run(script, fx.compiler, fx.source,
                  os.path.join(link, "custom_wf.bin"))
    check("guard: a symlinked destination directory is refused",
          rc != 0, out[-300:])

    # 3. `mv` fails -> `mv -- ... || fail`, and the freshness stamp must NOT
    # advance.  Subtle: `mv file existing-dir` SUCCEEDS by moving INTO the
    # directory (the first version of this test got that wrong and the
    # review's suggested construction shares the mistake).  What genuinely
    # fails is mv INTO an unwritable directory: the temporary is created in
    # the writable parent, the compile succeeds, and the install step is
    # the first thing to fail -- which is exactly the guard under test.
    fx = Fixture(tmp, "guard-mv")
    os.makedirs(fx.destination)          # destination IS a directory...
    os.chmod(fx.destination, 0o555)      # ...that mv cannot write into
    if os.access(fx.destination, os.W_OK):
        skip("guard: a failed install is a hard failure",
             "running as root -- 0555 does not bind")
        skip("guard: a failed install does not advance the freshness stamp",
             "running as root")
        return
    rc, out = run(script, fx.compiler, fx.source, fx.destination,
                  stamp=fx.stamp)
    os.chmod(fx.destination, 0o755)      # let cleanup remove it
    stamp_after = fx.read(fx.stamp)
    check("guard: a failed install is a hard failure", rc != 0, out[-300:])
    check("guard: a failed install does not advance the freshness stamp",
          stamp_after is None,
          "a stamp that advances past a failed mv IS the stale-artifact bug: "
          + repr(stamp_after))


def structural(repo, service):
    with open(service) as fh:
        scm = fh.read()

    check("service: the CLUT installer is a shepherd one-shot",
          "(one-shot? #t)" in scm)
    check("service: it is ordered after pinenote-waveform and the params one-shot",
          "(requirement '(pinenote-waveform pinenote-ebc-direct-params))" in scm,
          "without the waveform edge shepherd races the compile against its"
          " own input; without the params edge the rebind runs before"
          " temp_override/default_hint land (doc/status.md 2026-08-27)")
    check("service: it is not an activation snippet",
          "activation-service-type" not in scm,
          "activation runs before the filesystems this writes to are ready")

    # The suite executes pinenote/services/ebc-clut-install.sh.  Nothing so
    # far proved the SERVICE hands shepherd that same file -- review proved
    # it by pointing the .scm at "ebc-clut-install-NOPE.sh": every check
    # still passed.  Pin the reference, and pin that the referenced file is
    # the one this suite ran.
    check("service: it hands shepherd the script under test",
          '(local-file "ebc-clut-install.sh"' in scm,
          "the .scm no longer references the file this suite executes -- "
          "the suite is testing an orphan")

    # The service must hand the installer its rebind target: without the
    # two trailing arguments the script is install-only, and on the device
    # that is a green service over a dark panel (the CLUT lands, nothing
    # re-probes).  Pin the accessors INSIDE the start gexp: the record
    # defaults existing elsewhere in the file is not evidence the start
    # lambda passes them.
    start_at = scm.find("(start")
    stop_at = scm.find("(stop", start_at if start_at >= 0 else 0)
    start = scm[start_at:stop_at] if 0 <= start_at < stop_at else ""
    check("service: the start gexp passes the rebind target",
          "pinenote-ebc-clut-driver-directory" in start
          and "pinenote-ebc-clut-device" in start,
          "the start lambda no longer hands the script DRIVER_DIR/DEVICE -- "
          "the service would install the CLUT and never rebind")

    # Since the embrace sweep's S2 (2026-09-03) the reader itself carries
    # the CLUT service -- in POSITIVE form: exactly the reader instantiates
    # it (a negative pin passed green while NO flavor instantiated it, which
    # is the image the 2026-08-25 session booted: no clut service, D1 by
    # hand).  This fires both when the wiring is dropped and when it leaks
    # into a bringup flavor.
    systems = os.path.join(repo, "pinenote", "systems")
    users = []
    for name in sorted(os.listdir(systems)):
        if not name.endswith(".scm"):
            continue
        with open(os.path.join(systems, name)) as fh:
            body = fh.read()
        if "ebc-direct" in body or "pinenote-ebc-clut" in body:
            users.append(name)
    check("exactly the reader flavor instantiates the CLUT service",
          users == ["pinenote-reader.scm"], str(users))
    flavor_path = os.path.join(systems, "pinenote-reader.scm")
    flavor = ""
    if os.path.isfile(flavor_path):
        with open(flavor_path) as fh:
            flavor = fh.read()
    check("and it instantiates the service type, not just the module",
          "(service pinenote-ebc-clut-service-type)" in flavor,
          "importing (pinenote services ebc-direct) without instantiating "
          "pinenote-ebc-clut-service-type is the 2026-08-25 gap again")
    session_path = os.path.join(repo, "pinenote", "services", "reader-session.scm")
    with open(session_path) as fh:
        session = fh.read()
    check("and reader-session requires the CLUT one-shot (decision 9)",
          "pinenote-ebc-clut" in session,
          "reader-session no longer waits for the CLUT and rebind; the first "
          "paint can race the probe again")

    # The ordering premise D7 records.  Both halves are mechanism, not prose:
    # if either moves, the direct-mode plan's account of when probe happens
    # is out of date and the note has to be rewritten.
    initrd = os.path.join(repo, "pinenote", "images", "pinenote-initramfs.scm")
    with open(initrd) as fh:
        initrd_text = fh.read()
    raw_loaded = ('"rockchip_ebc"' in initrd_text
                  and "load-linux-modules-from-directory" in initrd_text)
    # An EXECUTED modprobe, not a mention: every service that really runs one
    # invokes the kmod binary by path (usb-gadget.scm, dmc.scm, orientation.scm),
    # so a file pairing "/bin/modprobe" with the bare module name is the
    # precise signature.  (pinenote services ebc) only writes
    # /etc/modprobe.d/rockchip_ebc.conf and matches neither half.
    loaders = []
    for where in ("services", "systems"):
        base = os.path.join(repo, "pinenote", where)
        for name in sorted(os.listdir(base)):
            if not name.endswith(".scm"):
                continue
            with open(os.path.join(base, name)) as fh:
                body = fh.read()
            if "/bin/modprobe" in body and '"rockchip_ebc"' in body:
                loaders.append(name)
    check("D7 premise: rockchip_ebc is still raw-loaded from the initrd, and "
          "no service modprobes it",
          raw_loaded and not loaders,
          "raw_loaded=%s loaders=%s -- if this changed, probe no longer "
          "happens in the initramfs and doc/direct-mode-adoption.md D7 must "
          "be rewritten" % (raw_loaded, loaders))


def guix_module_loads(repo):
    guix = shutil.which("guix")
    if not guix:
        skip("(pinenote services ebc-direct) compiles",
             "no guix on PATH (this is the CI case)")
        return
    with tempfile.NamedTemporaryFile("w", suffix=".scm", delete=False) as fh:
        # Also evaluate the rebind-target accessors: the structural grep
        # above only matched their names; this proves the record fields
        # are real and carry the sysfs defaults the device needs.
        fh.write("(use-modules (gnu services) (pinenote services ebc-direct))\n"
                 "(display (service-type-name pinenote-ebc-clut-service-type))\n"
                 "(newline)\n"
                 "(display (pinenote-ebc-clut-driver-directory\n"
                 "          (pinenote-ebc-clut-configuration)))\n"
                 "(newline)\n"
                 "(display (pinenote-ebc-clut-device\n"
                 "          (pinenote-ebc-clut-configuration)))\n")
        probe = fh.name
    try:
        proc = subprocess.run([guix, "repl", "-L", repo, probe],
                              capture_output=True, timeout=600)
        check("(pinenote services ebc-direct) compiles",
              proc.returncode == 0
              and b"pinenote-ebc-clut" in proc.stdout
              and b"/sys/bus/platform/drivers/rockchip-ebc" in proc.stdout
              and b"fdec0000.ebc" in proc.stdout,
              (proc.stdout + proc.stderr).decode("utf-8", "replace")[-800:])
    except subprocess.TimeoutExpired:
        skip("(pinenote services ebc-direct) compiles", "guix repl timed out")
    finally:
        os.unlink(probe)


def main(argv):
    repo = os.path.abspath(argv[1]) if len(argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    script = os.path.join(repo, "pinenote", "services", "ebc-clut-install.sh")
    service = os.path.join(repo, "pinenote", "services", "ebc-direct.scm")
    for path in (script, service):
        if not os.path.isfile(path):
            print("FAIL: no such file: %s" % path)
            return 1

    print("subject: %s" % script)
    tmp = tempfile.mkdtemp(prefix="wilkbook-ebc-clut-")
    try:
        branch_tests(script, tmp)
        mutation_control(script, tmp)
        failure_guards(script, tmp)
        rebind_tests(script, tmp)
        structural(repo, service)
        guix_module_loads(repo)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("ebc-clut installer: %d checks, %d failed"
          % (CHECKS[0], FAILURES[0]))
    if FAILURES[0]:
        print("TESTS FAILED")
        return 1
    print("ALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
