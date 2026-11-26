#!/usr/bin/env python3
"""Checks scripts/edition.py with the machine stood in for: no package
manager, no systemd, no network. The run is shaped after a real one (24
November 2026: 24 packages on Fedora 45)."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import edition  # noqa: E402

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


# ── versions ──
check(edition.jump("157.0.8103.78-1.fc45", "158.0.8127.36-1.fc45") == "major", "a first number that moves is major")
check(edition.jump("5.4.1-4.fc45", "5.4.2-2.fc45") == "patch", "5.4.1 → 5.4.2 is a patch")
check(edition.jump("10.5p1-1.fc45", "10.6p1-1.fc45") == "minor", "10.5 → 10.6 is minor")
check(edition.jump("3.26.6-1.fc45", "3.26.6-2.fc45") == "rebuild", "a new release of the same version is a rebuild")
check(edition.jump("0.0.git.3097.02ee0585-1.fc45", "0.0.git.3102.398026a8-1.fc45") == "git", "git builds are git")
check(edition.jump("2026.11.3", "2027.1.1") == "minor", "a calendar version is not a major release")
check(edition.commits_between("0.0.git.3097.02ee0585-1", "0.0.git.3102.398026a8-1") == 5, "commits from copr counts")
check(edition.commits_between("2.1.3+git205.73581769-1", "2.1.3+git207.bacee31d-1") == 2, "commits from +gitN counts")
check(edition.commits_between("1.0", "1.1") == 0, "no counts, no commits")

# ── stories ──
items = [
    {"key": "system/chromium", "name": "chromium", "base": "chromium", "repo": "system", "from": "157.0-1", "to": "158.0-1", "status": "done", "bytes": 147743379,
     "t": {"d0": 6.7, "d1": 30.9, "i0": 46.9, "i1": 48.3}},
    {"key": "system/chromium-common", "name": "chromium-common", "base": "chromium-common", "repo": "system", "from": "157.0-1", "to": "158.0-1", "status": "done", "bytes": 14944870,
     "t": {"d0": 6.7, "d1": 19.1, "i0": 46.6, "i1": 46.9}},
    {"key": "system/openssh-server", "name": "openssh-server", "base": "openssh-server", "repo": "system", "from": "10.5p1-1", "to": "10.6p1-1", "status": "done", "bytes": 671641,
     "t": {"d0": 6.7, "d1": 12.3, "i0": 51.4, "i1": 51.4}},
    {"key": "system/openssh", "name": "openssh", "base": "openssh", "repo": "system", "from": "10.5p1-1", "to": "10.6p1-1", "status": "done", "bytes": 387993,
     "t": {"d0": 6.7, "d1": 11.6, "i0": 46.5, "i1": 46.5}},
    {"key": "system/brave-origin", "name": "brave-origin", "base": "brave-origin", "repo": "system", "from": "1.100.58-1", "to": "1.100.59-1", "status": "done", "bytes": 145228533,
     "t": {"d0": 6.7, "d1": 19.6, "i0": 58.0, "i1": 64.9}},
    {"key": "system/niri", "name": "niri", "base": "niri", "repo": "system", "from": "0.0.git.3097.02ee0585-1", "to": "0.0.git.3102.398026a8-1", "status": "done", "bytes": 25100000,
     "t": {"d0": 6.7, "d1": 22.1, "i0": 51.6, "i1": 52.1}},
    {"key": "system/hplip", "name": "hplip", "base": "hplip", "repo": "system", "from": "3.26.6-1", "to": "3.26.6-2", "status": "error", "error": "conflict", "bytes": 21900000, "t": {}},
    {"key": "flatpak/org.gimp.GIMP", "name": "org.gimp.GIMP", "label": "GIMP", "repo": "flatpak", "from": "3.0.6", "to": "3.2.0", "status": "done", "bytes": 112000000,
     "t": {"w0": 66.0, "w1": 79.0}},
    {"key": "system/chromium-debuginfo", "name": "chromium-debuginfo", "base": "chromium-debuginfo", "repo": "system", "from": "157.0-1", "to": "158.0-1", "status": "done"},
]
sources = {"chromium-common": "chromium", "openssh-server": "openssh", "chromium": "chromium", "openssh": "openssh"}
stories = edition.group_items([i for i in items if not edition.GROUP_SKIP.search(i["base"] if "base" in i else i["name"])], sources)
ids = [s["id"] for s in stories]
check(ids == ["system/chromium", "system/openssh", "system/brave-origin", "system/niri", "system/hplip", "flatpak/org.gimp.GIMP"],
      "parts join their source package, in run order: %r" % ids)
check(next(s for s in stories if s["id"] == "system/openssh")["lead"]["name"] == "openssh", "the story is led by the package named after the source")

files = {
    "chromium": ["/usr/bin/chromium-browser", "/usr/share/applications/chromium-browser.desktop"],
    "openssh-server": ["/usr/sbin/sshd", "/usr/lib/systemd/system/sshd.service", "/usr/lib/systemd/system/sshd@.service"],
    "brave-origin": ["/opt/brave.com/brave-origin/brave", "/usr/share/applications/brave-origin.desktop"],
    "niri": ["/usr/bin/niri"],
}
check(edition.unit_files(files["openssh-server"]) == ["sshd.service"], "template units are not services that run")

with tempfile.TemporaryDirectory() as tmp:
    os.environ["DSD_DATA_DIR"] = tmp
    now = 1795553400
    usage = {"brave-origin": (9, now - 3600), "chromium-browser": (0, 0)}
    launch = {"/usr/share/applications/chromium-browser.desktop", "/usr/share/applications/brave-origin.desktop"}
    real_launchable = edition.launchable
    edition.launchable = lambda path: path in launch
    run = {"ts": 1795553234, "backend": "dnf", "duration": 80.6, "rate": [0, 28000000], "phases": [["starting", 0]],
           "items": items,
           "advisories": {"chromium": {"type": "security", "severity": "critical", "ids": ["CVE-2026-%05d" % i for i in range(204)]},
                          "openssh": {"type": "security", "severity": "moderate", "ids": []}}}
    ed = edition.build(run, be="dnf", usage=usage, now=now, history=[], files=files, sources=sources,
                       active=lambda units: [u for u in units if u == "sshd.service"], notes=False)
    by = {s["id"]: s for s in ed["stories"]}
    check(ed["totals"]["packages"] == 8, "debuginfo is not counted: %r" % ed["totals"])
    check(ed["totals"]["cves"] == 204, "CVEs are counted once: %r" % ed["totals"])
    check(ed["totals"]["failed"] == 1, "one failure")
    check(by["system/chromium"]["t"]["dl"] == [6.7, 30.9] and by["system/chromium"]["t"]["inst"] == [46.6, 48.3],
          "a story's span covers its parts: %r" % by["system/chromium"]["t"])
    check(by["flatpak/org.gimp.GIMP"]["t"]["work"] == [66.0, 79.0], "passes without phases have a work span")
    check(by["system/openssh"]["facts"]["services"] == ["sshd.service"], "a running service is found")
    check(by["system/brave-origin"]["facts"]["uses"] == 9, "launcher use is found through the desktop entry")
    check(by["system/niri"]["facts"]["role"] == "desktop", "a compositor is the desktop")
    check(ed["stories"][0]["id"] == "system/hplip", "a failure is news first: %r" % [s["id"] for s in ed["stories"]])
    check(ed["stories"][1]["id"] == "system/chromium", "then the critical advisory")
    check(by["system/openssh"]["rank"] > by["system/brave-origin"]["rank"], "a running service with an advisory beats an app update")
    check(by["system/brave-origin"]["score"][1] == 18, "use: 9 starts, recent: %r" % by["system/brave-origin"]["score"])
    check(by["flatpak/org.gimp.GIMP"]["name"] == "GIMP", "a Flatpak keeps its label")

    # routine: niri as a git build in two of the last three editions
    history = [{"stories": [{"id": "system/niri", "facts": {"jump": "git"}}]}] * 2
    ed2 = edition.build(run, be="dnf", usage=usage, now=now, history=history, files=files, sources=sources,
                        active=lambda units: [], notes=False)
    niri = next(s for s in ed2["stories"] if s["id"] == "system/niri")
    check(niri["routine"] and niri["rank"] < by["system/niri"]["rank"], "a routine git build drops: %r" % niri["score"])

    # after
    checks = edition.after(ed, be="dnf", files=files, reboot=False,
                           stale={"system/brave-origin": {"pids": [586395], "since": 1795469994}, "system/niri": {"pids": [1916], "since": 1795377264}},
                           started=lambda unit: 1795553308, usage=usage, now=now)["after"]["checks"]
    kinds = [(c["kind"], c.get("story")) for c in checks]
    check(("reboot", None) in kinds and not checks[0]["needed"], "no reboot needed is said")
    svc = next(c for c in checks if c["kind"] == "service")
    check(svc["restarted"] and svc["unit"] == "sshd.service", "a service started after the run began is on the new version")
    check(("stale", "system/brave-origin") in kinds and ("stale", "system/niri") in kinds, "replaced programs still running are said")
    check(("unused", "system/chromium") in kinds, "an app never started is said: %r" % kinds)
    check(("unused", "system/brave-origin") not in kinds, "a used app is not")
    check(("stale", "system/hplip") not in kinds and ("unused", "system/hplip") not in kinds, "a failed story has no after")
    edition.launchable = real_launchable

    # save, load, archive
    edition.save(ed)
    check(edition.load("latest")["ts"] == ed["ts"], "the latest edition loads")
    log = [
        {"type": "update", "ts": 1795400000, "items": [{"name": "kernel-core", "base": "kernel-core", "repo": "system", "from": "7.3.3-200", "to": "7.3.4-200", "status": "done"},
                                                      {"name": "kernel", "base": "kernel", "repo": "system", "from": "7.3.3-200", "to": "7.3.4-200", "status": "done"}]},
        {"type": "update-failed", "ts": 1795401000, "items": [{"name": "libheif", "base": "libheif", "repo": "system", "from": "1", "to": "2", "status": "error"}]},
        {"type": "install", "ts": 1795402000, "items": []},
        {"type": "update", "ts": 1795553300, "items": [{"name": "chromium", "base": "chromium", "repo": "system", "from": "157", "to": "158", "status": "done"}]},
    ]
    path = os.path.join(tmp, "log.json")
    with open(path, "w") as fh:
        json.dump(log, fh)
    os.environ["DSD_ACTION_LOG"] = path
    arch = edition.archive()
    check(len(arch) == 2, "a retry joins the run before it, an install is no edition: %r" % [a["ts"] for a in arch])
    check(arch[0]["kernel"] and arch[0]["lead"]["role"] == "kernel", "a kernel run says so")
    check(arch[0].get("late") and arch[0]["late"][0]["failed"] == 1, "the retry is a late note with its failure")
    check(arch[1]["edition"] and arch[1]["cves"] == 204, "the logged run with an edition is the edition")

# ── notes ──
brave = ("<p>Release v1.100.59 (Chromium 158.0.8127.92)</p><p><b>Android</b></p><p>Pick the <code>APK</code>.</p>"
         "<p><b>Linux</b></p><p>DEB and RPM packages attached below</p><p><b>Desktop Release Notes</b></p>"
         "<ul><li>Fixed incorrect formatting. (#61987)</li><li>Upgraded Chromium to 158.0.8127.92.</li></ul>"
         "<p><b>Desktop Origin Release Notes</b></p><ul><li>Upgraded Chromium to 158.0.8127.92.</li></ul>"
         "<p><b>Android Release Notes</b></p><ul><li>Android only</li></ul>")
check(edition._html_lines(brave) == ["Fixed incorrect formatting. (#61987)", "Upgraded Chromium to 158.0.8127.92."],
      "other platforms and prose are left out, repeats once: %r" % edition._html_lines(brave))
check(edition._html_lines("<p>One</p><p>Two &amp; three</p>") == ["One", "Two & three"], "paragraphs when there is no list")
check(edition.thin(["Rebasing OpenSSH to 10.6p1"]) and edition.thin(["Regenerate"]), "version-only notes are thin")
check(not edition.thin(["scanning fails on Photosmart 5520 (USB)", "add /var/lib/hp into systemd-tmpfiles"]), "real notes are not")
st = {"facts": {"advisory": {"type": "security", "ids": ["CVE-2026-110339"]}},
      "notes": ["Upgrade to 5.4.2 for CVE-2026-110339 and CVE-2026-115846"]}
check(edition.story_cves(st) == ["CVE-2026-110339", "CVE-2026-115846"], "CVEs from the advisory and the notes, once each")

changelog = """* Mon Nov 16 2026 Packager <p@x> - 5.4.2-1
- Upgrade to 5.4.2 for CVE-2026-110339 and CVE-2026-115846

