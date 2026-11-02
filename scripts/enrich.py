#!/usr/bin/env python3
"""Metadata enrichment for the dankSoftwareDepot DMS plugin.

Reads a JSON request on stdin:
  {"rpm":    [{"name": "freerdp-libs", "from": "3.24.2-1.fc44", "to": "2:3.30.0-1.fc44"}, ...],
   "flatpak":[{"name": "md.obsidian.Obsidian", "from": "1.12.7", "to": ""}, ...]}

Writes a JSON response on stdout:
  {"rpm": {"freerdp-libs": {...info...}}, "flatpak": {"md.obsidian.Obsidian": {...info...}}}

info = {name, summary, developer, homepage, icon, releases: [{version, date, notesHtml, newer}]}

Data sources: AppStream catalogs (distro + flatpak remotes), with a `dnf repoquery`
fallback for rpm packages that have no AppStream component.

Alternate mode:  enrich.py --changelog <pkg>   → plain-text rpm changelog (top entries).
Alternate mode:  enrich.py --gitnotes <pkg> <from-evr> <to-evr>
                 → release notes / commits from the upstream forge, for
                   packages built from git (see run_gitnotes).
"""

import glob
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

import pkg_backend

# "dnf" (Fedora, the in-file code paths) or "apt" (dispatched to pkg_backend)
BACKEND = pkg_backend.detect()

CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dankSoftwareDepot")
CACHE_FILE = os.path.join(CACHE_DIR, "enrich-cache.json")
MAX_RELEASES = 8


# Where each distro family keeps its AppStream catalog. Fedora and Arch both
# ship XML (Arch through archlinux-appstream-data, at the modern swcatalog
# path on current installs and the legacy app-info path on older ones); the
# Debian family ships DEP-11 YAML, which apt itself downloads into its lists
# directory and appstreamcli caches next to it.
XML_CATALOG_GLOBS = (
    "/usr/share/swcatalog/xml/*.xml",
    "/usr/share/swcatalog/xml/*.xml.gz",
    "/usr/share/app-info/xmls/*.xml",
    "/usr/share/app-info/xmls/*.xml.gz",
    "/var/lib/app-info/xmls/*.xml.gz",
)

YAML_CATALOG_GLOBS = (
    "/usr/share/swcatalog/yaml/*.yml.gz",
    "/usr/share/app-info/yaml/*.yml.gz",
    "/var/lib/app-info/yaml/*.yml.gz",
    "/var/cache/app-info/yaml/*.yml.gz",
    "/var/lib/apt/lists/*Components-*.yml.gz",
    "/var/lib/apt/lists/*Components-*.yml",
)


def distro_catalog_paths():
    """The distro's own AppStream catalog, without the flatpak remotes —
    that is a separate source with its own lifecycle."""
    paths = []
    for pattern in XML_CATALOG_GLOBS:
        paths += glob.glob(pattern)
    if BACKEND == "apt":
        for pattern in YAML_CATALOG_GLOBS:
            paths += glob.glob(pattern)
    return sorted(set(paths))


def catalog_paths():
    paths = distro_catalog_paths()
    for base in ("/var/lib/flatpak/appstream", os.path.expanduser("~/.local/share/flatpak/appstream")):
        paths += glob.glob(os.path.join(base, "*", "*", "active", "appstream.xml.gz"))
        paths += glob.glob(os.path.join(base, "*", "*", "active", "appstream.xml"))
    return sorted(set(paths))


_locale_langs_cache = None


def get_locale_langs():
    global _locale_langs_cache
    if _locale_langs_cache is None:
        _locale_langs_cache = locale_langs()
    return _locale_langs_cache


def text_locale(elem, name):
    """Child <name> text preferring the active locale, then untranslated."""
    langs = get_locale_langs()
    best = ""
    best_rank = 99
    for child in elem:
        if localname(child.tag) != name:
            continue
        value = (child.text or "").strip()
        if not value:
            continue
        lang = child_lang(child)
        rank = langs.index(lang) if lang in langs else (50 if lang == "" else 99)
        if rank < best_rank:
            best = value
            best_rank = rank
    return best


def fingerprint(paths):
    h = hashlib.md5()
    h.update(("locale:" + ",".join(get_locale_langs())).encode())
    for p in paths:
        try:
            st = os.stat(p)
            h.update(f"{p}:{st.st_mtime_ns}:{st.st_size};".encode())
        except OSError:
            continue
    return h.hexdigest()


def load_cache(fp):
    try:
        with open(CACHE_FILE) as f:
            cache = json.load(f)
        if cache.get("fingerprint") == fp:
            return cache
    except (OSError, ValueError):
        pass
    return {"fingerprint": fp, "rpm": {}, "flatpak": {}}


def save_cache(cache):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = CACHE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE_FILE)
    except OSError:
        pass


