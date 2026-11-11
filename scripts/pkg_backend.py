#!/usr/bin/env python3
"""System package-manager backend for the metadata layer.

On Fedora the battle-tested dnf code paths in enrich.py stay in use; on
apt systems (Debian/Ubuntu, python3-apt) enrich.py dispatches to this
module instead. The functions mirror the shapes of their dnf
counterparts so the callers need no per-backend logic.

Also usable as a CLI (JSON on stdout), which is how the QML layer and
the container tests call it:

    pkg_backend.py search <query>     [{name, homepage, summary}]
    pkg_backend.py info <name>        {descriptionHtml, download, installed, homepage}
    pkg_backend.py sizes <name>...    {"totalBytes": N, "sizes": {name: bytes}}
    pkg_backend.py dashboard          {"total": N, "recent": [{name, ts}]}
    pkg_backend.py holds              {name: reason}
    pkg_backend.py versions <name>    [{version, repo, installed}]
    pkg_backend.py desktop-owners     {name: {icon, name}}  (every backend)
    pkg_backend.py changelog <name>   plain text (may be empty)
    pkg_backend.py provenance <name>  {userInstalled, requiredBy: [name]}
    pkg_backend.py cleanup-scan      {unneeded: {...}, cache: {...}}
"""
import glob
import html
import json
import os
import re
import subprocess
import sys

_backend = None


def detect():
    """"apt" (Debian family), "pacman" (Arch family) or "dnf" (default)."""
    global _backend
    if _backend is None:
        _backend = "dnf"
        try:
            with open("/etc/os-release") as f:
                osr = f.read()
            if re.search(r"^(ID|ID_LIKE)=.*?(debian|ubuntu)", osr, re.M | re.I):
                _backend = "apt"
            elif re.search(r"^(ID|ID_LIKE)=.*?(arch|manjaro)", osr, re.M | re.I):
                _backend = "pacman"
        except OSError:
            pass
    return _backend


def _alpm():
    """Read-only libalpm handle over the on-disk databases."""
    # The bindings live in the system interpreter's site-packages only; if the
    # one running this is a virtualenv or a pyenv shim, hand the command over
    import interp
    interp.ensure("pyalpm")
    import pyalpm
    handle = pyalpm.Handle("/", "/var/lib/pacman")
    for path in glob.glob("/var/lib/pacman/sync/*.db"):
        handle.register_syncdb(os.path.basename(path)[:-3], 0)
    return handle


def _alpm_sync_pkg(handle, name):
    for db in handle.get_syncdbs():
        pkg = db.get_pkg(name)
        if pkg is not None:
            return pkg
    return None


def _human(size):
    if size >= 1e9:
        return f"{size / 1e9:.1f} GB"
    if size >= 1e6:
        return f"{size / 1e6:.1f} MB"
    return f"{max(1, round(size / 1e3))} kB"


def _cache():
    import interp
    interp.ensure("apt")
    import apt
    return apt.Cache()


def name_search(query):
    """Match packages by name — mirror of dnf_name_search."""
    if not re.match(r"^[\w.+-]+$", query):
        return []
    needle = query.lower()
    out = []
    try:
        if detect() == "pacman":
            seen = set()
            for db in _alpm().get_syncdbs():
                for pkg in db.pkgcache:
                    if needle in pkg.name and pkg.name not in seen:
                        seen.add(pkg.name)
                        out.append({"name": pkg.name, "homepage": pkg.url or "",
                                    "summary": pkg.desc or ""})
                        if len(out) >= 400:
                            return out
            return out
        for pkg in _cache():
            if needle not in pkg.name or re.search(r"-(dbg|dbgsym)$", pkg.name):
                continue
            cand = pkg.candidate
            if cand is None:
                continue
            out.append({"name": pkg.name, "homepage": cand.homepage or "",
                        "summary": cand.summary or ""})
            if len(out) >= 400:
                break
    except Exception:
        return []
    return out


