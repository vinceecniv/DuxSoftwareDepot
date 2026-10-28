#!/usr/bin/env python3
"""Flatpak update engine for the dankSoftwareDepot DMS plugin.

Runs flatpak updates through libflatpak (like GNOME Software does), emitting
newline-delimited JSON progress events on stdout:

  {"event":"plan","ops":[{"ref":"app/...","appid":"...","action":"update","downloadBytes":N,"installation":"system"}],"totalDownloadBytes":N}
  {"event":"op-start","ref":"app/...","appid":"..."}
  {"event":"progress","ref":"app/...","appid":"...","percent":42,"bytesTransferred":N,"status":"..."}
  {"event":"op-done","ref":"app/...","appid":"..."}
  {"event":"op-error","ref":"app/...","appid":"...","message":"..."}
  {"event":"done","ok":true,"failed":[]}

Usage:  flatpak_helper.py update [appid ...]
        (no appids = update everything that has an update available)
        flatpak_helper.py install <remote> <appid>
        (install from the named remote, system installation when the remote
        exists there, user installation otherwise; same event stream)
        flatpak_helper.py inspect-file <path>
        (what a .flatpak bundle or .flatpakref is, and whether it is
        installed; one JSON object)
        flatpak_helper.py install-file <path>
        (install it, replacing the installed build; same event stream)

System-installation updates authenticate through polkit (the DMS agent shows
the prompt); no terminal is ever involved. SIGTERM/SIGINT abort the
transaction cleanly.
"""

import json
import os
import shutil
import signal
import sys

import interp


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# PyGObject and the Flatpak typelib are distribution packages living in the
# system interpreter; a pyenv shim or an activated virtualenv cannot see them.
# Hand the command over rather than die, and if it still fails, say so inside
# the protocol — an import that kills the process ends the stream before its
# first event, and the caller can only report that everything failed.
#
# The handover probes both halves, not just `import gi`: a pip-installed
# PyGObject satisfies the import without bringing a typelib with it, and
# probing the import alone kept the command in the very interpreter that
# cannot finish it.
FLATPAK_PROBE = ("import gi; gi.require_version('Flatpak', '1.0'); "
                 "from gi.repository import Flatpak")
interp.ensure("gi", probe=FLATPAK_PROBE)

try:
    import gi
    gi.require_version("Flatpak", "1.0")
    from gi.repository import Flatpak, Gio, GLib  # noqa: E402
except (ImportError, ValueError) as exc:
    # Which half is missing decides what the window may ask for. Naming the
    # PyGObject package for a missing typelib is what issue #15 was: the
    # banner asked for python3-gobject-base on a machine that had it, and
    # installing it again changed nothing, because the typelib comes with
    # flatpak itself. And a machine with no flatpak at all is not a machine
    # with a broken plugin — there is nothing there to update.
    if isinstance(exc, ImportError) and "gi.repository" not in str(exc):
        cause, what = "bindings", "the PyGObject bindings"
    elif shutil.which("flatpak") is None:
        cause, what = "absent", "Flatpak"
    else:
        cause, what = "typelib", "the Flatpak typelib"
    emit({"event": "error",
          "cause": cause,
          "message": "Flatpak is not installed" if cause == "absent" else
                     "%s could not be loaded by %s (%s)"
                     % (what, interp.describe(), exc)})
    emit({"event": "done", "ok": False, "failed": []})
    sys.exit(1)


# libostree 2026.3 caps how large a decompressed delta part may be — a guard
# against decompression bombs — and set the cap too low: an app whose delta
# crosses it cannot be pulled at all, with "Decompressed delta part exceeds
# configured limit of N bytes". It is a libostree regression, fixed in 2026.4,
# and by upstream's own account there is nothing Flatpak can do about it.
#
# The update itself is fine. Pulling the objects instead of the delta walks
# around the cap at the cost of more bytes — `flatpak update
# --no-static-deltas` by hand — so that is what a failing operation is given
# here, once, rather than reporting an update the machine is perfectly able to
# perform.
DELTA_LIMIT_MARKER = "delta part exceeds"


def appid_of(ref_str):
    # ref format: app/org.example.App/x86_64/stable
    parts = ref_str.split("/")
    return parts[1] if len(parts) >= 2 else ref_str