* Wed Oct 28 2026 Packager <p@x> - 5.4.1-3
- Fix the thing

* Fri Oct 23 2026 Packager <p@x> - 5.4.1-2
- Older"""
real_run = edition._run
edition._run = lambda cmd, timeout=30: (0, changelog)
got = edition.changelog_lines("libreswan", "5.4.1-4.fc45", "dnf")
check(got == ["Upgrade to 5.4.2 for CVE-2026-110339 and CVE-2026-115846"],
      "entries stop at the first one not newer than the installed release, which need not exist: %r" % got)
edition._run = real_run

# ── stale processes in a stand-in /proc ──
with tempfile.TemporaryDirectory() as proc:
    with open(os.path.join(proc, "stat"), "w") as fh:
        fh.write("cpu 1 2 3\nbtime 1795300000\n")
    for pid, exe in (("100", "/opt/brave.com/brave-origin/brave (deleted)"), ("101", "/usr/bin/bash"), ("102", "/usr/bin/other (deleted)")):
        os.mkdir(os.path.join(proc, pid))
        os.symlink(exe, os.path.join(proc, pid, "exe"))
        with open(os.path.join(proc, pid, "stat"), "w") as fh:
            fh.write(pid + " (x y) S " + " ".join(["0"] * 18) + " 1000 0\n")
    got = edition.stale_processes({"system/brave-origin": ["/opt/brave.com/brave-origin/brave"]}, proc=proc)
    check(list(got) == ["system/brave-origin"] and got["system/brave-origin"]["pids"] == [100],
          "only a process whose replaced program the run owns: %r" % got)
    check(got["system/brave-origin"]["since"] > 1795300000, "with when it started")

# ── a run the shell reload cut off ──
with tempfile.TemporaryDirectory() as tmp:
    os.environ["DSD_DATA_DIR"] = tmp
    log = os.path.join(tmp, "log.json")
    os.environ["DSD_ACTION_LOG"] = log
    real_build = edition.build
    edition.build = lambda run, **kw: real_build(run, be="dnf", usage={}, now=1795600000, history=[], files={},
                                                 sources={}, active=lambda u: [], notes=False)
    edition.stash({"ts": 1795597000, "duration": 870, "rate": [[0, 5]], "items": [
        {"key": "system/niri.x86_64", "name": "niri", "base": "niri", "repo": "system", "from": "26.1-1", "to": "26.2-1",
         "status": "done", "t": {"d0": 1, "d1": 4}},
        {"key": "system/libetonyek.x86_64", "name": "libetonyek", "base": "libetonyek", "repo": "system",
         "from": "0.1.13-4", "to": "0.1.14-1", "status": "", "t": {"d0": 2}}]})
    entry = {"type": "update", "ts": 1795597870, "items": [
        {"name": "libetonyek", "id": "libetonyek.x86_64", "repo": "system", "from": "0.1.13-4", "to": "0.1.14-1", "status": "done"},
        {"name": "niri", "id": "niri.x86_64", "repo": "system", "from": "26.1-1", "to": "26.2-1", "status": "done"},
        {"name": "dms", "id": "dms", "repo": "system", "from": "0.0.git.5841", "to": "0.0.git.5844", "status": "done"}]}
    ed = edition.resume(entry)
    check(ed["rate"] == [[0, 5]] and ed["duration"] == 870, "the stashed measurements make the edition")
    check(ed["totals"]["packages"] == 3 and ed["totals"]["failed"] == 0,
          "with the logged outcome, the shell's own packages included: %r" % ed["totals"])
    check(not os.path.exists(edition.pending_path()), "and the stash is used once")
    check(edition.same_run(ed, entry["ts"]), "the edition and the log entry are of the same run")
    with open(log, "w") as fh:
        json.dump([entry], fh)
    check(edition.latest_unbuilt() is None, "a run with an edition needs none built")
    check(len(edition.archive()) == 1, "and appears in the archive once")
    later = dict(entry, ts=1795640000)
    with open(log, "w") as fh:
        json.dump([entry, later], fh)
    check(edition.latest_unbuilt() == later, "the newest run without an edition is found")
    ed = real_build(edition.log_run(later), be="dnf", usage={}, now=1795640000, history=[], files={}, sources={},
                    active=lambda u: [], notes=False)
    check(ed["ts"] == 1795640000 and ed["totals"]["packages"] == 3 and ed["after"] is None,
          "and built from its log entry: %r" % ed["totals"])
    check(sorted(s["packages"][0] for s in ed["stories"]) == ["dms", "libetonyek", "niri"],
          "under the package names, not the architecture-suffixed ids")
    edition.build = real_build
    del os.environ["DSD_ACTION_LOG"]

check(edition.commits_between("0.4.74^967.git1f768a3-1.fc45", "0.4.74^968.git710bf79-1.fc45") == 1,
      "a snapshot's count is before .git, not the first digit of its hash")
check(edition.commits_between("0.0.git.3097.02ee0585-1", "0.0.git.3102.398026a8-1") == 5, "the git.N style still counts")
check(edition.commits_between("2.1.3+git205.73581769-1", "2.1.3+git207.bacee31d-1") == 2, "and the gitN style")

# ── the forge's answers are kept ──
with tempfile.TemporaryDirectory() as tmp:
    os.environ["DSD_NOTES_CACHE"] = os.path.join(tmp, "notes.json")
    asked = []
    def forge(source, packages, old, new):
        asked.append(source)
        return {"lines": ["a commit"], "kind": "commits", "url": "u"}
    edition.cached_forge_notes("dms", ["dms"], "1", "2", now=1000, fetch=forge)
    got = edition.cached_forge_notes("dms", ["dms"], "1", "2", now=1000 + 86400 * 30, fetch=forge)
    check(asked == ["dms"] and got["lines"] == ["a commit"], "commits between two builds are asked once: %r" % asked)
    def limited(source, packages, old, new):
        raise edition.RateLimited(5000)
    check(edition.cached_forge_notes("niri", ["niri"], "1", "2", now=1000, fetch=limited) is None, "a rate limit gives no notes")
    edition.cached_forge_notes("brave", ["brave"], "1", "2", now=2000, fetch=forge)
    check("brave" not in asked, "and nothing is asked until the forge says the hour starts again")
    edition.cached_forge_notes("brave", ["brave"], "1", "2", now=6000, fetch=forge)
    check("brave" in asked, "after which it is")
    old = edition._notes_cache()
    old["dms|1|2"].pop("v")
    edition._notes_cache_save(old)
    edition.cached_forge_notes("dms", ["dms"], "1", "2", now=1000 + 86400 * 31, fetch=forge)
    check(asked.count("dms") == 2, "an entry from before commits had links is asked once more")
    del os.environ["DSD_NOTES_CACHE"]

ed = {"stories": [{"id": "system/dms", "source": "dms", "packages": ["dms"], "from": "1", "to": "2", "notes": [],
                   "notesFrom": "", "status": "done", "facts": {"kind": "system"}}], "totals": {}}
edition.fetch_notes(ed, fetch=lambda *a: {"lines": ["fix a (#12)", "tidy"], "links": ["", "https://github.com/o/r/commit/abc"],
                                          "kind": "commits", "url": "u"})
check(ed["stories"][0]["noteLinks"] == ["", "https://github.com/o/r/commit/abc"], "each commit line keeps where it leads: %r" % ed["stories"][0].get("noteLinks"))

for line in failures:
    print("FAIL: " + line)
print("edition: all checks passed" if not failures else "%d failed" % len(failures))
sys.exit(1 if failures else 0)
