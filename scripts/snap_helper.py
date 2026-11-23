#!/usr/bin/env python3
"""Snap support for the dankSoftwareDepot DMS plugin.

Snaps sit beside the distribution's own package manager, as Flatpak, AppImages
and Homebrew do, so they are their own kind of software here rather than a
fourth entry in pkg_backend.py's dnf/apt/pacman list.

Everything goes through snapd's REST API on its unix socket rather than
through the `snap` command line, for two reasons:

* The API answers in JSON. `snap list` and `snap refresh --list` print columns
  meant for a terminal, and `snap refresh` draws a progress bar with carriage
  returns that has to be scraped. The API reports a change as a list of tasks,
  each with its own status and — for the download — its own byte counter.
* It authorises the way the rest of the desktop does. Reading is open to every
  user. Changing something is checked by snapd itself against polkit, and the
  `X-Allow-Interaction` header lets that check ask: the shell's polkit agent
  shows the prompt, as it does for every other privileged action here. There
  is no pkexec, and nothing in this helper ever runs as root.

Modes:

    snap_helper.py --state                 installed snaps and pending refreshes
    snap_helper.py --refresh [name ...]    refresh those, or everything pending
    snap_helper.py --remove <name>         remove one snap
    snap_helper.py --search <term>         snaps in the store matching a word
    snap_helper.py --info <name>           one snap from the store, in detail
    snap_helper.py --install <name> [--classic]

`--state`, `--search` and `--info` print one JSON document. The others print
newline-delimited events, in the shape the other helpers use:

    {"event":"plan","ops":[{"name":"hello","from":"2.10","to":"2.11","bytes":65536}]}
    {"event":"op-start","name":"hello"}
    {"event":"op-progress","name":"hello","fraction":0.4,"bytesDone":26214,"bytesTotal":65536}
    {"event":"op-done","name":"hello"}
    {"event":"op-error","name":"hello","message":"..."}
    {"event":"done","ok":true,"failed":[]}

`--remove` speaks the dialect the Installed tab's uninstall already reads
(`status`, `plan`, `op-start`/`progress` with phase "remove"), and exits
non-zero when nothing was removed.
"""

import http.client
import json
import os
import re
import socket
import sys
import time
import urllib.parse

SOCKET = os.environ.get("DSD_SNAPD_SOCKET", "/run/snapd.socket")
# Where snapd puts the desktop entries of the snaps it installs; one file per
# app, named <snap>_<app>.desktop
DESKTOP_DIR = os.environ.get("DSD_SNAP_DESKTOP_DIR", "/var/lib/snapd/desktop/applications")
# /snap on Debian and Ubuntu; Fedora and Arch mount under /var/lib/snapd/snap
# and only have /snap when someone made the symlink for classic snaps
MOUNT_DIRS = [d for d in os.environ.get("DSD_SNAP_MOUNT_DIRS", "/snap:/var/lib/snapd/snap").split(":") if d]

READ_TIMEOUT = 30
# Asking the store what is newer is a network round trip on snapd's side
STORE_TIMEOUT = 90
# A change is polled, not waited on: the request itself returns at once
POLL_INTERVAL = 0.25


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


class SnapdError(Exception):
    """snapd answered, and the answer was no. `kind` is snapd's own name for
    why — "auth-cancelled", "snap-not-found", "snap-needs-classic" — which is
    what tells a dismissed password prompt apart from a real failure."""

    def __init__(self, message, kind="", status=0):
        super().__init__(message)
        self.kind = kind
        self.status = status


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def available():
    """Whether there is a snapd to ask. The socket existing is the test snapd
    itself uses for "is the daemon installed"; whether it answers is the next
    question, and the one every call below answers for itself."""
    return os.path.exists(SOCKET)