def package_info(name):
    """Description and sizes — mirror of rpm_repoquery_info."""
    out = {}
    if detect() == "pacman":
        try:
            handle = _alpm()
            pkg = _alpm_sync_pkg(handle, name) or handle.get_localdb().get_pkg(name)
            if pkg is None:
                return out
            if pkg.desc:
                out["descriptionHtml"] = "<p>" + html.escape(pkg.desc) + "</p>"
            if getattr(pkg, "download_size", 0):
                out["download"] = _human(pkg.download_size)
            if pkg.isize:
                out["installed"] = _human(pkg.isize)
            if pkg.url:
                out["homepage"] = pkg.url
            if pkg.licenses:
                out["license"] = " / ".join(pkg.licenses)
        except Exception:
            pass
        return out
    try:
        cache = _cache()
        if name not in cache:
            return out
        cand = cache[name].candidate or cache[name].installed
        if cand is None:
            return out
        if cand.description:
            paragraphs = [html.escape(p.strip()) for p in cand.description.split("\n\n") if p.strip()]
            out["descriptionHtml"] = "".join(f"<p>{p}</p>" for p in paragraphs)
        if cand.size:
            out["download"] = _human(cand.size)
        if cand.installed_size:
            out["installed"] = _human(cand.installed_size)
        if cand.homepage:
            out["homepage"] = cand.homepage
    except Exception:
        pass
    return out


def update_sizes(names):
    """Exact candidate download sizes — the apt mirror of the repoquery
    branch in run_update_sizes."""
    total = 0
    sizes = {}
    try:
        if detect() == "pacman":
            handle = _alpm()
            for name in names:
                pkg = _alpm_sync_pkg(handle, name)
                if pkg is not None and pkg.download_size:
                    sizes[name] = int(pkg.download_size)
                    total += int(pkg.download_size)
            return total, sizes
        cache = _cache()
        for name in names:
            if name not in cache:
                continue
            cand = cache[name].candidate
            if cand and cand.size:
                sizes[name] = int(cand.size)
                total += int(cand.size)
    except Exception:
        pass
    return total, sizes


def dashboard():
    """Installed count and recently-changed packages. dpkg records no
    install time; the package's .list file mtime is the standard stand-in.
    libalpm records real install dates. The "foreign" count covers AUR
    (and other out-of-repo) packages on Arch."""
    if detect() == "pacman":
        total = 0
        recent = []
        foreign = 0
        try:
            handle = _alpm()
            pkgs = handle.get_localdb().pkgcache
            total = len(pkgs)
            for pkg in pkgs:
                if _alpm_sync_pkg(handle, pkg.name) is None:
                    foreign += 1
            for pkg in sorted(pkgs, key=lambda p: -(p.installdate or 0))[:50]:
                recent.append({"name": pkg.name, "ts": int(pkg.installdate or 0)})
        except Exception:
            pass
        return {"total": total, "recent": recent, "foreign": foreign}
    total = 0
    recent = []
    try:
        res = subprocess.run(["dpkg-query", "-W", "-f", "${Package}\n"],
                             capture_output=True, text=True, timeout=20)
        names = [l for l in res.stdout.splitlines() if l]
        total = len(names)
        entries = []
        for path in glob.glob("/var/lib/dpkg/info/*.list"):
            base = os.path.basename(path)[:-5].split(":")[0]
            try:
                entries.append((int(os.stat(path).st_mtime), base))
            except OSError:
                continue
        entries.sort(reverse=True)
        recent = [{"name": name, "ts": ts} for ts, name in entries[:50]]
    except (OSError, subprocess.SubprocessError):
        pass
    return {"total": total, "recent": recent, "foreign": 0}


