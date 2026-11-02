#!/usr/bin/env python3
"""Checks fedora_upgrade.py's reading of dnf5: its output lines, its state
file, and the depot's own cache of the next release's metadata.

The lines below are dnf5 5.4's own, captured from a real `system-upgrade
download --releasever=45` in a Fedora 44 container. The download itself and
the libdnf5 resolve need a Fedora system and root; they were checked by hand
there, and this keeps the parts that turn their output into the window's
events from drifting.
"""
import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import enrich  # noqa: E402
import fedora_upgrade as fu  # noqa: E402

failures = []


def check(label, got, want):
    if got == want:
        print(f"  ok   {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label}\n       got:  {got!r}\n       want: {want!r}")


print("Which release is out")
# Bodhi's list on 2 November 2026, the day before Fedora 45 shipped
bodhi = [
    {"name": "EPEL-10.4", "version": "10.4", "id_prefix": "FEDORA-EPEL", "released_on": "2026-08-24"},
    {"name": "F43", "version": "43", "id_prefix": "FEDORA", "released_on": None},
    {"name": "F44", "version": "44", "id_prefix": "FEDORA", "released_on": "2026-04-28"},
    {"name": "F45", "version": "45", "id_prefix": "FEDORA", "released_on": "2026-11-03"},
    {"name": "F45F", "version": "45", "id_prefix": "FEDORA-FLATPAK", "released_on": "2026-11-03"},
]
check("a current release that ships tomorrow is not out", enrich.newest_fedora(bodhi, "2026-11-02"), 44)
check("on the day it ships, it is", enrich.newest_fedora(bodhi, "2026-11-03"), 45)
check("no released_on means long out", enrich.newest_fedora(bodhi[:2], "2026-11-02"), 43)
check("nothing listed, nothing to go to", enrich.newest_fedora([], "2026-11-02"), 0)

print("dnf5's lines")
state = {"bytes": 0, "stored": False}
check("the repository header is a stage",
      fu.parse_line("Updating and loading repositories:\n", state), {"event": "status", "message": "repos"})
check("a repository's own bar is not a package",
      fu.parse_line(" Fedora 45 - x86_64                     100% |   6.4 MiB/s |  36.8 MiB |  00m06s", state), None)
check("loaded repositories mean resolving",
      fu.parse_line("Repositories loaded.", state), {"event": "status", "message": "resolving"})
check("the transaction table is left alone",
      fu.parse_line(" bash                                          x86_64 0:5.3.15-2.fc45              fedora                             8.5 MiB", state), None)
event = fu.parse_line("[  1/150] redhat-systemd-presets-0:102- 100% | 812.0 KiB/s |   8.5 KiB |  00m00s", state)
check("a downloaded package is progress", (event["event"], event["index"], event["total"]), ("progress", 1, 150))
check("its size is counted", event["totalTransferred"], int(8.5 * 1024))
event = fu.parse_line("[118/150] shadow-utils-2:4.20.0-2.fc45. 100% |  10.5 MiB/s |   1.4 MiB |  00m00s", state)
check("and added up", event["totalTransferred"], int(8.5 * 1024) + int(1.4 * 1024 ** 2))
check("the total line is not a package",
      fu.parse_line("[150/150] Total                         100% |  13.1 MiB/s |  58.6 MiB |  00m04s", state), None)
check("testing is a stage",
      fu.parse_line("Testing offline transaction", state), {"event": "status", "message": "testing"})
check("the key import is left alone",
      fu.parse_line(" UserID     : \"Fedora (45) <fedora-45-primary@fedoraproject.org>\"", state), None)
check("storing it is the success",
      fu.parse_line("Transaction stored to be performed offline. Run `dnf5 offline reboot` to reboot and run the transaction.", state),
      {"event": "status", "message": "stored"})
check("and is remembered", state["stored"], True)

print("dnf5's state file")
tmp = tempfile.mkdtemp(prefix="dsd-test-fedora-upgrade-")
state_file = os.path.join(tmp, "offline-transaction-state.toml")
with open(state_file, "w") as f:
    f.write('[offline-transaction-state]\nrpmdb_cookie = "95ae"\nmodule_platform_id = ""\n'
            'poweroff_after = false\nverb = "system-upgrade download"\nsystem_releasever = "44"\n'
            'target_releasever = "45"\ncachedir = "/var/cache/libdnf5"\nstatus = "download-complete"\n'
            'cmd_line = "dnf5 system-upgrade download --releasever=45 -y"\nstate_version = 2\n')
os_release = os.path.join(tmp, "os-release")
with open(os_release, "w") as f:
    f.write('NAME="Fedora Linux"\nVERSION_ID=44\nID=fedora\n')
fu.OFFLINE_STATE = state_file
fu.OS_RELEASE = os_release
fu.CACHE_ROOT = os.path.join(tmp, "cache")


def status():
    out = io.StringIO()
    with redirect_stdout(out):
        fu.run_status()
    return json.loads(out.getvalue())


got = status()
check("a downloaded upgrade is prepared", (got["prepared"], got["targetReleasever"], got["current"]), (True, "45", 44))
check("and is not someone else's", got["otherOffline"], False)

with open(state_file, "w") as f:
    f.write('[offline-transaction-state]\nverb = "install"\nstatus = "download-complete"\nstate_version = 2\n')
got = status()
check("an offline install is not an upgrade", (got["prepared"], got["otherOffline"]), (False, True))

with open(state_file, "w") as f:
    f.write('[offline-transaction-state]\nverb = "system-upgrade download"\nstatus = "download-incomplete"\n'
            'target_releasever = "45"\nstate_version = 2\n')
check("a download that stopped halfway is not ready", status()["prepared"], False)

os.unlink(state_file)
got = status()
check("no state file, nothing prepared", (got["prepared"], got["status"]), (False, ""))

print("The depot's cache of the next release")
for name in ("upgrade-f44", "upgrade-f45", "something-else"):
    os.makedirs(os.path.join(fu.CACHE_ROOT, name))
fu.sweep_plan_caches()
check("the running release's is gone, the next one's and others stay",
      sorted(os.listdir(fu.CACHE_ROOT)), ["something-else", "upgrade-f45"])

print("The download")
if os.geteuid() != 0:
    out = io.StringIO()
    with redirect_stdout(out):
        code = fu.run_download(45, False)
    events = [json.loads(line) for line in out.getvalue().splitlines()]
    check("refuses without root, and says so", (code, events[0]["event"], events[-1]["ok"]), (1, "error", False))

import shutil  # noqa: E402
shutil.rmtree(tmp, ignore_errors=True)
print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks passed")
