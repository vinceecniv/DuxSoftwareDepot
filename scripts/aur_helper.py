#!/usr/bin/env python3
"""Build and install AUR packages through paru or yay with no terminal,
emitting a small subset of the NDJSON event protocol (see PROTOCOL.md).

Usage: aur_helper.py [--refresh] <name>...

The DMS daemon's own AUR pass opens a terminal because paru and yay want a
tty for their menus and for sudo. Neither is needed here: the menus are
answered up front (no PKGBUILD review, which is the choice the user made by
switching this on) and sudo is replaced with scripts/aur_sudo.sh: sudo where
it would not ask for a password, otherwise polkit — so any prompt is the
shell's own dialog.

`--refresh` makes it `-Sy`: the caller asks for it when no official pass ran
before this one. That pass is what refreshes the sync databases otherwise
(pacman_helper.py), and paru resolves an AUR package's repository
dependencies against them — a stale copy cannot know a dependency that came
out since, nor find the old file it names on a mirror that has moved on.

Events: op-start {name, phase: "build"}, op-done {name, phase: "build"} when
its build finished (installing comes after, in one batch with paru), output
{text} with the tail of what paru/yay printed, error {message, refused?},
done {ok, failed}. Whether a package really arrived is decided by the
caller, against the package database.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAKING = re.compile(r"^==> Making package: (\S+)")
# pkexec's own words when the prompt was cancelled or refused
REFUSED = re.compile(r"Error executing command as another user: (Request dismissed|Not authorized)")
TAIL_LINES = 40


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def argv_for(helper, sudo, names, refresh=False):
    sync = "-Sy" if refresh else "-S"
    common = ["--noconfirm", "--sudo", sudo]
    if helper == "paru":
        return ["paru", sync, "--skipreview", "--nosudoloop", "--batchinstall"] + common + names
    return ["yay", sync, "--answerclean", "None", "--answerdiff", "None",
            "--answeredit", "None"] + common + names


def main():
    refresh = "--refresh" in sys.argv[1:]
    names = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not names:
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    helper = next((h for h in ("paru", "yay") if shutil.which(h)), "")
    if not helper:
        emit({"event": "error", "message": "neither paru nor yay is installed"})
        emit({"event": "done", "ok": False, "failed": names})
        return 1
    sudo = os.path.join(HERE, "aur_sudo.sh")
    try:
        os.chmod(sudo, 0o755)
    except OSError:
        pass
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    env.pop("LANGUAGE", None)
    try:
        proc = subprocess.Popen(argv_for(helper, sudo, names, refresh), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace", env=env)
    except OSError as exc:
        emit({"event": "error", "message": "%s could not start: %s" % (helper, exc)})
        emit({"event": "done", "ok": False, "failed": names})
        return 1

    def stop(_sig, _frame):
        proc.terminate()
    signal.signal(signal.SIGTERM, stop)

    wanted = set(names)
    current = ""
    tail = []
    refused = False
    for line in proc.stdout:
        line = line.rstrip("\n")
        tail = (tail + [line])[-TAIL_LINES:]
        refused = refused or bool(REFUSED.search(line))
        match = MAKING.match(line)
        if match and match.group(1) in wanted and match.group(1) != current:
            if current:
                emit({"event": "op-done", "name": current, "phase": "build"})
            current = match.group(1)
            emit({"event": "op-start", "name": current, "phase": "build"})
    code = proc.wait()
    if code == 0 and current:
        emit({"event": "op-done", "name": current, "phase": "build"})
    emit({"event": "output", "text": "\n".join(tail).strip()})
    if code == 0:
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    message = "\n".join(tail).strip() or "%s exited with code %d" % (helper, code)
    emit({"event": "error", "message": message, "refused": refused})
    emit({"event": "done", "ok": False, "failed": names})
    return 1


if __name__ == "__main__":
    sys.exit(main())