class Runner:
    def __init__(self, wanted_ids):
        self.wanted = set(wanted_ids)
        self.cancellable = Gio.Cancellable()
        self.failed = []
        self.ops_meta = []

    def wants(self, ref):
        if not self.wanted:
            return True
        name = ref.get_name()
        # Match the app itself and its extensions (org.x.App.Locale etc.)
        return any(name == w or name.startswith(w + ".") for w in self.wanted)

    def collect(self, installation, label):
        try:
            updates = installation.list_installed_refs_for_update(self.cancellable)
        except GLib.Error as err:
            emit({"event": "warning", "message": f"{label}: {err.message}"})
            return []
        return [ref for ref in updates if self.wants(ref)]

    def run_transaction(self, installation, label, refs, no_deltas=False):
        """Runs `refs`; returns the refs that asked to be tried again without
        static deltas."""
        if not refs:
            return []
        retry = []
        txn = Flatpak.Transaction.new_for_installation(installation, self.cancellable)
        if no_deltas:
            txn.set_disable_static_deltas(True)

        def on_ready(transaction):
            for op in transaction.get_operations():
                self.ops_meta.append({
                    "ref": op.get_ref(),
                    "appid": appid_of(op.get_ref()),
                    "action": "install" if op.get_operation_type() == Flatpak.TransactionOperationType.INSTALL else "update",
                    "downloadBytes": op.get_download_size(),
                    "installation": label,
                })
            emit({"event": "plan", "installation": label, "ops": self.ops_meta,
                  "totalDownloadBytes": sum(o["downloadBytes"] for o in self.ops_meta)})
            return True

        def on_new_operation(transaction, op, progress):
            ref = op.get_ref()
            emit({"event": "op-start", "ref": ref, "appid": appid_of(ref)})

            def on_changed(prog):
                emit({"event": "progress", "ref": ref, "appid": appid_of(ref),
                      "percent": prog.get_progress(),
                      "bytesTransferred": prog.get_bytes_transferred(),
                      "status": prog.get_status() or ""})

            progress.set_update_frequency(250)
            progress.connect("changed", on_changed)

        def on_operation_done(transaction, op, commit, result):
            ref = op.get_ref()
            emit({"event": "op-done", "ref": ref, "appid": appid_of(ref)})

        def on_operation_error(transaction, op, error, details):
            ref = op.get_ref()
            message = error.message if error else "unknown error"
            # Not a failure yet — it is about to be tried again without
            # deltas, and a row that goes red and then green again describes
            # the workaround rather than the update.
            if not no_deltas and DELTA_LIMIT_MARKER in message:
                retry.append(ref)
                emit({"event": "warning", "ref": ref, "appid": appid_of(ref),
                      "message": f"{message} — retrying without static deltas"})
                return True
            self.failed.append(appid_of(ref))
            emit({"event": "op-error", "ref": ref, "appid": appid_of(ref),
                  "message": message})
            return True  # continue with remaining operations

        txn.connect("ready", on_ready)
        txn.connect("new-operation", on_new_operation)
        txn.connect("operation-done", on_operation_done)
        txn.connect("operation-error", on_operation_error)

        for ref in refs:
            try:
                txn.add_update(ref.format_ref(), None, None)
            except GLib.Error as err:
                emit({"event": "warning", "message": f"{ref.format_ref()}: {err.message}"})

        try:
            txn.run(self.cancellable)
        except GLib.Error as err:
            if err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                emit({"event": "done", "ok": False, "cancelled": True, "failed": self.failed})
                sys.exit(130)
            emit({"event": "error", "message": err.message})
            self.failed.append(label)
        return retry

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: self.cancellable.cancel())
        signal.signal(signal.SIGINT, lambda *_: self.cancellable.cancel())

        system = Flatpak.Installation.new_system(self.cancellable)
        user = Flatpak.Installation.new_user(self.cancellable)
        plans = [(system, "system"), (user, "user")]
        collected = [(inst, label, self.collect(inst, label)) for inst, label in plans]

        if not any(refs for _, _, refs in collected):
            emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
            return

        for inst, label, refs in collected:
            if self.cancellable.is_cancelled():
                break
            retry = self.run_transaction(inst, label, refs)
            if retry and not self.cancellable.is_cancelled():
                by_ref = {r.format_ref(): r for r in refs}
                again = [by_ref[name] for name in retry if name in by_ref]
                self.run_transaction(inst, label, again, no_deltas=True)

        emit({"event": "done", "ok": not self.failed, "failed": self.failed})


