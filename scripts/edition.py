#!/usr/bin/env python3
"""Editions: what an update run did, and what it means for this machine.

The run dashboard shows a run as it happens; an edition is what is kept of
it afterwards. It is written at the end of the run and filled in after, in
steps that each work on their own:

    edition.py build < run.json     the run as the engine saw it (timeline,
                                    throughput, phases, items, advisories):
                                    groups the items into stories, scores them,
                                    takes the notes the machine already has,
                                    saves editions/<ts>.json and prints it
    edition.py after <ts>           what still needs doing: a reboot, a service
                                    still on the old version, an app whose
                                    program was replaced under it, an app
                                    nobody opens
    edition.py notes <ts>           notes from the project itself (GitHub
                                    releases, or the commits between two git
                                    builds) for the stories that have none
    edition.py preview [notes] < run.json
                                    the same for what is ready to install or
                                    a run that starts, for the dashboard to
                                    rank and annotate; with notes, the
                                    projects' own too; nothing is saved
    edition.py stash < run.json     keep a run the shell reload will cut off
    edition.py resume < entry.json  its edition, with the logged outcome
    edition.py show <ts|latest>     (latest builds the newest logged run
                                    from the log when it has no edition)
    edition.py list                 the archive: every edition, and the runs
                                    in the action log from before editions

Everything here is code over data the machine has or a forge publishes: no
language model, no text that was not written by a person somewhere. Words
for people are the QML's job — an edition holds facts (counts, severities,
versions, names) and the notes as their authors wrote them, and the window
turns the facts into sentences in the user's language.

The texts are kept as they were when the run happened: release notes move
and disappear, and an archive that fetched them again later would show
something other than what was installed.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

FORMAT = 1
# The stories a run's notes are fetched for: the ones on top, which are the
# ones read. GitHub answers 60 unauthenticated requests an hour.
ONLINE_STORIES = 8
NOTES_MAX = 12
# A git build that came along in two of the three editions before is
# routine: it keeps a place in the list, not on top of it
ROUTINE_LOOKBACK = 3
UNUSED_DAYS = 30


def _test_hook(name):
    """A path the tests stand in for; refused when running as root."""
    return (os.environ.get(name) or None) if os.geteuid() != 0 else None


def data_dir():
    return _test_hook("DSD_DATA_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "dankSoftwareDepot")


def editions_dir():
    return os.path.join(data_dir(), "editions")


def appusage_path():
    return _test_hook("DSD_APPUSAGE") or os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "dms", "appusage.json")


def _run(cmd, timeout=30):
    try:
        res = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             timeout=timeout, env={**os.environ, "LC_ALL": "C"})
        return res.returncode, res.stdout
    except (OSError, subprocess.SubprocessError):
        return -1, ""


def backend():
    import pkg_backend
    return pkg_backend.detect()


# ── Versions ─────────────────────────────────────────────────────────────────

def evr_version(evr):
    v = re.sub(r"^\d+:", "", (evr or "").strip())
    return v.rsplit("-", 1)[0] if "-" in v else v


GIT_RE = re.compile(r"(?:^|[.^~+_-])(?:git|r\d+\.)", re.I)
# The commit count: after "git" ("git.3097.", "git205."), but not the first
# digit of a hash ("git1f768a3"); or before it, the snapshot style
# ("0.4.74^967.git1f768a3")
COUNT_RE = re.compile(r"(?:git|^r|\.r)\.?(\d+)(?![0-9a-f])|[.^~+](\d+)\.git[0-9a-f]{6,}", re.I)


def is_git(version):
    return bool(GIT_RE.search(version or ""))


def commits_between(old, new):
    """How many commits two git builds are apart, from the count in their
    versions ("0.0.git.3097.02ee0585", "2.1.3+git205.73581769",
    "1.2.r1234.abc1234"); 0 when either has none."""
    a, b = COUNT_RE.search(evr_version(old) or ""), COUNT_RE.search(evr_version(new) or "")
    if not a or not b:
        return 0
    return max(0, int(b.group(1) or b.group(2)) - int(a.group(1) or a.group(2)))


def _numbers(version):
    return [int(x) for x in re.findall(r"\d+", evr_version(version))]


def jump(old, new):
    """"git", "major", "minor", "patch" or "rebuild" (same version, new
    release), "" when there is nothing to compare."""
    if not new:
        return ""
    if is_git(new) or is_git(old):
        return "git"
    a, b = _numbers(old), _numbers(new)
    if not a or not b:
        return ""
    if evr_version(old) == evr_version(new):
        return "rebuild"
    # A version that is a date (2026.11.4, 20260812) moves its first number
    # once a year; that is a calendar, not a major release
    if a[0] != b[0] and b[0] < 1900:
        return "major"
    if a[:2] != b[:2]:
        return "minor"
    return "patch"


# ── Stories: the items of a run, one per source ──────────────────────────────

KERNEL_RE = re.compile(r"^(kernel|linux)(-|$)")
COMPOSITORS = {"niri", "sway", "hyprland", "river", "labwc", "wayfire", "mutter", "kwin", "kwin-wayland",
               "gnome-shell", "plasma-workspace", "cosmic-comp", "dms", "dms-shell", "dux-shell", "quickshell",
               "dms-git", "dux-shell-git", "quickshell-git"}
GROUP_SKIP = re.compile(r"(-debuginfo|-debugsource)$")


def source_names(names, be=None):
    """{binary package: source package} as the package manager records it:
    the source rpm, pacman's base, the Debian source. A package it does not
    know keeps its own name."""
    be = be or backend()
    out = {}
    if not names:
        return out
    if be == "dnf":
        for start in range(0, len(names), 200):
            chunk = names[start:start + 200]
            code, text = _run(["rpm", "-q", "--qf", "%{NAME}\t%{SOURCERPM}\n"] + chunk)
            for line in text.splitlines():
                name, _, srpm = line.partition("\t")
                m = re.match(r"^(.*)-[^-]+-[^-]+\.src\.rpm$", srpm.strip())
                if name.strip() and m:
                    out[name.strip()] = m.group(1)
    elif be == "pacman":
        code, text = _run(["pacman", "-Qi"] + names)
        name = ""
        for line in text.splitlines():
            key, _, value = line.partition(":")
            key, value = key.strip(), value.strip()
            if key == "Name":
                name = value
            elif key == "Base" and name and value and value != "None":
                out[name] = value
    elif be == "apt":
        code, text = _run(["dpkg-query", "-W", "-f", "${Package}\t${source:Package}\n"] + names)
        for line in text.splitlines():
            name, _, src = line.partition("\t")
            if name.strip() and src.strip():
                out[name.strip()] = src.strip()
    return out


def group_items(items, sources):
    """Stories from run items: system packages grouped by their source
    package, everything else one story per item. The story is named after
    the package that carries the source's name, or the shortest one."""
    stories, order = {}, []
    for it in items:
        if it.get("repo") in ("system", "", None):
            base = it.get("base") or it.get("name") or ""
            sid = "system/" + sources.get(base, base)
        else:
            sid = it.get("key") or (it.get("repo", "") + "/" + it.get("name", ""))
        if sid not in stories:
            stories[sid] = []
            order.append(sid)
        stories[sid].append(it)
    out = []
    for sid in order:
        parts = stories[sid]
        source = sid.split("/", 1)[1]
        lead = next((p for p in parts if (p.get("base") or p.get("name")) == source), None)
        lead = lead or min(parts, key=lambda p: len(p.get("base") or p.get("name") or ""))
        out.append({"id": sid, "source": source, "lead": lead, "parts": parts})
    return out


