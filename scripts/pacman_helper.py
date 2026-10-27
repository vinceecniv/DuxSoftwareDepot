#!/usr/bin/env python3
"""pacman/libalpm transactions through pyalpm, emitting the NDJSON event
protocol documented in PROTOCOL.md — the Arch counterpart of
rpm_helper.py.

Usage: pacman_helper.py <install|remove|upgrade|plan|selftest> <name>...

Transactions need root (run via pkexec); `plan` resolves against the
existing sync databases and works unprivileged, and `selftest` reports
whether the bindings are present *and* usable — it opens a handle, which
is where a pyalpm built against another libalpm gives way rather than at
its import. `downgrade` is not offered:
pacman keeps no version history in its repositories (that is the Arch
Linux Archive's job, out of scope here). Official repositories only —
AUR packages are never touched.
"""
import json
import os
import re
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# Missing bindings must be reported inside the protocol: an import that kills
# the process ends the stream before its first event, and the caller can only
# guess that every package failed. See the same guard in rpm_helper.py.
import interp

interp.ensure("pyalpm")

try:
    import pyalpm
except ImportError as exc:
    # Names the interpreter: "not installed" is a claim about the system,
    # and this is only ever a fact about one process
    emit({"event": "error",
          "message": "pyalpm cannot be imported by %s (%s)"
                     % (interp.describe(), exc)})
    emit({"event": "done", "ok": False, "failed": sys.argv[2:]})
    sys.exit(1)


DBPATH = "/var/lib/pacman"


def _test_hook(name):
    """A path the tests stand in for: the database directory, /proc.

    Never as root. pkexec builds its own environment, but sudo can be told
    to keep one, and a root process that let the environment say where
    pacman's lock is — or which processes exist — could be steered into
    removing a lock that is held."""
    if os.geteuid() == 0:
        return None
    return os.environ.get(name) or None


def architectures():
    """The architectures this pacman accepts, as pacman itself resolves them.

    pacman.conf says `Architecture = auto` on nearly every machine, and what
    `auto` means is pacman's decision. Arch's pacman reads it as the machine
    type; CachyOS's reads it as the machine type plus the CPU feature levels
    it can run (x86_64, x86_64_v2, x86_64_v3), and ships most of its
    repositories as x86_64_v3 packages. pycman resolves `auto` from
    os.uname() alone, so its handle accepted x86_64 and nothing else, and
    libalpm's prepare() refused every v3 package (#39).

    That refusal should have been an exception. Through pyalpm 0.12 it is a
    segfault: its prepare() reads whatever list libalpm hands back as
    missing-dependency records, and this one is a list of strings.

    `pacman-conf Architecture` answers the way the installed pacman does,
    distribution patches included. None when it cannot be asked."""
    import shutil
    import subprocess
    pacman_conf = shutil.which("pacman-conf")
    if not pacman_conf:
        return None
    try:
        proc = subprocess.run([pacman_conf, "Architecture"], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()] or None


def init_handle(dbpath=None):
    """Configured handle: pycman parses pacman.conf when available (it
    ships with pyalpm); otherwise register the sync dbs that exist on
    disk — enough for resolving and for reads. `dbpath` replaces the
    configured database directory, which is how `plan` gets a lock of its
    own (see plan_dbpath).

    Either way the accepted architectures are pacman-conf's, never pycman's
    guess (see architectures()). When pacman-conf cannot be asked the list
    is left empty, which switches libalpm's check off: the packages come
    from the configured repositories, so no check costs little, and a wrong
    list is the crash of #39."""
    real = configured_dbpath()
    try:
        import pycman.config
        config = pycman.config.PacmanConfig(conf="/etc/pacman.conf")
        config.options["DBPath"] = dbpath or real
        handle = config.initialize_alpm()
    except Exception:
        import glob
        handle = pyalpm.Handle("/", dbpath or real)
        for path in glob.glob(real + "/sync/*.db"):
            handle.register_syncdb(os.path.basename(path)[:-3], 0)
    try:
        handle.arch = architectures() or []
    except (AttributeError, TypeError):
        pass
    return handle


def configured_dbpath():
    hook = _test_hook("DSD_PACMAN_DBPATH")
    if hook:
        return hook
    try:
        import pycman.config
        return pycman.config.PacmanConfig(conf="/etc/pacman.conf").options["DBPath"].rstrip("/") or DBPATH
    except Exception:
        return DBPATH