def open_catalog(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    return open(path, "rb")


def localname(tag):
    return tag.rsplit("}", 1)[-1]


def text_no_lang(elem, name):
    """First child <name> without xml:lang attribute."""
    for child in elem:
        if localname(child.tag) == name and not any(k.endswith("lang") for k in child.attrib):
            return (child.text or "").strip()
    return ""


def description_html(elem):
    """Serialize an AppStream <description>-style element to a safe HTML subset.

    Only <p>, <ul>, <ol>, <li> structure survives; all text content is
    HTML-escaped so untrusted upstream release notes can never inject markup
    (links, images, etc.) into the Qt rich-text renderer.
    """
    import html as htmlmod

    def safe_text(e):
        return htmlmod.escape(" ".join("".join(e.itertext()).split()))

    parts = []
    for child in elem:
        if any(k.endswith("lang") for k in child.attrib):
            continue
        tag = localname(child.tag)
        if tag == "p":
            parts.append("<p>" + safe_text(child) + "</p>")
        elif tag in ("ul", "ol"):
            items = []
            for li in child:
                if localname(li.tag) == "li" and not any(k.endswith("lang") for k in li.attrib):
                    items.append("<li>" + safe_text(li) + "</li>")
            parts.append(f"<{tag}>" + "".join(items) + f"</{tag}>")
    return "".join(parts)


def normalize_date(value):
    """Return unix epoch seconds (int) for a timestamp or ISO date string, else 0."""
    if not value:
        return 0
    if value.isdigit():
        return int(value)
    try:
        import datetime
        return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def parse_component(elem):
    comp = {
        "id": text_no_lang(elem, "id"),
        "pkgname": text_no_lang(elem, "pkgname"),
        "name": text_locale(elem, "name"),
        "summary": text_locale(elem, "summary"),
        "developer": "",
        "homepage": "",
        "icon_cached": "",
        "icon_stock": "",
        "releases": [],
    }
    for child in elem:
        tag = localname(child.tag)
        if tag == "url" and child.attrib.get("type") == "homepage":
            comp["homepage"] = (child.text or "").strip()
        elif tag == "developer_name":
            comp["developer"] = (child.text or "").strip()
        elif tag == "developer":
            comp["developer"] = text_no_lang(child, "name") or comp["developer"]
        elif tag == "icon":
            itype = child.attrib.get("type")
            if itype == "cached" and not comp["icon_cached"]:
                comp["icon_cached"] = (child.text or "").strip()
            elif itype == "stock" and not comp["icon_stock"]:
                comp["icon_stock"] = (child.text or "").strip()
        elif tag == "releases":
            for rel in list(child)[:MAX_RELEASES]:
                if localname(rel.tag) != "release":
                    continue
                notes = ""
                for rc in rel:
                    if localname(rc.tag) == "description" and not any(k.endswith("lang") for k in rc.attrib):
                        notes = description_html(rc)
                        break
                comp["releases"].append({
                    "version": rel.attrib.get("version", ""),
                    "date": normalize_date(rel.attrib.get("timestamp", "") or rel.attrib.get("date", "")),
                    "notesHtml": notes,
                })
    return comp


def dep11_description_html(text):
    """DEP-11 keeps descriptions as an HTML string rather than as elements.
    Reparse it so it goes through the same reduction as the XML path — no
    upstream release note may reach the Qt renderer with markup intact."""
    import html as htmlmod
    if not text:
        return ""
    try:
        return description_html(ET.fromstring("<description>" + text + "</description>"))
    except ET.ParseError:
        # Entities or stray markup: keep the words, drop the tags
        return "<p>" + htmlmod.escape(" ".join(re.sub(r"<[^>]+>", " ", text).split())) + "</p>"


def dep11_localized(value):
    """DEP-11 carries translations as {lang: text}; "C" is untranslated."""
    if isinstance(value, str):
        return value.strip()
    if not isinstance(value, dict):
        return ""
    for lang in get_locale_langs():
        if lang in value and isinstance(value[lang], str):
            return value[lang].strip()
    for key in ("C", "en"):
        if key in value and isinstance(value[key], str):
            return value[key].strip()
    for text in value.values():
        if isinstance(text, str):
            return text.strip()
    return ""


def parse_dep11_component(doc):
    """A DEP-11 YAML document in parse_component's shape, so everything
    downstream stays unaware of which catalog format it came from."""
    comp = {
        "id": (doc.get("ID") or "").strip(),
        "pkgname": (doc.get("Package") or "").strip(),
        "name": dep11_localized(doc.get("Name")),
        "summary": dep11_localized(doc.get("Summary")),
        "developer": "",
        "homepage": "",
        "icon_cached": "",
        "icon_stock": "",
        "releases": [],
    }
    developer = doc.get("Developer")
    if isinstance(developer, dict):
        comp["developer"] = dep11_localized(developer.get("Name"))
    if not comp["developer"]:
        comp["developer"] = dep11_localized(doc.get("DeveloperName"))
    url = doc.get("Url")
    if isinstance(url, dict):
        comp["homepage"] = (url.get("homepage") or "").strip()
    icon = doc.get("Icon")
    if isinstance(icon, dict):
        cached = icon.get("cached")
        if isinstance(cached, list) and cached:
            # Largest first: resolve_icon walks sizes from big to small
            best = max((c for c in cached if isinstance(c, dict)),
                       key=lambda c: c.get("width", 0), default=None)
            if best:
                comp["icon_cached"] = (best.get("name") or "").strip()
        stock = icon.get("stock")
        if isinstance(stock, str):
            comp["icon_stock"] = stock.strip()
    releases = doc.get("Releases")
    if isinstance(releases, list):
        for rel in releases[:MAX_RELEASES]:
            if not isinstance(rel, dict):
                continue
            comp["releases"].append({
                "version": str(rel.get("version", "")),
                "date": normalize_date(str(rel.get("unix-timestamp", "") or rel.get("date", ""))),
                "notesHtml": dep11_description_html(dep11_localized(rel.get("description"))),
            })
    return comp


def scan_yaml_catalog(path, wanted):
    """Components for the wanted packages out of a DEP-11 catalog. Needs
    PyYAML; where it is missing the XML catalogs and the apt fallbacks still
    carry the list, only without AppStream descriptions."""
    try:
        import interp
        interp.ensure("yaml")
        import yaml
    except ImportError:
        return []
    found = []
    try:
        with open_catalog(path) as f:
            for doc in yaml.safe_load_all(f):
                if not isinstance(doc, dict):
                    continue
                package = doc.get("Package")
                if isinstance(package, str) and package in wanted:
                    found.append(parse_dep11_component(doc))
    except (OSError, yaml.YAMLError, UnicodeDecodeError):
        return found
    return found


def resolve_icon(comp, catalog_path):
    name = comp.get("icon_cached")
    if name:
        catalog_dir = os.path.dirname(catalog_path)
        candidates = []
        for size in ("128x128", "64x64", "48x48"):
            candidates.append(os.path.join(catalog_dir, "icons", size, name))
            candidates += glob.glob(os.path.join("/usr/share/swcatalog/icons", "*", size, name))
            candidates += glob.glob(os.path.join("/usr/share/app-info/icons", "*", size, name))
            # DEP-11 icons are unpacked from apt's Icons-*.tar.gz into the
            # appstream cache, never next to the catalog itself
            candidates += glob.glob(os.path.join("/var/lib/app-info/icons", "*", size, name))
            candidates += glob.glob(os.path.join("/var/cache/app-info/icons", "*", size, name))
            candidates += glob.glob(os.path.join("/var/lib/swcatalog/icons", "*", size, name))
        for c in candidates:
            if os.path.isfile(c):
                return c
    # Exported / themed icons by component id or stock name
    comp_id = comp.get("id", "")
    stock = comp.get("icon_stock", "")
    for icon_name in filter(None, (comp_id, stock)):
        for base in ("/var/lib/flatpak/exports/share/icons/hicolor",
                     os.path.expanduser("~/.local/share/flatpak/exports/share/icons/hicolor"),
                     "/usr/share/icons/hicolor"):
            for size in ("128x128", "scalable", "64x64", "48x48"):
                for ext in ("png", "svg"):
                    p = os.path.join(base, size, "apps", f"{icon_name}.{ext}")
                    if os.path.isfile(p):
                        return p
    return ""


def resolve_theme_icon(icon_name):
    """Resolve a themed icon name (from a desktop file) to an image path."""
    if not icon_name:
        return ""
    if os.path.isabs(icon_name):
        return icon_name if os.path.isfile(icon_name) else ""
    bases = (
        "/usr/share/icons/hicolor",
        os.path.expanduser("~/.local/share/icons/hicolor"),
        os.path.expanduser("~/.local/share/icons"),
        "/usr/share/pixmaps",
    )
    for base in bases:
        for size in ("128x128", "256x256", "scalable", "64x64", "48x48", ""):
            for ext in ("png", "svg", "xpm"):
                path = os.path.join(base, size, "apps", f"{icon_name}.{ext}") if size else os.path.join(base, f"{icon_name}.{ext}")
                if os.path.isfile(path):
                    return path
    return ""


def icon_for_installed_pkg(pkg_name):
    """Best-effort icon for an installed rpm without AppStream data, via its
    desktop file (e.g. COPR packages like zen-browser)."""
    for candidate in (f"/usr/share/applications/{pkg_name}.desktop",
                      os.path.expanduser(f"~/.local/share/applications/{pkg_name}.desktop")):
        try:
            with open(candidate, errors="replace") as f:
                for line in f:
                    if line.startswith("Icon="):
                        resolved = resolve_theme_icon(line.strip()[5:])
                        if resolved:
                            return resolved
                        break
        except OSError:
            continue
    return resolve_theme_icon(pkg_name)


VERSION_SPLIT = re.compile(r"[^a-zA-Z0-9]+")


def version_key(v):
    v = re.sub(r"^\d+:", "", v or "")  # strip epoch
    parts = []
    for tok in VERSION_SPLIT.split(v):
        if not tok:
            continue
        parts.append((0, int(tok)) if tok.isdigit() else (1, tok))
    return parts


def version_newer(candidate, installed):
    """True if candidate > installed (loose comparison)."""
    if not candidate or not installed:
        return False
    try:
        return version_key(candidate) > version_key(installed)
    except TypeError:
        return False


def scan_catalogs(wanted_rpm, wanted_flatpak):
    """Single pass over all catalogs, picking out wanted components."""
    rpm_found, flatpak_found = {}, {}
    for path in catalog_paths():
        # Entries without a name are stubs (e.g. org.gnome.App-list.xml carries
        # bare ids) — keep looking for a richer component in later catalogs.
        need_rpm = {n for n in wanted_rpm if n not in rpm_found or not rpm_found[n].get("name")}
        need_flat = {n for n in wanted_flatpak if n not in flatpak_found or not flatpak_found[n].get("name")}
        if not need_rpm and not need_flat:
            break
        if path.endswith((".yml", ".yml.gz")):
            # DEP-11: same components, different serialization
            for comp in scan_yaml_catalog(path, need_rpm):
                pkg = comp["pkgname"]
                if pkg not in rpm_found or not rpm_found[pkg].get("name"):
                    comp["icon"] = resolve_icon(comp, path)
                    rpm_found[pkg] = comp
            continue
        try:
            with open_catalog(path) as f:
                for _, elem in ET.iterparse(f, events=("end",)):
                    if localname(elem.tag) != "component":
                        continue
                    cid = text_no_lang(elem, "id")
                    pkg = text_no_lang(elem, "pkgname")
                    cid_base = re.sub(r"\.desktop$", "", cid)
                    hit_rpm = pkg in need_rpm
                    hit_flat = cid in need_flat or cid_base in need_flat
                    if hit_rpm or hit_flat:
                        comp = parse_component(elem)
                        comp["icon"] = resolve_icon(comp, path)
                        if hit_rpm and (pkg not in rpm_found or not rpm_found[pkg].get("name")):
                            rpm_found[pkg] = comp
                        if hit_flat:
                            key = cid if cid in need_flat else cid_base
                            if key not in flatpak_found or not flatpak_found[key].get("name"):
                                flatpak_found[key] = comp
                    elem.clear()
        except (OSError, ET.ParseError):
            continue
    return rpm_found, flatpak_found


def dnf_fallback(names):
    """Batch-resolve homepage/summary for rpm packages via dnf repoquery (cache only)."""
    if not names:
        return {}
    out = {}
    try:
        res = subprocess.run(
            ["dnf", "-Cq", "repoquery", "--qf", "%{name}\t%{url}\t%{summary}\n"] + sorted(names),
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "LC_ALL": "C"})
        for line in res.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) >= 3 and fields[0]:
                out[fields[0]] = {"homepage": fields[1].strip(), "summary": fields[2].strip()}
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def read_dnf_holds():
    """Collect package holds: excludepkgs globs and versionlock entries."""
    excludes = []
    locked = []
    conf_paths = ["/etc/dnf/dnf.conf"] + glob.glob("/etc/dnf/libdnf5.conf.d/*.conf")
    for path in conf_paths:
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*(excludepkgs|exclude)\s*=\s*(.+)", line)
                    if m:
                        excludes += [t for t in re.split(r"[,\s]+", m.group(2).strip()) if t]
        except OSError:
            continue
    try:
        with open("/etc/dnf/versionlock.toml") as f:
            for line in f:
                m = re.match(r"\s*name\s*=\s*\"([^\"]+)\"", line)
                if m:
                    locked.append(m.group(1))
    except OSError:
        pass
    return excludes, locked


def source_names(names):
    """pkgname -> source package name via dnf repoquery (cache only)."""
    if not names:
        return {}
    out = {}
    try:
        res = subprocess.run(
            ["dnf", "-Cq", "repoquery", "--qf", "%{name}\t%{source_name}\n"] + sorted(set(names)),
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "LC_ALL": "C"})
        for line in res.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) >= 2 and fields[0]:
                out[fields[0]] = fields[1].strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def compute_holds(rpm_names):
    """Return {pkgname: reason} for packages held back by dnf config.

    A package is held when its name matches an exclude glob or versionlock
    entry, or when it is built from the same source package as a locked
    package (locking freerdp effectively holds freerdp-libs/libwinpr too).
    """
    if BACKEND != "dnf":
        held_all = pkg_backend.holds()
        return {name: held_all[name] for name in rpm_names if name in held_all}
    import fnmatch
    excludes, locked = read_dnf_holds()
    if not excludes and not locked:
        return {}
    srcs = source_names(list(rpm_names) + locked)
    locked_sources = {srcs.get(name, name) for name in locked}
    held = {}
    for name in rpm_names:
        if name in locked:
            held[name] = "versionlock"
        elif any(fnmatch.fnmatch(name, pat) for pat in excludes):
            held[name] = "excluded"
        elif srcs.get(name) in locked_sources:
            held[name] = "versionlock (via " + srcs.get(name, "?") + ")"
    return held


def comp_to_info(comp, installed_version):
    releases = []
    for rel in comp.get("releases", []):
        releases.append({**rel, "newer": version_newer(rel.get("version"), installed_version)})
    return {
        "name": comp.get("name", ""),
        "summary": comp.get("summary", ""),
        "developer": comp.get("developer", ""),
        "homepage": comp.get("homepage", ""),
        "icon": comp.get("icon", ""),
        "releases": releases,
    }


def strip_arch(name):
    return re.sub(r"\.(x86_64|i686|noarch|aarch64|armv7hl|ppc64le|s390x)$", "", name)


def run_changelog(pkg):
    if BACKEND != "dnf":
        print(pkg_backend.changelog(strip_arch(pkg)))
        return
    try:
        res = subprocess.run(
            ["dnf", "-Cq", "repoquery", "--changelogs", "--available", "--latest-limit=1", strip_arch(pkg)],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "LC_ALL": "C"})
        text = res.stdout.strip()
        if not text:
            res = subprocess.run(
                ["rpm", "-q", "--changelog", strip_arch(pkg)],
                capture_output=True, text=True, timeout=30,
                env={**os.environ, "LC_ALL": "C"})
            text = res.stdout.strip()
        # Keep only the first few entries ("* <date> <author>" headers)
        entries = re.split(r"\n(?=\* )", text)
        print("\n\n".join(entries[:4]))
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"(changelog unavailable: {exc})", file=sys.stderr)
        sys.exit(1)