def _span(parts, a, b):
    starts = [p["t"][a] for p in parts if isinstance(p.get("t"), dict) and p["t"].get(a) is not None]
    ends = [p["t"][b] for p in parts if isinstance(p.get("t"), dict) and p["t"].get(b) is not None]
    if not starts:
        return None
    return [min(starts), max(ends) if ends else None]


def _severity(advisories, names):
    """The most serious advisory among a story's packages."""
    rank = {"critical": 4, "important": 3, "high": 3, "moderate": 2, "medium": 2, "low": 1}
    best, ids = None, []
    for n in names:
        adv = advisories.get(n)
        if not adv:
            continue
        for i in adv.get("ids") or []:
            if i not in ids:
                ids.append(i)
        if best is None or rank.get(adv.get("severity", ""), 0) > rank.get(best.get("severity", ""), 0) \
                or (best.get("type") != "security" and adv.get("type") == "security"):
            best = adv
    if not best:
        return None
    return {"type": best.get("type", ""), "severity": (best.get("severity") or "").lower(), "ids": ids}


# ── What the machine says about a story ──────────────────────────────────────

def load_usage():
    """DMS's launcher history: {desktop id: (count, last used, unix seconds)}."""
    try:
        with open(appusage_path()) as fh:
            ranking = json.load(fh).get("appUsageRanking") or {}
    except (OSError, ValueError, AttributeError):
        return {}
    out = {}
    for key, v in ranking.items():
        if not isinstance(v, dict):
            continue
        last = v.get("lastUsed") or 0
        out[re.sub(r"\.desktop$", "", key)] = (int(v.get("usageCount") or 0), last / 1000 if last > 1e11 else last)
    return out


def package_files(names, be=None):
    """{package: [paths]} of installed packages."""
    be = be or backend()
    out = {n: [] for n in names}
    if not names:
        return out
    if be == "dnf":
        for n in names:
            code, text = _run(["rpm", "-ql", n])
            if code == 0:
                out[n] = [l for l in text.splitlines() if l.startswith("/")]
    elif be == "pacman":
        code, text = _run(["pacman", "-Ql"] + list(names))
        for line in text.splitlines():
            pkg, _, path = line.partition(" ")
            if pkg in out and path.startswith("/") and not path.endswith("/"):
                out[pkg].append(path)
    elif be == "apt":
        for n in names:
            code, text = _run(["dpkg-query", "-L", n])
            if code == 0:
                out[n] = [l for l in text.splitlines() if l.startswith("/")]
    return out


def desktop_ids(story, files):
    """The launcher ids a story's apps are known by."""
    lead = story["lead"]
    repo = lead.get("repo")
    if repo == "flatpak":
        return [lead.get("name") or ""]
    if repo == "snap":
        return [lead.get("name") or ""]
    if repo == "appimage":
        return ["dsd-appimage-" + (lead.get("name") or "")]
    ids = []
    for p in story["parts"]:
        for path in files.get(p.get("base") or p.get("name") or "", []):
            if path.startswith("/usr/share/applications/") and path.endswith(".desktop") and launchable(path):
                ids.append(os.path.basename(path)[:-len(".desktop")])
    return ids


def launchable(path):
    """Whether a desktop entry is an app the launcher lists: an input
    method's settings dialog (NoDisplay) is part of a package, not an app
    anyone opens or could be told they never open."""
    try:
        with open(path, errors="replace") as fh:
            text = fh.read()
    except OSError:
        return False
    head = text.split("\n[", 1)[0]
    return not re.search(r"^(NoDisplay|Hidden)\s*=\s*true\s*$", head, re.M | re.I) \
        and re.search(r"^Type\s*=\s*Application\s*$", head, re.M) is not None


def desktop_entry(desktop_id, root="/usr/share/applications"):
    """(Name, Icon) of a desktop entry, untranslated; ("", "") when unreadable."""
    name = icon = ""
    try:
        with open(os.path.join(root, desktop_id + ".desktop"), errors="replace") as fh:
            section = ""
            for line in fh:
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
    except OSError:
        pass
    return name, icon