def plan_dbpath():
    """A database directory `plan` can lock without root (#38).

    libalpm takes db.lck beside the databases in init_transaction, a plan
    included, and only root may create a file in /var/lib/pacman — so every
    unprivileged plan died with "unable to lock database" before it resolved
    anything, and the update preview and the removal impact never appeared.
    `checkupdates` meets the same lock by pointing libalpm at a private
    directory; so does this, with `local` and `sync` linked to the real
    ones. The lock lands in the private directory, and a plan never commits,
    so nothing is written through the links.

    A plan that crashed (the segfaults of #39) never reached its cleanup, so
    what earlier ones left behind is swept here first."""
    import shutil
    import tempfile
    import time
    real = configured_dbpath()
    base = tempfile.gettempdir()
    try:
        for name in os.listdir(base):
            path = os.path.join(base, name)
            if (name.startswith("dsd-plan-") and os.path.isdir(path)
                    and not os.path.islink(path)
                    and os.stat(path).st_uid == os.geteuid()
                    and time.time() - os.stat(path).st_mtime > 3600):
                shutil.rmtree(path, ignore_errors=True)
    except OSError:
        pass
    tmp = tempfile.mkdtemp(prefix="dsd-plan-")
    for part in ("local", "sync"):
        os.symlink(os.path.join(real, part), os.path.join(tmp, part))
    return tmp


def _pkg_of_file(filename, plan_names):
    base = filename.split("/")[-1]
    for name in sorted(plan_names, key=len, reverse=True):
        if base.startswith(name + "-"):
            return name
    return ""


# alpm_download_event_type_t
DOWNLOAD_INIT, DOWNLOAD_PROGRESS, DOWNLOAD_RETRY, DOWNLOAD_COMPLETED = range(4)


class Callbacks:
    def __init__(self, handle):
        self.plan_names = set()
        self.totals = {}
        self.transferred = {}
        self.phase_started = set()
        self.dl_done = set()
        self.inst_done = set()
        self.install_pct = {}
        self.index = 0
        self.total_ops = 1
        self.removing = False
        handle.dlcb = self.dl
        handle.progresscb = self.progress

    def dl(self, filename, event, _data):
        """libalpm's download callback, as pyalpm actually delivers it.

        pyalpm (0.12, and master as of 2026-10) still wraps the callback
        libalpm had before 6.0 — `(filename, xfered, total)` — while libalpm
        now calls it with `(filename, event, data*)`. So the second argument
        is the event and the third is a pointer cut down to an int; reading
        them as bytes put a negative `bytesTotal` on the wire. Only the event
        survives the trip, so the sizes come from the plan: a download is
        reported when it starts and when it ends, with nothing in between.
        A retry on the next mirror starts nothing new."""
        if filename.endswith(".sig"):
            return
        name = _pkg_of_file(filename, self.plan_names)
        if not name:
            return
        total = int(self.totals.get(name, 0))
        if event == DOWNLOAD_INIT and name not in self.phase_started:
            self.phase_started.add(name)
            emit({"event": "op-start", "name": name, "phase": "download",
                  "bytesTotal": total})
        elif event == DOWNLOAD_COMPLETED and name not in self.dl_done:
            self.dl_done.add(name)
            self.transferred[name] = total
            agg = int(sum(self.transferred.values()))
            emit({"event": "progress", "name": name, "phase": "download",
                  "percent": 100, "bytesTransferred": total,
                  "bytesTotal": total, "totalTransferred": agg})
            emit({"event": "op-done", "name": name, "phase": "download",
                  "totalTransferred": agg})

    def progress(self, target, percent, howmany, current):
        if not target:
            return
        self.total_ops = max(self.total_ops, howmany)
        phase = "remove" if self.removing else "install"
        key = (target, current)
        if key not in self.install_pct:
            self.install_pct[key] = -1
            self.index = current
            emit({"event": "op-start", "name": target, "phase": phase,
                  "index": current, "total": howmany})
        if percent != self.install_pct[key]:
            self.install_pct[key] = percent
            emit({"event": "progress", "name": target, "phase": phase,
                  "percent": max(0, min(100, percent))})
        if percent >= 100 and key not in self.inst_done:
            self.inst_done.add(key)
            emit({"event": "op-done", "name": target, "phase": phase})


