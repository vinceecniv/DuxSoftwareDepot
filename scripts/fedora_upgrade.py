#!/usr/bin/env python3
"""Upgrading Fedora to its next release, the way Fedora documents it:
`dnf5 system-upgrade download`, then `dnf5 offline reboot`.

The banner that says a new release is out used to end at "Learn more". This
is the rest of it, in three steps, each one undoable until the last:

  plan <releasever>       What the upgrade would do, resolved by libdnf5
                          against the new release's metadata. No root, no
                          changes; the metadata goes into the depot's own
                          cache, not the system's. One JSON event line.
  download <releasever>   Download everything for it (root). The system
                          keeps running as it is; NDJSON progress events.
  status                  Whether an upgrade is downloaded and waiting for
                          its reboot, read from dnf5's own state file. JSON.

The reboot and dropping a prepared upgrade are dnf5's own `offline reboot`
and `offline clean`, run by the caller as they are.

libdnf5's Python bindings can resolve the upgrade but cannot store it as an
offline transaction — that part of dnf5 lives in the command-line tool — so
`download` drives `dnf5` itself and turns its lines into events.
"""
import json
import os
import re
import shutil
import subprocess
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


CACHE_ROOT = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
                          "dankSoftwareDepot")
OFFLINE_STATE = "/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml"
OS_RELEASE = "/etc/os-release"


def current_release():
    try:
        with open(OS_RELEASE) as f:
            for line in f:
                m = re.match(r"VERSION_ID=\"?(\d+)", line.strip())
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return 0


def plan_cache(releasever):
    return os.path.join(CACHE_ROOT, "upgrade-f%s" % releasever)


def sweep_plan_caches():
    """The new release's metadata, kept for a plan, is a few hundred MB
    that means nothing once that release is the running one."""
    running = current_release()
    try:
        names = os.listdir(CACHE_ROOT)
    except OSError:
        return
    for name in names:
        m = re.fullmatch(r"upgrade-f(\d+)", name)
        if m and running and int(m.group(1)) <= running:
            shutil.rmtree(os.path.join(CACHE_ROOT, name), ignore_errors=True)


# ── plan ─────────────────────────────────────────────────────────────────────

INBOUND = ("Install", "Upgrade", "Downgrade", "Reinstall")
OUTBOUND = ("Remove", "Replaced", "Obsoleted")


def resolve(releasever, allow_erasing):
    import libdnf5

    base = libdnf5.base.Base()
    base.load_config()
    os.makedirs(plan_cache(releasever), exist_ok=True)
    base.get_config().get_cachedir_option().set(plan_cache(releasever))
    base.get_vars().get().set("releasever", str(releasever))
    base.setup()
    sack = base.get_repo_sack()
    sack.create_repos_from_system_configuration()
    # A repository that cannot be loaded and may not be skipped — Fedora's
    # own — raises here, and that is the plan's answer: no upgrade today
    sack.load_repos()

    # One that may be skipped is left out quietly, which is exactly the
    # case worth saying out loud: a Copr or third-party repository with no
    # build for the new release yet. Its packages stay at the old release's
    # builds, or have to go, and its updates stop until it catches up.
    unavailable = []
    for repo in libdnf5.repo.RepoQuery(base):
        if not repo.is_enabled() or repo.get_type() != libdnf5.repo.Repo.Type_AVAILABLE:
            continue
        if repo.get_timestamp() == -1:
            unavailable.append({"id": repo.get_id(), "name": repo.get_name() or repo.get_id()})

    goal = libdnf5.base.Goal(base)
    goal.add_rpm_distro_sync()
    goal.set_allow_erasing(allow_erasing)
    transaction = goal.resolve()
    # The transaction refers into base; dropping base here frees what it
    # points at, and the next call on it takes the interpreter down
    return base, transaction, unavailable, libdnf5


def run_plan(releasever):
    emit({"event": "status", "message": "repos"})
    try:
        base, transaction, unavailable, libdnf5 = resolve(releasever, allow_erasing=False)
        allow_erasing = False
        if transaction.get_problems() != libdnf5.base.GoalProblem_NO_PROBLEM:
            # `system-upgrade download` refuses this unless told it may
            # remove packages; ask what it would remove, and let the user
            # decide with that list in front of them
            del transaction, base
            base, transaction, unavailable, libdnf5 = resolve(releasever, allow_erasing=True)
            allow_erasing = True
    except Exception as exc:
        emit({"event": "upgrade-plan", "ok": False, "releasever": releasever, "error": str(exc)})
        return 1
    if transaction.get_problems() != libdnf5.base.GoalProblem_NO_PROBLEM:
        logs = [line for line in transaction.get_resolve_logs_as_strings() if line.strip()]
        emit({"event": "upgrade-plan", "ok": False, "releasever": releasever,
              "error": "; ".join(logs) or "the upgrade could not be resolved",
              "unavailableRepos": unavailable})
        return 1

    counts = {"upgrade": 0, "install": 0, "downgrade": 0, "remove": 0}
    download = 0
    delta = 0
    arriving = set()
    leaving = []
    for tp in transaction.get_transaction_packages():
        pkg = tp.get_package()
        try:
            action = libdnf5.transaction.transaction_item_action_to_string(tp.get_action())
        except Exception:
            action = str(tp.get_action())
        if action in INBOUND:
            download += pkg.get_download_size()
            delta += pkg.get_install_size()
            arriving.add(pkg.get_name())
            key = action.lower()
            if key in counts:
                counts[key] += 1
        elif action in OUTBOUND:
            delta -= pkg.get_install_size()
            if action in ("Remove", "Obsoleted"):
                leaving.append(pkg.get_name())
    # An old kernel making room for the new release's kernel is the
    # installonly rotation every kernel update does, not a loss
    removed = sorted({name for name in leaving if name not in arriving})
    counts["remove"] = len(removed)
    emit({"event": "upgrade-plan", "ok": True, "releasever": releasever,
          "current": current_release(),
          "downloadBytes": download, "installDeltaBytes": delta,
          "counts": counts, "removed": removed, "allowErasing": allow_erasing,
          "unavailableRepos": unavailable})
    return 0