def usage_for(ids, usage, now):
    """Launcher starts weighted by how recent the last one was."""
    count, last = 0, 0
    for i in ids:
        c, l = usage.get(i, (0, 0))
        count += c
        last = max(last, l)
    if not count:
        return 0, 0, 0.0
    days = (now - last) / 86400 if last else 9999
    weight = 1.0 if days <= 30 else (0.5 if days <= 90 else 0.25)
    return count, last, weight


def unit_files(paths):
    return sorted({os.path.basename(p) for p in paths
                   if re.search(r"/systemd/system/[^/]+\.service$", p) and "@" not in os.path.basename(p)})


def active_units(units):
    """The ones running now."""
    if not units:
        return []
    code, text = _run(["systemctl", "is-active"] + list(units))
    states = text.split()
    return [u for u, s in zip(units, states) if s == "active"]


# ── Relevance ────────────────────────────────────────────────────────────────

SEV_SCORE = {"critical": 40, "important": 30, "high": 30, "moderate": 15, "medium": 15, "low": 8}
JUMP_SCORE = {"major": 15, "minor": 6, "patch": 2, "git": 3, "rebuild": 0, "": 0}


def score(facts, routine=False):
    """[security, use, role, new] for a story; the sum orders the feed.
    Each part is one rule, kept apart so the window can show why."""
    sec = 0
    if facts.get("advisory") and facts["advisory"].get("type") == "security":
        sec = SEV_SCORE.get(facts["advisory"].get("severity", ""), 10)
        sec += min(8, len(facts["advisory"].get("ids") or []) // 25)
    use = round(min(20, facts.get("uses", 0)) * 2 * facts.get("useWeight", 0))
    role = 0
    if facts.get("role") == "kernel":
        role = 30
    elif facts.get("role") == "desktop":
        role = 25
    elif facts.get("services"):
        role = 22
    elif facts.get("kind") == "firmware":
        role = 15
    new = JUMP_SCORE.get(facts.get("jump", ""), 0)
    if routine:
        role, new = role // 3, 0
    parts = [sec, use, role, new]
    # Something that did not install is what needs doing first
    total = sum(parts) + (80 if facts.get("failedAll") else (20 if facts.get("failed") else 0))
    return parts, total


def routine_sources(history):
    """Sources that came along as git builds in at least two of the last
    editions: those builds are routine, not news."""
    seen = {}
    for ed in history[-ROUTINE_LOOKBACK:]:
        for st in ed.get("stories") or []:
            if (st.get("facts") or {}).get("jump") == "git":
                seen[st["id"]] = seen.get(st["id"], 0) + 1
    return {k for k, n in seen.items() if n >= 2}


CVE_RE = re.compile(r"\bCVE-\d{4}-\d{4,}\b", re.I)


def story_cves(story):
    """The CVEs a story fixes: those its advisory references, and those its
    notes name — a Fedora advisory often points at Bugzilla entries while
    the changelog lists the CVE numbers themselves."""
    adv = story["facts"].get("advisory") or {}
    found = [i.upper() for i in adv.get("ids") or [] if CVE_RE.fullmatch(i)]
    for line in (story.get("notes") or []) + (story.get("noteCves") or []):
        for c in CVE_RE.findall(line):
            if c.upper() not in found:
                found.append(c.upper())
    return found


def recount(ed):
    """Per story and in total, after notes were added."""
    total = 0
    for s in ed["stories"]:
        cves = story_cves(s)
        s["facts"]["cves"] = len(cves)
        s["cves"] = cves[:400]
        total += len(cves)
    ed["totals"]["cves"] = total
    return ed


# ── Notes the machine already has ────────────────────────────────────────────

OTHER_PLATFORM = re.compile(r"\b(android|ios|ipados|macos|mac os|os x|windows|win32|win64)\b", re.I)
HEADING = re.compile(r"<p>\s*<(?:b|strong)>(.*?)</(?:b|strong)>\s*</p>|<h\d[^>]*>(.*?)</h\d>", re.S | re.I)


def _text(fragment):
    import html as htmlmod
    return re.sub(r"\s+", " ", htmlmod.unescape(re.sub(r"<[^>]+>", "", fragment or ""))).strip()


def _html_lines(html):
    """Plain lines from a release's notes. Sections headed for another
    platform (a browser's notes for Android, macOS…) are left out; where the
    rest has list items, those are the notes and the prose around them
    (download instructions, system requirements) is not. Repeats once."""
    html = html or ""
    sections, pos, heading = [], 0, ""
    for m in HEADING.finditer(html):
        sections.append((heading, html[pos:m.start()]))
        heading, pos = _text(m.group(1) or m.group(2)), m.end()
    sections.append((heading, html[pos:]))
    kept = [(h, body) for h, body in sections if not OTHER_PLATFORM.search(h)]
    items = [_text(li) for _h, body in kept for li in re.findall(r"<li[^>]*>(.*?)</li>", body, re.S | re.I)]
    if not items:
        for _h, body in kept:
            items += [_text(p) for p in re.split(r"</?(?:p|ul|ol|br)[^>]*>", body)]
    out = []
    for line in items:
        if line and line not in out:
            out.append(line)
    return out


def changelog_lines(name, old, be=None, limit=NOTES_MAX):
    """The changelog lines of the installed package newer than `old`: the
    entries above the one for the version that was installed before."""
    be = be or backend()
    if be != "dnf":
        import pkg_backend
        text = pkg_backend.changelog(name)
    else:
        code, text = _run(["rpm", "-q", "--changelog", name])
    old_v = evr_version(old)
    # version-release without the dist tag: changelog headers say "- 3.26.6-1"
    # for a package installed as 3.26.6-1.fc45. The first entry that is not
    # newer than that is where the old package's history begins — an
    # entry for the exact old release need not exist (a mass rebuild
    # bumps the release without writing one)
    old_vr = re.sub(r"\.(fc|el|mga|module_)\w*$", "", re.sub(r"^\d+:", "", old or ""))
    from enrich import version_newer
    lines = []
    for entry in re.split(r"\n(?=\* )", (text or "").strip()):
        head = entry.split("\n", 1)[0].strip()
        head_v = re.sub(r"^\d+:", "", head.rsplit(" ", 1)[-1]) if head.startswith("*") else ""
        if head_v and old_vr and not version_newer(head_v, old_vr):
            break
        if not head_v and old_v and re.search(r"[\s(-]" + re.escape(old_v) + r"(-|\s|\)|$)", head):
            break
        for line in entry.split("\n")[1:]:
            line = line.strip()
            if line.startswith(("- ", "* ")):
                lines.append(line[2:].strip())
            elif lines and line and not line.startswith("*"):
                lines[-1] += " " + line
        if limit and len(lines) >= limit:
            break
    return lines[:limit] if limit else lines


def appstream_notes(stories):
    """{story id: (lines, homepage, name, icon)} from the AppStream catalogs:
    the releases between the two versions."""
    try:
        import enrich
    except Exception:
        return {}
    rpm_names = {}
    flat = {}
    for st in stories:
        lead = st["lead"]
        if lead.get("repo") == "flatpak":
            flat[lead.get("name")] = st["id"]
        elif lead.get("repo") in ("system", "", None):
            for p in st["parts"]:
                rpm_names[p.get("base") or p.get("name")] = st["id"]
    try:
        found_rpm, found_flat = enrich.scan_catalogs(set(rpm_names), set(flat))
    except Exception:
        return {}
    out = {}

    def take(sid, comp, old, new):
        lines = []
        for rel in comp.get("releases") or []:
            v = rel.get("version") or ""
            if enrich.version_newer(v, evr_version(old)) and not enrich.version_newer(v, evr_version(new)):
                lines += _html_lines(rel.get("notesHtml") or rel.get("description") or "")
        prev = out.get(sid)
        if prev is None or (lines and not prev[0]):
            out[sid] = (lines[:NOTES_MAX], comp.get("homepage", ""), comp.get("name", ""), comp.get("icon", ""))

    by_id = {st["id"]: st for st in stories}
    for name, comp in found_rpm.items():
        sid = rpm_names.get(name)
        if sid:
            lead = by_id[sid]["lead"]
            take(sid, comp, lead.get("from"), lead.get("to"))
    for name, comp in found_flat.items():
        sid = flat.get(name)
        if sid:
            lead = by_id[sid]["lead"]
            take(sid, comp, lead.get("from"), lead.get("to"))
    return out


# ── build ────────────────────────────────────────────────────────────────────

def load_editions():
    d = editions_dir()
    out = []
    try:
        names = sorted(n for n in os.listdir(d) if re.match(r"^\d+\.json$", n))
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(d, n)) as fh:
                out.append(json.load(fh))
        except (OSError, ValueError):
            continue
    return out