def installed_table():
    """TSV matching the rpm inventory the Installed view parses:
    name<TAB>version<TAB>size-bytes<TAB>installtime, sorted by name.
    dpkg reports Installed-Size in KiB and records no install time; the
    .list file mtime is the stand-in. libalpm has both natively."""
    if detect() == "pacman":
        rows = []
        try:
            for pkg in _alpm().get_localdb().pkgcache:
                rows.append((pkg.name, pkg.version, int(pkg.isize or 0), int(pkg.installdate or 0)))
        except Exception:
            pass
        rows.sort()
        return "\n".join(f"{n}\t{v}\t{s}\t{t}" for n, v, s, t in rows)
    rows = []
    try:
        res = subprocess.run(["dpkg-query", "-W", "-f", "${Package}\t${Version}\t${Installed-Size}\n"],
                             capture_output=True, text=True, timeout=25)
        mtimes = {}
        for path in glob.glob("/var/lib/dpkg/info/*.list"):
            base = os.path.basename(path)[:-5].split(":")[0]
            try:
                mtimes[base] = int(os.stat(path).st_mtime)
            except OSError:
                continue
        for line in res.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) < 3 or not fields[0]:
                continue
            name = fields[0].split(":")[0]
            size_kib = int(fields[2]) if fields[2].isdigit() else 0
            rows.append((name, fields[1], size_kib * 1024, mtimes.get(name, 0)))
    except (OSError, subprocess.SubprocessError):
        pass
    rows.sort()
    return "\n".join(f"{n}\t{v}\t{s}\t{t}" for n, v, s, t in rows)


def holds():
    """{name: reason} — apt-mark holds and what `apt-get upgrade` keeps back,
    or pacman.conf IgnorePkg entries."""
    if detect() == "pacman":
        out = {}
        try:
            with open("/etc/pacman.conf") as f:
                for line in f:
                    m = re.match(r"\s*IgnorePkg\s*=\s*(.+)", line)
                    if m:
                        for name in re.split(r"\s+", m.group(1).strip()):
                            if name:
                                out[name] = "IgnorePkg"
        except OSError:
            pass
        return out
    out = _apt_holds()
    if out is not None:
        return out
    out = {}
    try:
        res = subprocess.run(["apt-mark", "showhold"],
                             capture_output=True, text=True, timeout=15)
        for line in res.stdout.splitlines():
            name = line.strip()
            if name:
                out[name] = "hold"
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def _apt_holds():
    """{name: reason} for apt-mark holds and for upgradable packages
    `apt-get upgrade` leaves alone; None when apt_pkg cannot be used.

    The daemon lists `apt list --upgradable` and then runs `apt-get upgrade`,
    which neither installs new packages nor removes any. An update that
    needs either, one an installed package does not allow (dms pinning the
    quickshell it was built against), or a phased one still rolling out is
    offered and then kept back, and the run reported it as failed — "try
    again", which never helps. So the same upgrade is resolved here, on the
    local cache only, and what it does not mark is held, with the reason.

    Opening the cache is nearly all of the cost (0.9 s on a full Debian
    index, the same as `apt list --upgradable`), so the holds are read from
    it too rather than from `apt-mark showhold`, which opens it again. And
    apt_pkg rather than apt.Cache: the wrapper builds a Python object per
    package in the archive, another second.
    """
    out = {}
    try:
        import interp
        interp.ensure("apt_pkg")
        import apt_pkg
        apt_pkg.init()
        cache = apt_pkg.Cache(None)
        depcache = apt_pkg.DepCache(cache)
    except Exception:
        return None
    try:
        upgradable = []
        for p in cache.packages:
            if not p.current_ver:
                continue
            if p.selected_state == apt_pkg.SELSTATE_HOLD:
                out[p.name] = "hold"
            elif depcache.is_upgradable(p):
                upgradable.append(p)
        if not upgradable:
            return out
        depcache.upgrade(False)
        records = apt_pkg.PackageRecords(cache)
        for pkg in upgradable:
            if not depcache.marked_upgrade(pkg):
                cand = depcache.get_candidate_ver(pkg)
                out[pkg.name] = _kept_back_reason(apt_pkg, records, pkg, cand)
    except Exception:
        pass
    return out