def run_install(remote, appid):
    """Install one app from a remote, emitting the same NDJSON event stream
    as updates. Uses the system installation when it has the remote (polkit
    authenticates), the user installation otherwise."""
    runner = Runner([])
    signal.signal(signal.SIGTERM, lambda *_: runner.cancellable.cancel())
    signal.signal(signal.SIGINT, lambda *_: runner.cancellable.cancel())

    installation = None
    label = ""
    for candidate, name in ((Flatpak.Installation.new_system(runner.cancellable), "system"),
                            (Flatpak.Installation.new_user(runner.cancellable), "user")):
        try:
            remotes = [r.get_name() for r in candidate.list_remotes(runner.cancellable)]
        except GLib.Error:
            continue
        if remote in remotes:
            installation = candidate
            label = name
            break
    if installation is None:
        emit({"event": "error", "message": f"remote '{remote}' not found"})
        sys.exit(1)

    def add(txn):
        arch = Flatpak.get_default_arch()
        try:
            # Fast path: flathub apps nearly always live on the stable branch
            txn.add_install(remote, f"app/{appid}/{arch}/stable", None)
        except GLib.Error:
            # Resolve the branch from the remote's published refs
            refs = installation.list_remote_refs_sync(remote, runner.cancellable)
            match = next((r for r in refs
                          if r.get_kind() == Flatpak.RefKind.APP
                          and r.get_name() == appid and r.get_arch() == arch), None)
            if match is None:
                raise GLib.Error(f"'{appid}' not found in remote '{remote}'")
            txn.add_install(remote, match.format_ref(), None)

    install_transaction(runner, installation, label, appid, add)


def install_transaction(runner, installation, label, appid, add, reinstall=False):
    """Run one install — `add(txn)` puts its operations in — with the event
    stream and the delta-cap retry, then emit done and exit."""

    def attempt(no_deltas):
        """Runs the install once. True when it hit libostree's delta cap
        and deserves another go with the deltas switched off."""
        retry = []
        try:
            txn = Flatpak.Transaction.new_for_installation(installation, runner.cancellable)
        except GLib.Error as err:
            emit({"event": "error", "message": err.message})
            emit({"event": "done", "ok": False, "failed": [appid]})
            sys.exit(1)
        if no_deltas:
            txn.set_disable_static_deltas(True)
        if reinstall:
            txn.set_reinstall(True)

        def on_ready(transaction):
            ops = [{
                "ref": op.get_ref(),
                "appid": appid_of(op.get_ref()),
                "action": "install",
                "downloadBytes": op.get_download_size(),
                "installation": label,
            } for op in transaction.get_operations()]
            emit({"event": "plan", "installation": label, "ops": ops,
                  "totalDownloadBytes": sum(o["downloadBytes"] for o in ops)})
            return True

        def on_new_operation(transaction, op, progress):
            ref = op.get_ref()
            emit({"event": "op-start", "ref": ref, "appid": appid_of(ref)})

            def on_changed(prog):
                emit({"event": "progress", "ref": ref, "appid": appid_of(ref),
                      "percent": prog.get_progress(),
                      "bytesTransferred": prog.get_bytes_transferred(),
                      "status": prog.get_status() or ""})

            progress.set_update_frequency(250)
            progress.connect("changed", on_changed)

        def on_operation_done(transaction, op, commit, result):
            emit({"event": "op-done", "ref": op.get_ref(), "appid": appid_of(op.get_ref())})

        def on_operation_error(transaction, op, error, details):
            ref = op.get_ref()
            message = error.message if error else "unknown error"
            # The same libostree cap an update can hit, hit while installing.
            # Not a failure until it has been tried without deltas.
            if not no_deltas and DELTA_LIMIT_MARKER in message:
                retry.append(ref)
                emit({"event": "warning", "ref": ref, "appid": appid_of(ref),
                      "message": f"{message} — retrying without static deltas"})
                return False
            runner.failed.append(appid_of(ref))
            emit({"event": "op-error", "ref": ref, "appid": appid_of(ref),
                  "message": message})
            return False

        def on_add_new_remote(transaction, reason, from_id, suggested_name, url):
            # A bundle or a .flatpakref naming the repository its runtime
            # comes from — usually Flathub, on a machine that does not have
            # it yet. `flatpak install` asks; installing the file was the
            # question, so the answer is yes, said out loud.
            emit({"event": "warning", "message": f"adding remote '{suggested_name}' ({url}) for {from_id}"})
            return True

        txn.connect("ready", on_ready)
        txn.connect("new-operation", on_new_operation)
        txn.connect("operation-done", on_operation_done)
        txn.connect("operation-error", on_operation_error)
        txn.connect("add-new-remote", on_add_new_remote)

        try:
            add(txn)
        except GLib.Error as err:
            emit({"event": "error", "message": err.message})
            sys.exit(1)

        try:
            txn.run(runner.cancellable)
        except GLib.Error as err:
            if err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                emit({"event": "done", "ok": False, "cancelled": True, "failed": runner.failed})
                sys.exit(130)
            # Aborting is what returning False above does, so the delta cap
            # arrives here as well as in the handler; either is enough.
            if retry:
                return True
            if not no_deltas and DELTA_LIMIT_MARKER in (err.message or ""):
                emit({"event": "warning", "message": f"{err.message} — retrying without static deltas"})
                return True
            emit({"event": "error", "message": err.message})
            runner.failed.append(appid)
        return bool(retry)

    if attempt(False):
        attempt(True)

    emit({"event": "done", "ok": not runner.failed, "failed": runner.failed})
    sys.exit(0 if not runner.failed else 1)