def save(ed):
    os.makedirs(editions_dir(), exist_ok=True)
    path = os.path.join(editions_dir(), "%d.json" % ed["ts"])
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(ed, fh, ensure_ascii=False)
    os.replace(tmp, path)
    return path


def load(ts):
    eds = load_editions()
    if not eds:
        return None
    if ts == "latest":
        return eds[-1]
    return next((e for e in eds if str(e.get("ts")) == str(ts)), None)


def build(run, be=None, usage=None, now=None, history=None, files=None, sources=None, active=None, notes=True):
    """An edition from the engine's account of a run. The machine is asked
    through the keyword arguments' defaults; tests hand them in."""
    be = be or run.get("backend") or backend()
    now = now or time.time()
    items = [it for it in run.get("items") or [] if not GROUP_SKIP.search(it.get("base") or it.get("name") or "")]
    sys_names = sorted({it.get("base") or it.get("name") for it in items if it.get("repo") in ("system", "", None)})
    if sources is None:
        sources = source_names(sys_names, be)
    stories = group_items(items, sources)
    if files is None:
        files = package_files(sys_names, be)
    usage = load_usage() if usage is None else usage
    history = load_editions() if history is None else history
    routine = routine_sources(history)
    advisories = run.get("advisories") or {}
    app_notes = appstream_notes(stories) if notes else {}

    out_stories = []
    total_cves = 0
    for st in stories:
        lead, parts = st["lead"], st["parts"]
        names = [p.get("base") or p.get("name") for p in parts]
        story_files = [f for n in names for f in files.get(n, [])]
        units = unit_files(story_files)
        running_units = (active or active_units)(units) if units else []
        adv = _severity(advisories, names)
        ids = desktop_ids(st, files)
        uses, last, weight = usage_for(ids, usage, now)
        source = st["source"]
        role = "kernel" if KERNEL_RE.match(source) else ("desktop" if source in COMPOSITORS else "")
        failed = [p.get("name") for p in parts if p.get("status") == "error"]
        facts = {
            "kind": lead.get("repo") or "system",
            "jump": jump(lead.get("from"), lead.get("to")),
            "commits": commits_between(lead.get("from"), lead.get("to")),
            "advisory": adv,
            "uses": uses, "lastUsed": int(last), "useWeight": weight,
            "desktopIds": ids,
            "services": running_units,
            "role": role,
            "failed": len(failed),
            "failedAll": bool(failed) and len(failed) == len(parts),
        }
        if adv and adv.get("type") == "security":
            total_cves += len([i for i in adv.get("ids") or [] if i.upper().startswith("CVE-")])
        score_parts, total = score(facts, routine=st["id"] in routine and facts["jump"] == "git")
        an = app_notes.get(st["id"])
        lines = list(an[0]) if an else []
        note_src = "appstream" if lines else ""
        note_cves = []
        # A git build's changelog is its packaging history, not what changed
        # upstream: those notes come from the commits (fetch_notes)
        if notes and not lines and facts["kind"] in ("system", "") and lead.get("to") and facts["jump"] != "git":
            every = changelog_lines(lead.get("base") or lead.get("name"), lead.get("from"), be, limit=0)
            lines = every[:NOTES_MAX]
            # Every CVE the entries name, not only those in the lines shown:
            # Chromium's lists two hundred
            note_cves = sorted({c.upper() for l in every for c in CVE_RE.findall(l)})
            note_src = "changelog" if lines else ""
        t = {"dl": _span(parts, "d0", "d1"), "inst": _span(parts, "i0", "i1")}
        # The generic span is for passes that report no phases
        t["work"] = None if t["dl"] or t["inst"] else _span(parts, "w0", "w1")
        d_name, d_icon = desktop_entry(ids[0]) if ids and facts["kind"] in ("system", "") else ("", "")
        out_stories.append({
            "id": st["id"],
            "name": (an[2] if an and an[2] else "") or d_name or lead.get("label") or lead.get("name") or st["source"],
            "source": st["source"],
            "icon": (an[3] if an and an[3] else "") or d_icon or lead.get("icon") or "",
            "homepage": an[1] if an else "",
            "from": lead.get("from") or "", "to": lead.get("to") or "",
            "packages": names,
            "bytes": sum(int(p.get("bytes") or 0) for p in parts),
            "status": "error" if len(failed) == len(parts) else ("partial" if failed else "done"),
            "error": next((p.get("error") for p in parts if p.get("error")), ""),
            "t": t,
            "facts": facts,
            "score": score_parts, "rank": total,
            "notes": lines, "notesFrom": note_src, "notesUrl": "",
            "noteCves": note_cves,
            "routine": st["id"] in routine and facts["jump"] == "git",
        })
    out_stories.sort(key=lambda s: -s["rank"])
    ed = {
        "replay": bool(run.get("replay")),
        "format": FORMAT,
        "ts": int(run.get("ts") or now),
        "backend": be,
        "duration": run.get("duration") or 0,
        "phases": run.get("phases") or [],
        "rate": run.get("rate") or [],
        # Seconds between two rate samples; editions from before it said
        # were half a second
        "rateStep": run.get("rateStep") or 0.5,
        "totals": {
            "packages": len(items),
            "failed": sum(1 for it in items if it.get("status") == "error"),
            "bytes": sum(int(it.get("bytes") or 0) for it in items),
            "cves": total_cves,
            "stories": len(out_stories),
        },
        "stories": out_stories,
        "after": None,
    }
    return recount(ed)


