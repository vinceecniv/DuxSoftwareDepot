#!/usr/bin/env python3
"""Checks the snap path against a stand-in snapd, with no snapd present.

Runnable anywhere: a small HTTP server on a unix socket answers the calls the
helper makes, with documents in the shape snapd's REST API returns. The task
summaries and kinds are the ones snapd 2.6x writes for a refresh.
"""

import io
import json
import os
import socketserver
import sys
import tempfile
import threading
from contextlib import redirect_stdout, redirect_stderr
from http.server import BaseHTTPRequestHandler

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

failures = []


def check(label, condition, detail=""):
    if condition:
        print(f"  ok   {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label}" + (f"\n       {detail}" if detail else ""))


SNAPS = [
    {"name": "hello", "title": "Hello", "summary": "GNU Hello", "version": "2.10", "revision": "38",
     "tracking-channel": "latest/stable", "type": "app", "confinement": "strict",
     "publisher": {"display-name": "Canonical", "validation": "verified"},
     "installed-size": 98304, "install-date": "2026-11-01T10:00:00Z"},
    {"name": "core22", "summary": "Runtime", "version": "20250101", "revision": "1500",
     "type": "base", "publisher": {"display-name": "Canonical", "validation": "verified"}},
    {"name": "frozen", "version": "1.0", "revision": "3", "type": "app",
     "hold": "2315-01-01T00:00:00Z", "publisher": {"username": "someone"}},
]

REFRESHES = [
    {"name": "hello", "version": "2.11", "revision": "42", "channel": "stable", "download-size": 65536},
    {"name": "core22", "version": "20251101", "revision": "1600", "download-size": 70000000},
    {"name": "frozen", "version": "1.1", "revision": "4", "download-size": 1000},
]


def task(kind, summary, status, done=1, total=1, log=None):
    return {"kind": kind, "summary": summary, "status": status,
            "progress": {"label": "", "done": done, "total": total}, "log": log or []}


def refresh_tasks(name, rev, step):
    """One snap's lane of a refresh, `step` tasks in. Step 1 is halfway
    through the download."""
    lane = [
        ("prerequisites", f'Ensure prerequisites for "{name}" are available'),
        ("download-snap", f'Download snap "{name}" ({rev}) from channel "latest/stable"'),
        ("validate-snap", f'Fetch and check assertions for snap "{name}" ({rev})'),
        ("mount-snap", f'Mount snap "{name}" ({rev})'),
        ("link-snap", f'Make snap "{name}" ({rev}) available to the system'),
    ]
    out = []
    for i, (kind, summary) in enumerate(lane):
        if kind == "download-snap":
            if step > 1:
                out.append(task(kind, summary, "Done", 65536, 65536))
            elif step == 1:
                out.append(task(kind, summary, "Doing", 32768, 65536))
            else:
                out.append(task(kind, summary, "Do", 0, 65536))
            continue
        out.append(task(kind, summary, "Done" if i < step else ("Doing" if i == step else "Do")))
    return out


class Snapd:
    """What the stand-in answers; each test sets the fields it needs."""

    def __init__(self):
        self.posts = []
        self.headers = []
        self.change_polls = []
        self.post_error = None
        self.refreshes = REFRESHES
        self.refresh_404 = False

    def handle(self, method, path, body, headers):
        if method == "GET" and path == "/v2/snaps":
            return 200, {"type": "sync", "status-code": 200, "result": SNAPS}
        if method == "GET" and path.startswith("/v2/find?select=refresh"):
            if self.refresh_404:
                return 404, {"type": "error", "status-code": 404,
                             "result": {"message": "snap not found", "kind": "snap-not-found"}}
            return 200, {"type": "sync", "status-code": 200, "result": self.refreshes}
        if method == "GET" and path.startswith("/v2/find?"):
            return 200, {"type": "sync", "status-code": 200, "result": [
                {"name": "hello", "title": "Hello", "type": "app", "version": "2.11",
                 "media": [{"type": "icon", "url": "https://example/icon.png"}],
                 "publisher": {"display-name": "Canonical", "validation": "verified"}},
                {"name": "core24", "type": "base"},
                {"name": "code", "title": "Code", "type": "app", "confinement": "classic"},
            ]}
        if method == "POST":
            self.posts.append((path, body))
            self.headers.append(headers)
            if self.post_error:
                return 403, {"type": "error", "status-code": 403, "result": self.post_error}
            return 202, {"type": "async", "status-code": 202, "change": "7"}
        if method == "GET" and path == "/v2/changes/7":
            doc = self.changes[min(len(self.change_polls), len(self.changes) - 1)]
            self.change_polls.append(doc)
            return 200, {"type": "sync", "status-code": 200, "result": doc}
        return 404, {"type": "error", "status-code": 404, "result": {"message": "no such path " + path}}


SNAPD = Snapd()