def refresh_syncdbs():
    """`pacman -Sy` — which nothing else in this path does.

    A transaction resolves names against the sync databases as they are on
    disk, and on Arch those sit behind whatever the update list was built
    from: the daemon counts updates with `checkupdates`, which refreshes a
    private copy and throws it away, and its own upgrade would be a full
    `pacman -Syu`. So a list of eight updates resolved to the eight versions
    already installed, libalpm answered "is up to date -- reinstalling" for
    each, and the check afterwards found that nothing had reached its target
    version (#13).

    pacman itself does the refresh, not pyalpm's db.update: when a mirror
    failed mid-download, libalpm's failure path under pyalpm's download
    callbacks crashed the helper with SIGSEGV — no `finally`, so db.lck was
    left behind and every pacman command failed until it was removed by
    hand (#37). pacman walks the mirrorlist past the same failure. It runs
    before any handle is opened, so the handle reads what it wrote.

    A failure here is not fatal. One unreachable mirror is a reason to
    attempt the transaction with what is on disk, not a reason to refuse it.
    """
    import shutil
    import subprocess
    pacman = shutil.which("pacman") or "/usr/bin/pacman"
    try:
        proc = subprocess.run([pacman, "--sync", "--refresh", "--noconfirm",
                               "--noprogressbar"],
                              stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=1800)
    except (OSError, subprocess.SubprocessError) as exc:
        emit({"event": "error", "message": "could not refresh the databases: %s" % exc})
        return
    if proc.returncode != 0:
        lines = [line.strip() for line in (proc.stderr + proc.stdout).splitlines()
                 if line.strip().startswith(("error:", "ERROR:"))]
        emit({"event": "error",
              "message": "could not refresh the databases: %s"
                         % ("; ".join(lines) or "pacman exited with %d" % proc.returncode)})


def preresolve(action, specs):
    """Resolve the request in a process that may crash, before this one may.

    pyalpm 0.12's prepare() reads whatever list libalpm returns on failure
    as missing-dependency records. For missing dependencies that is right;
    for a conflict or a wrong architecture it is not, and the helper dies
    with SIGSEGV — inside the transaction, with db.lck held, so every
    pacman command after it failed until someone removed the lock by hand
    (#39, and the ending of #37). Python cannot catch that.

    So the same request is first resolved as a `plan`, in a child process
    with a database directory of its own (plan_dbpath): if anything in
    resolving it crashes, the child takes nothing down with it, and the
    real transaction is never started. A refusal the child reports
    normally is reported the same way, before any lock is taken.

    Returns None when the transaction may go ahead, otherwise the exit code
    of the run, its events already emitted."""
    import subprocess
    cmd = [sys.executable, os.path.abspath(__file__), "plan", action] + list(specs)
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as exc:
        # Not a verdict on the request: go on as before this existed
        emit({"event": "warning", "message": "could not resolve the request ahead: %s" % exc})
        return None
    events = []
    for line in proc.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    if proc.returncode < 0:
        import signal
        try:
            what = signal.Signals(-proc.returncode).name
        except ValueError:
            what = "signal %d" % -proc.returncode
        # libalpm logs its refusal before pyalpm falls over reading it
        said = [line.strip()[len("error:"):].strip() for line in proc.stderr.splitlines()
                if line.strip().lower().startswith("error:")]
        emit({"event": "error",
              "message": "%s — resolving it crashed pyalpm (%s), so nothing was changed"
                         % ("; ".join(said) if said else "pacman could not resolve the request", what)})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    done = next((e for e in reversed(events) if e.get("event") == "done"), None)
    if done is not None and done.get("ok") is False:
        for event in events:
            if event.get("event") == "error":
                emit(event)
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    return None


PACKAGE_MANAGERS = {"pacman", "pacman-key", "pacman-db-upgrade", "makepkg", "paru",
                    "yay", "pikaur", "trizen", "pamac", "pamac-daemon", "packagekitd"}


def _ancestors(proc_root):
    """This process and the ones it runs under. They are not another
    package manager: sudo stays as the helper's parent and keeps its
    command line, and so does simulate.py while a run is recorded."""
    pids = {os.getpid()}
    pid = os.getppid()
    while pid > 1 and pid not in pids:
        pids.add(pid)
        try:
            with open(os.path.join(proc_root, str(pid), "status")) as fh:
                ppid = next((int(line.split()[1]) for line in fh if line.startswith("PPid:")), 0)
        except (OSError, ValueError, IndexError):
            break
        pid = ppid
    return pids