# ── after: what still needs doing ────────────────────────────────────────────

def reboot_needed(be=None):
    """True, False, or None when it cannot be told."""
    be = be or backend()
    if be == "dnf":
        for cmd in (["dnf5", "needs-restarting", "-r"], ["dnf", "needs-restarting", "-r"]):
            code, _ = _run(cmd, timeout=180)
            if code in (0, 1):
                return code == 1
        return None
    if be == "apt":
        return os.path.exists("/var/run/reboot-required")
    if be == "pacman":
        return not os.path.isdir("/usr/lib/modules/" + os.uname().release)
    return None


def _boot_time(proc):
    try:
        with open(os.path.join(proc, "stat")) as fh:
            for line in fh:
                if line.startswith("btime "):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def stale_processes(files_by_story, proc=None, uid=None):
    """{story id: {pids, since}} for this user's processes still running a
    program the run replaced: the executable they started from is gone."""
    proc = proc or _test_hook("DSD_PROC") or "/proc"
    uid = os.getuid() if uid is None else uid
    owner = {}
    for sid, paths in files_by_story.items():
        for p in paths:
            owner[p] = sid
    try:
        hz = os.sysconf("SC_CLK_TCK")
    except (ValueError, OSError):
        hz = 100
    btime = _boot_time(proc)
    out = {}
    try:
        pids = [p for p in os.listdir(proc) if p.isdigit()]
    except OSError:
        return out
    for pid in pids:
        base = os.path.join(proc, pid)
        try:
            if os.stat(base).st_uid != uid:
                continue
            exe = os.readlink(os.path.join(base, "exe"))
        except OSError:
            continue
        if not exe.endswith(" (deleted)"):
            continue
        path = exe[:-len(" (deleted)")]
        sid = owner.get(path)
        if not sid:
            continue
        since = 0
        try:
            with open(os.path.join(base, "stat")) as fh:
                fields = fh.read().rsplit(")", 1)[1].split()
            since = btime + int(fields[19]) / hz if btime else 0
        except (OSError, IndexError, ValueError):
            pass
        entry = out.setdefault(sid, {"pids": [], "since": 0})
        entry["pids"].append(int(pid))
        if since and (not entry["since"] or since < entry["since"]):
            entry["since"] = int(since)
    return out


def unit_started(unit):
    """When a unit last became active, in unix seconds; 0 when unknown."""
    code, text = _run(["systemctl", "show", "-p", "ActiveEnterTimestamp", "--value", "--timestamp=unix", unit])
    m = re.match(r"^@(\d+)", text.strip())
    return int(m.group(1)) if m else 0


