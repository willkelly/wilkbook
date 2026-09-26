#!/usr/bin/env python3
"""Fixed ARM64 QEMU scenario; never selects a native execution fallback.

The service supplies immutable inputs and private mounted storage. Authored
source is opaque to this coordinator and executes only through sandbox_command.
This exercises the production session coordinator; native widget tests prove
the distinct KOReader rendering/interaction boundary.
"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import sys

TOOL = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("editor", TOOL / "native-editor.py")
editor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(editor)


def run(supervisor, command, workspace_parent, runtime_parent):
    os.umask(0o077)
    editor.TEMP_PARENT.mkdir(mode=0o700, parents=True, exist_ok=True)
    editor.subreaper()
    checks = 0
    session = None
    owned_root = editor.PrivateTree("editor-scenario-")
    root = Path(owned_root.name)
    workspace = Path(tempfile.mkdtemp(prefix="editor.", dir=workspace_parent))
    baseline = set(Path("/sys/fs/cgroup").glob("wilkbook-execution-*"))
    seed = (TOOL / "editor-seed.scm").read_text()

    def check(label, value):
        nonlocal checks
        if not value:
            raise AssertionError(label)
        checks += 1
        print("BOOK_WORKBENCH_EDITOR_CHECK: " + label, flush=True)

    def until(predicate, timeout=35):
        end = time.monotonic() + timeout
        while not predicate():
            session.pump()
            if session.failure:
                raise RuntimeError("editor session failed: " + session.failure)
            if time.monotonic() >= end:
                raise TimeoutError("editor scenario observation deadline")
            time.sleep(0.01)

    def action(target, name, text=None):
        old = target.form["sequence"]
        target.action(name, text)
        until(lambda: target.form["sequence"] != old)
        return target.form

    def snapshot(target=None):
        target = target or session
        target.command("host-snapshot")
        return target.snapshot.copy()

    def preview():
        session.action("preview")
        until(lambda: session.preview is not None and session.preview.form is not None)
        return session.preview

    def finish(accept):
        old = session.form["sequence"]
        session.finish_preview(accept)
        until(lambda: session.form["sequence"] != old)

    def groups():
        return set(Path("/sys/fs/cgroup").glob("wilkbook-execution-*")) - baseline

    def live_controls(count):
        current = groups()
        return len(current) == count and all(
            (group / "memory.max").read_text().strip() == "268435456"
            and (group / "cpu.max").read_text().strip() == "50000 100000"
            and (group / "pids.max").read_text().strip() == "256"
            for group in current)

    try:
        session = editor.EditorSession(workspace, root, supervisor,
                                       sandbox_command=command,
                                       startup_timeout=20, action_timeout=20)
        until(lambda: session.form is not None)
        check("initial sandbox editor form and ready controls",
              session.form["title"] == "Source Workbench" and session.owner_ready
              and live_controls(1))
        owner = session.child.pid
        initial = snapshot()
        check("source-defined successor operation", action(session, "successor")["text"] == seed)
        successor = seed.replace('"Source Workbench"', '"Sandbox R1"')
        check("saved successor through workspace grant",
              "Draft saved" in action(session, "save", successor)["status"])
        saved = snapshot()
        check("save preserves installed revision", saved["workspace-version"] == 1
              and saved["active-revision"] == initial["active-revision"])
        candidate = preview()
        candidate_root = Path(session.preview_root.name)
        check("two simultaneous isolated editor domains", live_controls(2)
              and candidate.child.pid != owner and candidate.owner_ready
              and candidate.form["title"] == "Sandbox R1")
        candidate_owner = candidate.child.pid
        check("candidate actions run interactively",
              action(candidate, "insert-header")["text"].startswith(";;; Edited in Source Workbench"))
        check("candidate grant disables privileged UI actions",
              all(not item["enabled"] for item in candidate.form["actions"]
                  if item["id"] in ("preview", "install", "export")))
        check("candidate disposable save", "Draft saved" in action(candidate, "save", "preview-only draft")["status"])
        check("candidate disposable read", action(candidate, "read")["text"] == "preview-only draft")
        check("candidate writes never change author workspace", snapshot() == saved
              and snapshot(candidate)["workspace-version"] == 1)
        check("multiple actions reuse both live execution owners",
              session.child.pid == owner and candidate.child.pid == candidate_owner)
        # Human think time must not consume either action deadline. Lower only
        # the future-action budget; do not delay a running request in this test.
        candidate.action_timeout = session.action_timeout = 0.1
        for _ in range(5):
            time.sleep(0.1)
            session.pump()
        check("human preview idle has no action clock",
              session.deadline is None and candidate.deadline is None
              and not session.failure and not candidate.failure)
        candidate.action_timeout = session.action_timeout = 20
        finish(True)
        check("finish destroys preview before returning author receipt",
              session.preview is None and not candidate_root.exists()
              and candidate.owner_exit_status == 0
              and live_controls(1) and snapshot() == saved)
        session.action("install")
        until(lambda: session.proposal is not None)
        check("proposal alone has no activation", snapshot() == saved)
        old = session.form["sequence"]
        session.confirm()
        until(lambda: session.form["sequence"] != old)
        installed = snapshot()
        check("trusted confirmation activates exact saved successor",
              installed["activation-generation"] == 1
              and installed["active-revision"] != initial["active-revision"])
        session.command("host-reopen")
        until(lambda: session.form is not None)
        check("installed sandbox successor executes after reopen",
              session.form["title"] == "Sandbox R1" and session.child.pid != owner
              and action(session, "successor")["text"] == successor)
        candidate = preview()
        candidate_root = Path(session.preview_root.name)
        finish(False)
        check("cancel disposes preview without author write",
              not candidate_root.exists() and live_controls(1) and snapshot() == installed)
        check("cancel does not grant an installation ticket",
              "preview" in action(session, "install")["status"].lower()
              and session.proposal is None and snapshot() == installed)
        # Trusted QEMU-only control drift, targeting exactly the newly created
        # candidate group. It tightens quota; the owner must still reject it.
        author_groups = groups()
        candidate = preview()
        candidate_group, = groups() - author_groups
        (candidate_group / "cpu.max").write_text("49000 100000\n")
        end = time.monotonic() + 12
        while editor.status(candidate.child) is None:
            if time.monotonic() >= end:
                raise TimeoutError("candidate owner did not reject changed controls")
            time.sleep(0.05)
        finish(True)
        check("contained owner failure cannot authorize Finish",
              candidate.owner_exit_status == 1 and "failed" in session.form["status"].lower()
              and live_controls(1) and snapshot() == installed)
        check("owner failure grants no installation ticket",
              "preview" in action(session, "install")["status"].lower()
              and session.proposal is None)
        # Exercise a hung *action* rather than just startup: the candidate must
        # first paint, then remain separately cancellable while its author waits.
        looping = successor.replace('(let ((next (string-append header-text text)))',
                                    '(let ((next (let loop () (loop))))')
        action(session, "save", looping)
        before_loop = snapshot()
        candidate = preview()
        candidate.action("insert-header")
        finish(False)
        check("trusted cancellation interrupts an outstanding candidate action",
              live_controls(1) and snapshot() == before_loop and not session.failure)
        candidate = preview()
        candidate.action_timeout = 1
        candidate.action("insert-header")
        until(lambda: session.preview is None and session.preview_failure is not None)
        check("failed candidate is disposed while awaiting trusted dismissal",
              live_controls(1) and snapshot() == before_loop)
        finish(False)
        check("hung candidate action fails after owned cleanup",
              "failed" in session.form["status"].lower() and live_controls(1)
              and snapshot() == before_loop)
        session.command("host-recover", kind="seed")
        until(lambda: session.form is not None)
        check("trusted seed recovery preserves broken saved draft",
              session.form["title"] == "Source Workbench"
              and session.form["text"] == looping
              and snapshot()["workspace-version"] == before_loop["workspace-version"])
        check("fresh action succeeds after failed preview", action(session, "successor")["text"] == seed)
        recovered = snapshot()
        session.close()
        session = None
        check("complete coordinator shutdown before recovery",
              not groups() and not list(runtime_parent.iterdir()) and not editor.LIVE)
        restarted_root = root / "restart"
        restarted_root.mkdir(mode=0o700)
        session = editor.EditorSession(workspace, restarted_root, supervisor,
                                       sandbox_command=command,
                                       startup_timeout=20, action_timeout=20)
        until(lambda: session.form is not None)
        check("fresh coordinator recovers installed seed and saved draft",
              session.form["title"] == "Source Workbench" and session.form["text"] == looping
              and snapshot() == recovered and live_controls(1))
        session.close()
        session = None
        check("all sandbox and coordinator lifetimes cleaned",
              not groups() and not list(runtime_parent.iterdir()) and not editor.LIVE)
        mounts = Path("/proc/self/mountinfo").read_text().splitlines()
        check("no retained runtime mounts", not any(str(runtime_parent) in line.split()[4]
                                                  for line in mounts))
        owned_root.cleanup()
        print("BOOK_WORKBENCH_EDITOR: " + json.dumps({"status": "pass", "checks": checks,
              "workspace": workspace.name, "backend": command.name}), flush=True)
    finally:
        if session is not None:
            session.close()
        # Keep the authority database on the retained ext4 artifact. Runtime
        # evidence on failure is retained for diagnosis, not recursively erased.


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("requires supervisor sandbox-command workspace-parent runtime-parent")
    try:
        run(*(Path(value) for value in sys.argv[1:]))
    except BaseException as error:
        # Diagnostics can contain captured authored stderr. Escape it as data,
        # never raw console lines that resemble trusted success/failure markers.
        print("BOOK_WORKBENCH_EDITOR_FAILURE: " + json.dumps({
            "kind": type(error).__name__, "error": str(error)[:8192]}), flush=True)
        raise SystemExit(1)