def _describe(proc_root, pid):
    try:
        with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as fh:
            words = [w.decode(errors="replace") for w in fh.read().split(b"\0") if w]
    except OSError:
        words = []
    return "pid %d%s" % (pid, (" (" + " ".join(words[:3]) + ")") if words else "")


def clear_stale_lock():
    """Remove a pacman lock nothing holds. None when the way is clear,
    otherwise why it is not.

    A helper that died inside its transaction left db.lck behind, and every
    run after it failed with "unable to lock database" until someone opened
    a terminal and removed the file as root (#37, #39). pacman leaves that
    to the person who is sure no package manager is running; nobody is at
    a shell here, so the helper makes the checks such a person makes:

    - no process has the file open. libalpm opens the lock when it takes it
      and keeps the descriptor until it lets go, so an open file is a live
      holder;
    - no package manager is running at all, lock or no lock yet — this
      process and the ones it runs under excepted (_ancestors), and so are
      plans, which lock a directory of their own;
    - the file is not brand new.

    A lock that fails any of them stays, and the run says who has it."""
    import time
    proc_root = _test_hook("DSD_PROC") or "/proc"
    lockfile = os.path.join(os.path.realpath(configured_dbpath()), "db.lck")
    if not os.path.exists(lockfile):
        return None
    try:
        pids = [int(p) for p in os.listdir(proc_root) if p.isdigit()]
    except OSError:
        return "%s exists, and whether a package manager holds it cannot be told" % lockfile
    own = _ancestors(proc_root)
    unreadable = False
    for pid in pids:
        fd_dir = os.path.join(proc_root, str(pid), "fd")
        try:
            fds = os.listdir(fd_dir)
        except PermissionError:
            unreadable = True
            continue
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(os.path.join(fd_dir, fd))
            except OSError:
                continue
            target = target[:-len(" (deleted)")] if target.endswith(" (deleted)") else target
            if os.path.realpath(target) == lockfile:
                return "pacman is busy: %s holds %s" % (_describe(proc_root, pid), lockfile)
    # Root reads every process; anything less cannot rule a holder out
    if unreadable:
        return "%s exists, and whether a package manager holds it cannot be told" % lockfile
    for pid in pids:
        if pid in own:
            continue
        try:
            with open(os.path.join(proc_root, str(pid), "comm")) as fh:
                comm = fh.read().strip()
            with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as fh:
                argv = [w.decode(errors="replace") for w in fh.read().split(b"\0") if w]
        except OSError:
            continue
        if comm in PACKAGE_MANAGERS:
            return "%s is running (%s); %s is left alone" % (comm, _describe(proc_root, pid), lockfile)
        helper = [i for i, w in enumerate(argv) if os.path.basename(w) == "pacman_helper.py"]
        if helper and argv[helper[0] + 1:helper[0] + 2] != ["plan"]:
            return "another update is running (%s); %s is left alone" % (_describe(proc_root, pid), lockfile)
    try:
        age = time.time() - os.stat(lockfile).st_mtime
    except OSError:
        return None
    if age < 5:
        return "%s was created a moment ago; a package manager may be starting" % lockfile
    try:
        os.unlink(lockfile)
    except OSError as exc:
        return "could not remove the stale lock %s: %s" % (lockfile, exc)
    emit({"event": "warning",
          "message": "removed a stale pacman lock (%s): nothing held it and no package "
                     "manager was running, so an earlier run ended without releasing it" % lockfile})
    return None


def find_sync_pkg(handle, name):
    for db in handle.get_syncdbs():
        pkg = db.get_pkg(name)
        if pkg is not None:
            return pkg
    return None


def run(action, specs, dry_run=False):
    if not dry_run:
        # Before anything takes the lock; the refresh is the first that does
        reason = clear_stale_lock()
        if reason:
            emit({"event": "error", "message": reason})
            emit({"event": "done", "ok": False, "failed": list(specs)})
            return 1
    # Reading the repositories is the whole point of install and upgrade, so
    # they get a fresh copy first. `plan` is deliberately left out: it runs
    # unprivileged, and writing the sync databases needs root.
    if action != "remove" and not dry_run:
        refresh_syncdbs()
    if not dry_run:
        refused = preresolve(action, specs)
        if refused is not None:
            return refused
        return transact(init_handle(), action, specs, dry_run)
    import shutil
    dbpath = plan_dbpath()
    try:
        return transact(init_handle(dbpath), action, specs, dry_run)
    finally:
        shutil.rmtree(dbpath, ignore_errors=True)