def after(ed, be=None, files=None, reboot=None, stale=None, started=None, usage=None, now=None):
    """The checks after a run: each a fact, the window decides the words."""
    be = be or ed.get("backend") or backend()
    now = now or time.time()
    done = [s for s in ed["stories"] if s["status"] != "error"]
    names = [n for s in done if s["facts"]["kind"] in ("system", "") for n in s["packages"]]
    files = package_files(names, be) if files is None else files
    by_story = {s["id"]: [f for n in s["packages"] for f in files.get(n, [])] for s in done}
    finished_at = ed["ts"] + (ed.get("duration") or 0)
    checks = []

    need = reboot_needed(be) if reboot is None else reboot
    if need is not None:
        checks.append({"kind": "reboot", "needed": bool(need)})

    started = started or unit_started
    for s in done:
        for unit in s["facts"].get("services") or []:
            at = started(unit)
            if at:
                checks.append({"kind": "service", "story": s["id"], "unit": unit,
                               "restarted": at >= ed["ts"], "at": at})

    stale = stale_processes(by_story) if stale is None else stale
    for sid, info in stale.items():
        story = next((s for s in done if s["id"] == sid), None)
        if story:
            checks.append({"kind": "stale", "story": sid, "pids": info["pids"], "since": info.get("since", 0),
                           "desktop": (story["facts"].get("desktopIds") or [""])[0],
                           "role": story["facts"].get("role", "")})

    # An app the launcher has never or long not started. Only said where the
    # launcher keeps a history at all, and never for something running now.
    usage = load_usage() if usage is None else usage
    if usage:
        for s in done:
            ids = s["facts"].get("desktopIds") or []
            if not ids or s["id"] in stale or s["facts"].get("role"):
                continue
            last = s["facts"].get("lastUsed") or 0
            if s["facts"].get("uses", 0) == 0 or (last and now - last > UNUSED_DAYS * 86400):
                checks.append({"kind": "unused", "story": s["id"], "uses": s["facts"].get("uses", 0),
                               "lastUsed": last, "bytes": s.get("bytes", 0),
                               "cves": s["facts"].get("cves", 0)})
    ed["after"] = {"at": int(now), "finishedAt": int(finished_at), "checks": checks}
    return ed


# ── notes: from the project itself ───────────────────────────────────────────

def fetch_notes(ed, limit=ONLINE_STORIES, fetch=None):
    """For the top stories without notes: the release notes the project
    published on GitHub for this version, or the commits between two git
    builds. enrich.py's forge code, with its cache."""
    fetch = fetch or cached_forge_notes
    wanted = [s for s in ed["stories"] if (not s["notes"] or (thin(s["notes"]) and s["notesFrom"] != "release"))
              and s["status"] != "error" and s["facts"]["kind"] in ("system", "") and s["notesFrom"] not in ("commits",)][:limit]
    for s in wanted:
        got = fetch(s["source"], s["packages"], s["from"], s["to"])
        if got and got.get("lines"):
            # A packager's own line stays above what the project said: it
            # names the CVEs a version was taken for
            keep = [l for l in s["notes"] if re.match(r"^(CVE-|.*\bCVE-\d+)", l)] if s["notes"] else []
            link_of = dict(zip(got["lines"], got.get("links") or []))
            s["notes"] = (keep + [l for l in got["lines"] if l not in keep])[:NOTES_MAX]
            # Parallel to notes: where each line leads ("" when nowhere)
            s["noteLinks"] = [link_of.get(l, "") for l in s["notes"]]
            if got.get("date"):
                s["notesDate"] = int(got["date"])
            s["notesFrom"] = got.get("kind", "forge")
            s["notesUrl"] = got.get("url", "")
            if got.get("more"):
                s["notesMore"] = got["more"]
    return recount(ed)


# Projects whose package points at a website rather than at the repository
# their releases are published in
KNOWN_REPOS = {
    "brave-browser": "brave/brave-browser", "brave-origin": "brave/brave-browser",
    "brave-browser-beta": "brave/brave-browser", "brave-browser-nightly": "brave/brave-browser",
    "libreswan": "libreswan/libreswan",
}

# What a packager writes when the version is all there is to say
THIN = re.compile(r"^(update|upgrade|rebase|rebasing|new upstream|regenerate|rebuil[dt]|bump)\b.{0,60}$", re.I)


def thin(lines):
    """Notes that only name the new version: the project will say more."""
    real = [l for l in lines if not re.match(r"^(CVE-\d+-\d+|resolves?:|related:)", l, re.I)]
    return not real or all(THIN.match(l) for l in real[:2]) and len(real) <= 2


# What the forge said, kept: GitHub answers sixty questions an hour without
# an account, and a dashboard that asks again on every start runs out. The
# commits between two builds never change; a project's releases are asked
# again after a day, a question that failed after an hour. When GitHub says
# the hour is used up, nothing is asked until it says it starts again.
NOTES_CACHE_DAYS = {"commits": None, "release": 1, "": 1 / 24}
# Raised when an entry gains something an older one lacks (2: each commit's
# link; 3: the date), so the older ones are asked again once
NOTES_CACHE_VERSION = 3


def _notes_cache_path():
    return _test_hook("DSD_NOTES_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dankSoftwareDepot", "forge-notes.json")


def _notes_cache():
    try:
        with open(_notes_cache_path()) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _notes_cache_save(data):
    path = _notes_cache_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        pass


class RateLimited(Exception):
    def __init__(self, until=0):
        super().__init__("rate limited")
        self.until = until


def cached_forge_notes(source, packages, old, new, now=None, fetch=None):
    now = now or time.time()
    fetch = fetch or _forge_notes
    cache = _notes_cache()
    if cache.get("_blockedUntil", 0) > now:
        return None
    key = "%s|%s|%s" % (source, old, new)
    hit = cache.get(key)
    if hit and hit.get("v") == NOTES_CACHE_VERSION:
        days = NOTES_CACHE_DAYS.get(hit.get("kind", ""), 1)
        if days is None or now - hit.get("at", 0) < days * 86400:
            return hit if hit.get("lines") else None
    try:
        got = fetch(source, packages, old, new)
    except RateLimited as e:
        cache["_blockedUntil"] = e.until or now + 3600
        _notes_cache_save(cache)
        return None
    entry = dict(got or {"lines": [], "kind": ""})
    entry["at"] = int(now)
    entry["v"] = NOTES_CACHE_VERSION
    cache[key] = entry
    _notes_cache_save(cache)
    return entry if entry.get("lines") else None


