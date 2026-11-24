#!/usr/bin/env python3
"""Build and install AUR packages through paru or yay with no terminal,
emitting a small subset of the NDJSON event protocol (see PROTOCOL.md).

Usage: aur_helper.py [--use-sudo] <name>...

The DMS daemon's own AUR pass opens a terminal because paru and yay want a
tty for their menus and for sudo. Neither is needed here: the menus are
answered up front (no PKGBUILD review, which is the choice the user made by
switching this on) and sudo is replaced with scripts/aur_sudo.sh: polkit, so
any prompt is the shell's own dialog — or, with --use-sudo (the plugin's
"Authorise with sudo"), sudo where it would not ask for a password.

No `-y`: the update run always puts the full official upgrade first
(pacman_helper.py sysupgrade), which refreshes the sync databases and
brings the system up to them, so paru resolves against current ones.

pacman's lock is checked before paru starts, because paru does not give up
on a held lock: it says "Pacman is currently in use, please wait..." once
and waits for as long as it takes. A run with nobody to answer a prompt in
another terminal then waits forever. So a lock another package manager
holds fails the pass at once, naming it; a lock nothing holds (left by an
interrupted update) fails it too, since only root can clear it and the next
update does that. A lock that appears while paru runs is said as a status,
so the window can say what it is waiting for, and can be cancelled.

Events: op-start {name, phase: "build"}, op-done {name, phase: "build"} when
its build finished (installing comes after, in one batch with paru), status
{message: "waiting-lock", holder} while paru waits for another package
manager, output {text} with the tail of what paru/yay printed, error
{message, refused?, busy?, stale?}, done {ok, failed}. Whether a package really arrived is decided by the
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
# paru (and yay) when pacman's lock is held: said once, then it waits
LOCK_WAIT = re.compile(r"currently in use, please wait", re.I)
# The same list pacman_helper.py keeps
PACKAGE_MANAGERS = {"pacman", "pacman-key", "pacman-db-upgrade", "makepkg", "paru",
                    "yay", "pikaur", "trizen", "pamac", "pamac-daemon", "packagekitd"}
TAIL_LINES = 40


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _test_hook(name):
    """A path the tests stand in for. This helper never runs as root, and
    the hook is refused if it ever does."""
    return os.environ.get(name) or None if os.geteuid() != 0 else None


def lock_path():
    dbpath = _test_hook("DSD_PACMAN_DBPATH")
    if not dbpath:
        try:
            dbpath = subprocess.run(["pacman-conf", "DBPath"], capture_output=True, text=True,
                                    timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            dbpath = ""
    return os.path.join((dbpath or "/var/lib/pacman").rstrip("/"), "db.lck")


def holder():
    """The package manager running now, other than this process and the
    ones it runs under, as "pid N (its command line)"; "" when there is none."""
    proc_root = _test_hook("DSD_PROC") or "/proc"
    own = set()
    pid = os.getpid()
    while pid > 1 and pid not in own:
        own.add(pid)
        try:
            with open(os.path.join(proc_root, str(pid), "status")) as fh:
                pid = next((int(l.split()[1]) for l in fh if l.startswith("PPid:")), 0)
        except (OSError, ValueError, IndexError):
            break
    try:
        pids = sorted(int(p) for p in os.listdir(proc_root) if p.isdigit())
    except OSError:
        return ""
    for pid in pids:
        if pid in own:
            continue
        try:
            with open(os.path.join(proc_root, str(pid), "comm")) as fh:
                comm = fh.read().strip()
            if comm not in PACKAGE_MANAGERS:
                continue
            with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as fh:
                words = [w.decode(errors="replace") for w in fh.read().split(b"\0") if w]
        except OSError:
            continue
        return "pid %d (%s)" % (pid, " ".join(words[:4]) or comm)
    return ""


def argv_for(helper, sudo, names):
    common = ["--noconfirm", "--sudo", sudo]
    if helper == "paru":
        return ["paru", "-S", "--skipreview", "--nosudoloop", "--batchinstall"] + common + names
    return ["yay", "-S", "--answerclean", "None", "--answerdiff", "None",
            "--answeredit", "None"] + common + names


def main():
    names = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not names:
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    helper = next((h for h in ("paru", "yay") if shutil.which(h)), "")
    if not helper:
        emit({"event": "error", "message": "neither paru nor yay is installed"})
        emit({"event": "done", "ok": False, "failed": names})
        return 1
    lock = lock_path()
    if os.path.exists(lock):
        who = holder()
        if who:
            emit({"event": "error", "busy": who,
                  "message": "pacman is in use by %s; %s is left alone" % (who, lock)})
        else:
            emit({"event": "error", "stale": True,
                  "message": "%s was left behind by an interrupted update and nothing holds it; "
                             "only root can clear it, which the next update does" % lock})
        emit({"event": "done", "ok": False, "failed": names})
        return 1
    sudo = os.path.join(HERE, "aur_sudo.sh")
    try:
        os.chmod(sudo, 0o755)
    except OSError:
        pass
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    env.pop("LANGUAGE", None)
    env.pop("DSD_AUR_USE_SUDO", None)
    if "--use-sudo" in sys.argv[1:]:
        env["DSD_AUR_USE_SUDO"] = "1"
    try:
        proc = subprocess.Popen(argv_for(helper, sudo, names), stdin=subprocess.DEVNULL,
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
        if LOCK_WAIT.search(line):
            emit({"event": "status", "message": "waiting-lock", "holder": holder()})
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