# ── Release notes for packages built from git ──────────────────────────────
# A package from a *-git copr or an AUR -git PKGBUILD has no release to
# describe: its version is a commit count and a short hash, so AppStream
# carries no <release> for it and the rpm changelog records only the rebuild.
# Upstream does know, and the package manager already knows where upstream
# lives (the rpm URL field), so ask the forge for what the distro cannot say:
# the notes of the release being installed, or the commits between the two
# snapshots when both sides are builds of a branch.

GITNOTES_CACHE = os.path.join(CACHE_DIR, "gitnotes-cache.json")
GITNOTES_MAX_COMMITS = 40
GITNOTES_MAX_CHARS = 6000

# "0.0.git.4350.3f6cd0b5" (copr), "1.2^git20260808.abc1234" (Fedora snapshot
# convention), "2.0.0.r1234.abc1234" (AUR -git)
GIT_MARKER_RE = re.compile(r"(?:^|[.^~+_-])(?:git|r\d+\.)", re.I)
# A hash never gets confused with the commit count or date stamp beside it:
# all-digit tokens are rejected below, not matched loosely here.
HASH_RE = re.compile(r"(?<![0-9a-z])([0-9a-f]{7,40})(?![0-9a-z])", re.I)


def evr_version(evr):
    """Version part of an EVR — no epoch, no release."""
    v = re.sub(r"^\d+:", "", (evr or "").strip())
    return v.rsplit("-", 1)[0] if "-" in v else v


def snapshot_hash(version):
    """Short commit hash of a git-snapshot version, "" for a real release."""
    if not version or not GIT_MARKER_RE.search(version):
        return ""
    found = ""
    for match in HASH_RE.finditer(version):
        token = match.group(1)
        # 4350 is the commit count, 20260808 the date it was built; neither
        # is the commit, and a hash that happens to be all digits is rarer
        # than the two things it would be mistaken for
        if token.isdigit():
            continue
        found = token.lower()
    return found


def github_repo(url):
    """"owner/repo" for a GitHub URL, "" for anything else."""
    match = re.match(r"https?://(?:www\.)?github\.com/([^/\s]+)/([^/\s#?]+)", (url or "").strip())
    if not match:
        return ""
    return match.group(1) + "/" + re.sub(r"\.git$", "", match.group(2))


def package_url(name):
    """Upstream URL the package manager records, available build first."""
    if BACKEND != "dnf":
        return (pkg_backend.package_info(name) or {}).get("homepage", "")
    url = dnf_fallback({name}).get(name, {}).get("homepage", "")
    if url:
        return url
    # Dropped from every enabled repo but still installed
    try:
        res = subprocess.run(["rpm", "-q", "--qf", "%{url}", name],
                             capture_output=True, text=True, timeout=15,
                             env={**os.environ, "LC_ALL": "C"})
        return res.stdout.strip() if res.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def markdown_inline(text):
    """Inline marks of a release body, on text that is escaped first.

    Links keep their words and lose their target, and embedded HTML is
    dropped before the escape rather than shown as its own source: these
    notes are written by whoever owns the repository, and the same rule holds
    as for AppStream — no upstream markup reaches the Qt renderer intact.
    """
    import html as htmlmod
    stripped = re.sub(r"</?[a-zA-Z][^>]*>", "", text)
    out = htmlmod.escape(stripped)
    out = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", out)
    out = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"(?<![\w*])\*([^*]+)\*(?![\w*])", r"<i>\1</i>", out)
    out = re.sub(r"(?<!\w)_([^_]+)_(?!\w)", r"<i>\1</i>", out)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    return out.strip()


def markdown_notes_html(md, limit=GITNOTES_MAX_CHARS):
    """Reduce a release body to the safe HTML subset, cut to a popup's worth.

    Returns (html, dropped_blocks): a body that runs to several screens is
    truncated at a block boundary rather than mid-sentence, and the caller
    says so instead of pretending that was all of it.
    """
    import html as htmlmod
    blocks = []
    para, items, code = [], [], []
    fenced = False

    def flush_para():
        if para:
            blocks.append("<p>" + markdown_inline(" ".join(para)) + "</p>")
            para.clear()

    def flush():
        flush_para()
        if items:
            blocks.append("<ul>" + "".join("<li>" + i + "</li>" for i in items) + "</ul>")
            items.clear()
        if code:
            blocks.append("<p><code>" + "<br>".join(htmlmod.escape(c) for c in code) + "</code></p>")
            code.clear()

    for raw in (md or "").replace("\r\n", "\n").split("\n"):
        line = raw.strip()
        if line.startswith("```") or line.startswith("~~~"):
            flush()
            fenced = not fenced
            continue
        if fenced:
            code.append(raw.rstrip())
            continue
        # A quote is content; its markers are not. GitHub's alert syntax
        # ("> [!NOTE]") names the box it would have been drawn in.
        while line.startswith(">"):
            line = line[1:].strip()
        alert = re.match(r"\[!(\w+)\]\s*(.*)", line)
        if alert:
            rest = alert.group(2).strip()
            line = alert.group(1).capitalize() + ":" + (" " + rest if rest else "")
        if not line:
            flush()
            continue
        # A table loses its columns in a one-column popup and reads as a row
        # of pipes; the prose around it carries the same news
        if line.startswith("|"):
            flush_para()
            continue
        if re.fullmatch(r"[-=*_ ]{3,}", line):
            continue  # horizontal rule or setext underline
        heading = re.match(r"#{1,6}\s+(.*)", line)
        if heading:
            flush()
            blocks.append("<p><b>" + markdown_inline(heading.group(1)) + "</b></p>")
            continue
        bullet = re.match(r"(?:[-*+]|\d+[.)])\s+(.*)", line)
        if bullet:
            flush_para()
            items.append(markdown_inline(bullet.group(1)))
            continue
        if items:
            items[-1] += " " + markdown_inline(line)
        else:
            para.append(line)
    flush()

    blocks = [b for b in blocks if re.sub(r"<[^>]+>", "", b).strip()]

    kept, total = [], 0
    for block in blocks:
        if total and total + len(block) > limit:
            return "".join(kept), len(blocks) - len(kept)
        kept.append(block)
        total += len(block)
    return "".join(kept), 0


def github_commits(repo, old, new):
    """Commits between two snapshot builds, newest first."""
    data = _http_json(f"https://api.github.com/repos/{repo}/compare/{old}...{new}", timeout=20)
    subjects = []
    for commit in reversed(data.get("commits") or []):
        subject = ((commit.get("commit") or {}).get("message") or "").split("\n")[0].strip()
        # A merge commit names the pull request whose commits are listed
        # right below it — the same change, twice
        if subject and not subject.startswith("Merge "):
            subjects.append(subject)
    if not subjects:
        return {"kind": "", "error": "no commits"}
    total = data.get("total_commits") or len(subjects)
    shown = subjects[:GITNOTES_MAX_COMMITS]
    date = 0
    if data.get("commits"):
        author = ((data["commits"][-1].get("commit") or {}).get("author") or {})
        date = normalize_date(author.get("date", ""))
    import html as htmlmod
    return {
        "kind": "commits",
        "commitCount": total,
        "more": max(0, total - len(shown)),
        "url": data.get("html_url") or f"https://github.com/{repo}/compare/{old}...{new}",
        "releases": [{
            "version": new,
            "date": date,
            "notesHtml": "<ul>" + "".join("<li>" + htmlmod.escape(s) + "</li>" for s in shown) + "</ul>",
            "newer": True,
        }],
    }


def tag_version(tag):
    return re.sub(r"^v(?=\d)", "", (tag or "").strip())


def tags_match(tag, version):
    """Same release, allowing for a tag and a package version that disagree
    about trailing zeros (tag v26.04.0 packaged as 26.04)."""
    if not tag or not version:
        return False
    return tag == version or tag.startswith(version + ".") or version.startswith(tag + ".")


def github_releases(repo, from_version, to_version):
    """Published notes for the release being installed, plus any release
    skipped between the two versions."""
    data = _http_json(f"https://api.github.com/repos/{repo}/releases?per_page=30", timeout=20)
    if not isinstance(data, list):
        return {"kind": "", "error": "no releases"}
    published = [r for r in data if not r.get("draft")]
    target = evr_version(to_version)
    previous = "" if snapshot_hash(evr_version(from_version)) else evr_version(from_version)

    wanted = []
    for rel in published:
        tag = tag_version(rel.get("tag_name") or "")
        if tags_match(tag, target):
            wanted.append(rel)
        elif previous and version_newer(tag, previous) and not version_newer(tag, target):
            # A version skipped along the way: its fixes are being installed
            # too, and they are the ones nobody has read
            wanted.append(rel)
    if not wanted:
        return {"kind": "", "error": "no release matching " + target}

    wanted.sort(key=lambda r: version_key(tag_version(r.get("tag_name") or "")), reverse=True)
    releases, dropped = [], 0
    for rel in wanted[:MAX_RELEASES]:
        notes, more = markdown_notes_html(rel.get("body") or "")
        dropped += more
        releases.append({
            "version": tag_version(rel.get("tag_name") or ""),
            "date": normalize_date(rel.get("published_at") or ""),
            "notesHtml": notes,
            "newer": True,
        })
    return {
        "kind": "release",
        "more": dropped,
        "url": wanted[0].get("html_url") or f"https://github.com/{repo}/releases",
        "releases": releases,
    }