def _kept_back_reason(apt_pkg, records, pkg, cand):
    if cand.file_list and records.lookup(cand.file_list[0]) \
            and "\nPhased-Update-Percentage:" in "\n" + records.record:
        return "kept back (phased update)"
    # Who stands in the way: an installed package whose dependency the new
    # version does not satisfy, or that breaks or conflicts with it
    blockers = set()
    for dep in pkg.rev_depends_list:
        parent = dep.parent_pkg
        if parent.current_ver is None or dep.parent_ver.id != parent.current_ver.id:
            continue
        fits = not dep.target_ver or apt_pkg.check_dep(cand.ver_str, dep.comp_type, dep.target_ver)
        if (dep.dep_type_untranslated in ("Depends", "PreDepends") and not fits) \
                or (dep.dep_type_untranslated in ("Breaks", "Conflicts") and fits):
            blockers.add(parent.name)
    # ...or one the new version itself breaks
    for dep_type in ("Breaks", "Conflicts"):
        for group in cand.depends_list.get(dep_type, []):
            for dep in group:
                target = dep.target_pkg
                if target.current_ver is None or target.name == pkg.name:
                    continue
                if not dep.target_ver or apt_pkg.check_dep(target.current_ver.ver_str, dep.comp_type, dep.target_ver):
                    blockers.add(target.name)
    if blockers:
        return "kept back (via " + ", ".join(sorted(blockers)[:3]) + ")"
    # A dependency of the new version that nothing installed satisfies
    for dep_type in ("Depends", "PreDepends"):
        for group in cand.depends_list.get(dep_type, []):
            if not any(_installed_or_provided(dep.target_pkg) for dep in group):
                return "kept back (needs new packages)"
    return "kept back"


def _installed_or_provided(target):
    if target.current_ver is not None:
        return True
    return any(ver.parent_pkg.current_ver is not None
               for _, _, ver in target.provides_list)


def available_versions(name):
    """All available versions, newest first — feeds "Previous versions".
    pacman repositories carry only the newest version, so the Arch answer
    is always empty (the UI shows its no-older-versions state)."""
    if detect() == "pacman":
        return []
    out = []
    try:
        import functools

        import apt_pkg
        cache = _cache()
        if name not in cache:
            return out
        pkg = cache[name]
        installed = pkg.installed.version if pkg.installed else ""
        versions = sorted(pkg.versions,
                          key=functools.cmp_to_key(lambda a, b: apt_pkg.version_compare(a.version, b.version)),
                          reverse=True)
        for v in versions:
            repo = ""
            for origin in v.origins or []:
                if origin.archive:
                    repo = origin.archive
                    break
            out.append({"version": v.version, "repo": repo,
                        "installed": v.version == installed})
    except Exception:
        pass
    return out


# ── Which packages are applications ────────────────────────────────────────
# "A program you would start" has no field in package metadata, but it has a
# reliable fingerprint on disk: a desktop entry the launcher would show. A
# package owning one is something the user installed to use; everything else
# is a library, a font, a driver or a service. Unlike an install-reason flag
# this survives reinstalls and distro upgrades, and it needs no network.

DESKTOP_DIRS = ("/usr/share/applications", "/usr/local/share/applications")


ICON_THEME_DIRS = ("/usr/share/icons", os.path.expanduser("~/.local/share/icons"))
ICON_SIZES = ("scalable", "512x512", "256x256", "128x128", "96x96", "64x64", "48x48", "32x32")
PIXMAP_DIRS = ("/usr/share/pixmaps", "/usr/share/icons")


def _resolve_icon(name):
    """Icon= as a file path. The launcher resolves these through the icon
    theme; packages outside AppStream have no other icon anywhere, so the
    desktop entry is the only place to find one."""
    if not name:
        return ""
    if name.startswith("/"):
        return name if os.path.exists(name) else ""
    for theme_dir in ICON_THEME_DIRS:
        for theme in ("hicolor", "Adwaita", "breeze"):
            for size in ICON_SIZES:
                for ext in (".svg", ".png"):
                    path = os.path.join(theme_dir, theme, size, "apps", name + ext)
                    if os.path.exists(path):
                        return path
    for directory in PIXMAP_DIRS:
        for ext in (".svg", ".png", ".xpm"):
            path = os.path.join(directory, name + ext)
            if os.path.exists(path):
                return path
    return ""


def _launchable_desktop_files():
    """Desktop entries the launcher would offer, as (path, icon, name):
    Type=Application, not NoDisplay and not Hidden. Only the first group is
    read — later groups are actions, whose own NoDisplay says nothing about
    the entry."""
    entries = []
    for directory in DESKTOP_DIRS:
        for path in sorted(glob.glob(os.path.join(directory, "*.desktop"))):
            try:
                with open(path, errors="replace") as f:
                    body = f.read()
            except OSError:
                continue
            head = body.split("\n[", 1)[0]
            if not re.search(r"^Type\s*=\s*Application\s*$", head, re.M):
                continue
            if re.search(r"^(NoDisplay|Hidden)\s*=\s*true\s*$", head, re.M | re.I):
                continue
            icon = re.search(r"^Icon\s*=\s*(.+?)\s*$", head, re.M)
            label = re.search(r"^Name\s*=\s*(.+?)\s*$", head, re.M)
            entries.append((path, _resolve_icon(icon.group(1) if icon else ""),
                            label.group(1) if label else ""))
    return entries


