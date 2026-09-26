#!/usr/bin/env python3
"""Dedicated native execution owner. Never a sandbox or source interpreter.

Each instance is a separate Linux subreaper for exactly one authored execution.
The coordinator's other executions and children cannot become this owner's
descendants. Only this process may reap all of its children during cleanup.
"""
import ctypes
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import time


def cleanup(deadline):
    while True:
        # These are unreaped direct children, so their PIDs remain reserved.
        # Killing a parent adopts its descendants here, including setsid forks.
        children = list(map(int, Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()))
        for pid in children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                break
        if time.monotonic() >= deadline:
            raise TimeoutError("native execution descendants were not completely reaped")
        time.sleep(0.005)


def main():
    control_fd, guile, runner, source, protocol = sys.argv[1:]
    control = socket.socket(fileno=int(control_fd))
    control.set_inheritable(False)
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    stopped = False

    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, stop)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    acquired = False
    try:
        child = subprocess.Popen(
            [guile, "--no-auto-compile", "-L", protocol, runner,
             "--trusted-native-fixture", source, guile, protocol],
            stdin=0, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            close_fds=True)
        acquired = True
        # The owner must not keep the authored transport alive after the runner
        # exits. The distinct control descriptor never reaches the runner.
        null = os.open("/dev/null", os.O_RDONLY)
        os.dup2(null, 0)
        os.close(null)
        started = False
        deadline = time.monotonic() + 3
        while not stopped:
            info = os.waitid(os.P_PID, child.pid,
                             os.WSTOPPED | os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if info is not None:
                if info.si_code != os.CLD_STOPPED or info.si_status != signal.SIGSTOP:
                    break
                os.waitpid(child.pid, os.WUNTRACED)
                os.kill(child.pid, signal.SIGCONT)
                started = True
                break
            if time.monotonic() >= deadline:
                break
            if select.select([control], [], [], 0.005)[0]:
                control.recv(16)
                stopped = True
        while started and not stopped:
            if os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
                break
            if select.select([control], [], [], 0.1)[0]:
                control.recv(16)
                stopped = True
    finally:
        if acquired:
            cleanup(time.monotonic() + 2)
        # This acknowledgement is proof of complete per-execution reaping,
        # independent of whether the authored program succeeded or failed.
        try:
            control.sendall(b"clean\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        control.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"native-child-owner: {error}", file=sys.stderr)
        sys.exit(1)