def run_gitnotes(pkg, from_evr, to_evr):
    """enrich.py --gitnotes <pkg> <from-evr> <to-evr> → notes from the forge."""
    import time
    name = strip_arch(pkg)
    from_version = evr_version(from_evr)
    to_version = evr_version(to_evr)
    empty = {"kind": "", "repo": "", "url": "", "releases": [], "more": 0}

    # Only packages that actually track a branch pay for a network round trip
    if not snapshot_hash(from_version) and not snapshot_hash(to_version):
        json.dump({**empty, "error": "not a git build"}, sys.stdout)
        return

    key = "|".join((name, from_evr or "", to_evr or ""))
    cache = _load_daily_cache(GITNOTES_CACHE)
    if key in cache["data"]:
        json.dump(cache["data"][key], sys.stdout)
        return

    repo = github_repo(package_url(name))
    if not repo:
        json.dump({**empty, "error": "no GitHub repository for " + name}, sys.stdout)
        return

    try:
        to_hash = snapshot_hash(to_version)
        if to_hash:
            from_hash = snapshot_hash(from_version)
            out = (github_commits(repo, from_hash, to_hash) if from_hash
                   else {"kind": "", "error": "no commit to compare from"})
        else:
            out = github_releases(repo, from_version, to_version)
    except Exception as exc:
        # Rate limit, no network, a repository that moved and no longer
        # answers: the changelog below still shows, so say nothing loudly
        json.dump({**empty, "repo": repo, "error": str(exc)}, sys.stdout)
        return

    out = {**empty, **out, "repo": repo}
    if not cache["ts"]:
        cache["ts"] = time.time()
    cache["data"][key] = out
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(GITNOTES_CACHE, "w") as f:
            json.dump(cache, f)
    except OSError:
        pass
    json.dump(out, sys.stdout)


APPSTREAM_MAX_AGE = 24 * 3600