def _run_lines(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in out.stdout.splitlines() if line.strip()]


def _owners_of(paths):
    """[(path, package)] for the paths the package manager knows. rpm keeps
    the argument order, so it is matched positionally; dpkg and pacman name
    the path in each line."""
    backend = detect()
    pairs = []
    # Chunked: a few hundred paths stay well inside any argv limit, and a
    # single unowned file must not lose the rest of the batch
    for start in range(0, len(paths), 200):
        chunk = paths[start:start + 200]
        if backend == "apt":
            for line in _run_lines(["dpkg", "-S"] + chunk):
                # "pkg1, pkg2: /path" — diversions and multi-owner paths
                owner, _, path = line.partition(": ")
                first = owner.split(",")[0].strip().split(":")[0]
                if first and path.strip():
                    pairs.append((path.strip(), first))
        elif backend == "pacman":
            for line in _run_lines(["pacman", "-Qo"] + chunk):
                # "/path is owned by pkg 1.2.3"
                match = re.match(r"^(.*?) is owned by (\S+)\s", line)
                if match:
                    pairs.append((match.group(1), match.group(2)))
        else:
            lines = _run_lines(["rpm", "-qf", "--qf", "%{NAME}\\n"] + chunk)
            if len(lines) == len(chunk):
                pairs.extend((path, name.strip()) for path, name in zip(chunk, lines)
                             if name.strip() and not name.startswith("file "))
            else:
                # An unowned file breaks the alignment: ask one by one
                for path in chunk:
                    got = _run_lines(["rpm", "-qf", "--qf", "%{NAME}\\n", path])
                    if len(got) == 1 and got[0].strip() and not got[0].startswith("file "):
                        pairs.append((path, got[0].strip()))
    return pairs


def _installed_subset(names):
    """The names in `names` that are installed packages."""
    if not names:
        return set()
    backend = detect()
    if backend == "apt":
        lines = _run_lines(["dpkg-query", "-W", "-f", "${Package} ${db:Status-Status}\n"] + names)
        return {line.split()[0] for line in lines if line.endswith(" installed")}
    if backend == "pacman":
        return {line.strip() for line in _run_lines(["pacman", "-Qq"] + names)} & set(names)
    # Not installed prints "package X is not installed", on stdout
    return {line.strip() for line in _run_lines(["rpm", "-q", "--qf", "%{NAME}\n"] + names)} & set(names)


APP_FILE_PATTERNS = ("/usr/share/metainfo/%s.metainfo.xml", "/usr/share/metainfo/%s.appdata.xml",
                     "/usr/share/appdata/%s.appdata.xml", "/usr/share/applications/%s.desktop")


def installed_app_owners(names_by_id):
    """{app id: package} for apps whose catalog names a package that is not
    installed while the app's own metainfo or desktop file is on disk.

    The catalog's package name is usually right, and then this finds
    nothing to say. When a package ships a metainfo file naming a package
    that does not exist (CachyOS's chatgpt-desktop-bin names "chatgpt",
    #49), the app is installed under a name the catalog never mentions: it
    showed Install, and Install ran `pacman -S chatgpt`. The package that
    owns the file is the one that is really there."""
    # Only apps whose own file is on disk can be installed under another
    # name, and a stat is all it takes to find them: a few dozen on a
    # desktop, out of the catalog's thousands. Listing every installed
    # package to rule the rest out cost ten times as long, on every opening
    # of the Install tab.
    path_to_id = {}
    for app_id in names_by_id:
        for pattern in APP_FILE_PATTERNS:
            path = pattern % app_id
            if app_id and os.path.exists(path):
                path_to_id[path] = app_id
                break
    candidates = {}
    for path, package in _owners_of(list(path_to_id)):
        app_id = path_to_id.get(path)
        if app_id and package != names_by_id.get(app_id):
            candidates[app_id] = package
    if not candidates:
        return {}
    # A catalog name that is installed too stays: then it is the right one
    # (a metapackage, say), and the file just lives in a dependency
    installed = _installed_subset(sorted({names_by_id[app_id] for app_id in candidates}))
    return {app_id: package for app_id, package in candidates.items() if names_by_id[app_id] not in installed}


