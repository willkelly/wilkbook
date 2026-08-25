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
are `make clut-check''s job, and it is byte-identical-or-fail.  Nothing here
has loaded a module, and no panel has ever run this driver.

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


def run(script, compiler, source, destination, stamp=None, env=None):
    argv = ["sh", script, compiler, source, destination]
    if stamp is not None:
        argv.append(stamp)
    environ = dict(os.environ)
    if env is not None:
        environ = env
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
    check("service: it is ordered after pinenote-waveform",
          "(requirement '(pinenote-waveform))" in scm,
          "without the edge shepherd races the compile against its own input")
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

    # Rule 4 of the direct-mode work: nothing here may reach a shipping
    # image.  This fires the day someone adds it to a flavor whose name does
    # not say `direct'.
    systems = os.path.join(repo, "pinenote", "systems")
    offenders = []
    for name in sorted(os.listdir(systems)):
        if not name.endswith(".scm"):
            continue
        with open(os.path.join(systems, name)) as fh:
            body = fh.read()
        if "ebc-direct" in body or "pinenote-ebc-clut" in body:
            if "direct" not in name:
                offenders.append(name)
    check("no flavor outside the direct-mode study instantiates the CLUT service",
          not offenders, str(offenders))

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
        fh.write("(use-modules (gnu services) (pinenote services ebc-direct))\n"
                 "(display (service-type-name pinenote-ebc-clut-service-type))\n")
        probe = fh.name
    try:
        proc = subprocess.run([guix, "repl", "-L", repo, probe],
                              capture_output=True, timeout=600)
        check("(pinenote services ebc-direct) compiles",
              proc.returncode == 0
              and b"pinenote-ebc-clut" in proc.stdout,
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