# ── status ───────────────────────────────────────────────────────────────────

def read_offline_state(path=None):
    """dnf5's state file, a small flat TOML table; read with tomllib when
    there is one (3.11+), by line otherwise."""
    try:
        with open(path or OFFLINE_STATE, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    try:
        import tomllib
        data = tomllib.loads(raw.decode("utf-8", "replace"))
        return data.get("offline-transaction-state", data)
    except Exception:
        pass
    state = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        m = re.match(r'\s*([A-Za-z_]+)\s*=\s*"?([^"]*)"?\s*$', line)
        if m:
            state[m.group(1)] = m.group(2)
    return state


def run_status():
    sweep_plan_caches()
    state = read_offline_state() or {}
    status = str(state.get("status", ""))
    verb = str(state.get("verb", ""))
    target = str(state.get("target_releasever", ""))
    # Only a downloaded system upgrade is ours to offer a reboot for; an
    # offline transaction of another kind (`dnf5 install --offline`) is
    # someone's own business, and only reported as being there
    print(json.dumps({
        "current": current_release(),
        # dnf5 records the verb as "system-upgrade download"
        "prepared": status in ("download-complete", "ready") and verb.startswith("system-upgrade"),
        "status": status,
        "verb": verb,
        "targetReleasever": target,
        "otherOffline": bool(status) and not verb.startswith("system-upgrade"),
    }), flush=True)
    return 0


# ── download ─────────────────────────────────────────────────────────────────
# dnf5 talks to a pipe in whole lines: a header per stage, then one line per
# package as it finishes, "[ 12/2340] name-evr  100% | 3.1 MiB/s | 2.4 MiB |
# 00m01s". That is enough for a count, a byte total and a stage.

DOWNLOADED = re.compile(r"^\[\s*(\d+)/(\d+)\]\s+(\S+).*\|\s*([\d.]+)\s*([KMGT]?i?B)\s*\|\s*\S+\s*$")
UNITS = {"B": 1, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4,
         "KB": 1000, "MB": 1000 ** 2, "GB": 1000 ** 3}


def parse_line(line, state):
    """One line of dnf5's output → an event, or None. `state` carries the
    running byte total between lines."""
    line = line.rstrip()
    if line.startswith("Updating and loading repositories"):
        return {"event": "status", "message": "repos"}
    if line.startswith("Repositories loaded"):
        return {"event": "status", "message": "resolving"}
    m = DOWNLOADED.match(line)
    if m:
        index, total, name = int(m.group(1)), int(m.group(2)), m.group(3)
        if name == "Total":
            return None
        state["bytes"] += int(float(m.group(4)) * UNITS.get(m.group(5), 1))
        return {"event": "progress", "phase": "download", "index": index, "total": total,
                "name": name, "totalTransferred": state["bytes"]}
    if line.startswith("Testing offline transaction"):
        return {"event": "status", "message": "testing"}
    if line.startswith("Transaction stored to be performed offline"):
        state["stored"] = True
        return {"event": "status", "message": "stored"}
    return None


def run_download(releasever, allow_erasing):
    if os.geteuid() != 0:
        emit({"event": "error", "message": "the download needs root (run through pkexec)"})
        emit({"event": "done", "ok": False, "failed": []})
        return 1
    cmd = ["dnf5", "system-upgrade", "download", "--releasever=%d" % releasever, "-y"]
    if allow_erasing:
        cmd.append("--allowerasing")
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    emit({"event": "status", "message": "starting", "command": " ".join(cmd)})
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, env=env, text=True, bufsize=1)
    except OSError as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": []})
        return 1
    import signal
    signal.signal(signal.SIGTERM, lambda *_: proc.terminate())
    state = {"bytes": 0, "stored": False}
    tail = []
    for line in proc.stdout:
        # Kept for the error: dnf5 says what went wrong in its last lines
        tail = (tail + [line.rstrip()])[-12:]
        event = parse_line(line, state)
        if event:
            emit(event)
        else:
            # The rest is the details panel's
            print(line.rstrip(), file=sys.stderr, flush=True)
    code = proc.wait()
    if code == 0 and state["stored"]:
        emit({"event": "done", "ok": True, "failed": [], "releasever": releasever})
        return 0
    reason = next((l.strip() for l in reversed(tail)
                   if l.strip() and not l.startswith("[")), "") or "dnf5 exited with %d" % code
    emit({"event": "error", "message": reason})
    emit({"event": "done", "ok": False, "failed": [], "exitCode": code})
    return 1


def main():
    args = sys.argv[1:]
    if args and args[0] == "status":
        return run_status()
    if len(args) == 2 and args[0] == "plan" and args[1].isdigit():
        import interp
        interp.ensure("libdnf5")
        return run_plan(int(args[1]))
    if len(args) >= 2 and args[0] == "download" and args[1].isdigit():
        return run_download(int(args[1]), "--allowerasing" in args[2:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