def refresh_appstream_if_stale():
    """Kick off a flatpak appstream refresh when catalogs are older than a day.

    Runs detached: the enrichment response must never wait on the network
    (that showed as icons appearing a minute late after a fresh boot) —
    refreshed catalogs are simply picked up by the next call."""
    stamps = []
    for base in ("/var/lib/flatpak/appstream", os.path.expanduser("~/.local/share/flatpak/appstream")):
        for p in glob.glob(os.path.join(base, "*", "*", "active", "appstream.xml.gz")):
            try:
                stamps.append(os.stat(p).st_mtime)
            except OSError:
                pass
    import time
    if stamps and time.time() - max(stamps) < APPSTREAM_MAX_AGE:
        return
    stamp = os.path.join(CACHE_DIR, "appstream-refresh.stamp")
    try:
        if time.time() - os.stat(stamp).st_mtime < 3600:
            return
    except OSError:
        pass
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(stamp, "w"):
            pass
        subprocess.Popen(["flatpak", "update", "--appstream"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        pass


SEARCH_INDEX_FILE = os.path.join(CACHE_DIR, "search-index.json")
ODRS_CACHE_FILE = os.path.join(CACHE_DIR, "odrs-ratings.json")
ODRS_URL = "https://odrs.gnome.org/1.0/reviews/api/ratings"
ODRS_MAX_AGE = 24 * 3600

FLATHUB_INSTALLS_CACHE = os.path.join(CACHE_DIR, "flathub-installs.json")
FLATHUB_INSTALLS_URL = "https://flathub.org/api/v2/collection/popular?page=1&per_page=1000"
FLATHUB_INSTALLS_MAX_AGE = 24 * 3600


def catalog_source(path):
    """Human source label for a catalog path."""
    if "/flatpak/appstream/" in path:
        parts = path.split("/flatpak/appstream/")[1].split("/")
        return parts[0] if parts else "flatpak"
    return "fedora"


SEARCH_INDEX_VERSION = 4


def build_search_index(paths, fp):
    try:
        with open(SEARCH_INDEX_FILE) as f:
            cached = json.load(f)
        if cached.get("fingerprint") == fp and cached.get("version") == SEARCH_INDEX_VERSION:
            return cached["entries"]
    except (OSError, ValueError):
        pass

    entries = []
    for path in paths:
        source = catalog_source(path)
        try:
            with open_catalog(path) as f:
                for _, elem in ET.iterparse(f, events=("end",)):
                    if localname(elem.tag) != "component":
                        continue
                    ctype = elem.attrib.get("type", "")
                    if ctype not in ("desktop", "desktop-application", "console-application", ""):
                        elem.clear()
                        continue
                    cid = re.sub(r"\.desktop$", "", text_no_lang(elem, "id"))
                    name = text_locale(elem, "name")
                    if not cid or not name:
                        elem.clear()
                        continue
                    comp = {
                        "id": cid,
                        "name": name,
                        "name_en": text_no_lang(elem, "name"),
                        "summary": text_locale(elem, "summary"),
                        "summary_en": text_no_lang(elem, "summary"),
                        "pkgname": text_no_lang(elem, "pkgname"),
                        "source": source,
                    }
                    for child in elem:
                        tag = localname(child.tag)
                        if tag == "url" and child.attrib.get("type") == "homepage":
                            comp["homepage"] = (child.text or "").strip()
                        elif tag == "icon" and child.attrib.get("type") == "cached" and "icon_cached" not in comp:
                            comp["icon_cached"] = (child.text or "").strip()
                        elif tag == "categories":
                            comp["categories"] = [(c.text or "").strip() for c in child if localname(c.tag) == "category" and c.text]
                        elif tag == "releases":
                            latest = 0
                            for rel in child:
                                if localname(rel.tag) == "release":
                                    latest = max(latest, normalize_date(rel.attrib.get("timestamp", "") or rel.attrib.get("date", "")))
                            if latest:
                                comp["updated"] = latest
                    comp["icon"] = resolve_icon({
                        "id": cid,
                        "icon_cached": comp.pop("icon_cached", ""),
                        "icon_stock": ""
                    }, path)
                    entries.append(comp)
                    elem.clear()
        except (OSError, ET.ParseError):
            continue
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(SEARCH_INDEX_FILE, "w") as f:
            json.dump({"fingerprint": fp, "version": SEARCH_INDEX_VERSION, "entries": entries}, f)
    except OSError:
        pass
    return entries


def load_odrs_ratings():
    """Star ratings from the Open Desktop Ratings Service (cached daily)."""
    import time
    try:
        st = os.stat(ODRS_CACHE_FILE)
        if time.time() - st.st_mtime < ODRS_MAX_AGE:
            with open(ODRS_CACHE_FILE) as f:
                return json.load(f)
    except (OSError, ValueError):
        pass
    try:
        import urllib.request
        req = urllib.request.Request(ODRS_URL, headers={"User-Agent": "dankSoftwareDepot/0.1"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(ODRS_CACHE_FILE, "w") as f:
            json.dump(data, f)
        return data
    except Exception:
        try:
            with open(ODRS_CACHE_FILE) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}


def load_flathub_installs(refresh=False):
    """Installs over the last month per Flathub app id (cached daily).

    Without `refresh` this never touches the network and never fails: it
    returns whatever is cached, at whatever age, or nothing. The storefront
    reads it that way because it is drawn on the way to a search box, and a
    slow host on the other side of the world is not a reason for a search
    index to be late. Refreshing is somebody else's job, done out of sight.

    One request for the whole storefront rather than one per app: the
    per-app endpoint is a round trip each and a section holds dozens.

    The list is ordered by installs and cut at the top thousand, so an app
    missing from it has fewer installs than every app in it — which is
    exactly what sorting it last says. Absence therefore means "fewer than
    the smallest number here", not "unknown", and it is only a real unknown
    for software Flathub does not carry at all: an rpm with no Flatpak of
    the same name has no download figure anywhere, and sorts last.
    """
    import time
    try:
        st = os.stat(FLATHUB_INSTALLS_CACHE)
        if refresh is False or time.time() - st.st_mtime < FLATHUB_INSTALLS_MAX_AGE:
            with open(FLATHUB_INSTALLS_CACHE) as f:
                return json.load(f)
    except (OSError, ValueError):
        pass
    if not refresh:
        return {}
    try:
        import urllib.request
        req = urllib.request.Request(FLATHUB_INSTALLS_URL,
                                     headers={"User-Agent": "dankSoftwareDepot/0.1"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
        installs = {}
        for hit in data.get("hits") or []:
            app_id = hit.get("app_id")
            count = hit.get("installs_last_month")
            if app_id and isinstance(count, int):
                installs[app_id] = count
        # A response that parsed but carried nothing is a shape change, not an
        # empty storefront: keep whatever is on disk rather than caching it away
        if not installs:
            raise ValueError("no installs in response")
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(FLATHUB_INSTALLS_CACHE, "w") as f:
            json.dump(installs, f)
        return installs
    except Exception:
        try:
            with open(FLATHUB_INSTALLS_CACHE) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}


def run_flathub_installs():
    """Refresh the download figures and hand them straight to the caller.

    Printing what it fetched rather than only writing the cache is what makes
    the first run right: the index is already built and on screen by the time
    this returns, and a storefront that had to be rebuilt to learn its own
    order would reshuffle itself under the reader.
    """
    json.dump(load_flathub_installs(refresh=True), sys.stdout)


def installs_for(installs, sources):
    """Downloads last month for whichever of an app's sources Flathub knows."""
    best = 0
    for source in sources:
        if source.get("kind") == "flatpak":
            best = max(best, installs.get(source.get("ref"), 0))
    return best


def rating_for(ratings, cid):
    entry = ratings.get(cid) or ratings.get(cid + ".desktop")
    if not entry:
        return None
    total = sum(entry.get("star%d" % i, 0) for i in range(6))
    if total == 0:
        return None
    score = sum(entry.get("star%d" % i, 0) * i for i in range(6)) / total
    return {"stars": round(score, 1), "count": total}


def dnf_name_search(query):
    """Match rpm packages by name via cache-only repoquery.

    Covers command-line tools without AppStream metadata (e.g. playerctl)
    that `dnf search` finds but the catalog index does not."""
    if BACKEND != "dnf":
        return pkg_backend.name_search(query)
    if not re.match(r"^[\w.+-]+$", query):
        return []
    try:
        res = subprocess.run(
            ["dnf", "-Cq", "repoquery", "--qf", "%{name}\t%{url}\t%{summary}\n", f"*{query}*"],
            capture_output=True, text=True, timeout=20,
            env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return []
    seen = {}
    for line in res.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 3 or not fields[0]:
            continue
        name = fields[0]
        if re.search(r"-(debuginfo|debugsource)$", name):
            continue
        seen[name] = {"name": name, "homepage": fields[1].strip(), "summary": fields[2].strip()}
    return list(seen.values())


def run_search(query):
    paths = catalog_paths()
    fp = fingerprint(paths)
    entries = build_search_index(paths, fp)
    needle = query.lower()

    def score(entry):
        name = entry["name"].lower()
        cid = entry["id"].lower()
        if name == needle or cid == needle:
            return 0
        if name.startswith(needle):
            return 1
        if needle in name or needle in cid or needle in entry.get("pkgname", "").lower():
            return 2
        if needle in entry.get("summary", "").lower():
            return 3
        return -1

    merged = {}
    for entry in entries:
        s = score(entry)
        if s < 0:
            continue
        cid = entry["id"].lower()
        if cid not in merged:
            merged[cid] = {
                "id": entry["id"],
                "name": entry["name"],
                "summary": entry.get("summary", ""),
                "homepage": entry.get("homepage", ""),
                "icon": entry.get("icon", ""),
                "updated": entry.get("updated", 0),
                "score": s,
                "sources": [],
            }
        item = merged[cid]
        item["score"] = min(item["score"], s)
        item["updated"] = max(item.get("updated", 0), entry.get("updated", 0))
        if not item["icon"] and entry.get("icon"):
            item["icon"] = entry["icon"]
        source = entry["source"]
        kind = "dnf" if source == "fedora" else "flatpak"
        ref = entry.get("pkgname") if kind == "dnf" else entry["id"]
        if ref and not any(s_["source"] == source for s_ in item["sources"]):
            item["sources"].append({"source": source, "kind": kind, "ref": ref})

    covered = {s_["ref"] for item in merged.values() for s_ in item["sources"] if s_["kind"] == "dnf"}
    for pkg in dnf_name_search(query):
        if pkg["name"] in covered or ("pkg:" + pkg["name"].lower()) in merged:
            continue
        lower = pkg["name"].lower()
        merged["pkg:" + lower] = {
            "id": pkg["name"],
            "name": pkg["name"],
            "summary": pkg["summary"],
            "homepage": pkg["homepage"],
            "icon": "",
            "updated": 0,
            "score": 0 if lower == needle else (1 if lower.startswith(needle) else 2),
            "sources": [{"source": "fedora", "kind": "dnf", "ref": pkg["name"]}],
        }

    ratings = load_odrs_ratings()
    results = []
    for item in merged.values():
        if not item["sources"]:
            continue
        item["rating"] = rating_for(ratings, item["id"])
        results.append(item)
    results.sort(key=lambda r: (r["score"], -(r["rating"]["count"] if r["rating"] else 0), r["name"].lower()))
    json.dump(results[:40], sys.stdout)


APPINFO_CACHE_FILE = os.path.join(CACHE_DIR, "appinfo-cache.json")
REVIEWS_URL = "https://odrs.gnome.org/1.0/reviews/api/fetch"


FORCED_LANG_FILE = "dsd-lang"


def forced_lang():
    """A language the window is being shown in regardless of the locale —
    English while the screenshots are made. The window writes it to the
    runtime dir rather than into every helper's environment: it starts a
    dozen kinds of helper from as many places, and a file is gone after a
    reboot even if the window never got to remove it."""
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid(), FORCED_LANG_FILE)
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def locale_langs():
    """Preferred description languages from the active locale, most specific
    first — e.g. ["nl_NL", "nl"]. English (untranslated) is the fallback."""
    lang = (forced_lang() or os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or "").split(".")[0]
    if not lang or lang.lower() in ("c", "posix") or lang.startswith("en"):
        return []
    langs = [lang]
    if "_" in lang:
        langs.append(lang.split("_")[0])
    return langs


def child_lang(child):
    for key, value in child.attrib.items():
        if key.endswith("lang"):
            return value
    return ""


def find_component_details(app_id):
    """Full component details (description, screenshots, developer, license)
    for one AppStream id, scanned from all catalogs. Descriptions prefer the
    active locale, falling back to the untranslated (English) text."""
    target = re.sub(r"\.desktop$", "", app_id).lower()
    langs = locale_langs()
    result = {}
    desc_rank = 99  # lower is better: 0.. = locale match, 50 = untranslated
    for path in catalog_paths():
        found_here = False
        try:
            with open_catalog(path) as f:
                for _, elem in ET.iterparse(f, events=("end",)):
                    if localname(elem.tag) != "component":
                        continue
                    cid = re.sub(r"\.desktop$", "", text_no_lang(elem, "id")).lower()
                    if cid != target:
                        elem.clear()
                        continue
                    for child in elem:
                        tag = localname(child.tag)
                        has_lang = any(k.endswith("lang") for k in child.attrib)
                        if tag == "description":
                            lang = child_lang(child)
                            rank = langs.index(lang) if lang in langs else (50 if lang == "" else 99)
                            if rank < desc_rank:
                                html = description_html(child)
                                if html:
                                    result["descriptionHtml"] = html
                                    desc_rank = rank
                        elif tag == "project_license" and not result.get("license"):
                            result["license"] = (child.text or "").strip()
                        elif tag == "developer_name" and not has_lang and not result.get("developer"):
                            result["developer"] = (child.text or "").strip()
                        elif tag == "developer" and not result.get("developer"):
                            result["developer"] = text_no_lang(child, "name")
                        elif tag == "screenshots" and not result.get("screenshots"):
                            shots = []
                            for shot in child:
                                if localname(shot.tag) != "screenshot":
                                    continue
                                best = ""
                                source_url = ""
                                for image in shot:
                                    if localname(image.tag) != "image":
                                        continue
                                    url = (image.text or "").strip()
                                    if not url.startswith("http"):
                                        continue
                                    itype = image.attrib.get("type", "")
                                    width = image.attrib.get("width", "")
                                    if itype == "source":
                                        source_url = url
                                    elif width in ("624", "752"):
                                        best = best or url
                                if best or source_url:
                                    shots.append(best or source_url)
                            if shots:
                                result["screenshots"] = shots[:8]
                    found_here = True
                    elem.clear()
                    break
        except (OSError, ET.ParseError):
            continue
        if found_here and result.get("descriptionHtml") and result.get("screenshots"):
            break
    return result


SCREENSHOT_CACHE_DIR = os.path.join(CACHE_DIR, "screenshots")
SCREENSHOT_MAX_AGE = 30 * 24 * 3600


def cache_screenshots(urls):
    """Download screenshot images into the local cache and return file paths.

    Files are kept for 30 days (well beyond the 24h appinfo cache), so
    reopening a popup never re-downloads images. Failed downloads fall back
    to the remote URL."""
    import time
    import hashlib
    from concurrent.futures import ThreadPoolExecutor
    try:
        os.makedirs(SCREENSHOT_CACHE_DIR, exist_ok=True)
        now = time.time()
        for name in os.listdir(SCREENSHOT_CACHE_DIR):
            path = os.path.join(SCREENSHOT_CACHE_DIR, name)
            try:
                if now - os.stat(path).st_mtime > SCREENSHOT_MAX_AGE:
                    os.unlink(path)
            except OSError:
                pass
    except OSError:
        return urls

    def fetch(url):
        ext = os.path.splitext(url.split("?")[0])[1][:5] or ".img"
        path = os.path.join(SCREENSHOT_CACHE_DIR, hashlib.sha1(url.encode()).hexdigest() + ext)
        if os.path.exists(path):
            return path
        try:
            import urllib.request
            req = urllib.request.Request(url, headers={"User-Agent": "dankSoftwareDepot/0.1"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
            return path
        except Exception:
            return url

    with ThreadPoolExecutor(max_workers=4) as pool:
        return list(pool.map(fetch, urls))


def repo_origin(repo):
    """Who stands behind the repository an rpm comes out of.

    "updates" is the distribution and "rpmfusion-nonfree" is not, and a Copr
    is one person. The package manager is the same command for all three,
    which is exactly why the difference has to be written down somewhere.

    Returns a kind and, where there is one, the name to show after it. The
    distribution's own name is not decided here: the app already knows what
    to call it, and it is not the same word on Debian.
    """
    name = (repo or "").strip()
    if not name:
        return {"origin": "distro"}
    lowered = name.lower()
    if lowered.startswith("copr:"):
        # copr:copr.fedorainfracloud.org:owner:project
        parts = name.split(":")
        return {"origin": "copr", "detail": "/".join(parts[-2:]) if len(parts) >= 3 else ""}
    if lowered in ("updates", "fedora", "updates-testing", "rawhide", "koji",
                   "stable", "main", "core", "extra", "testing", "@system",
                   "anaconda", "updates-archive"):
        return {"origin": "distro"}
    if lowered.startswith("rpmfusion"):
        return {"origin": "third-party", "detail": "RPM Fusion " + name.split("-", 1)[-1]}
    return {"origin": "third-party", "detail": name}


def rpm_repoquery_info(pkg):
    """Description, license and sizes for an rpm via cache-only repoquery."""
    if BACKEND != "dnf":
        return pkg_backend.package_info(pkg)
    try:
        res = subprocess.run(
            ["dnf", "-Cq", "repoquery", "--info", "--latest-limit=1", "--arch=x86_64,noarch", pkg],
            capture_output=True, text=True, timeout=25,
            env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return {}
    import html as htmlmod
    out = {}
    desc_lines = []
    in_desc = False
    for line in res.stdout.splitlines():
        m = re.match(r"^([A-Z][A-Za-z ]+?)\s*:\s*(.*)$", line)
        if m:
            field, value = m.group(1).strip(), m.group(2).strip()
            in_desc = field == "Description"
            if in_desc:
                desc_lines.append(value)
            elif field == "License":
                out["license"] = value
            elif field == "Download size":
                out["download"] = value
            elif field == "Installed size":
                out["installed"] = value
            elif field == "Version":
                out["version"] = value
            elif field == "Release":
                out["release"] = value
            elif field == "Repository":
                # Which repository, not just which package manager: "updates"
                # and "rpmfusion-nonfree" are the same command and a different
                # amount of trust
                out["repo"] = value
        elif in_desc and re.match(r"^\s*:\s?", line):
            desc_lines.append(re.sub(r"^\s*:\s?", "", line))
    if desc_lines:
        out["descriptionHtml"] = "<p>" + htmlmod.escape(" ".join(desc_lines)) + "</p>"
    return out


def flatpak_remote_sizes(remote, ref):
    """Size, version and build date from flatpak remote metadata."""
    try:
        res = subprocess.run(
            ["flatpak", "remote-info", remote, ref],
            capture_output=True, text=True, timeout=20,
            env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return {}
    out = {}
    for line in res.stdout.splitlines():
        m = re.match(r"^\s*(Download|Installed):?\s*(?:Size:?\s*)?(.+)$", line.replace("Download Size", "Download").replace("Installed Size", "Installed"))
        if m:
            out[m.group(1).lower()] = m.group(2).strip()
            continue
        m = re.match(r"^\s*(Version|Date|Branch)\s*:\s*(.+)$", line)
        if m:
            out[m.group(1).lower()] = m.group(2).strip()
    return out


def fetch_flathub_stats(app_ref):
    """Install statistics from the Flathub API (installs/month etc.)."""
    try:
        import urllib.request
        req = urllib.request.Request("https://flathub.org/api/v2/stats/" + app_ref,
                                     headers={"User-Agent": "dankSoftwareDepot/0.1"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.load(resp)
    except Exception:
        return None
    out = {}
    for src, dst in (("installs_total", "total"), ("installs_last_month", "month"), ("installs_last_7_days", "week")):
        if isinstance(data.get(src), int):
            out[dst] = data[src]
    return out or None


def fetch_reviews(app_id):
    """Review texts from the Open Desktop Ratings Service (cached daily)."""
    import time
    import hashlib
    cache_file = os.path.join(CACHE_DIR, "reviews-cache.json")
    try:
        with open(cache_file) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    key = app_id.lower()
    entry = cache.get(key)
    if entry and time.time() - entry.get("ts", 0) < ODRS_MAX_AGE:
        return entry["reviews"]

    def query(odrs_id):
        body = {
            "user_hash": hashlib.sha1(b"dankSoftwareDepot").hexdigest(),
            "app_id": odrs_id,
            "locale": "en",
            "distro": "Fedora",
            "version": "unknown",
            "limit": 50,
        }
        import urllib.request
        req = urllib.request.Request(REVIEWS_URL, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "User-Agent": "dankSoftwareDepot/0.1"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.load(resp)

    reviews = []
    try:
        raw = query(app_id + ".desktop")
        if not any(r.get("description") for r in raw):
            raw = query(app_id)
        for r in raw:
            if not r.get("description") or r.get("reported", 0) >= 2:
                continue
            reviews.append({
                "user": r.get("user_display") or "Anonymous",
                "stars": max(0, min(5, round((r.get("rating") or 0) / 20))),
                "date": int(r.get("date_created") or 0),
                "summary": (r.get("summary") or "").strip(),
                "text": (r.get("description") or "").strip(),
            })
    except Exception:
        return entry["reviews"] if entry else []
    reviews = reviews[:40]
    cache[key] = {"ts": time.time(), "reviews": reviews}
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(cache_file, "w") as f:
            json.dump(cache, f)
    except OSError:
        pass
    return reviews


def run_appinfo(arg):
    """Detail-popup payload: description, screenshots, sizes, reviews.

    Emits NDJSON in up to two lines so the popup renders fast: first the
    local part (description/license, marked {"partial": true}), then the
    full payload once the network extras — fetched in parallel — are in.
    A cache hit emits the full payload as a single line."""
    import time
    from concurrent.futures import ThreadPoolExecutor
    try:
        request = json.loads(arg)
    except ValueError:
        print("{}")
        return
    app_id = request.get("id", "")
    sources = request.get("sources", [])
    key = app_id.lower()

    try:
        with open(APPINFO_CACHE_FILE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    entry = cache.get(key)
    loc = ",".join(get_locale_langs())
    if entry and entry.get("v") == 8 and entry.get("loc") == loc and time.time() - entry.get("ts", 0) < ODRS_MAX_AGE:
        json.dump(entry["info"], sys.stdout)
        return

    def safe(fut, default=None):
        try:
            return fut.result()
        except Exception:
            return default

    rpm_ref = next((s["ref"] for s in sources if s.get("kind") == "dnf"), "")
    flathub_ref = next((s["ref"] for s in sources if s.get("kind") == "flatpak"), "")

    pool = ThreadPoolExecutor(max_workers=6)
    rpm_fut = pool.submit(rpm_repoquery_info, rpm_ref) if rpm_ref else None

    # Scanning every AppStream catalog for an id that is not in them is the
    # slowest possible path (several seconds of XML parsing for nothing) —
    # the cached search index knows which ids exist, so skip the scan for
    # plain rpm packages.
    in_catalogs = True
    try:
        paths = catalog_paths()
        known = build_search_index(paths, fingerprint(paths))
        target = re.sub(r"\.desktop$", "", app_id).lower()
        in_catalogs = any(re.sub(r"\.desktop$", "", e["id"]).lower() == target for e in known)
    except Exception:
        pass
    info = find_component_details(app_id) if in_catalogs else {}

    rpm = safe(rpm_fut, {}) if rpm_fut else {}
    if not info.get("descriptionHtml") and rpm.get("descriptionHtml"):
        info["descriptionHtml"] = rpm["descriptionHtml"]
    if not info.get("license") and rpm.get("license"):
        info["license"] = rpm["license"]

    # Local part is complete: let the popup render it now
    info["partial"] = True
    json.dump(info, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
    info.pop("partial", None)

    # Network extras, all in parallel
    shots_fut = pool.submit(cache_screenshots, info["screenshots"]) if info.get("screenshots") else None
    flatpak_size_futs = [(s, pool.submit(flatpak_remote_sizes, s.get("source", "flathub"), s["ref"]))
                         for s in sources if s.get("kind") == "flatpak"]
    stats_fut = pool.submit(fetch_flathub_stats, flathub_ref) if flathub_ref else None
    summary_fut = pool.submit(fetch_flathub_summary, flathub_ref) if flathub_ref else None
    reviews_fut = pool.submit(fetch_reviews, app_id)
    ratings_fut = pool.submit(load_odrs_ratings)

    if shots_fut:
        info["screenshots"] = safe(shots_fut, info.get("screenshots"))
    if flathub_ref:
        info["installStats"] = safe(stats_fut)
        info["flathub"] = safe(summary_fut)

    # ── The same app, offered several ways ───────────────────────────────────
    # Merging the sources into one app is what makes it findable; it also
    # hides the decision. These carry what the choice actually turns on —
    # which version, how big, out of whose hands, and how much of the machine
    # it gets — so the popup can put them side by side instead of leaving
    # "Flathub or Fedora?" as something the reader is expected to already know.
    origins = []
    if rpm_ref:
        version = rpm.get("version", "")
        if version and rpm.get("release"):
            version += "-" + rpm["release"]
        origin = {
            "kind": "dnf",
            "ref": rpm_ref,
            "version": version,
            "download": rpm.get("download", ""),
            "installed": rpm.get("installed", ""),
            # An rpm runs as the machine, whoever built it. Saying so next to
            # a sandbox listing seven permissions is the honest comparison.
            "sandbox": "none",
        }
        origin.update(repo_origin(rpm.get("repo", "")))
        origins.append(origin)
    flathub = info.get("flathub") or {}
    for s, fut in flatpak_size_futs:
        fs = safe(fut, {}) or {}
        remote = s.get("source", "flathub")
        origin = {
            "kind": "flatpak",
            "origin": "remote",
            "detail": remote.capitalize(),
            "ref": s["ref"],
            "version": fs.get("version", ""),
            "download": fs.get("download", ""),
            "installed": fs.get("installed", ""),
            "sandbox": "flatpak",
        }
        if s["ref"] == flathub_ref and flathub:
            origin["permissions"] = len(flathub.get("permissions") or [])
            if flathub.get("verified") is not None:
                origin["verified"] = flathub["verified"]
        origins.append(origin)
    info["origins"] = origins
    info["reviews"] = safe(reviews_fut, [])
    info["rating"] = rating_for(safe(ratings_fut, {}) or {}, app_id)
    pool.shutdown(wait=False)

    cache[key] = {"ts": time.time(), "v": 8, "loc": loc, "info": info}
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(APPINFO_CACHE_FILE, "w") as f:
            json.dump(cache, f)
    except OSError:
        pass
    json.dump(info, sys.stdout)
    sys.stdout.write("\n")


def run_qml_index():
    """Full merged search index for in-QML type-to-filter searching.

    Emits every installable app once (sources merged, ODRS rating and section
    attached) with precomputed lowercase fields so QML can filter instantly
    per keystroke without spawning a process.

    This is also the storefront. Sections used to be a second, shorter payload
    built by a second process, which meant a section could only hold what that
    payload had room for — and searching one could only search what had been
    sent. Cut from the same index, a section is a filter over everything.
    """
    paths = catalog_paths()
    fp = fingerprint(paths)
    entries = build_search_index(paths, fp)
    ratings = load_odrs_ratings()
    merged = {}
    for entry in entries:
        cid = entry["id"].lower()
        if cid not in merged:
            merged[cid] = {
                "id": entry["id"],
                "name": entry["name"],
                "name_en": entry.get("name_en", ""),
                "summary": entry.get("summary", ""),
                "summary_en": entry.get("summary_en", ""),
                "homepage": entry.get("homepage", ""),
                "icon": entry.get("icon", ""),
                "updated": entry.get("updated", 0),
                "sources": [],
                "_cats": set(),
            }
        item = merged[cid]
        item["updated"] = max(item.get("updated", 0), entry.get("updated", 0))
        if not item["icon"] and entry.get("icon"):
            item["icon"] = entry["icon"]
        item["_cats"].update(entry.get("categories", []))
        source = entry["source"]
        kind = "dnf" if source == "fedora" else "flatpak"
        ref = entry.get("pkgname") if kind == "dnf" else entry["id"]
        if ref and not any(s_["source"] == source for s_ in item["sources"]):
            item["sources"].append({"source": source, "kind": kind, "ref": ref})

    out = []
    used_sections = set()
    for item in merged.values():
        if not item["sources"]:
            continue
        item["rating"] = rating_for(ratings, item["id"])
        item["section"] = section_for(item.pop("_cats"))
        used_sections.add(item["section"])
        item["nl"] = item["name"].lower()
        item["ne"] = (item.get("name_en") or "").lower()
        item["il"] = item["id"].lower()
        item["pl"] = " ".join((s_.get("ref") or "").lower() for s_ in item["sources"] if s_["kind"] == "dnf")
        # Searchable summary covers both the locale and the English text
        item["sl"] = ((item.get("summary") or "") + " " + (item.get("summary_en") or "")).lower()
        item.pop("name_en", None)
        item.pop("summary_en", None)
        out.append(item)

    # The order the sections are offered in, decided here because the rule
    # that assigns them lives here. A section nothing landed in is not shown.
    order = [label for label, _ in CATEGORY_GROUPS if label in used_sections]
    if OTHER_SECTION in used_sections:
        order.append(OTHER_SECTION)
    json.dump({"sections": order, "items": out}, sys.stdout)


def run_search_dnf(query):
    """Async extras for the QML search: rpm packages matched by name that
    have no AppStream entry (e.g. playerctl)."""
    needle = query.lower()
    out = []
    for pkg in dnf_name_search(query):
        lower = pkg["name"].lower()
        out.append({
            "id": pkg["name"],
            "name": pkg["name"],
            "summary": pkg["summary"],
            "homepage": pkg["homepage"],
            "icon": icon_for_installed_pkg(pkg["name"]),
            "updated": 0,
            "rating": None,
            "score": 0 if lower == needle else (1 if lower.startswith(needle) else 2),
            "sources": [{"source": "fedora", "kind": "dnf", "ref": pkg["name"]}],
        })
    json.dump(out, sys.stdout)



FLATHUB_SUMMARY_CACHE = os.path.join(CACHE_DIR, "flathub-summary.json")


def _load_daily_cache(path):
    import time
    try:
        with open(path) as f:
            cache = json.load(f)
        if time.time() - cache.get("ts", 0) < 24 * 3600:
            return cache
    except (OSError, ValueError):
        pass
    return {"ts": 0, "data": {}}


def _http_json(url, payload=None, timeout=15):
    import urllib.request
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"User-Agent": "dankSoftwareDepot/0.1"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def fetch_flathub_summary(ref):
    """Sizes, sandbox permissions and verification for a Flathub app (cached daily)."""
    import time
    cache = _load_daily_cache(FLATHUB_SUMMARY_CACHE)
    if ref in cache["data"]:
        return cache["data"][ref]
    out = None
    try:
        summary = _http_json("https://flathub.org/api/v2/summary/" + ref)
        perms = (summary.get("metadata") or {}).get("permissions") or {}
        tokens = []
        for shared in perms.get("shared") or []:
            tokens.append(shared)                      # network, ipc
        for sock in perms.get("sockets") or []:
            tokens.append(sock)                        # wayland, x11, pulseaudio…
        devices = perms.get("devices") or []
        if devices:
            tokens.append("devices:all" if "all" in devices else "devices")
        for fs in perms.get("filesystems") or []:
            tokens.append("fs:" + fs)
        bus = perms.get("session-bus") or {}
        if bus.get("talk"):
            tokens.append("dbus-talk")
        if (perms.get("system-bus") or {}).get("talk"):
            tokens.append("system-dbus")
        out = {
            "downloadSize": summary.get("download_size") or 0,
            "installedSize": summary.get("installed_size") or 0,
            "permissions": tokens,
        }
        try:
            ver = _http_json("https://flathub.org/api/v2/verification/" + ref + "/status")
            out["verified"] = bool(ver.get("verified"))
        except Exception:
            out["verified"] = None
    except Exception:
        out = None
    if not cache["ts"]:
        cache["ts"] = time.time()
    cache["data"][ref] = out
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(FLATHUB_SUMMARY_CACHE, "w") as f:
            json.dump(cache, f)
    except OSError:
        pass
    return out


def parse_human_size(text):
    m = re.match(r"([\d.,]+)\s*([KMGT]i?B|B)?", (text or "").replace(",", "."))
    if not m:
        return 0
    value = float(m.group(1) or 0)
    unit = (m.group(2) or "B").rstrip("B").rstrip("i")
    factor = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}.get(unit, 1)
    return int(value * factor)


def run_update_sizes(arg):
    """Estimated total download size for pending updates.

    Flatpak sizes come from the Flathub summary API (exact), rpm sizes from a
    batched cache-only `dnf repoquery --info`."""
    try:
        request = json.loads(arg)
    except ValueError:
        print("{}")
        return
    flatpak_bytes = 0
    flatpak_known = 0
    flatpak_ids = request.get("flatpak") or []
    for ref in flatpak_ids:
        summary = fetch_flathub_summary(ref)
        if summary and summary.get("downloadSize"):
            flatpak_bytes += summary["downloadSize"]
            flatpak_known += 1
    rpm_bytes = 0
    rpm_known = 0
    rpm_map = {}
    rpm_names = [n for n in (request.get("rpm") or []) if re.match(r"^[\w.+-]+$", n)]
    if rpm_names and BACKEND != "dnf":
        rpm_bytes, rpm_map = pkg_backend.update_sizes(rpm_names)
        rpm_known = len(rpm_map)
    elif rpm_names:
        try:
            res = subprocess.run(
                ["dnf", "-Cq", "repoquery", "--info", "--latest-limit=1", "--arch=x86_64,noarch"] + rpm_names,
                capture_output=True, text=True, timeout=30,
                env={**os.environ, "LC_ALL": "C"})
            current_name = None
            for line in res.stdout.splitlines():
                m = re.match(r"^Name\s*:\s*(\S+)", line)
                if m:
                    current_name = m.group(1)
                    continue
                m = re.match(r"^Download size\s*:\s*(.+)$", line)
                if m:
                    size = parse_human_size(m.group(1))
                    rpm_bytes += size
                    rpm_known += 1
                    if current_name:
                        rpm_map[current_name] = rpm_map.get(current_name, 0) + size
                        current_name = None
        except (OSError, subprocess.SubprocessError):
            pass
    json.dump({
        "flatpakBytes": flatpak_bytes,
        "rpmBytes": rpm_bytes,
        "rpmSizes": rpm_map,
        "totalBytes": flatpak_bytes + rpm_bytes,
        "knownCount": flatpak_known + rpm_known,
        "requestedCount": len(flatpak_ids) + len(rpm_names),
    }, sys.stdout)


DISTRO_UPGRADE_CACHE = os.path.join(CACHE_DIR, "distro-upgrade.json")


def newest_fedora(releases, today):
    """The newest Fedora release that is out by `today` (an ISO date).

    Bodhi lists a release as current from its final freeze on, a week or
    more before it ships, with the day it ships as released_on. Older
    releases have no released_on at all; they are out."""
    versions = []
    for r in releases:
        if r.get("id_prefix") != "FEDORA" or not str(r.get("version", "")).isdigit():
            continue
        released = r.get("released_on")
        if released and str(released)[:10] > today:
            continue
        versions.append(int(r["version"]))
    return max(versions) if versions else 0


def run_distro_upgrade():
    """Is a newer Fedora release available? (Bodhi, cached daily)"""
    if BACKEND != "dnf":
        json.dump({}, sys.stdout)
        return
    import time
    current = 0
    distro = ""
    try:
        with open("/etc/os-release") as f:
            for line in f:
                m = re.match(r"VERSION_ID=\"?(\d+)", line.strip())
                if m:
                    current = int(m.group(1))
                m = re.match(r"ID=\"?([\w.-]+)", line.strip())
                if m:
                    distro = m.group(1)
    except OSError:
        pass
    # RHEL 9 and its rebuilds are dnf systems too, and 9 is less than any
    # Fedora release there will ever be
    if distro != "fedora":
        json.dump({}, sys.stdout)
        return
    cache = _load_daily_cache(DISTRO_UPGRADE_CACHE)
    # "released", not "latest": a cache from before released_on was looked
    # at may hold a release that is not out yet
    latest = cache["data"].get("released")
    if latest is None:
        try:
            data = _http_json("https://bodhi.fedoraproject.org/releases/?state=current&rows_per_page=60", timeout=20)
            latest = newest_fedora(data.get("releases", []), time.strftime("%Y-%m-%d"))
            cache["ts"] = time.time()
            cache["data"]["released"] = latest
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(DISTRO_UPGRADE_CACHE, "w") as f:
                json.dump(cache, f)
        except Exception:
            latest = 0
    json.dump({"current": current, "latest": latest or 0, "available": bool(latest and current and latest > current)}, sys.stdout)


def run_submit_review(arg):
    """Submit a review to the Open Desktop Ratings Service."""
    import hashlib
    try:
        request = json.loads(arg)
    except ValueError:
        json.dump({"ok": False, "error": "bad request"}, sys.stdout)
        return
    try:
        with open("/etc/machine-id") as f:
            machine_id = f.read().strip()
    except OSError:
        machine_id = "unknown"
    user = os.environ.get("USER") or "user"
    user_hash = hashlib.sha1((user + ":" + machine_id).encode()).hexdigest()
    app_id = request.get("app_id", "")
    payload = {
        "user_hash": user_hash,
        "user_skey": hashlib.sha1((user_hash + app_id + ".desktop").encode()).hexdigest(),
        "app_id": app_id + ".desktop",
        "locale": (get_locale_langs() or ["en"])[0],
        "distro": "Fedora",
        "version": request.get("version") or "unknown",
        "user_display": request.get("user_display") or user,
        "summary": (request.get("summary") or "").strip()[:70],
        "description": (request.get("description") or "").strip()[:3000],
        "rating": max(20, min(100, int(request.get("rating", 3)) * 20)),
    }
    try:
        result = _http_json("https://odrs.gnome.org/1.0/reviews/api/submit", payload, timeout=20)
        ok = bool(result.get("success", True)) if isinstance(result, dict) else True
        # Drop the cached reviews for this app so the new one shows up
        try:
            cache_file = os.path.join(CACHE_DIR, "reviews-cache.json")
            with open(cache_file) as f:
                cache = json.load(f)
            cache.pop(app_id.lower(), None)
            with open(cache_file, "w") as f:
                json.dump(cache, f)
        except (OSError, ValueError):
            pass
        json.dump({"ok": ok, "error": (result or {}).get("msg", "") if isinstance(result, dict) else ""}, sys.stdout)
    except Exception as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)


def run_dashboard():
    """Data for the up-to-date dashboard: per-source install counts, recently
    updated apps and basic system info."""
    import platform
    import time
    out = {}
    recent = []

    # system package counts + recent installs
    if BACKEND != "dnf":
        dash = pkg_backend.dashboard()
        out["rpmTotal"] = dash["total"]
        for entry in dash["recent"]:
            recent.append({"name": entry["name"], "source": "System", "ts": entry["ts"]})
        # On Arch this is the AUR/foreign-package count
        out["coprCount"] = dash.get("foreign", 0)
    else:
        rpm_lines = []
        try:
            res = subprocess.run(["rpm", "-qa", "--qf", "%{NAME}\t%{INSTALLTIME}\n"],
                                 capture_output=True, text=True, timeout=20)
            rpm_lines = [l.split("\t") for l in res.stdout.strip().split("\n") if l]
        except (OSError, subprocess.SubprocessError):
            pass
        out["rpmTotal"] = len(rpm_lines)
        for name, ts in sorted(((l[0], int(l[1])) for l in rpm_lines if len(l) > 1 and l[1].isdigit()),
                               key=lambda x: -x[1])[:50]:
            recent.append({"name": name, "source": "System", "ts": ts})

        # copr-installed count
        copr = 0
        try:
            res = subprocess.run(["dnf", "-Cq", "repoquery", "--installed", "--qf", "%{from_repo}\n"],
                                 capture_output=True, text=True, timeout=30,
                                 env={**os.environ, "LC_ALL": "C"})
            for repo in res.stdout.split():
                if repo.startswith("copr"):
                    copr += 1
        except (OSError, subprocess.SubprocessError):
            pass
        out["coprCount"] = copr

    # flatpaks + their deploy times; use cached friendly names when known
    names_cache = {}
    try:
        with open(CACHE_FILE) as f:
            names_cache = json.load(f).get("flatpak", {})
    except (OSError, ValueError):
        pass
    flatpak_count = 0
    try:
        res = subprocess.run(["flatpak", "list", "--app", "--columns=application,installation"],
                             capture_output=True, text=True, timeout=15,
                             env={**os.environ, "LC_ALL": "C"})
        for line in res.stdout.strip().split("\n"):
            parts = line.split("\t")
            if not parts or not parts[0].strip():
                continue
            flatpak_count += 1
            app_id = parts[0].strip()
            base = os.path.expanduser("~/.local/share/flatpak") if (len(parts) > 1 and parts[1].strip() == "user") else "/var/lib/flatpak"
            try:
                ts = int(os.stat(os.path.join(base, "app", app_id, "current", "active")).st_mtime)
            except OSError:
                continue
            display = (names_cache.get(app_id) or {}).get("name") or app_id.split(".")[-1]
            recent.append({"name": display, "source": "Flatpak", "ts": ts})
    except (OSError, subprocess.SubprocessError):
        pass
    out["flatpakCount"] = flatpak_count

    # appimages (managed records + files in the app folders)
    appimage_files = set()
    try:
        with open(os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "dankSoftwareDepot", "appimages.json")) as f:
            for record in json.load(f):
                if os.path.isfile(record.get("file", "")):
                    appimage_files.add(record["file"])
                    recent.append({"name": record.get("name") or record["id"], "source": "AppImage", "ts": record.get("installedAt") or 0})
    except (OSError, ValueError):
        pass
    for directory in (os.path.expanduser("~/AppImages"), os.path.expanduser("~/Applications")):
        for path in glob.glob(os.path.join(directory, "*.[Aa]pp[Ii]mage")):
            if path not in appimage_files:
                appimage_files.add(path)
                stem = re.sub(r"\.appimage$", "", os.path.basename(path), flags=re.I)
                try:
                    recent.append({"name": stem, "source": "AppImage", "ts": int(os.stat(path).st_mtime)})
                except OSError:
                    pass
    out["appimageCount"] = len(appimage_files)

    recent.sort(key=lambda r: -r["ts"])
    out["recent"] = recent[:50]

    # system info
    out["hostname"] = platform.node()
    out["kernel"] = platform.release()
    try:
        with open("/proc/uptime") as f:
            out["uptimeSecs"] = int(float(f.read().split()[0]))
    except (OSError, ValueError):
        out["uptimeSecs"] = 0
    pretty = ""
    try:
        with open("/etc/os-release") as f:
            for line in f:
                m = re.match(r'PRETTY_NAME="?([^"]+)"?', line.strip())
                if m:
                    pretty = m.group(1)
    except OSError:
        pass
    out["osPretty"] = pretty

    # DMS logo from the running shell (path changes per shell version; Dux
    # Shell 2.0 unpacks under dms-shell/, older versions under danklinux-shell/)
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/1000")
    logos = [path for shell_dir in ("dms-shell", "danklinux-shell")
             for path in glob.glob(os.path.join(runtime, shell_dir, "*", "assets", "danklogo.svg"))]
    out["dankLogo"] = logos[0] if logos else ""

    json.dump(out, sys.stdout)


# Freedesktop menu categories → storefront groups, in display order
# Every app lands in exactly one of these, and the order is what decides
# which: the first group whose categories it carries takes it. Browsers and
# Communication therefore come before Internet, or Firefox and Discord would
# be filed under Network with the torrent clients; Utilities is last because
# almost everything is also a Utility to someone.
#
# The set is Flathub's eleven top-level categories, with Network split into
# the two parts big enough to browse on their own and the rest kept together.
# Whatever matches nothing is still shown — see OTHER_SECTION.
CATEGORY_GROUPS = [
    ("Browsers", {"WebBrowser"}),
    ("Office", {"Office", "WordProcessor", "Spreadsheet", "Presentation", "Finance"}),
    ("Communication", {"InstantMessaging", "Chat", "Email", "VideoConference", "Telephony"}),
    ("Media", {"AudioVideo", "Audio", "Video", "Player", "Music", "TV"}),
    ("Graphics & Photo", {"Graphics", "Photography", "RasterGraphics", "VectorGraphics"}),
    ("Games", {"Game"}),
    ("Development", {"Development", "IDE", "TextEditor"}),
    ("Education", {"Education", "Languages", "Dictionary", "Literature", "Teaching"}),
    ("Science", {"Science", "Astronomy", "Chemistry", "Physics", "Biology", "Math",
                 "NumericalAnalysis", "Geography", "Geoscience", "Electronics",
                 "Engineering", "DataVisualization", "ComputerScience"}),
    ("Health & Fitness", {"Sports", "MedicalSoftware", "Amusement"}),
    ("Internet", {"Network", "FileTransfer", "P2P", "RemoteAccess", "Feed", "News",
                  "WebDevelopment", "Monitor", "HamRadio", "Dialup"}),
    ("Utilities", {"Utility", "System", "FileTools", "Archiving", "Settings",
                   "HardwareSettings", "Security", "Accessibility", "PackageManager",
                   "TerminalEmulator", "Filesystem", "Printing", "DesktopSettings",
                   "Viewer"}),
]

# The catch-all. Around one per cent of a catalog carries no category at all,
# and a browsable storefront that quietly drops them is one that cannot be
# browsed to the end.
OTHER_SECTION = "Other"


def section_for(categories):
    """Which single section an app belongs to."""
    for label, cats in CATEGORY_GROUPS:
        if categories & cats:
            return label
    return OTHER_SECTION


def run_warm_index():
    """Build the AppStream search index ahead of the first thing that needs it.

    Every path into the catalogs goes through build_search_index, which is a
    file read when the fingerprint still matches and several seconds of XML
    parsing when it does not. The catalogs change when appstream-data is
    updated — that is, during an update run — so without this the cost lands
    on whoever opens a details popup or the Install tab next, in front of a
    spinner. A cache hit here costs a process start and nothing else.

    The parsing is CPU the user did not ask for at that moment, so it asks to
    be scheduled behind everything else.
    """
    try:
        os.nice(5)
    except (OSError, AttributeError):
        pass
    try:
        paths = catalog_paths()
        entries = build_search_index(paths, fingerprint(paths))
        print(json.dumps({"ok": True, "entries": len(entries)}))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--catalog-status":
        # Whether the distro's AppStream catalog is installed at all, asked
        # through the same globs the enrichment uses so the answer can never
        # drift from what the app actually reads
        json.dump({"catalogs": len(distro_catalog_paths())}, sys.stdout)
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "--changelog":
        run_changelog(sys.argv[2])
        return
    if len(sys.argv) >= 5 and sys.argv[1] == "--gitnotes":
        run_gitnotes(sys.argv[2], sys.argv[3], sys.argv[4])
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "--search":
        run_search(sys.argv[2])
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "--flathub-installs":
        run_flathub_installs()
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "--qml-index":
        run_qml_index()
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "--warm-index":
        run_warm_index()
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "--search-dnf":
        run_search_dnf(sys.argv[2])
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "--update-sizes":
        run_update_sizes(sys.argv[2])
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "--dashboard":
        run_dashboard()
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "--distro-upgrade":
        run_distro_upgrade()
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "--submit-review":
        run_submit_review(sys.argv[2])
        return
    if len(sys.argv) >= 3 and sys.argv[1] == "--appinfo":
        run_appinfo(sys.argv[2])
        return

    try:
        if len(sys.argv) >= 2 and sys.argv[1].strip().startswith("{"):
            request = json.loads(sys.argv[1])
        else:
            request = json.load(sys.stdin)
    except ValueError:
        print("{}")
        return

    rpm_items = request.get("rpm", [])
    flatpak_items = request.get("flatpak", [])
    if flatpak_items:
        refresh_appstream_if_stale()
    rpm_from = {strip_arch(i["name"]): i.get("from", "") for i in rpm_items}
    flatpak_from = {i["name"]: i.get("from", "") for i in flatpak_items}

    paths = catalog_paths()
    fp = fingerprint(paths)
    cache = load_cache(fp)

    need_rpm = {n for n in rpm_from if n not in cache["rpm"]}
    need_flat = {n for n in flatpak_from if n not in cache["flatpak"]}

    if need_rpm or need_flat:
        rpm_found, flatpak_found = scan_catalogs(need_rpm, need_flat)
        missing_rpm = need_rpm - set(rpm_found)
        dnf_info = dnf_fallback(missing_rpm)
        for name in need_rpm:
            if name in rpm_found:
                comp = rpm_found[name]
            else:
                extra = dnf_info.get(name, {})
                comp = {"name": "", "summary": extra.get("summary", ""),
                        "homepage": extra.get("homepage", ""),
                        "icon": icon_for_installed_pkg(name), "releases": []}
            cache["rpm"][name] = comp
        for name in need_flat:
            cache["flatpak"][name] = flatpak_found.get(name, {"name": "", "summary": "", "homepage": "", "icon": "", "releases": []})
        save_cache(cache)

    held = compute_holds(set(rpm_from))
    result = {
        "rpm": {n: comp_to_info(cache["rpm"].get(n, {}), rpm_from[n]) for n in rpm_from},
        "flatpak": {n: comp_to_info(cache["flatpak"].get(n, {}), flatpak_from[n]) for n in flatpak_from},
    }
    for name, reason in held.items():
        if name in result["rpm"]:
            result["rpm"][name]["held"] = True
            result["rpm"][name]["holdReason"] = reason
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