def _forge_notes(source, packages, old, new):
    import enrich
    repo = KNOWN_REPOS.get(source, "")
    for name in ([] if repo else [source] + list(packages)):
        repo = enrich.github_repo(enrich.package_url(name))
        if repo:
            break
    if not repo:
        return None
    try:
        to_hash = enrich.snapshot_hash(evr_version(new))
        if to_hash:
            from_hash = enrich.snapshot_hash(evr_version(old))
            out = enrich.github_commits(repo, from_hash, to_hash) if from_hash else {}
        else:
            out = enrich.github_releases(repo, old, new)
    except Exception as e:
        # The forge's "come back later", told apart from a project that
        # simply has nothing there
        if getattr(e, "code", 0) in (403, 429):
            reset = 0
            try:
                reset = int((e.headers or {}).get("X-RateLimit-Reset") or 0)
            except (TypeError, ValueError, AttributeError):
                pass
            raise RateLimited(reset)
        return None
    lines = []
    for rel in out.get("releases") or []:
        lines += _html_lines(rel.get("notesHtml") or "")
    # Where each line leads, when it is a commit
    by_subject = {c.get("subject", ""): c.get("url", "") for c in out.get("commits") or []}
    links = [by_subject.get(l, "") for l in lines]
    # When the project published it: the newest release, or the last commit
    date = max([int(rel.get("date") or 0) for rel in out.get("releases") or []] or [0])
    return {"lines": lines, "links": links, "url": out.get("url", ""), "kind": out.get("kind", ""),
            "more": out.get("more", 0), "date": date, "v": NOTES_CACHE_VERSION}


# ── list: the archive ────────────────────────────────────────────────────────

def _action_log():
    path = _test_hook("DSD_ACTION_LOG") or os.path.join(data_dir(), "action-log.json")
    try:
        with open(path) as fh:
            entries = json.load(fh)
        return entries if isinstance(entries, list) else []
    except (OSError, ValueError):
        return []


def same_run(ed, ts):
    """Whether an edition is of the run a log entry at ts records. The
    edition is dated at the run's start, the entry at its end."""
    end = int(ed.get("ts") or 0) + int(ed.get("duration") or 0)
    return abs(end - ts) < 600 or abs(int(ed.get("ts") or 0) - ts) < 600


def summary(ed):
    """What the archive shows of an edition."""
    lead = ed["stories"][0] if ed.get("stories") else None
    subs = [s for s in ed.get("stories", [])[1:4] if s["rank"] >= 15]
    return {
        "ts": ed["ts"],
        "packages": ed["totals"]["packages"], "failed": ed["totals"]["failed"],
        "stories": ed["totals"]["stories"], "cves": ed["totals"].get("cves", 0),
        "bytes": ed["totals"].get("bytes", 0), "duration": ed.get("duration", 0),
        "lead": _brief(lead) if lead and lead["rank"] >= 15 else None,
        "subs": [_brief(s) for s in subs],
        "kernel": any(s["facts"].get("role") == "kernel" for s in ed.get("stories", [])),
        "names": sorted({s["name"] for s in ed.get("stories", [])} | {n for s in ed.get("stories", []) for n in s["packages"]}),
        "edition": True,
    }


def _brief(s):
    f = s["facts"]
    return {"name": s["name"], "from": s["from"], "to": s["to"], "jump": f.get("jump", ""),
            "commits": f.get("commits", 0), "role": f.get("role", ""), "failed": f.get("failed", 0),
            "packages": len(s["packages"]), "uses": f.get("uses", 0),
            "severity": (f.get("advisory") or {}).get("severity", "") if (f.get("advisory") or {}).get("type") == "security" else "",
            "cves": f.get("cves", len((f.get("advisory") or {}).get("ids") or []))}


def from_log(entry, sources=None):
    """An archive entry for a run from before editions: the action log keeps
    the items, which is enough for the facts that need no machine."""
    items = []
    for it in entry.get("items") or []:
        if it.get("status") not in ("done", "error"):
            continue
        items.append({"name": it.get("base") or it.get("name"), "label": it.get("name"), "repo": it.get("repo") or "system",
                      "key": (it.get("repo") or "system") + "/" + (it.get("id") or it.get("base") or ""),
                      "base": it.get("base") or "", "from": it.get("from", ""), "to": it.get("to", ""),
                      "status": it.get("status")})
    stories = group_items(items, sources or {})
    out = []
    for st in stories:
        lead = st["lead"]
        facts = {"kind": lead.get("repo"), "jump": jump(lead.get("from"), lead.get("to")),
                 "commits": commits_between(lead.get("from"), lead.get("to")), "advisory": None, "uses": 0,
                 "useWeight": 0, "services": [],
                 "role": "kernel" if KERNEL_RE.match(st["source"]) else ("desktop" if st["source"] in COMPOSITORS else ""),
                 "failed": sum(1 for p in st["parts"] if p.get("status") == "error")}
        facts["failedAll"] = facts["failed"] == len(st["parts"])
        parts, total = score(facts)
        out.append({"id": st["id"], "name": lead.get("label") or lead.get("name") or st["source"], "from": lead.get("from", ""),
                    "to": lead.get("to", ""), "packages": [p.get("name") for p in st["parts"]], "facts": facts,
                    "score": parts, "rank": total})
    out.sort(key=lambda s: -s["rank"])
    ts = entry.get("ts") or 0
    ts = int(ts / 1000) if ts > 1e11 else int(ts)
    ed = {"ts": ts, "stories": out, "totals": {"packages": len(items), "failed": sum(1 for i in items if i["status"] == "error"),
                                              "stories": len(out), "cves": 0, "bytes": 0}, "duration": 0}
    s = summary(ed)
    s["edition"] = False
    return s


