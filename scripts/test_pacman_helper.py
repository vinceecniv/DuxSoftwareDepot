#!/usr/bin/env python3
"""Checks pacman_helper.py against a stand-in for pyalpm.

This runs on a machine that has no pacman and no pyalpm, which is the point:
the Arch path is the one nobody here can try by hand, and it is where #13
happened — the transaction resolved against sync databases that nothing had
refreshed, so a run of eight updates reinstalled the eight versions already
installed and then reported that none of them had arrived.

The stand-in is a module on PYTHONPATH rather than a patched import, because
the helper re-execs itself looking for an interpreter that can import pyalpm
(see interp.ensure) and only a real, importable module stops it.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HELPER = Path(__file__).resolve().parent / "pacman_helper.py"

# name -> (installed version, version in the repositories before a refresh,
#          version in the repositories after one)
STUB = '''
import json, os, signal, sys

error = Exception
SCENARIO = json.loads(os.environ["PACMAN_STUB"])
TRACE = os.environ["PACMAN_TRACE"]
# A plan started by a transaction (the helper's preresolve) traces apart
# from the transaction itself
PRE = "pre " if (os.environ.get("PACMAN_STUB_ROOT") and sys.argv[1:2] == ["plan"]) else ""


def _trace(what):
    with open(TRACE, "a") as fh:
        fh.write(PRE + what + "\\n")


def vercmp(a, b):
    return (a > b) - (a < b)


class Pkg:
    def __init__(self, name, version, arch="x86_64"):
        self.name = name
        self.version = version
        self.arch = arch
        self.download_size = 0 if SCENARIO.get("packages", {}).get(name, {}).get("cached") else 1000
        self.filename = "%s-%s-%s.pkg.tar.zst" % (name, version, arch)
        self.isize = 2000


class SyncDB:
    name = "extra"

    def __init__(self):
        # The refresh is pacman's, run before the handle opens: what it
        # wrote is what this database reads
        self.refreshed = os.path.exists(TRACE + ".refreshed")

    def update(self, force):
        _trace("pyalpm refresh")
        raise error("db.update is the path that crashed in #37")

    def get_pkg(self, name):
        entry = SCENARIO["packages"].get(name)
        if entry is None:
            return None
        version = entry["after"] if self.refreshed else entry["before"]
        _trace("resolve %s -> %s" % (name, version))
        return Pkg(name, version, entry.get("arch", "x86_64"))


class LocalDB:
    def get_pkg(self, name):
        entry = SCENARIO["packages"].get(name)
        if entry is None or entry.get("installed") is None:
            return None
        return Pkg(name, entry["installed"])


class Transaction:
    def __init__(self, handle, flags):
        self.handle = handle
        self.flags = flags
        self.to_add = []
        self.to_remove = []

    def add_pkg(self, pkg):
        _trace("add %s-%s" % (pkg.name, pkg.version))
        self.to_add.append(pkg)

    def remove_pkg(self, pkg):
        self.to_remove.append(pkg)

    def sysupgrade(self, downgrade):
        # pacman -Su: every installed package the databases have newer, but
        # the ignored ones
        _trace("sysupgrade")
        refreshed = self.handle._sync[0].refreshed
        for name, entry in sorted(SCENARIO["packages"].items()):
            if entry.get("installed") is None:
                continue
            version = entry["after"] if refreshed else entry["before"]
            if version and vercmp(version, entry["installed"]) > 0 and name not in self.handle.ignored:
                _trace("add %s-%s" % (name, version))
                self.to_add.append(Pkg(name, version, entry.get("arch", "x86_64")))

    def prepare(self):
        # pyalpm 0.12 on a conflict or a wrong architecture: not an
        # exception, the process is gone (#39)
        if SCENARIO.get("prepareCrashes"):
            os.kill(os.getpid(), signal.SIGSEGV)
        arch = self.handle.arch
        for pkg in self.to_add:
            if arch and pkg.arch not in arch and pkg.arch != "any":
                os.kill(os.getpid(), signal.SIGSEGV)

    def commit(self):
        # What pyalpm really passes its download callback: the event where
        # the bytes transferred used to be, and a pointer cut to an int
        # where the total was
        dlcb = getattr(self.handle, "dlcb", None)
        if dlcb:
            for pkg in self.to_add:
                filename = "%s-%s-x86_64.pkg.tar.zst" % (pkg.name, pkg.version)
                for event in (0, 1, 2, 1, 3):
                    dlcb(filename, event, -523683652)
        _trace("commit")

    def release(self):
        pass


class Handle:
    def __init__(self, root, dbpath):
        # A pyalpm linked against a libalpm it was not built for imports
        # cleanly and gives way here, at the first call into the library
        if SCENARIO.get("handleFails"):
            raise error("could not initialise the library")
        _trace("dbpath %s" % dbpath)
        # init_transaction takes db.lck here, which only root may create
        if os.path.realpath(dbpath) == os.path.realpath(os.environ["DSD_PACMAN_DBPATH"]):
            self._locked_out = True
        self._sync = [SyncDB()]
        # pycman's guess; the helper replaces it with pacman-conf's answer
        self.arch = ["x86_64"]
        self.cachedirs = [os.environ["PACMAN_STUB_CACHE"] + "/"]
        self.ignored = []

    def register_syncdb(self, name, level):
        pass

    def add_ignorepkg(self, name):
        self.ignored.append(name)

    def get_syncdbs(self):
        return self._sync

    def get_localdb(self):
        return LocalDB()

    def init_transaction(self, **kwargs):
        if getattr(self, "_locked_out", False) and not os.environ.get("PACMAN_STUB_ROOT"):
            raise error("transaction could not be initialized, pm_errno 10 (unable to lock database)")
        return Transaction(self, kwargs)

    # The helper installs progress callbacks when they exist; it checks with
    # hasattr, so leaving them off is a supported shape.
'''

# Stands in for /usr/bin/pacman, which now does the refresh (#37)
FAKE_PACMAN = '''#!/usr/bin/env python3
import json, os, sys
scenario = json.loads(os.environ["PACMAN_STUB"])
trace = os.environ["PACMAN_TRACE"]
with open(trace, "a") as fh:
    fh.write("pacman " + " ".join(sys.argv[1:]) + "\\n")
args = sys.argv[1:]
if "--refresh" in args:
    if scenario.get("refreshFails"):
        print("error: failed retrieving file 'extra.db' from mirror.example : mirror unreachable", file=sys.stderr)
        sys.exit(1)
    with open(trace, "a") as fh:
        fh.write("refresh\\n")
    open(trace + ".refreshed", "w").close()
    sys.exit(0)
# --via-sudo's install or removal: as pacman does it, one directory per
# package in the local database
if scenario.get("installFails"):
    print("error: failed to commit transaction (conflicting files)")
    print("%s: /usr/bin/x exists in filesystem" % args[-1])
    sys.exit(1)
local = os.path.join(os.environ["DSD_PACMAN_DBPATH"], "local")
if "--sysupgrade" in args:
    ignored = args[args.index("--ignore") + 1].split(",") if "--ignore" in args else []
    names = sorted(n for n, e in scenario["packages"].items()
                   if e.get("installed") is not None and e["after"] > e["installed"] and n not in ignored)
else:
    names = args[args.index("--") + 1:]
if "--remove" not in args:
    # Downloads first, each moved into the cache whole, as pacman does
    for name in names:
        entry = scenario["packages"][name]
        path = os.path.join(os.environ["PACMAN_STUB_CACHE"],
                            "%s-%s-%s.pkg.tar.zst" % (name, entry["after"], entry.get("arch", "x86_64")))
        if not os.path.exists(path):
            open(path, "w").close()
            with open(trace, "a") as fh:
                fh.write("pacman downloaded " + name + "\\n")
for name in names:
    entry = scenario["packages"][name]
    if "--remove" in args:
        os.rmdir(os.path.join(local, "%s-%s" % (name, entry["installed"])))
    else:
        os.makedirs(os.path.join(local, "%s-%s" % (name, entry["after"])), exist_ok=True)
'''

# sudo, for --via-sudo: `-l` answers whether pacman may run without a
# password (SUDO_ALLOWS), and pacman runs as the stub above
FAKE_SUDO = '''#!/bin/sh
echo "sudo $*" >> "$PACMAN_TRACE.sudo"
[ "$1" = "-n" ] && shift
if [ "$1" = "-l" ]; then
    [ "$SUDO_ALLOWS" = 1 ]
    exit $?
fi
if [ "$1" = "/usr/bin/pacman" ]; then
    echo "$PATH" >> "$PACMAN_TRACE.sudopath"
    shift
    exec "$(dirname "$0")/pacman" "$@"
fi
exit 1
'''


# pacman-conf, when the scenario names the architectures this pacman
# accepts. Without one there is no pacman-conf in front of the system's.
FAKE_PACMAN_CONF = '''#!/usr/bin/env python3
import os
with open(os.environ["PACMAN_TRACE"], "a") as fh:
    fh.write("pacman-conf Architecture\\n")
for arch in os.environ["PACMAN_ARCHS"].split():
    print(arch)
'''

LAST = {}


def fake_proc(root, lock, shape):
    """A /proc for the lock checks. `shape` is who else is there:

    - "stale": a bystander, and nothing holding the lock
    - "held": pacman, with the lock among its open files as libalpm keeps it
    - "manager": paru running, the lock not open (yet)
    - "sudo": this test process standing in for the sudo the helper runs
      under, its command line naming pacman_helper.py — the helper's parent,
      which must not count as another update
    - "other-run": another helper run, which must
    - "plan": a plan, which locks a directory of its own and does not count
    """
    def proc(pid, comm, argv, holds=False):
        (root / str(pid) / "fd").mkdir(parents=True)
        (root / str(pid) / "comm").write_text(comm + "\n")
        (root / str(pid) / "cmdline").write_bytes(b"\0".join(w.encode() for w in argv) + b"\0")
        (root / str(pid) / "status").write_text("Name:\t%s\nPPid:\t1\n" % comm)
        if holds:
            os.symlink(str(lock), root / str(pid) / "fd" / "3")

    proc(4242, "sleep", ["sleep", "60"])
    if shape == "held":
        proc(4343, "pacman", ["pacman", "-Syu"], holds=True)
    elif shape == "manager":
        proc(4444, "paru", ["paru", "-Syu"])
    elif shape == "sudo":
        proc(os.getpid(), "sudo", ["sudo", "-n", "/usr/bin/python3", "/x/scripts/pacman_helper.py", "upgrade", "dolphin"])
    elif shape == "other-run":
        proc(4545, "python3", ["/usr/bin/python3", "/x/scripts/pacman_helper.py", "install", "sl"])
    elif shape == "plan":
        proc(4646, "python3", ["/usr/bin/python3", "/x/scripts/pacman_helper.py", "plan", "install", "sl"])
    return root


def run(scenario, *args):
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "pyalpm.py").write_text(STUB)
        bindir = Path(tmp) / "bin"
        bindir.mkdir()
        (bindir / "pacman").write_text(FAKE_PACMAN)
        (bindir / "pacman").chmod(0o755)
        (bindir / "sudo").write_text(FAKE_SUDO)
        (bindir / "sudo").chmod(0o755)
        if scenario.get("architectures") is not None:
            (bindir / "pacman-conf").write_text(FAKE_PACMAN_CONF)
            (bindir / "pacman-conf").chmod(0o755)
        trace = Path(tmp) / "trace"
        trace.write_text("")
        env = dict(os.environ)
        # Stands in for /var/lib/pacman: where the lock lives, and what a
        # plan must not open for a transaction
        dbpath = Path(tmp) / "db"
        dbpath.mkdir()
        (dbpath / "local").mkdir()
        for name, entry in scenario.get("packages", {}).items():
            if entry.get("installed"):
                (dbpath / "local" / ("%s-%s" % (name, entry["installed"]))).mkdir()
        env["DSD_PACMAN_DBPATH"] = str(dbpath)
        env["XDG_CACHE_HOME"] = str(Path(tmp) / "cache")
        syscache = Path(tmp) / "syscache"
        syscache.mkdir()
        for name, entry in scenario.get("packages", {}).items():
            if entry.get("cached"):
                (syscache / ("%s-%s-%s.pkg.tar.zst" % (name, entry["after"], entry.get("arch", "x86_64")))).touch()
        env["PACMAN_STUB_CACHE"] = str(syscache)
        env["SUDO_ALLOWS"] = "0" if scenario.get("sudoAsks") else "1"
        if scenario.get("architectures") is not None:
            env["PACMAN_ARCHS"] = " ".join(scenario["architectures"])
        lock = dbpath / "db.lck"
        if scenario.get("lock"):
            lock.touch()
            # Old enough not to be a package manager that is just starting
            os.utime(lock, (0, 0))
            env["DSD_PROC"] = str(fake_proc(Path(tmp) / "proc", lock, scenario["lock"]))
        env["PATH"] = "%s:%s" % (bindir, env.get("PATH", ""))
        env["PYTHONPATH"] = tmp
        env["PACMAN_STUB"] = json.dumps(scenario)
        env["PACMAN_TRACE"] = str(trace)
        # Transactions run as root under pkexec; only `plan` and `selftest`
        # are the user's own
        if args[0] not in ("plan", "selftest", "--via-sudo"):
            env["PACMAN_STUB_ROOT"] = "1"
        if "--via-sudo" in args:
            # The helper finds sudo on this PATH. Anything but the stand-in
            # is the real sudo, and the real sudo runs the real pacman
            import shutil
            found = shutil.which("sudo", path=env["PATH"])
            if found != str(bindir / "sudo"):
                raise SystemExit("refusing to run: sudo resolves to %s, not the stand-in" % found)
        proc = subprocess.run([sys.executable, str(HELPER), *args],
                              capture_output=True, text=True, env=env, timeout=60)
        events = []
        for line in proc.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        lines = [line for line in trace.read_text().splitlines()
                 if not line.startswith(("dbpath ", "pacman ", "pre "))]
        LAST.clear()
        LAST["lockRemains"] = lock.exists()
        LAST["dbpath"] = str(dbpath)
        LAST["local"] = sorted(os.listdir(dbpath / "local"))
        LAST["syscache"] = sorted(os.listdir(syscache))
        LAST["userCache"] = (Path(tmp) / "cache").exists()
        sudo_log = Path(str(trace) + ".sudo")
        LAST["sudo"] = sudo_log.read_text().splitlines() if sudo_log.exists() else []
        path_log = Path(str(trace) + ".sudopath")
        LAST["sudoPath"] = path_log.read_text().splitlines() if path_log.exists() else []
        return events, lines, proc, trace.read_text().splitlines()


def event(events, kind):
    for item in events:
        if item.get("event") == kind:
            return item
    return None


def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label + (" — " + detail if detail and not condition else ""))
    return condition


def main():
    ok = True

    # The reported case: the repositories have a newer build, the sync
    # database on disk does not know it yet.
    behind = {"packages": {"dolphin": {"installed": "26.08.0-2",
                                       "before": "26.08.0-2",
                                       "after": "26.08.1-1"}}}
    events, trace, proc, _ = run(behind, "upgrade", "dolphin")
    ok &= check("refresh happens before the package is resolved",
                trace[:2] == ["refresh", "resolve dolphin -> 26.08.1-1"], str(trace))
    _, _, _, raw = run(behind, "upgrade", "dolphin")
    ok &= check("and the request is resolved ahead in a plan of its own, after the refresh",
                "pre resolve dolphin -> 26.08.1-1" in raw
                and raw.index("refresh") < raw.index("pre resolve dolphin -> 26.08.1-1")
                and "pre commit" not in raw, str(raw))
    plan = event(events, "plan")
    ok &= check("the plan carries the version the refresh revealed",
                plan is not None and plan["ops"][0]["evr"] == "26.08.1-1", json.dumps(plan))
    ok &= check("and it is an upgrade, not a reinstall",
                plan is not None and plan["ops"][0]["action"] == "Upgrade")
    ok &= check("the transaction is committed", "commit" in trace)
    downloads = [e for e in events if e.get("phase") == "download"]
    ok &= check("the download is reported with the plan's size, not the callback's pointer",
                bool(downloads) and all(e.get("bytesTotal") == 1000 for e in downloads if "bytesTotal" in e),
                json.dumps(downloads))
    ok &= check("and starts once, ends once, through a retry",
                [e["event"] for e in downloads] == ["op-start", "progress", "op-done"]
                and downloads[-1].get("totalTransferred") == 1000, json.dumps(downloads))
    events, trace, proc, raw = run(behind, "upgrade", "dolphin")
    ok &= check("pacman does the refresh, not pyalpm's db.update (#37)",
                "pacman --sync --refresh --noconfirm --noprogressbar" in raw
                and "pyalpm refresh" not in raw, str(raw))

    # Already at the version the repositories offer: adding it anyway is the
    # "is up to date -- reinstalling" line from the report.
    current = {"packages": {"libdeflate": {"installed": "1.25-1",
                                           "before": "1.25-1",
                                           "after": "1.25-1"}}}
    events, trace, proc, _ = run(current, "upgrade", "libdeflate")
    ok &= check("a package already at the repository version is not added",
                not any(line.startswith("add ") for line in trace), str(trace))
    done = event(events, "done")
    ok &= check("and the run says there was nothing to do",
                done is not None and done.get("ok") is True and done.get("nothingToDo") is True,
                json.dumps(done))

    # An unreachable mirror is not a reason to refuse the transaction: what
    # the database already knows about still gets installed.
    partly = {"refreshFails": True,
              "packages": {"dolphin": {"installed": "26.08.0-2",
                                       "before": "26.08.1-1",
                                       "after": "26.08.2-1"}}}
    events, trace, proc, _ = run(partly, "upgrade", "dolphin")
    ok &= check("a failed refresh still installs what the stale database has",
                "commit" in trace and "add dolphin-26.08.1-1" in trace, str(trace))
    ok &= check("and says why it could not refresh",
                any(e.get("event") == "error" and "refresh" in e.get("message", "") for e in events))

    # And when the stale database has nothing newer, the run has nothing it
    # can do — which must not read as "updated". The reason is the failed
    # refresh, and it has to reach the caller, because the check that follows
    # will otherwise fail every row with nothing to show for it.
    stuck = dict(behind)
    stuck["refreshFails"] = True
    events, trace, proc, _ = run(stuck, "upgrade", "dolphin")
    ok &= check("a stale database with nothing newer adds nothing",
                not any(line.startswith("add ") for line in trace), str(trace))
    ok &= check("and the refresh failure is the reason on the wire",
                any(e.get("event") == "error" and "mirror unreachable" in e.get("message", "") for e in events))

    # `plan` is unprivileged: writing the sync databases needs root.
    events, trace, proc, raw = run(behind, "plan", "upgrade", "dolphin")
    ok &= check("plan does not try to refresh",
                not any("refresh" in line for line in raw), str(raw))
    ok &= check("and does not commit", "commit" not in trace)

    # The lock libalpm takes in init_transaction lives beside the databases,
    # and only root may create it in /var/lib/pacman: a plan opened there
    # failed every time (#38). It gets a directory of its own, removed after.
    done = event(events, "done")
    ok &= check("plan resolves without the lock on the real databases",
                done is not None and done.get("ok") is True
                and not any("unable to lock" in e.get("message", "") for e in events),
                json.dumps(events))
    dbpaths = [line[len("dbpath "):] for line in raw if line.startswith("dbpath ")]
    ok &= check("in a private database directory",
                bool(dbpaths) and os.path.realpath(dbpaths[-1]) != "/var/lib/pacman", str(raw))
    ok &= check("which is gone afterwards",
                bool(dbpaths) and not os.path.exists(dbpaths[-1]), dbpaths[-1] if dbpaths else "")

    # Installing is the other side of the same staleness: a package added to
    # the repositories today is not in yesterday's database at all.
    fresh = {"packages": {"newthing": {"installed": None,
                                       "before": None,
                                       "after": "1.0-1"}}}
    events, trace, proc, _ = run(fresh, "install", "newthing")
    ok &= check("install resolves against the refreshed database",
                any(line == "add newthing-1.0-1" for line in trace), str(trace))

    # An AUR-only package is absent from every sync database by definition —
    # libalpm cannot resolve it, and the helper refuses the transaction with
    # the reason on the wire rather than a silent half-run. This is the
    # failure behind the "package not found" reports: the QML layer routes
    # repo "aur" updates to the DMS daemon's AUR backend (paru/yay) and
    # never hands them here. The test pins the refusal that routing exists
    # to avoid, so a future caller cannot reintroduce it by accident.
    events, trace, proc, _ = run(behind, "upgrade", "some-aur-package")
    ok &= check("a package outside every sync database fails with its reason",
                any(e.get("event") == "error" and "package not found: some-aur-package" in e.get("message", "") for e in events))
    done = event(events, "done")
    ok &= check("and the failure names the package",
                done is not None and done.get("ok") is False and "some-aur-package" in (done.get("failed") or []),
                json.dumps(done))

    # --via-sudo: pacman is the only thing run as root. The refresh and the
    # install go through sudo; pyalpm only resolves, as the user, and never
    # commits anything. pacman downloads into the system cache.
    # Names no real system has: if the real pacman were ever reached, it
    # would answer "target not found" and change nothing
    fake_behind = {"packages": {"dsd-test-viewer": dict(behind["packages"]["dolphin"])}}
    fake_current = {"packages": {"dsd-test-lib": dict(current["packages"]["libdeflate"])}}
    events, trace, proc, raw = run(fake_behind, "--via-sudo", "upgrade", "dsd-test-viewer")
    ok &= check("via sudo: the refresh is sudo pacman -Sy, before the package is resolved",
                "sudo -n /usr/bin/pacman --sync --refresh --noconfirm --noprogressbar" in LAST["sudo"]
                and raw.index("refresh") < raw.index("resolve dsd-test-viewer -> 26.08.1-1"), str(raw) + str(LAST["sudo"]))
    ok &= check("via sudo: pyalpm downloads nothing and commits nothing; the user's cache is untouched",
                "commit" not in raw and not LAST["userCache"], str(raw))
    install = [l for l in LAST["sudo"] if l.startswith("sudo -n /usr/bin/pacman --sync --noconfirm")]
    ok &= check("via sudo: sudo pacman -S --needed downloads and installs, with pacman's own cache",
                len(install) == 1 and "--needed" in install[0] and "--cachedir" not in install[0]
                and install[0].endswith("-- dsd-test-viewer"), str(LAST["sudo"]))
    ok &= check("via sudo: the new version stays in the system cache, for rolling back",
                LAST["syscache"] == ["dsd-test-viewer-26.08.1-1-x86_64.pkg.tar.zst"], str(LAST["syscache"]))
    kinds = [(e["event"], e.get("phase")) for e in events if e.get("name") == "dsd-test-viewer"]
    ok &= check("via sudo: the events are a root run's — the download as its file lands, then the install",
                event(events, "plan") is not None
                and kinds == [("op-start", "download"), ("progress", "download"), ("op-done", "download"),
                              ("op-start", "install"), ("progress", "install"), ("op-done", "install")]
                and (event(events, "progress") or {}).get("totalTransferred") == 1000
                and "dsd-test-viewer-26.08.1-1" in LAST["local"], json.dumps(events))
    ok &= check("via sudo: pacman gets the system's PATH, not the caller's, for the hooks it runs as root",
                LAST["sudoPath"] and set(LAST["sudoPath"]) == {"/usr/local/sbin:/usr/local/bin:/usr/bin"},
                str(LAST["sudoPath"]))
    ok &= check("via sudo: and it ends well",
                proc.returncode == 0 and (event(events, "done") or {}).get("ok") is True,
                json.dumps(event(events, "done")))
    cached = {"packages": {"dsd-test-viewer": dict(fake_behind["packages"]["dsd-test-viewer"], cached=True)}}
    events, trace, proc, raw = run(cached, "--via-sudo", "upgrade", "dsd-test-viewer")
    kinds = [(e["event"], e.get("phase")) for e in events if e.get("name") == "dsd-test-viewer"]
    ok &= check("via sudo: a package already in the cache goes straight to the install",
                kinds == [("op-start", "install"), ("progress", "install"), ("op-done", "install")]
                and proc.returncode == 0, json.dumps(events))

    asks = dict(fake_behind)
    asks["sudoAsks"] = True
    events, trace, proc, raw = run(asks, "--via-sudo", "upgrade", "dsd-test-viewer")
    ok &= check("via sudo: when sudo would ask, nothing is done or said, and the exit code is 3",
                proc.returncode == 3 and proc.stdout == "" and not [l for l in raw if not l.startswith("pacman-conf")]
                and all(l.startswith("sudo -n -l ") for l in LAST["sudo"]), proc.stdout + str(raw) + str(LAST["sudo"]))

    failing = dict(fake_behind)
    failing["installFails"] = True
    events, trace, proc, raw = run(failing, "--via-sudo", "upgrade", "dsd-test-viewer")
    ok &= check("via sudo: a failed install carries pacman's reason, and its whole output on stderr",
                proc.returncode == 1 and (event(events, "done") or {}).get("ok") is False
                and any(e.get("event") == "error" and "conflicting files" in e.get("message", "") for e in events)
                and "exists in filesystem" in proc.stderr, json.dumps(events) + proc.stderr)

    events, trace, proc, raw = run(fake_current, "--via-sudo", "upgrade", "dsd-test-lib")
    ok &= check("via sudo: nothing to do runs no pacman -S",
                (event(events, "done") or {}).get("nothingToDo") is True
                and not any(l.startswith("sudo -n /usr/bin/pacman --sync --noconfirm") for l in LAST["sudo"]),
                str(LAST["sudo"]))

    # A lock nothing visibly holds needs root to clear, which the rule does
    # not give: the usual path does it, password and all. A lock a package
    # manager holds is that manager's, and waiting for it needs no password.
    stale = dict(fake_behind)
    stale["lock"] = "stale"
    events, trace, proc, raw = run(stale, "--via-sudo", "upgrade", "dsd-test-viewer")
    ok &= check("via sudo: a stale lock sends the run down the usual path, having done nothing",
                proc.returncode == 3 and proc.stdout == "" and LAST["lockRemains"]
                and not [l for l in LAST["sudo"] if not l.startswith("sudo -n -l ")], proc.stdout + str(LAST["sudo"]))
    busy = dict(fake_behind)
    busy["lock"] = "manager"
    events, trace, proc, raw = run(busy, "--via-sudo", "upgrade", "dsd-test-viewer")
    ok &= check("via sudo: a lock while paru runs is reported, with no password and nothing done",
                proc.returncode == 1 and LAST["lockRemains"]
                and any(e.get("event") == "error" and "paru is running" in e.get("message", "") for e in events)
                and (event(events, "done") or {}).get("ok") is False
                and not [l for l in LAST["sudo"] if not l.startswith("sudo -n -l ")], json.dumps(events) + str(LAST["sudo"]))

    events, trace, proc, raw = run(fake_current, "--via-sudo", "remove", "dsd-test-lib")
    ok &= check("via sudo: a removal is resolved by pyalpm and done by sudo pacman -R, with no refresh",
                "sudo -n /usr/bin/pacman --remove --noconfirm --noprogressbar -- dsd-test-lib" in LAST["sudo"]
                and not any("--refresh" in l for l in LAST["sudo"] if not l.startswith("sudo -n -l"))
                and "dsd-test-lib-1.25-1" not in LAST["local"]
                and [(e["event"], e.get("phase")) for e in events if e.get("name") == "dsd-test-lib"][-1] == ("op-done", "remove")
                and (event(events, "done") or {}).get("ok") is True, json.dumps(events) + str(LAST["sudo"]))

    # sysupgrade: what the update run uses on Arch. Everything the refreshed
    # databases have newer — including what the list could not know yet —
    # but the packages named, which stay.
    whole = {"packages": {
        "dolphin": dict(behind["packages"]["dolphin"]),                 # newer only after the refresh
        "kio": {"installed": "6.20.0-1", "before": "6.21.0-1", "after": "6.21.0-1"},
        "dms-shell": {"installed": "1.7.0-1", "before": "1.7.0-1", "after": "1.8.0-1"},
        "sl": {"installed": None, "before": "5.05-6", "after": "5.05-6"},
    }}
    events, trace, proc, raw = run(whole, "sysupgrade", "dms-shell")
    ok &= check("sysupgrade refreshes, then takes everything newer but what it was told to leave",
                trace[:2] == ["refresh", "sysupgrade"] and "add dolphin-26.08.1-1" in trace
                and "add kio-6.21.0-1" in trace and not any("dms-shell" in l for l in trace)
                and not any(l.startswith("add sl-") for l in trace) and "commit" in trace, str(trace))
    plan = event(events, "plan")
    ok &= check("and its plan says what each package was",
                plan is not None and {(o["name"], o["fromEvr"], o["evr"]) for o in plan["ops"]}
                == {("dolphin", "26.08.0-2", "26.08.1-1"), ("kio", "6.20.0-1", "6.21.0-1")}, json.dumps(plan))
    ok &= check("and the names it left alone are not reported as failed",
                (event(events, "done") or {}) == {"event": "done", "ok": True, "failed": []}, json.dumps(events))
    events, trace, proc, raw = run(whole, "plan", "sysupgrade")
    ok &= check("plan sysupgrade needs no names, and no refresh",
                proc.returncode == 0 and event(events, "plan") is not None and "refresh" not in raw
                and "commit" not in trace, str(raw))
    events, trace, proc, raw = run(current, "sysupgrade")
    ok &= check("sysupgrade with nothing newer has nothing to do",
                (event(events, "done") or {}).get("nothingToDo") is True and "commit" not in trace, str(trace))

    fake_whole = {"packages": {
        "dsd-test-viewer": dict(behind["packages"]["dolphin"]),
        "dsd-test-kio": dict(whole["packages"]["kio"]),
        "dsd-test-shell": dict(whole["packages"]["dms-shell"]),
    }}
    events, trace, proc, raw = run(fake_whole, "--via-sudo", "sysupgrade", "dsd-test-shell")
    ok &= check("via sudo: sysupgrade is sudo pacman -Su, the packages to leave given as --ignore",
                "sudo -n /usr/bin/pacman --sync --sysupgrade --noconfirm --noprogressbar --ignore dsd-test-shell"
                in LAST["sudo"], str(LAST["sudo"]))
    ok &= check("via sudo: and both upgrades land, downloads in the system cache, the shell's left alone",
                "dsd-test-viewer-26.08.1-1" in LAST["local"] and "dsd-test-kio-6.21.0-1" in LAST["local"]
                and "dsd-test-shell-1.7.0-1" in LAST["local"] and "dsd-test-shell-1.8.0-1" not in LAST["local"]
                and len(LAST["syscache"]) == 2
                and [e.get("name") for e in events if e.get("event") == "op-done" and e.get("phase") == "install"]
                == ["dsd-test-kio", "dsd-test-viewer"]
                and (event(events, "done") or {}).get("ok") is True, json.dumps(events) + str(LAST["local"]))

    # The startup check has to answer for the bindings the transaction will
    # actually use, not merely for the import. A pyalpm that imports and then
    # cannot open a handle used to pass the selftest, so the plugin said
    # nothing at startup and every later run failed with no reason to show
    # (#18); the selftest now takes that step itself.
    events, trace, proc, _ = run(behind, "selftest")
    done = event(events, "done")
    ok &= check("selftest passes when the library can be opened",
                proc.returncode == 0 and done is not None and done.get("ok") is True,
                json.dumps(done))

    events, trace, proc, _ = run({"packages": {}, "handleFails": True}, "selftest")
    ok &= check("selftest fails when pyalpm imports but libalpm will not open",
                proc.returncode != 0 and any(e.get("event") == "error" and "libalpm could not be used" in e.get("message", "") for e in events),
                proc.stdout + proc.stderr)
    ok &= check("and the reason libalpm gave travels with it",
                any("could not initialise the library" in e.get("message", "") for e in events if e.get("event") == "error"))

    # pyalpm 0.12 segfaults where libalpm refuses a transaction for a
    # conflict or a wrong architecture, and a helper that dies inside its
    # transaction leaves db.lck behind (#39). Resolving it ahead in a plan
    # of its own lets that crash take nothing down.
    crashing = dict(behind)
    crashing["prepareCrashes"] = True
    events, trace, proc, raw = run(crashing, "upgrade", "dolphin")
    ok &= check("a request that crashes pyalpm is never started for real",
                not any(line.startswith("add ") for line in trace) and "commit" not in trace, str(raw))
    ok &= check("and the crash is the reason on the wire, not a dead helper",
                proc.returncode == 1
                and any(e.get("event") == "error" and "crashed pyalpm (SIGSEGV)" in e.get("message", "") for e in events)
                and (event(events, "done") or {}).get("ok") is False, json.dumps(events))

    # CachyOS: pacman accepts the CPU's feature levels, and most of its
    # repositories ship x86_64_v3. pycman's handle accepts x86_64 alone.
    v3 = {"architectures": ["x86_64", "x86_64_v2", "x86_64_v3"],
          "packages": {"libsoup3": {"installed": "3.8.0-1", "before": "3.8.1-1.1",
                                    "after": "3.8.1-1.1", "arch": "x86_64_v3"}}}
    events, trace, proc, raw = run(v3, "upgrade", "libsoup3")
    ok &= check("the accepted architectures are pacman-conf's",
                "pacman-conf Architecture" in raw, str(raw))
    ok &= check("so an x86_64_v3 package installs",
                "add libsoup3-3.8.1-1.1" in trace and "commit" in trace, str(raw))
    events, trace, proc, raw = run(v3, "plan", "upgrade", "libsoup3")
    ok &= check("and a plan of one resolves too",
                event(events, "plan") is not None, json.dumps(events))
    narrow = dict(v3)
    narrow["architectures"] = ["x86_64"]
    events, trace, proc, raw = run(narrow, "plan", "upgrade", "libsoup3")
    ok &= check("a level this pacman does not accept is refused before prepare()",
                proc.returncode == 1 and any(
                    e.get("event") == "error" and "architecture is not valid: libsoup3-3.8.1-1.1-x86_64_v3" in e.get("message", "")
                    for e in events), json.dumps(events) + proc.stderr[-300:])

    # A lock nothing holds is what a helper that died in its transaction
    # leaves behind, and what every run after it failed on.
    for shape, cleared, why in (("stale", True, ""),
                                ("sudo", True, ""),
                                ("plan", True, ""),
                                ("held", False, "pacman is busy"),
                                ("manager", False, "paru is running"),
                                ("other-run", False, "another update is running")):
        scenario = dict(behind)
        scenario["lock"] = shape
        events, trace, proc, raw = run(scenario, "upgrade", "dolphin")
        if cleared:
            ok &= check("a stale lock is removed and the run goes on (%s)" % shape,
                        not LAST["lockRemains"] and "commit" in trace
                        and any(e.get("event") == "warning" and "stale pacman lock" in e.get("message", "") for e in events),
                        json.dumps(events))
        else:
            ok &= check("a lock is left alone while %s" % why,
                        LAST["lockRemains"] and "commit" not in trace and "refresh" not in raw
                        and any(e.get("event") == "error" and why in e.get("message", "") for e in events),
                        json.dumps(events))
    events, trace, proc, raw = run({"lock": "held", "packages": behind["packages"]}, "plan", "upgrade", "dolphin")
    ok &= check("a plan neither needs nor touches the real lock",
                LAST["lockRemains"] and (event(events, "done") or {}).get("ok") is True, json.dumps(events))

    print("\n" + ("all checks passed" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