def desktop_owners():
    """Installed packages that own a launchable desktop entry, with the icon
    and display name from that entry: {package: {icon, name}}."""
    entries = _launchable_desktop_files()
    if not entries:
        return {}
    by_path = {path: (icon, label) for path, icon, label in entries}
    out = {}
    for path, package in _owners_of([e[0] for e in entries]):
        icon, label = by_path.get(path, ("", ""))
        current = out.get(package)
        # A package can ship several entries; keep the one with an icon
        if current is None or (not current.get("icon") and icon):
            out[package] = {"icon": icon, "name": label}
    return out


# ── Changelogs ─────────────────────────────────────────────────────────────
# Neither apt nor pacman keeps changelogs in its repository metadata the way
# dnf does. What they do have is what the installed package shipped on disk,
# which is the version the details popup is showing anyway. Nothing here
# touches the network: a synchronous popup must not wait on packages.debian.org.

CHANGELOG_ENTRIES = 4


def _read_maybe_gzip(path):
    try:
        if path.endswith(".gz"):
            import gzip
            with gzip.open(path, "rt", errors="replace") as f:
                return f.read()
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def changelog(name):
    """Plain-text changelog of the installed package, "" when it ships none."""
    backend = detect()
    if backend == "apt":
        # Debian policy: /usr/share/doc/<pkg>/changelog.Debian.gz, with
        # changelog.gz for native packages
        for candidate in ("changelog.Debian.gz", "changelog.gz", "changelog.Debian", "changelog"):
            text = _read_maybe_gzip(os.path.join("/usr/share/doc", name, candidate))
            if text.strip():
                # Entries start at column 0 with "package (version) suite;"
                entries = re.split(r"\n(?=\S.*\(\S+\))", text.strip())
                return "\n\n".join(e.strip() for e in entries[:CHANGELOG_ENTRIES])
        return ""
    if backend == "pacman":
        # Only packages that ship a ChangeLog have one; pacman prints
        # "Changelog for <pkg>:" or an error on stderr
        try:
            res = subprocess.run(["pacman", "-Qc", name], capture_output=True,
                                 text=True, timeout=30,
                                 env={**os.environ, "LC_ALL": "C"})
        except (OSError, subprocess.SubprocessError):
            return ""
        lines = [l for l in res.stdout.splitlines() if not l.startswith("Changelog for ")]
        return "\n".join(lines).strip()
    return ""


# ── Reclaimable space ──────────────────────────────────────────────────────
# Two piles nobody looks at: packages that were pulled in for something since
# removed, and the download cache. Both are safe to lose and neither shows up
# anywhere until a disk fills.

CACHE_DIRS = ("/var/cache/libdnf5", "/var/cache/dnf", "/var/cache/rpm-ostree",
              "/var/cache/apt/archives", "/var/cache/pacman/pkg")
# Only downloaded packages count. The rest of these directories is repository
# metadata, which the next update check downloads straight back — deleting it
# is churn, not reclaimed space, and `clean packages` does not touch it either.
PACKAGE_SUFFIXES = (".rpm", ".deb", ".pkg.tar.zst", ".pkg.tar.xz", ".pkg.tar.gz")