def archive():
    """Every edition and every logged run without one, oldest first. A small
    run within an hour and a half of the one before, of seven packages at
    most, is a retry or a straggler: it joins that run as a late note."""
    full = load_editions()
    eds = {e["ts"]: summary(e) for e in full}
    out = []
    for entry in _action_log():
        if entry.get("type") not in ("update", "update-failed"):
            continue
        ts = entry.get("ts") or 0
        ts = int(ts / 1000) if ts > 1e11 else int(ts)
        # An edition is written at the end of its run, the log entry at the
        # same moment; match them within a few minutes
        match = next((e["ts"] for e in full if e["ts"] in eds and same_run(e, ts)), None)
        s = eds.pop(match) if match is not None else from_log(entry)
        s["ts"] = s["ts"] or ts
        if out and s["ts"] - out[-1]["ts"] < 5400 and s["packages"] <= 7 and not s.get("edition"):
            names = sorted({b for b in s["names"]})
            out[-1].setdefault("late", []).append({"ts": s["ts"], "packages": s["packages"], "failed": s["failed"],
                                                   "names": names[:6]})
            out[-1]["names"] = sorted(set(out[-1]["names"]) | set(names))
            continue
        out.append(s)
    out.extend(eds.values())
    out.sort(key=lambda s: s["ts"])
    return out


# ── A run the shell reload interrupted ───────────────────────────────────────
# Updating the shell itself reloads it before the run ends: what the engine
# measured is gone and the log entry is written by the next start, from a
# stash. The measurements are stashed too (stash), and that next start builds
# the edition from them with the outcome the log settled on (resume). A run
# that left no edition at all is built from its log entry alone.

def pending_path():
    return os.path.join(data_dir(), "pending-edition.json")


def stash(run):
    os.makedirs(data_dir(), exist_ok=True)
    tmp = pending_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(run, fh, ensure_ascii=False)
    os.replace(tmp, pending_path())


def log_run(entry):
    """The run an action-log entry describes, as build() takes it: no
    timeline, no throughput, no advisories."""
    ts = entry.get("ts") or 0
    ts = int(ts / 1000) if ts > 1e11 else int(ts)
    items = []
    for it in entry.get("items") or []:
        repo = it.get("repo") or "system"
        sys_row = repo in ("system", "aur")
        base = it.get("base") or (re.sub(r"\.(x86_64|aarch64|i686|noarch|armv7hl|ppc64le|s390x)$", "", it.get("id") or "") if sys_row else "")
        items.append({"key": repo + "/" + (it.get("id") or base or it.get("name") or ""),
                      "name": base if sys_row and base else (it.get("id") or it.get("name") or ""),
                      "base": base if sys_row else "", "label": it.get("name") or "",
                      "repo": "system" if sys_row else repo,
                      "from": it.get("from") or "", "to": it.get("to") or "",
                      "status": it.get("status") or "", "error": it.get("reason") or "",
                      "bytes": 0, "t": {}})
    return {"ts": ts, "duration": 0, "phases": [], "rate": [], "items": items, "advisories": {}}


def merge_outcome(run, entry):
    """The stashed run with the outcome its log entry records: the rows still
    in flight when the shell went, and the shell's own packages."""
    logged = log_run(entry)
    by_name = {}
    for it in logged["items"]:
        by_name[it["base"] or it["name"]] = it
    seen = set()
    for it in run.get("items") or []:
        name = it.get("base") or it.get("name")
        got = by_name.get(name)
        if got:
            seen.add(name)
            it["status"] = got["status"]
            if got["status"] != "error":
                it["error"] = ""
            it["to"] = it.get("to") or got["to"]
    for name, it in by_name.items():
        if name not in seen:
            run.setdefault("items", []).append(it)
    return run


def resume(entry):
    run = None
    try:
        with open(pending_path()) as fh:
            run = json.load(fh)
    except (OSError, ValueError):
        pass
    logged = log_run(entry)
    # The stash is from the start of this run, the entry from its shell
    # pass: hours apart at most. Anything else is a leftover.
    if run and 0 <= logged["ts"] - int(run.get("ts") or 0) < 6 * 3600:
        run = merge_outcome(run, entry)
    else:
        run = logged
    try:
        os.remove(pending_path())
    except OSError:
        pass
    ed = build(run)
    save(ed)
    return ed


def latest_unbuilt():
    """The newest logged run, when no edition was made of it."""
    runs = [e for e in _action_log() if e.get("type") in ("update", "update-failed")]
    if not runs:
        return None
    entry = runs[-1]
    ts = entry.get("ts") or 0
    ts = int(ts / 1000) if ts > 1e11 else int(ts)
    if any(same_run(e, ts) or e["ts"] > ts for e in load_editions()):
        return None
    return entry


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "stash":
        stash(json.loads(sys.stdin.readline() or "{}"))
        return 0
    if cmd == "resume":
        entry = json.loads(sys.stdin.readline() or "{}")
        if not entry.get("items"):
            print("{}")
            return 1
        json.dump(resume(entry), sys.stdout, ensure_ascii=False)
        return 0
    if cmd in ("build", "preview"):
        # One line: the shell writes it and cannot close the pipe after
        run = json.loads(sys.stdin.readline() or "{}")
        ed = build(run)
        # A preview can ask for the projects' own notes too: what is ready
        # to install is worth reading about before it is installed
        if cmd == "preview" and "notes" in sys.argv[2:]:
            fetch_notes(ed)
        if cmd == "build":
            save(ed)
        json.dump(ed, sys.stdout, ensure_ascii=False)
        return 0
    if cmd in ("after", "notes", "show"):
        which = sys.argv[2] if len(sys.argv) > 2 else "latest"
        ed = None
        if which == "latest" and cmd == "show":
            entry = latest_unbuilt()
            if entry:
                ed = build(log_run(entry))
                save(ed)
        ed = ed or load(which)
        if ed is None:
            print("{}")
            return 1
        if cmd == "after":
            after(ed)
            save(ed)
        elif cmd == "notes":
            fetch_notes(ed)
            save(ed)
        json.dump(ed, sys.stdout, ensure_ascii=False)
        return 0
    if cmd == "list":
        json.dump(archive(), sys.stdout, ensure_ascii=False)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