# ── Installing from a file (#41) ─────────────────────────────────────────────
# A .flatpak bundle carries the app itself; a .flatpakref names an app and
# the repository to get it from. Both used to arrive at the AppImage
# installer, which copied them into ~/Applications as if they were one.
# appimage.py --inspect tells them apart by their bytes and hands them here.

BUNDLE_MAGIC = b"flatpak\0"


def file_kind(path):
    """"bundle", "ref", or "" — the same test as appimage.file_kind, kept
    here so this helper does not have to import that one."""
    try:
        with open(path, "rb") as f:
            head = f.read(4096)
    except OSError:
        return ""
    if head.startswith(BUNDLE_MAGIC):
        return "bundle"
    for line in head.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return "ref" if line == "[Flatpak Ref]" else ""
    return ""


def read_flatpakref(path):
    """The [Flatpak Ref] group as a dict. GLib's keyfile parser, the one
    libflatpak reads it with, so both see the same values."""
    keyfile = GLib.KeyFile()
    keyfile.load_from_file(path, GLib.KeyFileFlags.NONE)
    group = "Flatpak Ref"
    out = {}
    for key in keyfile.get_keys(group)[0]:
        out[key] = keyfile.get_string(group, key)
    return out


def _appstream_summary(data):
    """Name and newest version out of a bundle's gzipped AppStream XML."""
    import gzip
    import xml.etree.ElementTree as ET
    name = version = ""
    try:
        root = ET.fromstring(gzip.decompress(bytes(data)))
    except Exception:
        return name, version
    components = [root] if root.tag == "component" else root.findall("component")
    for component in components:
        for node in component.findall("name"):
            if not node.attrib:
                name = (node.text or "").strip()
                break
        release = component.find("releases/release")
        if release is not None:
            version = release.get("version", "")
        if name:
            break
    return name, version


def _installed(ref_str):
    """(installation, label, installed ref) holding this ref, or Nones."""
    kind, name, arch, branch = (ref_str.split("/") + ["", "", "", ""])[:4]
    ref_kind = Flatpak.RefKind.RUNTIME if kind == "runtime" else Flatpak.RefKind.APP
    for installation, label in _installations():
        try:
            return installation, label, installation.get_installed_ref(ref_kind, name, arch, branch, None)
        except GLib.Error:
            continue
    return None, None, None


def _installations():
    out = []
    for make, label in ((Flatpak.Installation.new_system, "system"), (Flatpak.Installation.new_user, "user")):
        try:
            out.append((make(None), label))
        except GLib.Error:
            continue
    return out