def _package_cache_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(path, onerror=lambda e: None):
        for name in files:
            if not name.endswith(PACKAGE_SUFFIXES):
                continue
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def cleanup_scan():
    backend = detect()
    names, size = [], 0
    if backend == "apt":
        for line in _run_lines(["apt-get", "-s", "autoremove"]):
            if line.startswith("Remv "):
                names.append(line.split()[1])
    elif backend == "pacman":
        names = [l.strip() for l in _run_lines(["pacman", "-Qdtq"]) if l.strip()]
    else:
        try:
            res = subprocess.run(["dnf", "-Cq", "repoquery", "--unneeded", "--qf", "%{name}\t%{installsize}\n"],
                                 capture_output=True, text=True, timeout=60,
                                 env={**os.environ, "LC_ALL": "C"})
            for line in res.stdout.splitlines():
                parts = line.split("\t")
                if parts and parts[0].strip():
                    names.append(parts[0].strip())
                    if len(parts) > 1:
                        try:
                            size += int(parts[1])
                        except ValueError:
                            pass
        except (OSError, subprocess.SubprocessError):
            pass

    cache_bytes = 0
    for path in CACHE_DIRS:
        if os.path.isdir(path):
            cache_bytes += _package_cache_bytes(path)

    return {"unneeded": {"count": len(names), "bytes": size, "names": sorted(names)},
            "cache": {"bytes": cache_bytes}}


# ── Why is this here? ──────────────────────────────────────────────────────
# Every package manager can answer this and none of them are asked, because
# the answer lives behind a flag nobody remembers. Two facts settle it: did
# you ask for this package, and what would miss it if it went.


def provenance(name):
    backend = detect()
    user_installed = False
    required_by = []
    if backend == "apt":
        out = _run_lines(["apt-mark", "showmanual", name])
        user_installed = any(line.strip() == name for line in out)
        for line in _run_lines(["apt-cache", "rdepends", "--installed", "--no-recommends",
                                "--no-suggests", "--no-conflicts", "--no-breaks",
                                "--no-replaces", "--no-enhances", name]):
            dep = line.strip()
            if dep and dep != name and not dep.endswith(":") and not dep.startswith("Reverse"):
                required_by.append(dep.lstrip("| "))
    elif backend == "pacman":
        user_installed = bool(_run_lines(["pacman", "-Qeq", name]))
        for line in _run_lines(["pacman", "-Qi", name]):
            if line.startswith("Required By"):
                value = line.split(":", 1)[1].strip()
                if value and value != "None":
                    required_by = value.split()
                break
    else:
        env = {**os.environ, "LC_ALL": "C"}
        try:
            res = subprocess.run(["dnf", "-Cq", "repoquery", "--userinstalled", "--qf", "%{name}\n", name],
                                 capture_output=True, text=True, timeout=60, env=env)
            user_installed = any(l.strip() == name for l in res.stdout.splitlines())
            res = subprocess.run(["dnf", "-Cq", "repoquery", "--installed", "--whatrequires", name,
                                  "--qf", "%{name}\n"],
                                 capture_output=True, text=True, timeout=60, env=env)
            required_by = [l.strip() for l in res.stdout.splitlines() if l.strip() and l.strip() != name]
        except (OSError, subprocess.SubprocessError):
            pass
    # glibc has a thousand dependants; the popup wants a fact, not a wall.
    # The count is the fact, the names are the illustration.
    unique = sorted(dict.fromkeys(required_by))
    return {"userInstalled": user_installed,
            "requiredBy": unique[:12],
            "requiredByCount": len(unique)}


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    args = sys.argv[2:]
    if cmd == "search" and args:
        json.dump(name_search(args[0]), sys.stdout)
    elif cmd == "info" and args:
        json.dump(package_info(args[0]), sys.stdout)
    elif cmd == "sizes":
        total, sizes = update_sizes(args)
        json.dump({"totalBytes": total, "sizes": sizes}, sys.stdout)
    elif cmd == "dashboard":
        json.dump(dashboard(), sys.stdout)
    elif cmd == "installed-table":
        sys.stdout.write(installed_table() + "\n")
    elif cmd == "holds":
        json.dump(holds(), sys.stdout)
    elif cmd == "versions" and args:
        json.dump(available_versions(args[0]), sys.stdout)
    elif cmd == "desktop-owners":
        json.dump(desktop_owners(), sys.stdout)
    elif cmd == "changelog" and args:
        sys.stdout.write(changelog(args[0]))
    elif cmd == "provenance" and args:
        json.dump(provenance(args[0]), sys.stdout)
    elif cmd == "cleanup-scan":
        json.dump(cleanup_scan(), sys.stdout)
    elif cmd == "detect":
        json.dump({"backend": detect()}, sys.stdout)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
