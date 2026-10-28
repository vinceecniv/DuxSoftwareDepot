#!/usr/bin/env python3
"""Installing a .flatpak bundle or a .flatpakref, against the real libflatpak.

A stand-in would only repeat what the helper assumes about libflatpak, and
what #41 needs answered is what libflatpak does with these files: whether a
bundle's runtime is found in a remote, whether a newer build replaces the one
that is installed, whether a .flatpakref brings its repository along.

Everything happens in throwaway installations: FLATPAK_USER_DIR and
FLATPAK_SYSTEM_DIR point into a temporary directory, the "remote" is a local
repository built here with `flatpak build-export`, and the app is a shell
script on a runtime with nothing in it. Nothing is downloaded and the
machine's own Flatpak installations are never touched.

Needs flatpak and the Flatpak typelib; without them it says so and passes.
"""
import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HELPER = Path(__file__).resolve().parent / "flatpak_helper.py"

failures = []


def check(label, got, want):
    if got == want:
        print(f"  ok   {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label}\n       got:  {got!r}\n       want: {want!r}")


def have_libflatpak():
    if shutil.which("flatpak") is None:
        return False
    probe = "import gi; gi.require_version('Flatpak', '1.0'); from gi.repository import Flatpak"
    return subprocess.run([sys.executable, "-c", probe], capture_output=True).returncode == 0


if not have_libflatpak():
    print("flatpak or its typelib is not installed here — skipped")
    sys.exit(0)

tmp = Path(tempfile.mkdtemp(prefix="dsd-test-flatpak-files-"))
atexit.register(shutil.rmtree, tmp, ignore_errors=True)
env = dict(os.environ,
           FLATPAK_USER_DIR=str(tmp / "user"),
           FLATPAK_SYSTEM_DIR=str(tmp / "system"),
           XDG_CACHE_HOME=str(tmp / "cache"))
(tmp / "system").mkdir()


def sh(*args):
    proc = subprocess.run(args, env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit("%s failed:\n%s" % (" ".join(args[:2]), proc.stderr))


def helper(*args):
    proc = subprocess.run([sys.executable, str(HELPER), *args], env=env,
                          capture_output=True, text=True)
    lines = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]
    return proc.returncode, lines


def installed():
    out = subprocess.run(["flatpak", "--user", "list", "--columns=ref"], env=env,
                         capture_output=True, text=True).stdout
    return sorted(out.split())


def build(app_line):
    """Export the app (again) and bundle it; a changed line is a new build."""
    (app / "files/bin/hello").write_text("#!/bin/sh\n" + app_line + "\n")
    (app / "files/bin/hello").chmod(0o755)
    sh("flatpak", "build-export", str(repo), str(app), "stable")
    out = tmp / ("TestApp-%d.flatpak" % len(list(tmp.glob("TestApp-*.flatpak"))))
    sh("flatpak", "build-bundle", str(repo), str(out), "org.dsd.TestApp", "stable")
    return out


repo = tmp / "repo"
runtime = tmp / "runtime"
(runtime / "usr").mkdir(parents=True)
(runtime / "metadata").write_text(
    "[Runtime]\nname=org.dsd.TestPlatform\nruntime=org.dsd.TestPlatform/x86_64/1\n"
    "sdk=org.dsd.TestPlatform/x86_64/1\n")
sh("flatpak", "build-export", "--runtime", "--files=usr", str(repo), str(runtime), "1")
app = tmp / "app"
(app / "files/bin").mkdir(parents=True)
(app / "export/share/applications").mkdir(parents=True)
(app / "export/share/applications/org.dsd.TestApp.desktop").write_text(
    "[Desktop Entry]\nType=Application\nName=DSD Test App\nExec=hello\n")
(app / "metadata").write_text(
    "[Application]\nname=org.dsd.TestApp\nruntime=org.dsd.TestPlatform/x86_64/1\ncommand=hello\n")
first = build("echo one")
# Only the runtime is in the remote; the app arrives as a file
sh("flatpak", "--user", "remote-add", "--no-gpg-verify", "localtest", "file://" + str(repo))

print("A bundle")
code, out = helper("inspect-file", str(first))
info = out[0] if out else {}
check("is read as a bundle", (info.get("ok"), info.get("kind")), (True, "bundle"))
check("names its app", info.get("appid"), "org.dsd.TestApp")
check("is not installed yet", info.get("installed"), None)

code, out = helper("install-file", str(first))
check("installs", (code, out[-1].get("ok") if out else None), (0, True))
plan = next((e for e in out if e.get("event") == "plan"), {})
check("brings its runtime from the remote",
      [op["ref"] for op in plan.get("ops", [])],
      ["runtime/org.dsd.TestPlatform/x86_64/1", "app/org.dsd.TestApp/x86_64/stable"])
check("both are there", installed(),
      ["org.dsd.TestApp/x86_64/stable", "org.dsd.TestPlatform/x86_64/1"])

code, out = helper("inspect-file", str(first))
check("the same file is the installed build", (out[0].get("installed") or {}).get("current"), True)

second = build("echo two")
code, out = helper("inspect-file", str(second))
check("a newer build is not", (out[0].get("installed") or {}).get("current"), False)
code, out = helper("install-file", str(second))
check("and replaces it", (code, out[-1].get("ok") if out else None), (0, True))
code, out = helper("inspect-file", str(second))
check("after which it is", (out[0].get("installed") or {}).get("current"), True)

print("A .flatpakref")
sh("flatpak", "--user", "uninstall", "-y", "--noninteractive", "org.dsd.TestApp")
ref = tmp / "test.flatpakref"
ref.write_text("[Flatpak Ref]\nTitle=DSD Test\nName=org.dsd.TestApp\nBranch=stable\n"
               "Url=file://%s\nSuggestRemoteName=dsdtest\n" % repo)
code, out = helper("inspect-file", str(ref))
info = out[0] if out else {}
check("is read as a reference", (info.get("ok"), info.get("kind")), (True, "ref"))
check("takes its title as the name", info.get("name"), "DSD Test")
code, out = helper("install-file", str(ref))
check("installs from its repository", (code, out[-1].get("ok") if out else None), (0, True))
check("the app is back", "org.dsd.TestApp/x86_64/stable" in installed(), True)
code, out = helper("inspect-file", str(ref))
check("an installed app is nothing to do for a reference",
      (out[0].get("installed") or {}).get("current"), True)

print("Anything else")
junk = tmp / "Some.App.flatpak"
junk.write_bytes(os.urandom(512))
code, out = helper("inspect-file", str(junk))
check("is refused by inspect", out[0].get("ok") if out else None, False)
code, out = helper("install-file", str(junk))
check("and by install, with an error", (code, out[0].get("event") if out else None), (1, "error"))

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks passed")
