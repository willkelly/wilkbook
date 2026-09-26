#!/usr/bin/env python3
"""Process/profile fixture only: Guile owns all workspace and protocol operations."""

import argparse
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

TOOL = Path(__file__).resolve().parent
TEMP_PARENT = Path("/tmp/opencode")
STOP_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)


def private_directory(path):
    if not path.is_absolute() or any(ord(c) < 32 for c in str(path)):
        raise ValueError("DIRECTORY must be an absolute private directory path")
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700 or path.resolve() != path):
        raise ValueError(f"expected a canonical, user-owned mode-0700 directory: {path}")
    return path


def check_directory(parent):
    private_directory(parent)
    workspace = parent / "workspace"
    if os.path.lexists(workspace):
        private_directory(workspace)
    return workspace


def dependency(name):
    value = os.environ.get(name)
    if not value or not Path(value).is_absolute():
        raise ValueError(f"{name} must name an absolute native dependency directory")
    path = Path(value).resolve(strict=True)
    if not path.is_dir():
        raise ValueError(f"{name} is not a directory: {path}")
    return path


def executable(path):
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"native executable is unavailable: {path}")
    return str(path)


def environment(root, supervisor):
    home = root / "home"
    for path in (home, home / ".config", home / ".cache", home / ".local/share",
                 root / "ko/plugins", root / "tmp"):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Construct from scratch: no inherited Guile/Lua module paths, preload
    # hooks, user profiles or authored-source selectors reach either process.
    return {
        "HOME": str(home), "KO_HOME": str(root / "ko"), "KO_MULTIUSER": "1",
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "TMPDIR": str(root / "tmp"), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
        "PATH": str(supervisor / "bin"), "GUILE_AUTO_COMPILE": "0",
        "GUILE_LOAD_PATH": ":".join(map(str, (
            TOOL, TOOL.parent / "book-protocol", TOOL.parent / "book-session",
            supervisor / "share/guile/site/3.0"))),
        "GUILE_LOAD_COMPILED_PATH": str(supervisor / "lib/guile/3.0/site-ccache"),
    }


def child_status(process):
    # WNOWAIT keeps the direct child's PID reserved until group cleanup; poll()
    # would reap it and permit an unrelated process to reuse that identity.
    info = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if info is None:
        return None
    return info.si_status if info.si_code == os.CLD_EXITED else 128 + info.si_status