def _target(ref_str, runtime):
    """Where a file's app goes: where it already is; else where its runtime
    is; else the system installation, as `flatpak install` does, unless it
    has no remotes at all and the user installation does."""
    installation, label, _ = _installed(ref_str)
    if installation is not None:
        return installation, label
    candidates = _installations()
    if runtime:
        found = _installed("runtime/" + runtime)
        if found[0] is not None:
            return found[0], found[1]
    def has_remotes(inst):
        try:
            return bool(inst.list_remotes(None))
        except GLib.Error:
            return False
    for installation, label in candidates:
        if label == "system" and has_remotes(installation):
            return installation, label
    for installation, label in candidates:
        if has_remotes(installation):
            return installation, label
    return candidates[0] if candidates else (None, None)


def _runtime_of_metadata(text):
    for line in text.splitlines():
        if line.startswith("runtime="):
            return line[len("runtime="):].strip()
    return ""


def describe_file(path):
    """What `inspect-file` prints and `install-file` acts on."""
    kind = file_kind(path)
    if kind == "bundle":
        bundle = Flatpak.BundleRef.new(Gio.File.new_for_path(path))
        ref_str = bundle.format_ref()
        name, version = ("", "")
        appstream = bundle.get_appstream()
        if appstream is not None:
            name, version = _appstream_summary(appstream.get_data())
        metadata = bundle.get_metadata()
        runtime = _runtime_of_metadata(bytes(metadata.get_data()).decode("utf-8", "replace")) if metadata else ""
        info = {"kind": "bundle", "ref": ref_str, "appid": bundle.get_name(),
                "name": name, "version": version, "commit": bundle.get_commit() or "",
                "origin": bundle.get_origin() or "", "runtime": runtime,
                "icon": bundle.get_icon(64), "url": ""}
    elif kind == "ref":
        fields = read_flatpakref(path)
        appid = fields.get("Name", "")
        if not appid:
            raise GLib.Error("the .flatpakref names no app")
        is_runtime = fields.get("IsRuntime", "").lower() == "true"
        branch = fields.get("Branch") or "master"
        ref_str = "%s/%s/%s/%s" % ("runtime" if is_runtime else "app", appid,
                                   Flatpak.get_default_arch(), branch)
        info = {"kind": "ref", "ref": ref_str, "appid": appid,
                "name": fields.get("Title", ""), "version": "", "commit": "",
                "origin": fields.get("SuggestRemoteName", ""), "runtime": "",
                "icon": None, "iconUrl": fields.get("Icon", ""), "url": fields.get("Url", "")}
    else:
        raise GLib.Error("not a Flatpak bundle or .flatpakref")
    info["bytes"] = open(path, "rb").read() if kind == "ref" else None
    return info


def run_inspect_file(path):
    try:
        info = describe_file(path)
    except GLib.Error as err:
        print(json.dumps({"ok": False, "error": err.message}), flush=True)
        return
    _, label, installed = _installed(info["ref"])
    icon = ""
    if info.get("icon") is not None:
        cache = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dankSoftwareDepot")
        os.makedirs(cache, exist_ok=True)
        # One per app, overwritten by the next file of it, not one per look
        icon = os.path.join(cache, "flatpak-file-%s.png" % info["appid"].replace("/", "-"))
        with open(icon, "wb") as f:
            f.write(bytes(info["icon"].get_data()))
    print(json.dumps({
        "ok": True,
        "kind": info["kind"],
        "path": path,
        "ref": info["ref"],
        "appid": info["appid"],
        "name": info["name"] or (installed.get_appdata_name() if installed else "") or info["appid"],
        "version": info["version"],
        "icon": icon,
        "iconUrl": info.get("iconUrl", ""),
        "url": info["url"],
        "sizeBytes": os.path.getsize(path),
        "installed": None if installed is None else {
            "installation": label,
            "version": installed.get_appdata_version() or "",
            # Nothing to do: a bundle of the very build that is installed, or
            # a .flatpakref, which names the app and not a build — libflatpak
            # refuses one for an app already here, whose updates come in
            # through the updater like any other
            "current": info["kind"] == "ref" or installed.get_commit() == info["commit"],
        },
    }), flush=True)