def request(method, path, body=None, timeout=READ_TIMEOUT, interactive=False):
    """One call to snapd: the `result` of a sync answer, the change id of an
    async one. Anything else raises SnapdError; a socket that cannot be
    reached raises OSError."""
    conn = _UnixConnection(SOCKET, timeout)
    headers = {"Accept": "application/json"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if interactive:
        # Lets snapd's polkit check put up a prompt rather than refusing
        # outright; without it, a user who is not root gets "access denied"
        headers["X-Allow-Interaction"] = "true"
    try:
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        raw = response.read()
    except (http.client.HTTPException, socket.timeout) as e:
        raise OSError(str(e)) from e
    finally:
        conn.close()
    try:
        doc = json.loads(raw or b"{}")
    except ValueError:
        raise SnapdError("snapd sent something that is not JSON", status=response.status)
    if doc.get("type") == "error" or response.status >= 400:
        result = doc.get("result") or {}
        raise SnapdError(result.get("message") or doc.get("status") or "snapd refused the request",
                         kind=result.get("kind") or "", status=doc.get("status-code") or response.status)
    if doc.get("type") == "async":
        return doc.get("change") or ""
    return doc.get("result")


# ── What is installed, and what is newer ────────────────────────────────────

def _desktop_entries():
    """{snap name: {"name": launcher name, "icon": icon}} from the entries
    snapd exported. The first app of a snap wins; a snap with several apps
    usually leads with the one it is named after, and the name only has to
    be a better label than the snap's package name."""
    entries = {}
    try:
        files = sorted(os.listdir(DESKTOP_DIR))
    except OSError:
        return entries
    for filename in files:
        if not filename.endswith(".desktop") or "_" not in filename:
            continue
        snap = filename.split("_", 1)[0]
        if snap in entries:
            continue
        name = icon = ""
        no_display = False
        try:
            with open(os.path.join(DESKTOP_DIR, filename), encoding="utf-8", errors="replace") as f:
                section = ""
                for line in f:
                    line = line.strip()
                    if line.startswith("["):
                        section = line
                        continue
                    if section != "[Desktop Entry]":
                        continue
                    if line.startswith("Name=") and not name:
                        name = line[5:].strip()
                    elif line.startswith("Icon=") and not icon:
                        icon = line[5:].strip()
                    elif line.startswith("NoDisplay=") and line[10:].strip().lower() == "true":
                        no_display = True
        except OSError:
            continue
        if no_display:
            continue
        entries[snap] = {"name": name, "icon": icon}
    return entries


def _icon_for(name, entry):
    """A file to draw for this snap, or "". The desktop entry's Icon is an
    absolute path into the snap's mount when it is anything useful; failing
    that, the snap's own meta/gui/icon, which is where snapcraft puts it."""
    icon = (entry or {}).get("icon") or ""
    if icon.startswith("/") and os.path.isfile(icon):
        return icon
    for mount in MOUNT_DIRS:
        for ext in ("svg", "png"):
            path = os.path.join(mount, name, "current", "meta", "gui", "icon." + ext)
            if os.path.isfile(path):
                return path
    # A theme name: the window resolves those the way it does for packages
    return icon if icon and "/" not in icon else ""


def _publisher(snap):
    publisher = snap.get("publisher") or {}
    return {
        "publisher": publisher.get("display-name") or publisher.get("username") or snap.get("developer") or "",
        # "verified" is Canonical's check that the publisher is who it says
        # it is; "starred" is a tier below. Either is worth a badge, the way a
        # verified Flathub app gets one.
        "verified": (publisher.get("validation") or "") in ("verified", "starred"),
    }


def parse_installed(snaps, entries=None):
    """GET /v2/snaps into rows. Every type of snap is listed — the bases and
    snapd itself are refreshed like the rest, and an update row has to have
    something to name — but only `app` snaps are applications, and the
    Installed tab shows only those, as it shows only Flatpak apps and not
    their runtimes."""
    entries = entries if entries is not None else {}
    rows = []
    for snap in snaps or []:
        name = snap.get("name") or ""
        if not name:
            continue
        entry = entries.get(name)
        row = {
            "name": name,
            "title": snap.get("title") or (entry or {}).get("name") or name,
            "summary": snap.get("summary") or "",
            "version": snap.get("version") or "",
            "revision": str(snap.get("revision") or ""),
            "channel": snap.get("tracking-channel") or snap.get("channel") or "",
            "type": snap.get("type") or "app",
            "confinement": snap.get("confinement") or "strict",
            "devmode": bool(snap.get("devmode")),
            # snapd's own hold, from `snap refresh --hold`: the user asked for
            # this one to stay where it is, which is what held means here too
            "held": bool(snap.get("hold")),
            "installedSize": int(snap.get("installed-size") or 0),
            "installDate": snap.get("install-date") or "",
            "website": snap.get("website") or "",
            "license": snap.get("license") or "",
            "icon": _icon_for(name, entry),
            "hasDesktopEntry": entry is not None,
        }
        row.update(_publisher(snap))
        rows.append(row)
    rows.sort(key=lambda r: r["name"])
    return rows


def parse_refreshes(found, installed_rows):
    """GET /v2/find?select=refresh into update rows. The store answers with
    the snap as it will be — its version is the new one — so the installed
    version comes from the other list."""
    by_name = {row["name"]: row for row in installed_rows}
    rows = []
    for snap in found or []:
        name = snap.get("name") or ""
        if not name:
            continue
        current = by_name.get(name) or {}
        rows.append({
            "name": name,
            "displayName": current.get("title") or snap.get("title") or name,
            "type": snap.get("type") or current.get("type") or "app",
            "fromVersion": current.get("version") or "",
            "toVersion": snap.get("version") or "",
            "fromRevision": current.get("revision") or "",
            "toRevision": str(snap.get("revision") or ""),
            "channel": snap.get("channel") or current.get("channel") or "",
            "downloadSize": int(snap.get("download-size") or 0),
            "held": bool(current.get("held")),
            "icon": current.get("icon") or "",
        })
    rows.sort(key=lambda r: r["name"])
    return rows


def run_state():
    if not available():
        print(json.dumps({"supported": False, "installed": [], "outdated": []}))
        return
    try:
        installed = parse_installed(request("GET", "/v2/snaps"), _desktop_entries())
    except (OSError, SnapdError) as e:
        # A socket nobody answers on: snapd is installed but not running, or
        # socket activation is off. Saying so is more use than an empty list
        print(json.dumps({"supported": False, "installed": [], "outdated": [],
                          "error": str(e)}))
        return
    outdated = []
    refresh_error = ""
    try:
        outdated = parse_refreshes(
            request("GET", "/v2/find?select=refresh", timeout=STORE_TIMEOUT), installed)
    except SnapdError as e:
        # Older snapd answers "nothing to refresh" as a 404 rather than an
        # empty list; that is the good news, not an error
        if e.kind not in ("snap-not-found",) and e.status != 404:
            refresh_error = str(e)
    except OSError as e:
        refresh_error = str(e)
    print(json.dumps({
        "supported": True,
        "installed": installed,
        "outdated": outdated,
        "refreshError": refresh_error,
    }))


# ── Following a change ──────────────────────────────────────────────────────
# snapd answers a refresh, install or removal at once with the id of a
# "change", and does the work in the background. The change is a list of
# tasks; each names the snap it is about in its summary
# ('Download snap "hello" (43) from channel "latest/stable"'), and the
# download task counts bytes in its progress.

QUOTED = re.compile(r'"([^"]+)"')
# Not about any one snap, though they quote several: the task that watches for
# a second round of refreshes stays waiting until every snap is done
SHARED_TASK_KINDS = {"check-rerefresh", "conditional-auto-refresh"}
DONE = {"Done"}
FAILED = {"Error", "Undone", "Undoing", "Hold"}
STARTED = {"Doing", "Done", "Undoing", "Undone", "Error", "Abort"}


def tasks_by_snap(change, names):
    """{name: [task, ...]} for the tasks of this change that are about one of
    `names` alone. A task about something else — a base the refresh had to
    pull in, say — is not attributed to anything it did not name."""
    wanted = set(names)
    grouped = {name: [] for name in names}
    for task in change.get("tasks") or []:
        if task.get("kind") in SHARED_TASK_KINDS:
            continue
        mentioned = [m for m in QUOTED.findall(task.get("summary") or "") if m in wanted]
        if len(set(mentioned)) != 1:
            continue
        grouped[mentioned[0]].append(task)
    return grouped


def snap_progress(tasks):
    """(status, fraction, bytes done, bytes total) for one snap's tasks.

    The download is most of the waiting, so it is most of the bar: 70% for
    its bytes, the rest spread over the other tasks as they finish.
    """
    if not tasks:
        return "pending", 0.0, 0, 0
    statuses = [t.get("status") or "" for t in tasks]
    if any(s == "Error" for s in statuses):
        status = "error"
    elif all(s in DONE for s in statuses):
        status = "done"
    elif any(s in STARTED for s in statuses):
        status = "active"
    else:
        status = "pending"
    bytes_done = bytes_total = 0
    download = None
    for task in tasks:
        if task.get("kind") == "download-snap":
            progress = task.get("progress") or {}
            total = int(progress.get("total") or 0)
            # Until the download starts, snapd fills progress in as 1 of 1 —
            # a placeholder that read as a finished download and put the bar
            # at 70% before a byte had moved (seen against snapd 2.77)
            if total > 1:
                bytes_total = total
                bytes_done = int(progress.get("done") or 0)
            if task.get("status") == "Done":
                bytes_done = bytes_total
                download = 1.0
            elif bytes_total > 0 and task.get("status") == "Doing":
                download = min(1.0, bytes_done / bytes_total)
            else:
                download = 0.0
                bytes_done = 0
    finished = sum(1 for s in statuses if s in DONE)
    rest = finished / len(tasks)
    if download is not None:
        fraction = 0.7 * download + 0.3 * rest
    else:
        fraction = rest
    return status, min(1.0, fraction), bytes_done, bytes_total


def snap_error(change, name, tasks):
    """What went wrong for this snap, in snapd's words. A failed task logs
    the reason; failing that, the change's error lists one line per task
    that failed, and the ones naming this snap are the ones that matter."""
    lines = []
    for task in tasks:
        if task.get("status") != "Error":
            continue
        for entry in task.get("log") or []:
            # "2026-11-23T10:00:00Z ERROR cannot ..." — the date is noise
            parts = entry.split(" ", 2)
            text = parts[2] if len(parts) == 3 and parts[1] in ("ERROR", "INFO") else entry
            if parts[1:2] == ["ERROR"] or len(parts) < 3:
                lines.append(text)
    if lines:
        return "\n".join(lines[-4:])
    err = change.get("err") or ""
    named = [line.strip("- ").strip() for line in err.splitlines() if '"' + name + '"' in line]
    return "\n".join(named) or err or "snapd did not finish this"


def follow(change_id, names, on_update, sleep=time.sleep):
    """Poll a change until snapd calls it ready, reporting each snap's state
    to `on_update(name, status, fraction, bytes_done, bytes_total)` whenever
    it moves. Returns the final change document."""
    last = {}
    highest = {}
    while True:
        change = request("GET", "/v2/changes/" + urllib.parse.quote(str(change_id)))
        grouped = tasks_by_snap(change, names)
        ready = bool(change.get("ready"))
        for name in names:
            status, fraction, done, total = snap_progress(grouped[name])
            if ready and status not in ("done", "error"):
                # The change is over and this snap never got there: rolled
                # back, or held back by a failure in a task it waited on
                status = "done" if change.get("status") == "Done" and grouped[name] else "error"
            # A task added mid-change (snapd adds hooks and re-refresh steps as
            # it goes) grows the denominator; the bar should wait, not go back
            fraction = max(fraction, highest.get(name, 0.0))
            highest[name] = fraction
            state = (status, round(fraction, 3), done)
            if last.get(name) != state:
                last[name] = state
                on_update(name, status, fraction, done, total)
        if ready:
            return change
        sleep(POLL_INTERVAL)


def _refusal(e):
    if e.kind == "auth-cancelled":
        return "authorisation was cancelled"
    if e.kind in ("login-required", "auth-required") or e.status in (401, 403):
        return "not authorised: " + str(e)
    return str(e)


def run_changes(names, start, sleep=time.sleep):
    """Start a change for `names` and report it as op-* events. `start` sends
    the request and returns the change id."""
    try:
        change_id = start()
    except SnapdError as e:
        message = _refusal(e)
        emit({"event": "error", "message": message, "kind": e.kind})
        for name in names:
            emit({"event": "op-error", "name": name, "message": message})
        emit({"event": "done", "ok": False, "failed": names})
        return False
    except OSError as e:
        emit({"event": "error", "message": "snapd could not be reached: " + str(e)})
        for name in names:
            emit({"event": "op-error", "name": name, "message": str(e)})
        emit({"event": "done", "ok": False, "failed": names})
        return False

    started = set()
    reported = set()
    failed = []

    def update(name, status, fraction, done, total):
        if status == "pending" or name in reported:
            return
        if name not in started:
            started.add(name)
            emit({"event": "op-start", "name": name})
        if status == "active":
            emit({"event": "op-progress", "name": name, "fraction": round(fraction, 3),
                  "bytesDone": done, "bytesTotal": total})

    try:
        change = follow(change_id, names, update, sleep)
    except (OSError, SnapdError) as e:
        for name in names:
            emit({"event": "op-error", "name": name,
                  "message": "lost track of snapd's change " + str(change_id) + ": " + str(e)})
        emit({"event": "done", "ok": False, "failed": names})
        return False

    grouped = tasks_by_snap(change, names)
    for name in names:
        status, _, _, _ = snap_progress(grouped[name])
        if status == "done" or (change.get("status") == "Done" and status != "error"):
            if name not in started:
                emit({"event": "op-start", "name": name})
            emit({"event": "op-done", "name": name})
        else:
            failed.append(name)
            emit({"event": "op-error", "name": name, "message": snap_error(change, name, grouped[name])})
        reported.add(name)
    emit({"event": "done", "ok": not failed, "failed": failed})
    return not failed


# ── Refreshing, installing, removing ────────────────────────────────────────

def run_refresh(names, sleep=time.sleep):
    if not available():
        emit({"event": "error", "message": "snapd is not installed"})
        emit({"event": "done", "ok": False, "failed": names})
        return False
    try:
        installed = parse_installed(request("GET", "/v2/snaps"))
        pending = parse_refreshes(request("GET", "/v2/find?select=refresh", timeout=STORE_TIMEOUT), installed)
    except SnapdError as e:
        pending = [] if (e.kind == "snap-not-found" or e.status == 404) else None
        if pending is None:
            emit({"event": "error", "message": str(e)})
            emit({"event": "done", "ok": False, "failed": names})
            return False
    except OSError as e:
        emit({"event": "error", "message": "snapd could not be reached: " + str(e)})
        emit({"event": "done", "ok": False, "failed": names})
        return False

    by_name = {row["name"]: row for row in pending}
    if names:
        planned = list(names)
    else:
        # Held ones sit out a run that did not name them, as pinned formulae do
        planned = [row["name"] for row in pending if not row["held"]]
    if not planned:
        emit({"event": "plan", "ops": []})
        emit({"event": "done", "ok": True, "failed": []})
        return True

    emit({"event": "plan", "ops": [{
        "name": n,
        "from": (by_name.get(n) or {}).get("fromVersion", ""),
        "to": (by_name.get(n) or {}).get("toVersion", ""),
        "bytes": (by_name.get(n) or {}).get("downloadSize", 0),
    } for n in planned]})
    return run_changes(planned, lambda: request(
        "POST", "/v2/snaps", {"action": "refresh", "snaps": planned}, interactive=True), sleep)


def run_install(name, classic=False, sleep=time.sleep):
    if not available():
        emit({"event": "error", "message": "snapd is not installed"})
        emit({"event": "done", "ok": False, "failed": [name]})
        return False
    emit({"event": "plan", "ops": [{"name": name}]})
    body = {"action": "install"}
    if classic:
        # Only when the window has said what classic means and the user went
        # ahead: snapd refuses a classic snap without it, and that refusal is
        # the right answer for anyone who did not see the warning
        body["classic"] = True
    return run_changes([name], lambda: request(
        "POST", "/v2/snaps/" + urllib.parse.quote(name), body, interactive=True), sleep)


def run_remove(name, sleep=time.sleep):
    """Remove one snap, reported in the Installed tab's uninstall dialect."""
    if not available():
        sys.stderr.write("snapd is not installed\n")
        return False
    emit({"event": "status"})
    try:
        change_id = request("POST", "/v2/snaps/" + urllib.parse.quote(name),
                            {"action": "remove"}, interactive=True)
    except SnapdError as e:
        sys.stderr.write(_refusal(e) + "\n")
        return False
    except OSError as e:
        sys.stderr.write("snapd could not be reached: " + str(e) + "\n")
        return False
    emit({"event": "plan", "totalDownloadBytes": 0})
    emit({"event": "op-start", "phase": "remove", "index": 1, "total": 1})

    def update(_name, status, fraction, _done, _total):
        if status == "active":
            emit({"event": "progress", "phase": "remove", "percent": round(fraction * 100)})

    try:
        change = follow(change_id, [name], update, sleep)
    except (OSError, SnapdError) as e:
        sys.stderr.write("lost track of snapd's change: " + str(e) + "\n")
        return False
    if change.get("status") != "Done":
        sys.stderr.write(snap_error(change, name, tasks_by_snap(change, [name])[name]) + "\n")
        return False
    emit({"event": "done", "ok": True})
    return True


# ── Searching the store ─────────────────────────────────────────────────────

def _describe(snap, installed_names):
    media = snap.get("media") or []
    icon = next((m.get("url") for m in media if m.get("type") == "icon" and m.get("url")), "")
    out = {
        "name": snap.get("name") or "",
        "title": snap.get("title") or snap.get("name") or "",
        "summary": snap.get("summary") or "",
        "description": snap.get("description") or "",
        "version": snap.get("version") or "",
        "channel": snap.get("channel") or "",
        "confinement": snap.get("confinement") or "strict",
        "downloadSize": int(snap.get("download-size") or 0),
        "license": snap.get("license") or "",
        "website": snap.get("website") or "",
        "storeUrl": snap.get("store-url") or "",
        "iconUrl": icon,
        "type": snap.get("type") or "app",
        "installed": (snap.get("name") or "") in installed_names,
    }
    out.update(_publisher(snap))
    return out


def _installed_names():
    try:
        return {s.get("name") for s in (request("GET", "/v2/snaps") or [])}
    except (OSError, SnapdError):
        return set()


def run_search(term, limit=40):
    if not available() or not (term or "").strip():
        print(json.dumps({"supported": available(), "results": []}))
        return
    try:
        found = request("GET", "/v2/find?" + urllib.parse.urlencode({"q": term.strip()}),
                        timeout=STORE_TIMEOUT) or []
    except SnapdError as e:
        if e.kind == "snap-not-found" or e.status == 404:
            found = []
        else:
            print(json.dumps({"supported": True, "term": term, "results": [], "error": str(e)}))
            return
    except OSError as e:
        print(json.dumps({"supported": True, "term": term, "results": [], "error": str(e)}))
        return
    installed = _installed_names()
    # Only applications: a search for "core" listing bases, kernels and gadget
    # snaps would be listing things nobody installs by hand
    results = [_describe(s, installed) for s in found if (s.get("type") or "app") == "app"]
    print(json.dumps({
        "supported": True,
        "term": term,
        "truncated": len(results) > limit,
        "results": results[:limit],
    }))


def run_info(name):
    if not available():
        print(json.dumps({"supported": False}))
        return
    try:
        found = request("GET", "/v2/find?" + urllib.parse.urlencode({"name": name}),
                        timeout=STORE_TIMEOUT) or []
    except (OSError, SnapdError):
        found = []
    if not found:
        print(json.dumps({"supported": True, "found": False, "name": name}))
        return
    out = _describe(found[0], _installed_names())
    out.update({"supported": True, "found": True})
    print(json.dumps(out))


def main():
    args = sys.argv[1:]
    mode = args[0] if args else ""
    rest = [a for a in args[1:] if not a.startswith("--")]
    if mode == "--state":
        run_state()
        return 0
    if mode == "--refresh":
        return 0 if run_refresh(rest) else 1
    if mode == "--remove" and rest:
        return 0 if run_remove(rest[0]) else 1
    if mode == "--install" and rest:
        return 0 if run_install(rest[0], classic="--classic" in args) else 1
    if mode == "--search":
        run_search(" ".join(rest).strip())
        return 0
    if mode == "--info" and rest:
        run_info(rest[0])
        return 0
    print(json.dumps({"error": "usage: snap_helper.py --state | --refresh [name ...] | --remove <name> | "
                               "--search <term> | --info <name> | --install <name> [--classic]"}))
    return 2


if __name__ == "__main__":
    sys.exit(main())