class Handler(BaseHTTPRequestHandler):
    def _answer(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        status, doc = SNAPD.handle(method, self.path, body, dict(self.headers))
        raw = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._answer("GET")

    def do_POST(self):
        self._answer("POST")

    def address_string(self):
        return "snapd"

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def events_of(fn, *args, **kwargs):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        result = fn(*args, **kwargs)
    events = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    return result, events, err.getvalue()


def main():
    tmp = tempfile.mkdtemp(prefix="dsd-snap-")
    sock = os.path.join(tmp, "snapd.socket")
    desktop = os.path.join(tmp, "applications")
    os.makedirs(desktop)
    icon = os.path.join(tmp, "hello.png")
    open(icon, "wb").close()
    with open(os.path.join(desktop, "hello_hello.desktop"), "w") as f:
        f.write(f"[Desktop Entry]\nName=Hello World\nIcon={icon}\nExec=hello\n")
    with open(os.path.join(desktop, "hello_helper.desktop"), "w") as f:
        f.write("[Desktop Entry]\nName=Helper\nNoDisplay=true\n")
    os.environ["DSD_SNAPD_SOCKET"] = sock
    os.environ["DSD_SNAP_DESKTOP_DIR"] = desktop
    os.environ["DSD_SNAP_MOUNT_DIRS"] = os.path.join(tmp, "nowhere")

    import snap_helper as snap

    # ── No snapd ────────────────────────────────────────────────────────────
    out = io.StringIO()
    with redirect_stdout(out):
        snap.run_state()
    check("without a socket, snaps are not supported and nothing is listed",
          json.loads(out.getvalue()) == {"supported": False, "installed": [], "outdated": []}, out.getvalue())

    server = Server(sock, Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        # ── State ───────────────────────────────────────────────────────────
        out = io.StringIO()
        with redirect_stdout(out):
            snap.run_state()
        state = json.loads(out.getvalue())
        installed = {row["name"]: row for row in state["installed"]}
        outdated = {row["name"]: row for row in state["outdated"]}
        check("state is supported with every installed snap",
              state["supported"] and sorted(installed) == ["core22", "frozen", "hello"], str(sorted(installed)))
        check("a snap's launcher entry gives its icon",
              installed["hello"]["icon"] == icon and installed["hello"]["hasDesktopEntry"], str(installed["hello"]))
        check("the publisher and its verification travel",
              installed["hello"]["publisher"] == "Canonical" and installed["hello"]["verified"])
        check("snapd's own hold is read", installed["frozen"]["held"] and not installed["hello"]["held"])
        check("a base is listed as a base", installed["core22"]["type"] == "base")
        check("an update row names both versions and the download",
              outdated["hello"]["fromVersion"] == "2.10" and outdated["hello"]["toVersion"] == "2.11"
              and outdated["hello"]["downloadSize"] == 65536, str(outdated["hello"]))
        check("an update row carries the launcher's name", outdated["hello"]["displayName"] == "Hello")

        SNAPD.refresh_404 = True
        out = io.StringIO()
        with redirect_stdout(out):
            snap.run_state()
        state = json.loads(out.getvalue())
        check("older snapd's 404 for nothing to refresh is no updates, not an error",
              state["outdated"] == [] and state["refreshError"] == "", str(state))
        SNAPD.refresh_404 = False

        # ── Following a change ──────────────────────────────────────────────
        rerefresh = task("check-rerefresh",
                         'Monitoring snaps "hello", "core22" to determine whether extra refresh steps are required',
                         "Do")
        SNAPD.changes = [
            {"id": "7", "status": "Doing", "ready": False,
             "tasks": refresh_tasks("hello", 42, 1) + refresh_tasks("core22", 1600, 0) + [rerefresh]},
            {"id": "7", "status": "Doing", "ready": False,
             "tasks": refresh_tasks("hello", 42, 5) + refresh_tasks("core22", 1600, 3) + [rerefresh]},
            {"id": "7", "status": "Done", "ready": True,
             "tasks": refresh_tasks("hello", 42, 5) + refresh_tasks("core22", 1600, 5)
             + [dict(rerefresh, status="Done")]},
        ]
        ok, events, _ = events_of(snap.run_refresh, [], sleep=lambda s: None)
        names = [op["name"] for op in events[0]["ops"]]
        check("an unnamed refresh takes everything pending but the held snap",
              names == ["core22", "hello"], str(names))
        check("the plan carries the download size", events[0]["ops"][1]["bytes"] == 65536, str(events[0]))
        check("the request asks snapd to allow a polkit prompt",
              SNAPD.headers[-1].get("X-Allow-Interaction") == "true", str(SNAPD.headers[-1]))
        check("one refresh request names the snaps",
              SNAPD.posts[-1] == ("/v2/snaps", {"action": "refresh", "snaps": ["core22", "hello"]}), str(SNAPD.posts[-1]))
        progress = [e for e in events if e["event"] == "op-progress" and e["name"] == "hello"]
        check("the download reports its bytes",
              progress and progress[0]["bytesDone"] == 32768 and progress[0]["bytesTotal"] == 65536, str(progress))
        check("the download is most of the bar", progress and 0.35 < progress[0]["fraction"] < 0.5, str(progress))
        starts = [e["name"] for e in events if e["event"] == "op-start"]
        check("a snap starts once, when its lane does", starts.count("hello") == 1 and starts.count("core22") == 1,
              str(starts))
        check("every planned snap is reported done",
              sorted(e["name"] for e in events if e["event"] == "op-done") == ["core22", "hello"], str(events))
        check("a clean refresh ends ok", ok and events[-1] == {"event": "done", "ok": True, "failed": []}, str(events[-1]))
        check("the shared re-refresh task held nothing back",
              not [e for e in events if e["event"] == "op-error"])

        # snapd fills a download that has not started in as 1 of 1
        waiting = refresh_tasks("hello", 42, 1)
        waiting[1] = task("download-snap", waiting[1]["summary"], "Doing", 1, 1)
        _, fraction, done, total = snap.snap_progress(waiting)
        check("a download not yet started is not a finished one",
              fraction < 0.1 and done == 0 and total == 0, f"{fraction} {done}/{total}")

        # One lane fails; the other is still done
        SNAPD.change_polls = []
        broken = refresh_tasks("core22", 1600, 2)
        broken[2] = task("validate-snap", broken[2]["summary"], "Error",
                         log=["2026-11-23T10:00:00Z ERROR cannot verify snap \"core22\": signature mismatch"])
        SNAPD.changes = [{"id": "7", "status": "Error", "ready": True,
                          "err": 'cannot perform the following tasks:\n- Fetch and check assertions for snap "core22" (1600) (signature mismatch)',
                          "tasks": refresh_tasks("hello", 42, 5) + broken}]
        ok, events, _ = events_of(snap.run_refresh, ["hello", "core22"], sleep=lambda s: None)
        errors = {e["name"]: e["message"] for e in events if e["event"] == "op-error"}
        check("a failed lane is the only failure", list(errors) == ["core22"] and not ok, str(events))
        check("the failure is in snapd's words, without the timestamp",
              errors.get("core22") == 'cannot verify snap "core22": signature mismatch', str(errors))
        check("the other lane is still done", {"event": "op-done", "name": "hello"} in events)
        check("the run says which failed", events[-1] == {"event": "done", "ok": False, "failed": ["core22"]})

        # The password prompt dismissed
        SNAPD.post_error = {"message": "cancelled", "kind": "auth-cancelled"}
        ok, events, _ = events_of(snap.run_refresh, ["hello"], sleep=lambda s: None)
        check("a dismissed prompt fails every snap and says so",
              not ok and events[-1]["failed"] == ["hello"]
              and any(e.get("message") == "authorisation was cancelled" for e in events), str(events))

        # ── Removing ────────────────────────────────────────────────────────
        ok, events, err = events_of(snap.run_remove, "hello", sleep=lambda s: None)
        check("a cancelled removal fails with the reason on stderr",
              not ok and "cancelled" in err, err)
        SNAPD.post_error = None
        SNAPD.change_polls = []
        SNAPD.changes = [
            {"id": "7", "status": "Doing", "ready": False,
             "tasks": [task("stop-snap-services", 'Stop snap "hello" services', "Done"),
                       task("remove-profiles", 'Remove security profile for snap "hello" (38)', "Doing")]},
            {"id": "7", "status": "Done", "ready": True,
             "tasks": [task("stop-snap-services", 'Stop snap "hello" services', "Done"),
                       task("remove-profiles", 'Remove security profile for snap "hello" (38)', "Done")]},
        ]
        ok, events, _ = events_of(snap.run_remove, "hello", sleep=lambda s: None)
        check("removing asks for the remove action",
              SNAPD.posts[-1] == ("/v2/snaps/hello", {"action": "remove"}), str(SNAPD.posts[-1]))
        check("removing speaks the uninstall dialect",
              ok and [e["event"] for e in events] == ["status", "plan", "op-start", "progress", "done"]
              and events[2]["phase"] == "remove" and events[3]["percent"] == 50, str(events))

        # ── Installing and searching ────────────────────────────────────────
        SNAPD.change_polls = []
        SNAPD.changes = [{"id": "7", "status": "Done", "ready": True,
                          "tasks": refresh_tasks("code", 200, 5)}]
        ok, events, _ = events_of(snap.run_install, "code", classic=True, sleep=lambda s: None)
        check("a classic install says classic to snapd",
              ok and SNAPD.posts[-1] == ("/v2/snaps/code", {"action": "install", "classic": True}), str(SNAPD.posts[-1]))
        out = io.StringIO()
        with redirect_stdout(out):
            snap.run_search("hello")
        found = json.loads(out.getvalue())["results"]
        check("a search lists applications only", [r["name"] for r in found] == ["hello", "code"], str(found))
        check("a search marks what is installed and keeps the store icon",
              found[0]["installed"] and found[0]["iconUrl"] == "https://example/icon.png" and not found[1]["installed"])
        check("a classic snap says so", found[1]["confinement"] == "classic")
    finally:
        server.shutdown()
        server.server_close()

    print()
    if failures:
        print(f"{len(failures)} failed")
        return 1
    print("snap helper: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