def transact(handle, action, specs, dry_run):
    callbacks = Callbacks(handle)
    localdb = handle.get_localdb()
    accepted = list(getattr(handle, "arch", None) or [])

    transaction = handle.init_transaction()
    try:
        for spec in specs:
            name = spec.partition("=")[0]
            if action == "remove":
                pkg = localdb.get_pkg(name)
                if pkg is None:
                    emit({"event": "error", "message": f"package not installed: {name}"})
                    emit({"event": "done", "ok": False, "failed": list(specs)})
                    return 1
                transaction.remove_pkg(pkg)
            else:
                pkg = find_sync_pkg(handle, name)
                if pkg is None:
                    emit({"event": "error", "message": f"package not found: {name}"})
                    emit({"event": "done", "ok": False, "failed": list(specs)})
                    return 1
                # The check libalpm makes in prepare(), made here, where a
                # refusal is an event and not a segfault (see architectures())
                arch = getattr(pkg, "arch", None)
                if accepted and arch and arch != "any" and arch not in accepted:
                    emit({"event": "error",
                          "message": "package architecture is not valid: %s-%s-%s (this pacman accepts %s)"
                                     % (pkg.name, pkg.version, arch, ", ".join(accepted))})
                    emit({"event": "done", "ok": False, "failed": list(specs)})
                    return 1
                # --needed, which is what the daemon's own `pacman -Syu` uses.
                # After the refresh a package can already be at the version
                # the repositories offer — because something else updated it,
                # or because it was never behind — and adding it anyway
                # reinstalls the same files for nothing.
                if action == "upgrade":
                    have = localdb.get_pkg(name)
                    if have is not None and have.version == pkg.version:
                        continue
                transaction.add_pkg(pkg)
        transaction.prepare()

        ops = []
        total_download = 0
        for pkg in transaction.to_add:
            installed = localdb.get_pkg(pkg.name)
            act = "Install" if installed is None else ("Upgrade" if pyalpm.vercmp(pkg.version, installed.version) >= 0 else "Downgrade")
            down = int(pkg.download_size or 0)
            total_download += down
            callbacks.plan_names.add(pkg.name)
            callbacks.totals[pkg.name] = down
            ops.append({"name": pkg.name, "evr": pkg.version, "action": act,
                        "downloadBytes": down, "installBytes": int(pkg.isize or 0)})
        disk_delta = sum(o["installBytes"] for o in ops)
        for pkg in transaction.to_remove:
            ops.append({"name": pkg.name, "evr": pkg.version, "action": "Remove",
                        "downloadBytes": 0, "installBytes": int(pkg.isize or 0)})
            disk_delta -= int(pkg.isize or 0)
        callbacks.removing = bool(transaction.to_remove) and not transaction.to_add
        if not ops:
            emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
            return 0
        emit({"event": "plan", "ops": ops, "totalDownloadBytes": total_download,
              "installDeltaBytes": disk_delta})
        if dry_run:
            emit({"event": "done", "ok": True, "failed": []})
            return 0
        transaction.commit()
    except pyalpm.error as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    finally:
        try:
            transaction.release()
        except pyalpm.error:
            pass
    emit({"event": "done", "ok": True, "failed": []})
    return 0


def main():
    # Reaching this point means the bindings imported: the answer selftest exists for
    if len(sys.argv) == 2 and sys.argv[1] == "selftest":
        # Importing pyalpm and being able to use it are not the same thing.
        # The module is a binding over libalpm, and a pyalpm built against a
        # different libalpm than the one installed imports perfectly well and
        # then fails — or dies — at the first call into the library. A
        # selftest that stopped at the import called such a system ready, so
        # nothing was said at startup and the fault appeared much later as a
        # run where every package failed without a reason (#18).
        #
        # So take the first step a transaction takes, and no more: build the
        # handle and open the local database. That crosses into libalpm,
        # while needing no root, no network and no database lock.
        try:
            init_handle().get_localdb()
        except Exception as exc:
            emit({"event": "error",
                  "message": "pyalpm imported but libalpm could not be used: %s" % exc})
            emit({"event": "done", "ok": False, "failed": []})
            return 1
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    # `plan <action> …` resolves without root and without changing anything
    argv = sys.argv[1:]
    dry_run = bool(argv) and argv[0] == "plan"
    if dry_run:
        argv = argv[1:]
    if len(argv) < 2 or argv[0] not in ("install", "remove", "upgrade"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return run(argv[0], argv[1:], dry_run)
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": argv[1:]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