def signal_group(process, signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def stop_children(processes, reader=None):
    if reader is not None:
        signal_group(reader, signal.SIGTERM)
        # EOF is a courtesy grace, not proof of preview cleanup: SQLite waits
        # can delay the start of its <=3s execution budget. The authority's TERM
        # handler must then cancel and unwind its separately grouped runner.
        deadline = time.monotonic() + 4
        while any(child_status(p) is None for p in processes) and time.monotonic() < deadline:
            time.sleep(0.05)
    for process in processes:
        signal_group(process, signal.SIGTERM)
    deadline = time.monotonic() + 2
    while any(child_status(p) is None for p in processes) and time.monotonic() < deadline:
        time.sleep(0.05)
    # Signal even an exited leader's group, then reap. Descendants may still be
    # running after their leader exits; each leader's identity is still reserved.
    for process in processes:
        signal_group(process, signal.SIGKILL)
    failure = None
    for process in processes:
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired as error:
            failure = error
    if failure is not None:
        raise failure


def wait_for(process, stopped, authority=None):
    authority_status = None
    while not stopped():
        # Keep the reader open after authority closure so its disconnect status
        # and any unsaved text remain visible until the operator exits it.
        if authority is not None and authority_status is None:
            authority_status = child_status(authority)
            if authority_status:
                print(f"book-workbench: authority exited {authority_status}; close KOReader to finish",
                      file=sys.stderr)
        status = child_status(process)
        if status is not None:
            return status or authority_status or 0
        time.sleep(0.05)
    return 128 + stopped()


def run(workspace, root, supervisor, export, stopped):
    guile = executable(supervisor / "bin/guile")
    env = environment(root, supervisor)
    processes = []
    reader = None
    try:
        if export:
            process = subprocess.Popen(
                [guile, "--no-auto-compile", str(TOOL / "export-active.scm"),
                 str(workspace), str(TOOL / "seed.scm"), guile],
                env=env, cwd=root, stdin=subprocess.DEVNULL, start_new_session=True)
            processes.append(process)
            return wait_for(process, stopped)

        reader_dir = dependency("KOREADER_NATIVE_BUNDLE") / "lib/koreader"
        luajit = executable(reader_dir / "luajit")
        if not (reader_dir / "reader.lua").is_file():
            raise ValueError(f"KOReader entrypoint is unavailable: {reader_dir}")
        entrypoint = TOOL / "desktop-reader.lua"
        if not entrypoint.is_file():
            raise ValueError(f"Workbench desktop entrypoint is unavailable: {entrypoint}")
        plugin = TOOL / "plugin/bookworkbench.koplugin"
        for name in ("main.lua", "_meta.lua", "workbench_channel.lua"):
            if not (plugin / name).is_file():
                raise ValueError(f"Workbench plugin is incomplete: {plugin / name}")
        shutil.copytree(plugin, root / "ko/plugins/bookworkbench.koplugin")
        book = root / "workbench.txt"
        book.write_text(
            "Book Workbench — trusted-native developer fixture\n\n"
            "Open More tools → Book Workbench (experimental) from KOReader's tools menu.\n",
            encoding="utf-8")
        reader_env = env.copy()
        reader_env["PATH"] += os.pathsep + str(reader_dir)
        reader_env["SDL_AUDIODRIVER"] = "dummy"
        # Desktop display selection is operator-controlled, including an
        # explicit SDL_VIDEODRIVER=offscreen for native launch tests.
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "XDG_RUNTIME_DIR",
                     "SDL_VIDEODRIVER", "SDL_AUDIODRIVER"):
            if name in os.environ:
                reader_env[name] = os.environ[name]
        if reader_env.get("SDL_VIDEODRIVER") != "offscreen":
            graphics = dependency("BOOK_WORKBENCH_GRAPHICS")
            for relative in ("lib/libEGL.so.1", "lib/libGLESv2.so.2"):
                if not (graphics / relative).is_file():
                    raise ValueError(f"desktop graphics input is unavailable: {graphics / relative}")
            reader_env.update({
                "SDL_EGL_LIBRARY": str(graphics / "lib/libEGL.so.1"),
                "SDL_OPENGL_LIBRARY": str(graphics / "lib/libGLESv2.so.2"),
                "SDL_RENDER_DRIVER": "opengles2",
            })
        # Xlib's implicit ~/.Xauthority must still name the operator's
        # display cookie after HOME moves to the disposable reader profile.
        if "XAUTHORITY" not in reader_env and (Path.home() / ".Xauthority").is_file():
            reader_env["XAUTHORITY"] = str(Path.home() / ".Xauthority")
        ui_socket, authority_socket = socket.socketpair()
        with ui_socket, authority_socket:
            authority = subprocess.Popen(
                [guile, "--no-auto-compile", str(TOOL / "native-authority.scm"),
                 "--trusted-native-fixture", str(authority_socket.fileno()),
                 str(workspace), str(TOOL / "seed.scm"), guile,
                 str(TOOL / "workbench-runner.scm"), str(TOOL.parent / "book-protocol")],
                env=env, cwd=root, pass_fds=(authority_socket.fileno(),),
                stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
                start_new_session=True)
            processes.append(authority)
            authority_socket.close()
            reader_env["BOOK_WORKBENCH_UI_FD"] = str(ui_socket.fileno())
            reader = subprocess.Popen(
                [luajit, str(entrypoint), str(book)], env=reader_env, cwd=reader_dir,
                pass_fds=(ui_socket.fileno(),), stdin=subprocess.DEVNULL,
                stdout=sys.stderr, stderr=sys.stderr, start_new_session=True)
            processes.append(reader)
        return wait_for(reader, stopped, authority)
    finally:
        stop_children(processes, reader)


def main():
    parser = argparse.ArgumentParser(
        prog="run-native-demo.sh", description="Trusted-native developer Workbench fixture.",
        epilog="Native authored Guile has your host user privileges. Dependencies are lowered "
               "with Guix through channels.scm; BOOK_WORKBENCH_SUPERVISOR, KOREADER_NATIVE_BUNDLE "
               "and BOOK_WORKBENCH_GRAPHICS can select explicit cached native outputs. "
               "SDL_VIDEODRIVER=offscreen is opt-in.")
    parser.add_argument("--export", action="store_true",
                        help="print the sealed active artifact to stdout, without launching KOReader")
    parser.add_argument("--check-directory", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("directory", type=Path, metavar="DIRECTORY",
                        help="existing absolute, user-owned mode-0700 parent; data stays in DIRECTORY/workspace")
    args = parser.parse_args()
    try:
        workspace = check_directory(args.directory)
        if args.export:
            private_directory(workspace)
        if args.check_directory:
            return 0
        os.umask(0o077)
        if not args.export:
            workspace.mkdir(mode=0o700, exist_ok=True)
            private_directory(workspace)
        supervisor = dependency("BOOK_WORKBENCH_SUPERVISOR")
        stop_signal = 0

        def request_stop(signum, _frame):
            nonlocal stop_signal
            # Record rather than raise: a signal between Popen and append must
            # not strand a child, and repeated signals must not interrupt reap.
            stop_signal = stop_signal or signum

        for signum in STOP_SIGNALS:
            signal.signal(signum, request_stop)
        TEMP_PARENT.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="book-workbench-native-", dir=TEMP_PARENT) as name:
            return run(workspace, Path(name), supervisor, args.export, lambda: stop_signal)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"book-workbench: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