def run_install_file(path):
    runner = Runner([])
    signal.signal(signal.SIGTERM, lambda *_: runner.cancellable.cancel())
    signal.signal(signal.SIGINT, lambda *_: runner.cancellable.cancel())
    try:
        info = describe_file(path)
    except GLib.Error as err:
        emit({"event": "error", "message": err.message})
        emit({"event": "done", "ok": False, "failed": []})
        sys.exit(1)
    installation, label = _target(info["ref"], info["runtime"])
    if installation is None:
        emit({"event": "error", "message": "no Flatpak installation to install into"})
        emit({"event": "done", "ok": False, "failed": []})
        sys.exit(1)
    # A newer build of an app that is already here is that app, replaced
    reinstall = _installed(info["ref"])[2] is not None

    def add(txn):
        if info["kind"] == "bundle":
            txn.add_install_bundle(Gio.File.new_for_path(path), None)
        else:
            txn.add_install_flatpakref(GLib.Bytes.new(info["bytes"]))

    install_transaction(runner, installation, label, info["appid"], add, reinstall=reinstall)


def _app_runtime(ref):
    """The runtime an installed app runs on, as "id/arch/branch"."""
    try:
        data = ref.load_metadata(None).get_data()
    except Exception:
        return ""
    for line in bytes(data).decode("utf-8", "replace").splitlines():
        if line.startswith("runtime="):
            return line[len("runtime="):].strip()
    return ""


def run_eol_check():
    """Installed refs their remote marks end-of-life (or eol-rebased), one
    entry per thing a person would recognise.

    Flathub marks a runtime branch end-of-life together with every extension
    of it, so a single old Freedesktop Platform arrived as five names — Mesa,
    Mesa (Extra), the Locale, the VAAPI driver and the Platform — with no
    version, which reads as if Mesa itself were dead. An extension of a
    runtime that is listed too is folded into it, a runtime installed both
    system-wide and per user is listed once, and each runtime says which apps
    still run on it: that is what keeps it installed, and what has to move
    before it can go.
    """
    found = {}
    users = {}
    for installation in (Flatpak.Installation.new_system(None), Flatpak.Installation.new_user(None)):
        try:
            refs = installation.list_installed_refs(None)
        except Exception:
            continue
        for ref in refs:
            is_app = ref.get_kind() == Flatpak.RefKind.APP
            name = ref.get_appdata_name() or ref.get_name()
            if is_app:
                runtime = _app_runtime(ref)
                if runtime:
                    users.setdefault(runtime, set()).add(name)
            try:
                eol = ref.get_eol()
                rebase = ref.get_eol_rebase()
            except Exception:
                continue
            if not (eol or rebase) or ref.format_ref() in found:
                continue
            found[ref.format_ref()] = {
                "ref": ref.format_ref(),
                "id": ref.get_name(),
                "branch": ref.get_branch(),
                "kind": "app" if is_app else "runtime",
                "appName": name,
                "eol": eol or "",
                "eolRebase": rebase or "",
                "extensions": [],
                "usedBy": [],
            }
    entries = sorted(found.values(), key=lambda e: (e["id"], e["branch"]))
    out = []
    for entry in entries:
        parent = next((p for p in entries
                       if p is not entry and p["kind"] == "runtime"
                       and entry["kind"] == "runtime"
                       and entry["id"].startswith(p["id"] + ".")
                       and entry["branch"].startswith(p["branch"])), None)
        if parent:
            parent["extensions"].append(entry["appName"])
            continue
        if entry["kind"] == "runtime":
            arch = entry["ref"].split("/")[2] if entry["ref"].count("/") >= 3 else ""
            entry["usedBy"] = sorted(users.get(f"{entry['id']}/{arch}/{entry['branch']}", ()))
        out.append(entry)
    print(json.dumps(out), flush=True)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "selftest":
        # Reaching here means gi imported and the Flatpak typelib resolved:
        # the two halves that are separate packages on Debian and Ubuntu,
        # where gir1.2-flatpak-1.0 does not come with flatpak itself.
        emit({"event": "done", "ok": True, "failed": []})
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "eol":
        run_eol_check()
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "inspect-file":
        run_inspect_file(sys.argv[2])
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "install-file":
        run_install_file(sys.argv[2])
        return
    if len(sys.argv) >= 4 and sys.argv[1] == "install":
        run_install(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) < 2 or sys.argv[1] != "update":
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    Runner(sys.argv[2:]).run()


if __name__ == "__main__":
    main()
