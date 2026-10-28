import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Standalone updater window: the full visual experience with logos, release
// notes, per-item progress and the phase stepper. Opens as a regular
// toplevel window, independent of the bar popout.
FloatingWindow {
    id: win

    // Whether the window has keyboard focus. FloatingWindow has no `active`
    // of its own, but the attached property works on any item inside it.
    readonly property bool focused: focusProbe.Window.active === true

    Item {
        id: focusProbe
    }

    required property var store
    required property var engine
    property var firmware: null
    property var widgetRoot: null
    property bool showRuntimes: false
    property int lastUpdateUnix: 0
    property real checkFraction: 0
    property int checkElapsedSecs: 0
    property int estCheckSecs: 45

    // Bumped whenever installed software changed (install, update run);
    // the Installed tab reloads its list when this moves.
    property int softwareSerial: 0

    Connections {
        target: win.engine

        function onFinished(ok) {
            if (win.engine.completedCount > 0) {
                win.softwareSerial++;
                win._dashFetchedAt = 0;
                win.refreshDashboard();
            }
            if (win._pendingShellNames.length > 0) {
                const shellNames = win._pendingShellNames;
                win._pendingShellNames = [];
                win._daemonUpgradeOnly(shellNames);
            }
        }
    }

    // ── Details popup for Updates-tab cards ─────────────────────────────────
    function openUpdateDetails(rowData, info) {
        const pkg = rowData.pkg || {};
        const isFirmware = pkg.repo === "firmware";
        const isFlatpak = pkg.repo === "flatpak";
        // A DMS plugin is none of the things this dialog usually shows: no
        // repository to name, no rpm changelog to read (asking for one told
        // the user "package quickCapture is not installed", which is true and
        // useless), and nobody has reviewed it. Its manifest is the source.
        const isPlugin = pkg.repo === "dmsplugin";
        // Neither of these is a package the system knows about either: a
        // formula lives in brew's own prefix, an AppImage is a file. Asking
        // rpm or dpkg what changed in one gets "not installed", which is true
        // and useless — the same answer plugins used to get.
        const isBrew = pkg.repo === "brew";
        const isAppImage = pkg.repo === "appimage";
        const manifest = isPlugin ? ((PluginService.availablePlugins || {})[pkg.name] || {}) : {};
        const base = win.store.stripArch(pkg.name || "");
        const newer = (info && info.releases) ? info.releases.filter(r => r.newer && (r.notesHtml || r.version)).slice(0, 5) : [];
        if (!isFlatpak && !isFirmware && !isPlugin && !isBrew && !isAppImage && newer.length === 0) {
            win.store.fetchChangelog(base);
            // Nothing in AppStream and, for a git build, nothing in the
            // changelog either — the notes exist, just not in the distro
            win.store.fetchGitNotes(base, pkg.fromVersion, pkg.toVersion);
        }
        updatesDialog.rowData = rowData;
        updatesDialog.releases = newer;
        // What brew knows about it — licence, homepage, dependencies, how
        // often it was installed last month — which is the same panel the
        // Install tab fills from the same helper. The version is on the card
        // already, so the popup has something to show while the answer
        // arrives rather than opening empty.
        updatesDialog.brewFacts = isBrew ? {
            name: pkg.name,
            version: pkg.toVersion || ""
        } : null;
        if (isBrew) {
            brewFactsProcess.running = false;
            brewFactsProcess.command = [Backend.python, Qt.resolvedUrl("scripts/brew_helper.py").toString().replace("file://", ""), "--info", pkg.name];
            brewFactsProcess.running = true;
        }
        if (isPlugin)
            win.store.fetchPluginNotes(pkg);
        updatesDialog.pluginFacts = isPlugin ? {
            author: manifest.author || "",
            category: manifest.category || "",
            source: manifest.source || "",
            directory: manifest.pluginDirectory || "",
            permissions: manifest.permissions || [],
            icon: manifest.icon || pkg.icon || ""
        } : null;
        let versionLabel = Ui.versionLabel(pkg.toVersion);
        if (pkg.fromVersion && pkg.toVersion)
            versionLabel = pkg.fromVersion + " → " + Ui.versionLabel(pkg.toVersion);
        updatesDialog.open({
            id: isFlatpak ? pkg.name : base,
            name: win.store.displayName(pkg),
            summary: isPlugin ? (manifest.description || "") : ((info && info.summary) || ""),
            iconPath: (info && info.icon) || (win._isShellPkg(pkg) && win.widgetRoot ? win.widgetRoot.dankLogoPath : ""),
            homepage: (info && info.homepage) || "",
            held: rowData.ignored === true || win.store.isHeld(pkg),
            holdReason: rowData.ignored === true ? Tr.t("held by you") : win.store.holdReason(pkg),
            versionLabel: versionLabel,
            origin: Ui.sourceLabel(pkg.repo),
            isFlatpak: isFlatpak,
            sources: (isFirmware || isPlugin || isBrew || isAppImage) ? [] : (isFlatpak ? [{
                source: "flathub",
                kind: "flatpak",
                ref: pkg.name
            }] : [{
                source: "fedora",
                kind: "dnf",
                ref: base
            }])
        });
    }

    // The answer is only accepted if it is still about the formula on screen:
    // opening a second popup before the first has answered would otherwise
    // fill it with the previous one's licence.
    Process {
        id: brewFactsProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const info = JSON.parse(text);
                    if (info.found === true && updatesDialog.brewFacts && info.name === updatesDialog.brewFacts.name)
                        updatesDialog.brewFacts = info;
                } catch (e) {
                }
            }
        }
    }

    // Opened from a name in the log. It shows what is known about the package
    // and its changelog; the actions belong to the tabs that own the package,
    // not to a record of something that already happened.
    AppDetailsDialog {
        id: logDialog

        property string base: ""
        property bool isRpm: false

        releasesTitle: Tr.t("What's new")
        changelogLoading: isRpm && win.store.changelogs[base] === undefined
        changelog: isRpm ? (win.store.changelogs[base] || "") : ""
    }

    function openLogPackageDetails(item) {
        // Older entries carry only the name, which for a system package is
        // the package name anyway
        const id = item.id || item.name || "";
        if (id === "")
            return;
        const isFlatpak = (item.repo || "") === "flatpak" || (item.source || "") === "Flatpak";
        // A plugin recorded before this knew about plugins carries no repo, so
        // the source it was logged under stands in for one
        const isPlugin = (item.repo || "") === "dmsplugin" || (item.source || "") === "DMS";
        const isRpm = !isFlatpak && !isPlugin && (item.repo || "") !== "appimage" && (item.repo || "") !== "firmware";
        const base = win.store.stripArch(id);
        logDialog.base = base;
        logDialog.isRpm = isRpm;
        const manifest = isPlugin ? ((PluginService.availablePlugins || {})[id] || {}) : {};
        logDialog.pluginFacts = isPlugin ? {
            author: manifest.author || "",
            category: manifest.category || "",
            source: manifest.source || "",
            directory: manifest.pluginDirectory || "",
            permissions: manifest.permissions || [],
            icon: manifest.icon || ""
        } : null;
        if (isRpm)
            win.store.fetchChangelog(base);
        const info = win.store.infoFor({
            name: id,
            repo: isFlatpak ? "flatpak" : (item.repo || "system")
        });
        logDialog.open({
            id: id,
            name: item.name || id,
            summary: (info && info.summary) || "",
            iconPath: (info && info.icon) || "",
            homepage: (info && info.homepage) || "",
            versionLabel: (item.from && item.to) ? (item.from + " → " + item.to) : (item.to || item.from || ""),
            origin: item.source || "",
            isFlatpak: isFlatpak,
            sources: []
        });
    }

    AppDetailsDialog {
        id: updatesDialog

        property var rowData: null
        readonly property var rowPkg: rowData ? rowData.pkg : null
        // Everything the rpm machinery hangs off — the changelog, the older
        // builds, the git-notes lookup. A plugin is not one of these, and
        // asking anyway left "Loading changelog…" on screen for good, because
        // nothing was ever going to arrive and clear it.
        readonly property bool rowIsRpm: rowPkg !== null && rowPkg.repo !== "flatpak" && rowPkg.repo !== "firmware" && rowPkg.repo !== "dmsplugin" && rowPkg.repo !== "brew" && rowPkg.repo !== "appimage"
        readonly property string rowBase: rowPkg ? win.store.stripArch(rowPkg.name || "") : ""

        // "" for anything not built from git, which is what keeps the
        // section — and the network call behind it — off every other package
        advisory: (win.widgetRoot && rowPkg) ? (win.widgetRoot.advisories[rowBase] || null) : null

        readonly property string rowGitKey: rowPkg ? win.store.gitNotesKey(rowBase, rowPkg.fromVersion, rowPkg.toVersion) : ""
        // A DMS plugin's notes come from the same card, asked differently
        readonly property string rowPluginKey: rowPkg ? win.store.pluginNotesKey(rowPkg) : ""
        readonly property var rowGitNotes: {
            if (rowPluginKey !== "")
                return win.store.pluginNotes[rowPluginKey] || null;
            return rowGitKey !== "" ? (win.store.gitNotes[rowGitKey] || null) : null;
        }

        releasesTitle: Tr.t("What's new")
        changelogLoading: rowIsRpm && releases.length === 0 && win.store.changelogs[rowBase] === undefined
        changelog: (rowIsRpm && releases.length === 0) ? (win.store.changelogs[rowBase] || "") : ""
        gitNotesLoading: (rowGitKey !== "" || rowPluginKey !== "") && releases.length === 0 && rowGitNotes === null
        gitReleases: rowGitNotes ? (rowGitNotes.releases || []) : []
        gitNotesKind: rowGitNotes ? (rowGitNotes.kind || "") : ""
        gitNotesUrl: rowGitNotes ? (rowGitNotes.url || "") : ""
        gitNotesMore: rowGitNotes ? (rowGitNotes.more || 0) : 0
        gitNotesCommits: rowGitNotes ? (rowGitNotes.commitCount || 0) : 0
        showHoldToggle: {
            if (!rowData)
                return false;
            if (rowData.ignored === true)
                return true;
            if (!rowPkg || rowPkg.repo === "firmware" || win.store.isHeld(rowPkg))
                return false;
            return SystemUpdateService.canIgnorePackage(rowPkg);
        }
        showUpdateButton: rowPkg !== null && rowPkg.repo !== "firmware" && !win.engine.running && win.singleBusyKey === "" && (rowData.ignored !== true)
        busy: {
            if (!rowPkg || !win.engine.running)
                return false;
            const state = win.engine.stateFor(rowPkg);
            return state !== null && state.status === "active";
        }

        onUpdateRequested: {
            const target = rowData;
            close();
            win.runSingleUpdate(target);
        }

        onHoldToggleRequested: {
            win.setHold(rowPkg, rowData.ignored !== true);
            close();
        }
    }

    // Manually update one pending item. Flatpaks and AppImages go through
    // the engine; firmware runs its own privileged command.
    property string singleBusyKey: ""

    // Upgrade ONLY the given rpm names, through the daemon: every other
    // pending rpm goes into this run's ignored list. Used for DMS/Quickshell
    // packages — the daemon finishes the transaction even when the shell
    // reloads mid-way (a plain pkexec child would be killed with the shell).
    function _daemonUpgradeOnly(rawNames) {
        const wanted = new Set(rawNames);
        const ignored = (SettingsData.updaterIgnoredPackages || []).slice();
        for (const pkg of win.pendingUpdates) {
            if (pkg.repo !== "flatpak" && !wanted.has(pkg.name))
                ignored.push(pkg.name);
        }
        // This pass has no completion hook (the shell reloads on dms
        // updates) — stash the log entry for replay at the next start
        if (widgetRoot)
            widgetRoot._stashShellRunLog(win.pendingUpdates.filter(p => p.repo !== "flatpak" && wanted.has(p.name)), []);
        DMSService.sysupdateUpgrade({
            includeFlatpak: false,
            ignored: ignored
        }, null);
    }

    // Hold and release in one place, so the lock button on a card and the one
    // in the details popup cannot end up recording different things
    function setHold(pkg, held) {
        if (!pkg || !pkg.name)
            return;
        if (held)
            SystemUpdateService.ignorePackage(pkg.name);
        else
            SystemUpdateService.unignorePackage(pkg.name);
        if (win.widgetRoot && win.widgetRoot.actionLogger)
            win.widgetRoot.actionLogger.recordHold(pkg.name, win.store.displayName(pkg), held);
    }

    function _isShellPkg(pkg) {
        return pkg.repo !== "flatpak" && pkg.repo !== "firmware" && engine.shellPackagePattern.test(store.stripArch(pkg.name));
    }

    function runSingleUpdate(rowData) {
        if (engine.running || engine.deferred || singleUpdateProcess.running)
            return;
        const pkg = rowData.pkg || {};
        if (pkg.repo === "appimage") {
            engine.start({
                dnf: false,
                flatpak: false,
                firmware: false,
                appimageIds: [pkg.name]
            });
            return;
        }
        if (pkg.repo === "flatpak") {
            engine.start({
                dnf: false,
                firmware: false,
                flatpak: true,
                flatpakIds: [pkg.name]
            });
            return;
        }
        if (_isShellPkg(pkg)) {
            _daemonUpgradeOnly([pkg.name]);
            return;
        }
        if (pkg.repo === "firmware" && rowData.fwInfo && rowData.fwInfo.deviceId) {
            singleBusyKey = rowData.key;
            singleUpdateProcess._label = store.displayName(pkg);
            singleUpdateProcess.command = ["fwupdmgr", "update", "-y", "--no-reboot-check", rowData.fwInfo.deviceId];
            singleUpdateProcess.running = true;
            return;
        }
        if (pkg.name) {
            _daemonUpgradeOnly([pkg.name]);
        }
    }

    property var _pendingShellNames: []

    // Last output line of the manual pass, shown in the progress strip
    property string singleUpdateStatus: ""

    Process {
        id: singleUpdateProcess

        property string _label: ""
        property int _count: 1
        property var _thenFlatpakIds: []
        property var _thenAppimageIds: []

        stdout: SplitParser {
            onRead: line => {
                const trimmed = line.trim();
                if (trimmed !== "")
                    win.singleUpdateStatus = trimmed;
            }
        }

        onExited: (exitCode, exitStatus) => {
            win.singleBusyKey = "";
            win.singleUpdateStatus = "";
            if (exitCode === 0 && win.widgetRoot && win.widgetRoot.actionLogger) {
                win.widgetRoot.actionLogger.record("update", (_count === 1 ? Tr.t("Updated %1 package") : Tr.t("Updated %1 packages")).arg(_count), [{
                    name: _label,
                    from: "",
                    to: "",
                    source: "System",
                    status: exitCode === 0 ? "done" : "error"
                }], 0, {
                    key: _count === 1 ? "Updated %1 package" : "Updated %1 packages",
                    args: [_count]
                });
            }
            _count = 1;
            const pending = _thenFlatpakIds || [];
            const pendingAi = _thenAppimageIds || [];
            _thenFlatpakIds = [];
            _thenAppimageIds = [];
            if ((pending.length > 0 || pendingAi.length > 0) && !win.engine.running) {
                win.engine.start({
                    dnf: false,
                    firmware: false,
                    flatpak: pending.length > 0,
                    flatpakIds: pending,
                    appimageIds: pendingAi
                });
            } else if (win._pendingShellNames.length > 0) {
                const shellNames = win._pendingShellNames;
                win._pendingShellNames = [];
                win._daemonUpgradeOnly(shellNames);
            } else {
                SystemUpdateService.checkForUpdates();
            }
        }
    }

    // Ctrl+F puts the caret in the current tab's search field
    Shortcut {
        sequences: [StandardKey.Find]
        enabled: win.visible
        onActivated: win.focusCurrentTab()
    }

    // Ctrl+K opens the palette: for a keyboard-driven desktop the fastest
    // path to anything should not be a tab and a scroll.
    Shortcut {
        sequence: "Ctrl+K"
        enabled: win.visible
        onActivated: palette.open()
    }

    // Whether any modal popup / dialog is open over the window content
    readonly property bool anyPopupShowing: sourcesDialog.showing || newsDialog.showing || logDialog.showing || updatesDialog.showing || settingsOpen || aboutOpen || palette.showing || (windowOverlayLayer.children.length > 0 && Array.prototype.some.call(windowOverlayLayer.children, function(c) { return c && c.showing; }))

    // ── Grabbing the whole window, for the screenshots ─────────────────────
    // grabToImage from QML wants an item with a QML engine, and the window's
    // own root item is made by Quickshell in C++ — it refuses ("item has no
    // QML engine"). Grabbing one child takes only that child: no dialogs over
    // it, no window colour under it. So for the length of one grab, every
    // child is hung under this stage, in the same order, over the window's
    // colour, and put back the moment the image exists.
    Item {
        id: shotStage
        anchors.fill: parent
        visible: false

        Rectangle {
            anchors.fill: parent
            color: win.color
        }
    }

    function grabWindow(callback) {
        const root = shotStage.parent;
        const kids = Array.prototype.slice.call(root.children).filter(c => c !== shotStage);
        shotStage.visible = true;
        for (const kid of kids)
            kid.parent = shotStage;
        const restore = () => {
            for (const kid of kids)
                kid.parent = root;
            shotStage.visible = false;
        };
        const ok = shotStage.grabToImage(result => {
            restore();
            callback(result);
        });
        if (!ok)
            restore();
        return ok;
    }

    // Full-window layer that hosts the view-local detail popups, so their
    // dim overlay covers the entire window instead of just the tab area.
    Item {
        id: windowOverlayLayer
        anchors.fill: parent
        z: 150
    }

    // Where software comes from. Window-wide, like the other panels, because
    // sources are a property of the system rather than of a tab.
    RepositoriesDialog {
        id: sourcesDialog
        anchors.fill: parent
        logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
    }

    // Arch news. The dialog holds the state whether or not it is on screen —
    // the banner below asks it how many items are unread.
    NewsDialog {
        id: newsDialog
        anchors.fill: parent
    }

    CommandPalette {
        id: palette
        anchors.fill: parent
        z: 200
        results: win.paletteResults
        onAccepted: index => win.runPaletteResult(index)
    }

    // ── About popup (info icon in the header) ───────────────────────────────
    property bool aboutOpen: false
    onAboutOpenChanged: {
        if (aboutOpen) {
            aboutOpen = false;
            settingsOpen = true;
        }
    }
    property var pluginManifest: ({})
    readonly property string githubUrl: "https://github.com/vinceecniv/DuxSoftwareDepot"

    FileView {
        path: Qt.resolvedUrl("plugin.json")

        onLoaded: {
            try {
                win.pluginManifest = JSON.parse(text());
            } catch (e) {
            }
        }
    }



    // ── Self-update: offer a newer plugin release published on GitHub ───────
    // Compares the version in main's plugin.json with the installed one and
    // shows a banner with the CHANGELOG section for the new version. The
    // update itself runs detached (`dms plugins update` + shell reload)
    // because the reload kills this process tree.
    property string selfUpdateVersion: ""
    property bool selfUpdateBusy: false
    // The raw CHANGELOG and the version to measure it against are what gets
    // stored; the rich text is derived. It used to be rendered once and kept
    // as a string, which baked that moment's theme colours into the headings
    // while the body kept a live binding — switch to dark afterwards and the
    // body followed, the date stayed a light-mode grey on a dark card.
    property string selfUpdateMarkdown: ""
    property string selfUpdateLocalVersion: ""
    readonly property string selfUpdateNotes: _changelogSince(selfUpdateMarkdown, selfUpdateLocalVersion)
    // Dismissed via the banner's X: stays hidden until a yet newer version
    // appears (persisted in pluginData)
    readonly property string selfUpdateDismissedVersion: (widgetRoot && widgetRoot.pluginData) ? (widgetRoot.pluginData.selfUpdateDismissedVersion || "") : ""

    // End-of-life notices dismissed via their X, per case: the ref, what its
    // remote says about it, and which apps still use it. When any of that
    // changes — the last app moves on and the runtime can go, or a successor
    // is named — it is a different case and the notice comes back.
    function eolKey(r) {
        return [r.ref, r.eol || "", r.eolRebase || "", (r.usedBy || []).join(",")].join("|");
    }
    readonly property var eolDismissed: (widgetRoot && widgetRoot.pluginData) ? (widgetRoot.pluginData.eolDismissed || []) : []
    readonly property var eolShown: ((widgetRoot ? widgetRoot.eolRefs : []) || []).filter(r => eolDismissed.indexOf(eolKey(r)) < 0)

    function dismissEol() {
        // Kept to the cases still present, so the list cannot grow forever
        const current = ((widgetRoot ? widgetRoot.eolRefs : []) || []).map(r => eolKey(r));
        const kept = eolDismissed.filter(k => current.indexOf(k) >= 0);
        PluginService.savePluginData("dankSoftwareDepot", "eolDismissed", kept.concat(eolShown.map(r => eolKey(r))));
    }

    function _versionNewer(remote, local) {
        const a = String(remote).split(".").map(n => parseInt(n, 10) || 0);
        const b = String(local).split(".").map(n => parseInt(n, 10) || 0);
        for (let i = 0; i < Math.max(a.length, b.length); i++) {
            const d = (a[i] || 0) - (b[i] || 0);
            if (d !== 0)
                return d > 0;
        }
        return false;
    }

    // Everything that happened since the installed version, not only the
    // newest release: skipping two versions used to mean skipping their notes,
    // and someone updating from 0.6.5 to 0.6.9 was told about 0.6.9 alone.
    //
    // Rendered as rich text rather than shown raw. The changelog is hard
    // wrapped at about 72 columns for reading in a terminal, so printing it
    // verbatim kept the lines short while the banner had twice that width to
    // give — and left **bold** standing as four asterisks.
    function _changelogSince(md, local) {
        const lines = md.split("\n");
        const parts = [];
        let taking = false;
        let sections = 0;
        let para = "";
        let indented = false;

        const flush = () => {
            if (para.trim() === "")
                return;
            parts.push("<div style=\"margin-left:" + (indented ? 26 : 12) + "px; margin-bottom:3px; text-indent:-10px\">• " + _notesInline(para.trim()) + "</div>");
            para = "";
        };

        for (const line of lines) {
            if (line.indexOf("## ") === 0) {
                flush();
                const found = line.match(/\d+(?:\.\d+)+/);
                taking = found !== null && _versionNewer(found[0], local);
                if (taking) {
                    const heading = line.replace(/^##\s*/, "").trim().split(" — ");
                    parts.push("<div style=\"margin-top:" + (sections === 0 ? 0 : 12) + "px; margin-bottom:5px\">" + "<font color=\"" + Theme.primary + "\" size=\"+1\"><b>" + heading[0] + "</b></font>" + (heading.length > 1 ? " <font color=\"" + Theme.surfaceVariantText + "\">· " + heading[1] + "</font>" : "") + "</div>");
                    sections++;
                }
                continue;
            }
            if (!taking)
                continue;
            const bullet = line.match(/^(\s*)[-*]\s+(.*)$/);
            if (bullet) {
                flush();
                indented = bullet[1].length >= 2;
                para = bullet[2];
            } else if (line.trim() === "") {
                flush();
            } else {
                // A wrapped continuation of the bullet above
                para += (para === "" ? "" : " ") + line.trim();
            }
        }
        flush();
        return parts.join("");
    }

    // How many releases those notes cover, counted separately rather than
    // recorded as a side effect of rendering them: the rendering is a binding
    // now, and a binding that assigns to another property is a trap
    function _changelogSections(md, local) {
        let sections = 0;
        for (const line of md.split("\n")) {
            if (line.indexOf("## ") !== 0)
                continue;
            const found = line.match(/\d+(?:\.\d+)+/);
            if (found !== null && _versionNewer(found[0], local))
                sections++;
        }
        return sections;
    }

    // The inline marks the changelog actually uses
    function _notesInline(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/`([^`]+)`/g, "<font face=\"" + Theme.monoFontFamily + "\">$1</font>").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
    }

    // How many releases the notes above cover, so a truncated banner is
    // read as "there is more" rather than as "that was all"
    readonly property int _selfUpdateSections: _changelogSections(selfUpdateMarkdown, selfUpdateLocalVersion)

    Timer {
        interval: 30 * 1000
        running: true
        onTriggered: selfUpdateProcess.running = true
    }

    Timer {
        interval: 24 * 3600 * 1000
        running: true
        repeat: true
        onTriggered: selfUpdateProcess.running = true
    }

    Process {
        id: selfUpdateProcess

        // Exit 3 on a symlinked (development) install: never self-update a
        // working copy. Fetched with the Python the helpers already need
        // rather than curl, which is not a dependency.
        command: [Backend.python, "-c", [
            "import os, sys, urllib.request",
            "if any(os.path.islink(os.path.expanduser('~/.config/' + d + '/plugins/dankSoftwareDepot')) for d in ('dms', 'DankMaterialShell')): sys.exit(3)",
            "def get(url):",
            "    try:",
            "        with urllib.request.urlopen(url, timeout=15) as resp: return resp.read().decode('utf-8', 'replace')",
            "    except Exception: return ''",
            "print(get(sys.argv[1] + '/main/plugin.json'))",
            "print('---NOTES---')",
            "print(get(sys.argv[1] + '/main/CHANGELOG.md'))"
        ].join("\n"), win.githubUrl.replace("github.com", "raw.githubusercontent.com")]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.split("---NOTES---");
                let remote = null;
                try {
                    remote = JSON.parse(parts[0]);
                } catch (e) {
                    return;
                }
                const localVersion = win.pluginManifest.version || "0";
                if (!remote || !remote.version || !win._versionNewer(remote.version, localVersion))
                    return;
                win.selfUpdateLocalVersion = localVersion;
                win.selfUpdateMarkdown = parts[1] || "";
                win.selfUpdateVersion = remote.version;
                if (win.widgetRoot)
                    win.widgetRoot.notifyPluginUpdate(remote.version, win._selfUpdateSections);
            }
        }
    }

    // ── Plugin settings popup (gear icon in header) ────────────────────────
    property bool settingsOpen: false
    property string settingsTab: "settings"
    property bool showUpdateChangelog: false

    onSettingsOpenChanged: {
        if (!settingsOpen)
            return;
        settingsFocus.forceActiveFocus();
        if (Backend.developmentInstall)
            Backend.refreshRecordings();
    }

    Rectangle {
        anchors.fill: parent
        visible: win.settingsOpen
        z: 90
        color: Qt.rgba(0, 0, 0, 0.55)

        MouseArea {
            anchors.fill: parent
            onClicked: win.settingsOpen = false
            onWheel: wheel => wheel.accepted = true
        }

        Item {
            id: settingsFocus
            Keys.onEscapePressed: win.settingsOpen = false
        }

        Rectangle {
            id: settingsCard
            anchors.centerIn: parent
            width: Math.min(560, parent.width - Theme.spacingL * 2)
            height: Math.min(620, parent.height - Theme.spacingL * 2)
            radius: Theme.cornerRadius + 4
            color: Ui.cardSurface
            border.width: 0

            scale: win.settingsOpen ? 1.0 : 0.94
            opacity: win.settingsOpen ? 1.0 : 0.0
            Behavior on scale { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutBack } }
            Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }

            MouseArea {
                anchors.fill: parent
            }

            ColumnLayout {
                id: settingsColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                // Header row
                RowLayout {
                    id: settingsHeaderRow
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    Rectangle {
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        radius: 8
                        color: Theme.withAlpha(Theme.primary, 0.10)
                        border.width: 0

                        DankIcon {
                            anchors.centerIn: parent
                            name: win.settingsTab === "about" ? "info" : "settings"
                            size: 20
                            color: Theme.primary
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: win.settingsTab === "about" ? Tr.t("About & System Info") : Tr.t("Plugin Settings")
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    Rectangle {
                        id: settingsCloseBtn
                        width: 32
                        height: 32
                        property bool isHovered: setCloseMa.containsMouse

                        radius: setCloseMa.pressed ? (height / 2) : (Theme.cornerRadius / 2)
                        Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                        // A standard icon button: no container until hovered,
                        // and then a red state layer, since it closes
                        color: isHovered ? Theme.withAlpha(Theme.error, 0.12) : Ui.buttonFill("icon", false)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: setCloseMa.pressed ? 0.92 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple {
                            id: setCloseRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.failColor
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "close"
                            size: 18
                            color: settingsCloseBtn.isHovered ? Ui.failColor : Ui.buttonInk("icon")
                        }

                        MouseArea {
                            id: setCloseMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => setCloseRip.trigger(m.x, m.y)
                            onClicked: win.settingsOpen = false
                        }
                    }
                }

                // Dynamic segmented switcher between Settings and About
                Rectangle {
                    id: settingsTabsSegment
                    Layout.fillWidth: true
                    height: 38
                    // A pill, like the active tab inside it: with the dialog's
                    // corner radius the two curves ran at different rates
                    radius: height / 2
                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                    border.width: 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 3
                        spacing: 4

                        // Tab 1: Preferences
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            readonly property bool isTabActive: win.settingsTab === "settings"
                            property bool isTabHovered: setTabMa.containsMouse

                            topLeftRadius: height / 2
                            bottomLeftRadius: height / 2
                            topRightRadius: (isTabActive || isTabHovered) ? ((height) / 2) : 4
                            bottomRightRadius: (isTabActive || isTabHovered) ? ((height) / 2) : 4

                            Behavior on topLeftRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            Behavior on topRightRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            Behavior on bottomRightRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                            color: isTabActive ? Theme.primary : (isTabHovered ? Theme.withAlpha(Theme.primary, 0.15) : "transparent")
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 6

                                DankIcon {
                                    name: "settings"
                                    size: 16
                                    color: parent.parent.isTabActive ? Theme.primaryText : (parent.parent.isTabHovered ? Theme.primary : Theme.surfaceVariantText)
                                }

                                StyledText {
                                    text: Tr.t("Preferences")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: parent.parent.isTabActive ? Font.DemiBold : Font.Normal
                                    color: parent.parent.isTabActive ? Theme.primaryText : (parent.parent.isTabHovered ? Theme.primary : Theme.surfaceVariantText)
                                }
                            }

                            MouseArea {
                                id: setTabMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: win.settingsTab = "settings"
                            }
                        }

                        // Tab 2: About / Info
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            readonly property bool isTabActive: win.settingsTab === "about"
                            property bool isTabHovered: abtTabMa.containsMouse

                            topLeftRadius: (isTabActive || isTabHovered) ? ((height) / 2) : 4
                            bottomLeftRadius: (isTabActive || isTabHovered) ? ((height) / 2) : 4
                            topRightRadius: height / 2
                            bottomRightRadius: height / 2

                            Behavior on topLeftRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            Behavior on topRightRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            Behavior on bottomRightRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                            color: isTabActive ? Theme.primary : (isTabHovered ? Theme.withAlpha(Theme.primary, 0.15) : "transparent")
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 6

                                DankIcon {
                                    name: "info"
                                    size: 16
                                    color: parent.parent.isTabActive ? Theme.primaryText : (parent.parent.isTabHovered ? Theme.primary : Theme.surfaceVariantText)
                                }

                                StyledText {
                                    text: Tr.t("About & Info")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: parent.parent.isTabActive ? Font.DemiBold : Font.Normal
                                    color: parent.parent.isTabActive ? Theme.primaryText : (parent.parent.isTabHovered ? Theme.primary : Theme.surfaceVariantText)
                                }
                            }

                            MouseArea {
                                id: abtTabMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: win.settingsTab = "about"
                            }
                        }
                    }
                }

                Item {
                    id: settingsContentContainer
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    // ═════════════════════════════════════════════════════
                    // 1. PREFERENCES VIEW (Dynamic Segmented Rows with Icons)
                    // ═════════════════════════════════════════════════════
                    // DankFlickable rather than a bare Flickable: the shell's
                    // wheel and touchpad momentum, and its scrollbar
                    DankFlickable {
                        id: prefFlickable
                        Component.onCompleted: Ui.softenScrollbar(prefFlickable)
                        anchors.fill: parent
                        contentWidth: width
                        contentHeight: prefColumn.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        opacity: win.settingsTab === "settings" ? 1.0 : 0.0
                        transform: Translate {
                            x: win.settingsTab === "settings" ? 0 : -24
                            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
                        }
                        Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }
                        visible: opacity > 0.0

                        Column {
                            id: prefColumn
                            width: prefFlickable.width
                            spacing: 2

                            // 1. Hide when up to date (First)
                            Rectangle {
                                width: prefColumn.width
                                height: row1.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: true
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row1
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "visibility_off"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Hide when up to date")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Hide the bar pill while there are no pending updates.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t1
                                        hideText: true
                                        checked: win.widgetRoot ? win.widgetRoot.hideWhenUpToDate : false
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "hideWhenUpToDate", checked)
                                    }
                                }
                            }

                            // 2. Show runtimes and extensions (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row2.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row2
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "extension"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Show runtimes and extensions")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("List Flatpak runtimes, locales and codec extensions. They are always included in Update All.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t2
                                        hideText: true
                                        checked: win.widgetRoot ? win.widgetRoot.showRuntimes : false
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "showRuntimes", checked)
                                    }
                                }
                            }

                            // 3. Include firmware updates (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row3.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row3
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "memory"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Include firmware updates")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Check for device firmware updates via fwupd (LVFS) and include them in Update All.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t3
                                        hideText: true
                                        checked: win.widgetRoot ? win.widgetRoot.includeFirmware : true
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "includeFirmware", checked)
                                    }
                                }
                            }

                            // 4. Confirm before updating (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row4.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row4
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "check_circle"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Confirm before updating")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Require a second click on Update All before the run starts.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t4
                                        hideText: true
                                        checked: win.widgetRoot ? win.widgetRoot.confirmBeforeUpdate : false
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "confirmBeforeUpdate", checked)
                                    }
                                }
                            }

                            // 5. Authorise with sudo (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row5.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row5
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "admin_panel_settings"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Authorise with sudo")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Run privileged commands through sudo instead of asking polkit, for systems where sudo has been configured to need no password. Falls back to the usual prompt whenever sudo would ask for one.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t5
                                        hideText: true
                                        checked: Backend.useSudo
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "useSudo", checked)
                                    }
                                }
                            }

                            // 6. Tint app icons with the theme colour (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row6.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row6
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "palette"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Tint app icons with the theme colour")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Draw app icons in greyscale and colour them with the active DMS accent, instead of showing each app's own colours.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t6
                                        hideText: true
                                        checked: Ui.tintAppIcons
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "tintAppIcons", checked)
                                    }
                                }
                            }

                            // 7. Show in app launcher (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row7.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row7
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "apps"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Show in app launcher")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Place a desktop entry so this window can be opened from the application launcher, like a standalone app.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t7
                                        hideText: true
                                        checked: Backend.launcherEntryPresent
                                        enabled: Backend.launcherEntryChecked && !Backend.launcherEntryBusy
                                        onToggled: checked => {
                                            if (checked)
                                                Backend.installLauncherEntry();
                                            else
                                                Backend.removeLauncherEntry();
                                            PluginService.savePluginData("dankSoftwareDepot", "launcherPromptDone", true);
                                        }
                                    }
                                }
                            }

                            // 8. Open .appimage files with this app (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row8.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row8
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "insert_drive_file"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Open .appimage files with this app")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Double-clicking an AppImage opens this window, which offers to install it — or to replace the copy you already have. Adds the launcher entry if it is not there yet.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t8
                                        hideText: true
                                        checked: Backend.appimageHandlerDefault
                                        enabled: Backend.appimageHandlerChecked && !Backend.appimageHandlerBusy && !Backend.launcherEntryBusy
                                        onToggled: checked => {
                                            if (checked)
                                                Backend.setAppimageHandler();
                                            else
                                                Backend.clearAppimageHandler();
                                        }
                                    }
                                }
                            }

                            // 9. Bar click opens window (Middle)
                            Rectangle {
                                width: prefColumn.width
                                height: row9.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: false
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                RowLayout {
                                    id: row9
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "open_in_browser"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            text: Tr.t("Bar click opens window")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: Tr.t("Open this window instead of the compact popout when clicking the bar pill. Right-click always opens the window.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankToggle {
                                        id: t9
                                        hideText: true
                                        checked: win.widgetRoot ? win.widgetRoot.pillOpensWindow : false
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "pillOpensWindow", checked)
                                    }
                                }
                            }

                            // 10. Automatic updates (Last - Stacked layout)
                            Rectangle {
                                width: prefColumn.width
                                height: autoCol.implicitHeight + Theme.spacingM * 2
                                readonly property bool isFirst: false
                                readonly property bool isLast: true
                                readonly property real outerR: Theme.cornerRadius
                                readonly property real innerR: 4

                                topLeftRadius: isFirst ? outerR : innerR
                                topRightRadius: isFirst ? outerR : innerR
                                bottomLeftRadius: isLast ? outerR : innerR
                                bottomRightRadius: isLast ? outerR : innerR

                                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                border.width: 0

                                ColumnLayout {
                                    id: autoCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingS

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingM

                                        DankIcon {
                                            name: "sync"
                                            size: 20
                                            color: Theme.primary
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2

                                            StyledText {
                                                text: Tr.t("Automatic updates")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Notify when updates are found, and optionally install Flatpak updates automatically. System packages always ask first.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }

                                    DankDropdown {
                                        id: t10
                                        readonly property var autoMap: ({
                                                "Off": "off",
                                                "Notify only": "notify",
                                                "Auto-install Flatpaks": "auto"
                                            })

                                        Layout.fillWidth: true
                                        compactMode: true
                                        dropdownWidth: parent.width
                                        options: Object.keys(autoMap).map(k => Tr.t(k))
                                        currentValue: {
                                            const mode = win.widgetRoot ? win.widgetRoot.autoUpdateMode : "notify";
                                            for (const label in autoMap) {
                                                if (autoMap[label] === mode)
                                                    return Tr.t(label);
                                            }
                                            return Tr.t("Off");
                                        }
                                        onValueChanged: value => {
                                            for (const label in autoMap) {
                                                if (Tr.t(label) === value) {
                                                    PluginService.savePluginData("dankSoftwareDepot", "autoUpdateMode", autoMap[label]);
                                                    return;
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // ── Developer: record a run, play it back ───────────────
                            // Only on a working copy (the plugin directory is a
                            // symlink), which is also the only place it means
                            // anything. Deliberately untranslated: sixteen catalogs
                            // carrying strings that appear on one machine in the
                            // world is a cost with no reader.
                            // prefColumn is a plain Column, so this one is
                            // sized rather than Layout.fillWidth'd; its own
                            // children are laid out by it as before.
                            ColumnLayout {
                                width: prefColumn.width
                                spacing: Theme.spacingS
                                visible: Backend.developmentInstall

                                StyledText {
                                    Layout.fillWidth: true
                                    text: "Developer"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceVariantText
                                }

                                Column {
                                    Layout.fillWidth: true

                                    DankToggle {
                                        width: parent.width
                                        text: "Record the next update run"
                                        description: "Wraps every helper the run starts and writes what it says to recordings/, alongside the list of packages the window was showing. The run itself is untouched."
                                        checked: Backend.simMode === "record"
                                        onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "simMode", checked ? "record" : "")
                                    }
                                }

                                // A replay is a run in every respect the interface can
                                // see, so it needs to be unmistakable from the outside.
                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: Backend.replaying
                                    implicitHeight: simulatingRow.implicitHeight + Theme.spacingM * 2
                                    radius: Theme.cornerRadius
                                    color: Theme.withAlpha(Theme.secondary, 0.14)

                                    RowLayout {
                                        id: simulatingRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM

                                        DankIcon {
                                            name: "science"
                                            size: 20
                                            color: Theme.secondary
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: "Simulating " + Backend.simRecording + " — nothing is being installed, and nothing reaches the log"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            wrapMode: Text.WordWrap
                                        }

                                        DankButton {
                                            buttonHeight: 28
                                            horizontalPadding: Theme.spacingM
                                            text: "Stop"
                                            backgroundColor: Ui.buttonFill("filled", false)
                                            textColor: Ui.buttonInk("filled")
                                            onClicked: PluginService.savePluginData("dankSoftwareDepot", "simMode", "")
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: "Speed"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    Repeater {
                                        model: [1, 2, 4, 10]

                                        delegate: DankButton {
                                            required property var modelData

                                            buttonHeight: 26
                                            horizontalPadding: Theme.spacingS
                                            text: modelData + "×"
                                            backgroundColor: Ui.buttonFill(Backend.simSpeed === modelData ? "filled" : "tonal", false)
                                            textColor: Ui.buttonInk(Backend.simSpeed === modelData ? "filled" : "tonal")
                                            onClicked: PluginService.savePluginData("dankSoftwareDepot", "simSpeed", modelData)
                                        }
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                    }

                                    DankButton {
                                        buttonHeight: 26
                                        horizontalPadding: Theme.spacingS
                                        iconName: "refresh"
                                        iconSize: 14
                                        text: "Rescan"
                                        backgroundColor: Ui.buttonFill("tonal", false)
                                        textColor: Ui.buttonInk("tonal")
                                        onClicked: Backend.refreshRecordings()
                                    }
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: Backend.recordings.length === 0
                                    text: Backend.simMode === "record" ? "Nothing recorded yet — the next Update All will be." : "Nothing recorded yet."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }

                                Repeater {
                                    model: Backend.recordings

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingM

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.name + " · " + modelData.packages + " packages · "
                                                + modelData.seconds + "s · " + (modelData.tags || []).join(", ")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Backend.simRecording === modelData.name ? Theme.primary : Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        DankButton {
                                            buttonHeight: 26
                                            horizontalPadding: Theme.spacingM
                                            iconName: "play_arrow"
                                            iconSize: 14
                                            text: "Play"
                                            enabled: !win.engine.running
                                            backgroundColor: Ui.buttonFill("tonal", false)
                                            textColor: Ui.buttonInk("tonal")
                                            onClicked: {
                                                PluginService.savePluginData("dankSoftwareDepot", "simRecording", modelData.name);
                                                PluginService.savePluginData("dankSoftwareDepot", "simMode", "replay");
                                                win.settingsOpen = false;
                                                // The list the run is about arrives
                                                // with the recording, and it arrives
                                                // asynchronously — start when it is
                                                // there, not before.
                                                simulationStart.begin();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ═════════════════════════════════════════════════════
                    // 2. ABOUT / INFO VIEW (Animated Slide In)
                    // ═════════════════════════════════════════════════════
                    DankFlickable {
                        id: aboutFlickable
                        Component.onCompleted: Ui.softenScrollbar(aboutFlickable)
                        anchors.fill: parent
                        contentWidth: width
                        contentHeight: aboutScrollColumn.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        opacity: win.settingsTab === "about" ? 1.0 : 0.0
                        transform: Translate {
                            x: win.settingsTab === "about" ? 0 : 24
                            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
                        }
                        Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }
                        visible: opacity > 0.0

                        ColumnLayout {
                            id: aboutScrollColumn
                            width: aboutFlickable.width
                            spacing: Theme.spacingM

                            // ── About & Plugin Info Card ───────────────────────────
                            StyledRect {
                                Layout.fillWidth: true
                                radius: Theme.cornerRadius
                                // Holds chips and buttons, each already a container
                                color: "transparent"
                                border.width: 0
                                implicitHeight: aboutCardCol.implicitHeight + Theme.spacingM * 2

                                ColumnLayout {
                                    id: aboutCardCol
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingM

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingM

                                        Rectangle {
                                            Layout.preferredWidth: 46
                                            Layout.preferredHeight: 46
                                            radius: Theme.cornerRadius
                                            color: Theme.withAlpha(Theme.primary, 0.10)
                                            border.width: 0

                                            Image {
                                                anchors.fill: parent
                                                anchors.margins: 4
                                                source: win.appIconSource
                                                sourceSize.width: 80
                                                sourceSize.height: 80
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: true
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2

                                            StyledText {
                                                text: "Dux Software Depot"
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.DemiBold
                                                color: Theme.surfaceText
                                            }

                                            StyledText {
                                                text: Tr.t("Version %1 (beta)").arg(win.pluginManifest.version || "?")
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceVariantText
                                            }
                                        }
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: win.pluginManifest.description ? Tr.t(win.pluginManifest.description) : Tr.t("Visual updater and software hub for Dux Shell.")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: Tr.t("Supports %1 packages, Flatpak and AppImage.").arg(Backend.systemRepoLabel)
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }

                                    // The name follows the shell's, with Dux Labs' permission;
                                    // it does not make this theirs, and nobody should go to them
                                    // with a problem in it
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: Tr.t("An unofficial community plugin by %1, not made or supported by Dux Labs.").arg(win.pluginManifest.author || "Vincent Blok")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }

                                    // Update notice inside settings with Fully Expanding Changelog Container
                                    Rectangle {
                                        Layout.fillWidth: true
                                        visible: win.selfUpdateVersion !== ""
                                        implicitHeight: aboutUpdateBox.implicitHeight + Theme.spacingM * 2
                                        radius: Theme.cornerRadius
                                        color: Theme.withAlpha(Theme.primary, 0.12)

                                        ColumnLayout {
                                            id: aboutUpdateBox
                                            anchors.fill: parent
                                            anchors.margins: Theme.spacingM
                                            spacing: Theme.spacingS

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: Theme.spacingS

                                                DankIcon {
                                                    name: "update"
                                                    size: 16
                                                    color: Theme.primary
                                                }

                                                StyledText {
                                                    Layout.fillWidth: true
                                                    text: Tr.t("Update to %1 available").arg(win.selfUpdateVersion)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Medium
                                                    color: Theme.primary
                                                }
                                            }

                                            // Two separate actions: the changelog is tonal (accent
                                            // while open), Update & Reload the one filled button
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: Theme.spacingS

                                                // 1. Show/Hide Changelog
                                                Rectangle {
                                                    id: logBtn
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: 34
                                                    property bool isHov: logBtnMa.containsMouse
                                                    readonly property string kind: win.showUpdateChangelog ? "accent" : "tonal"

                                                    radius: (logBtnMa.pressed || win.showUpdateChangelog) ? (height / 2) : Theme.cornerRadius
                                                    Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                                                    color: Ui.buttonFill(kind, isHov)
                                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                                    scale: logBtnMa.pressed ? 0.94 : 1.0
                                                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                                                    RowLayout {
                                                        anchors.centerIn: parent
                                                        spacing: 6

                                                        DankIcon {
                                                            name: win.showUpdateChangelog ? "expand_less" : "article"
                                                            size: 16
                                                            color: Ui.buttonInk(logBtn.kind)
                                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                                                        }

                                                        StyledText {
                                                            text: win.showUpdateChangelog ? Tr.t("Hide Changelog") : Tr.t("View Changelog")
                                                            font.pixelSize: Theme.fontSizeSmall - 1
                                                            font.weight: Font.Medium
                                                            color: Ui.buttonInk(logBtn.kind)
                                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                                                        }
                                                    }

                                                    MouseArea {
                                                        id: logBtnMa
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: win.showUpdateChangelog = !win.showUpdateChangelog
                                                    }
                                                }

                                                // 2. Update and reload
                                                Rectangle {
                                                    Layout.fillWidth: true
                                                    Layout.preferredHeight: 34
                                                    property bool isHov: updBtnMa.containsMouse

                                                    radius: updBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                                                    Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                                                    color: Ui.buttonFill("filled", isHov)
                                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                                    scale: updBtnMa.pressed ? 0.94 : 1.0
                                                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                                                    RowLayout {
                                                        anchors.centerIn: parent
                                                        spacing: 6

                                                        DankIcon {
                                                            name: "download"
                                                            size: 14
                                                            color: Ui.buttonInk("filled")
                                                        }

                                                        StyledText {
                                                            text: win.selfUpdateBusy ? Tr.t("Updating…") : Tr.t("Update & Reload")
                                                            font.pixelSize: Theme.fontSizeSmall - 1
                                                            font.weight: Font.Medium
                                                            color: Ui.buttonInk("filled")
                                                        }
                                                    }

                                                    MouseArea {
                                                        id: updBtnMa
                                                        anchors.fill: parent
                                                        hoverEnabled: !win.selfUpdateBusy
                                                        cursorShape: !win.selfUpdateBusy ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                        onClicked: {
                                                            win.settingsOpen = false;
                                                            win.applySelfUpdate();
                                                        }
                                                    }
                                                }
                                            }

                                            // Full expanding changelog box (No nested inner scroll, expands parent naturally)
                                            Rectangle {
                                                id: changelogBox
                                                Layout.fillWidth: true
                                                clip: true
                                                implicitHeight: win.showUpdateChangelog ? (notesText.implicitHeight + 20) : 0
                                                opacity: win.showUpdateChangelog ? 1.0 : 0.0
                                                radius: 8
                                                color: Theme.withAlpha(Theme.surfaceContainerLowest, 0.55)

                                                Behavior on implicitHeight { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                                                Behavior on opacity { NumberAnimation { duration: Theme.longDuration } }

                                                Item {
                                                    anchors.fill: parent
                                                    anchors.margins: 10

                                                    StyledText {
                                                        id: notesText
                                                        anchors.left: parent.left
                                                        anchors.right: parent.right
                                                        anchors.top: parent.top
                                                        text: win.selfUpdateNotes
                                                        textFormat: Text.RichText
                                                        font.pixelSize: Theme.fontSizeSmall - 1
                                                        color: Theme.surfaceText
                                                        wrapMode: Text.WordWrap
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Support & Community Chips (Upvote, Star, Vito)
                                    // Stacked, not in a row: three of these
                                    // side by side need about 500 pixels and
                                    // this card does not have them, so the
                                    // third hung over the edge. Left, because
                                    // every other thing in the card starts at
                                    // the left margin.
                                    SupportChips {
                                        Layout.fillWidth: true
                                        Layout.topMargin: Theme.spacingXS
                                        Layout.bottomMargin: Theme.spacingXS
                                        columns: 1
                                        chipAlignment: Qt.AlignLeft
                                        repoUrl: win.githubUrl
                                    }

                                    // GitHub & Issue Tracker: two separate tonal buttons,
                                    // not a connected group
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        // 1. GitHub (First)
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 34
                                            property bool isHov: ghMa.containsMouse

                                            radius: ghMa.pressed ? (height / 2) : Theme.cornerRadius
                                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                                            color: Ui.buttonFill("tonal", isHov)
                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                            RowLayout {
                                                anchors.centerIn: parent
                                                spacing: 6

                                                DankIcon {
                                                    name: "code"
                                                    size: 16
                                                    color: Ui.buttonInk("tonal")
                                                }

                                                StyledText {
                                                    text: Tr.t("GitHub Repository")
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    color: Ui.buttonInk("tonal")
                                                }
                                            }

                                            MouseArea {
                                                id: ghMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Qt.openUrlExternally(win.githubUrl)
                                            }
                                        }

                                        // 2. Report Bug (Last)
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 34
                                            property bool isHov: issueMa.containsMouse

                                            radius: issueMa.pressed ? (height / 2) : Theme.cornerRadius
                                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                                            color: Ui.buttonFill("tonal", isHov)
                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                            RowLayout {
                                                anchors.centerIn: parent
                                                spacing: 6

                                                DankIcon {
                                                    name: "bug_report"
                                                    size: 16
                                                    color: Ui.buttonInk("tonal")
                                                }

                                                StyledText {
                                                    text: Tr.t("Report an Issue")
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    color: Ui.buttonInk("tonal")
                                                }
                                            }

                                            MouseArea {
                                                id: issueMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Qt.openUrlExternally(win.githubUrl + "/issues")
                                            }
                                        }
                                    }
                                }
                            }

                            // ── System Links Container Card ────────────────────────
                            StyledRect {
                                Layout.fillWidth: true
                                radius: Theme.cornerRadius
                                // Holds two buttons, each already a container
                                color: "transparent"
                                border.width: 0
                                implicitHeight: sysCardCol.implicitHeight + Theme.spacingM * 2

                                ColumnLayout {
                                    id: sysCardCol
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingS

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: Tr.t("DMS Integration")
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: Tr.t("Check interval and ignored packages are managed in DMS Settings → System Updater.")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }

                                    // Two separate tonal buttons
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        // 1. System Updater (First)
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 34
                                            property bool isHov: dmsSetMa.containsMouse

                                            radius: dmsSetMa.pressed ? (height / 2) : Theme.cornerRadius
                                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                                            color: Ui.buttonFill("tonal", isHov)
                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                            RowLayout {
                                                anchors.centerIn: parent
                                                spacing: 6

                                                DankIcon {
                                                    name: "open_in_new"
                                                    size: 14
                                                    color: Ui.buttonInk("tonal")
                                                }

                                                StyledText {
                                                    text: Tr.t("System Updater Settings")
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    color: Ui.buttonInk("tonal")
                                                }
                                            }

                                            MouseArea {
                                                id: dmsSetMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    win.settingsOpen = false;
                                                    PopoutService.openSettingsWithTab("updater");
                                                }
                                            }
                                        }

                                        // 2. Manage Plugins (Last)
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 34
                                            property bool isHov: dmsPlugMa.containsMouse

                                            radius: dmsPlugMa.pressed ? (height / 2) : Theme.cornerRadius
                                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                                            color: Ui.buttonFill("tonal", isHov)
                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                            RowLayout {
                                                anchors.centerIn: parent
                                                spacing: 6

                                                DankIcon {
                                                    name: "open_in_new"
                                                    size: 14
                                                    color: Ui.buttonInk("tonal")
                                                }

                                                StyledText {
                                                    text: Tr.t("Manage Plugins")
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    color: Ui.buttonInk("tonal")
                                                }
                                            }

                                            MouseArea {
                                                id: dmsPlugMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    win.settingsOpen = false;
                                                    PopoutService.openSettingsWithTab("plugins");
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    function startSimulation() {
        simulationStart.begin();
    }

    // The recording's package list is read from disk, so it arrives a moment
    // after the mode changes — and starting a run before it is there would
    // start a run over an empty list, which the engine correctly refuses.
    Timer {
        id: simulationStart

        property int tries: 0

        interval: 150
        repeat: true

        function begin() {
            tries = 0;
            restart();
        }

        onTriggered: {
            if (!Backend.replaying || win.engine.running) {
                stop();
                return;
            }
            if ((Backend.simPackages || []).length > 0) {
                stop();
                win.engine.start({});
                return;
            }
            if (++tries > 30)
                stop();
        }
    }

    // Refresh relative timestamps once a minute while the window is open
    property int nowUnix: Math.floor(Date.now() / 1000)

    Timer {
        interval: 60000
        running: win.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: win.nowUnix = Math.floor(Date.now() / 1000)
    }

    function formatAgo(unix) {
        if (!unix)
            return "";
        const delta = Math.max(0, nowUnix - unix);
        if (delta < 90)
            return Tr.t("just now");
        if (delta < 3600)
            return Tr.t("%1m ago").arg(Math.round(delta / 60));
        if (delta < 86400)
            return Tr.t("%1h ago").arg(Math.round(delta / 3600));
        return Tr.t("%1d ago").arg(Math.round(delta / 86400));
    }

    title: "Dux Software Depot"
    minimumSize: Qt.size(560, 420)
    implicitWidth: 760
    implicitHeight: 640
    // The tone DMS paints its own floating windows with, so this window does
    // not sit beside DMS Settings looking like a different application.
    //
    // Asked for by name rather than by inheriting DankFloatingWindow, which
    // is what 0.9.7 did and what made this plugin impossible to enable on
    // every DMS that is not a recent git build: the type arrived upstream on
    // 6 August 2026, after 1.5.3, and a QML file naming a type that does not
    // exist does not degrade — it fails to load, taking the whole plugin with
    // it. The same release added the colour, so that is asked for defensively
    // too and falls back to the tone it is derived from.
    color: Theme.floatingWindowSurface !== undefined ? Theme.floatingWindowSurface : Ui.cardSurface
    visible: false

    // A compositor-side close (Super+Q) kills the toplevel without updating
    // our visible flag, so the next `visible = true` becomes a no-op and the
    // window can never reopen. Resync on close.
    onClosed: visible = false

    function toggle() {
        visible = !visible;
    }

    // Dashboard shows whenever nothing is actionable — including when only
    // held updates remain (those don't count as out-of-date)
    readonly property bool dashboardMode: !showingRun && effectiveCount === 0

    // Collapsible sections (collapsed by default). A long run finishes far
    // more packages than it is working on; leaving that pile open would push
    // the active rows off screen, which is the opposite of the point.
    property var collapsedCats: ({
            "6 · Held packages": true,
            "4 · Completed": true
        })

    function toggleCategory(category) {
        const updated = Object.assign({}, collapsedCats);
        updated[category] = !updated[category];
        collapsedCats = updated;
    }

    // Own app icon, following the active light/dark theme
    readonly property url appIconSource: Qt.resolvedUrl("assets/icons/dux-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg")

    // ── Dashboard data (up-to-date empty state) ─────────────────────────────
    property var dashboard: null
    property double _dashFetchedAt: 0

    function refreshDashboard() {
        const now = Date.now();
        if (now - _dashFetchedAt < 60 * 1000 || dashboardProcess.running)
            return;
        _dashFetchedAt = now;
        dashboardProcess.command = [Backend.python, Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--dashboard"];
        dashboardProcess.running = true;
    }

    Process {
        id: dashboardProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    win.dashboard = JSON.parse(text);
                } catch (e) {
                }
            }
        }
    }

    // ── OS compatibility: dnf-based features assume a Fedora-family distro.
    // Non-empty when running on anything whose os-release ID/ID_LIKE lacks
    // "fedora"; holds the distro's pretty name for the warning banner.
    property string osIncompatiblePretty: ""

    Process {
        id: osCheckProcess
        running: true
        command: ["sh", "-c", ". /etc/os-release 2>/dev/null; echo \"$ID $ID_LIKE|$PRETTY_NAME\""]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("|");
                const ids = (parts[0] || "").toLowerCase().split(/\s+/).filter(t => t !== "");
                const supported = ["fedora", "debian", "ubuntu", "arch", "manjaro"].some(id => ids.indexOf(id) >= 0);
                win.osIncompatiblePretty = (ids.length > 0 && !supported) ? ((parts[1] || "").trim() || parts[0].trim()) : "";
            }
        }
    }

    function formatUptime(secs) {
        if (secs <= 0)
            return "";
        const days = Math.floor(secs / 86400);
        const hours = Math.floor((secs % 86400) / 3600);
        const mins = Math.floor((secs % 3600) / 60);
        if (days > 0)
            return days + "d " + hours + "h";
        if (hours > 0)
            return hours + "h " + mins + "m";
        return mins + "m";
    }

    // Fresh start on reopen: whenever the window opens (after having been
    // closed) it shows the Updates tab. openTab() runs after this and can
    // still select a specific tab explicitly.
    onVisibleChanged: {
        if (visible) {
            tabs.currentIndex = 0;
            refreshDashboard();
            // Throttled to a few hours inside the script, so this is a
            // question about state rather than a fetch
            newsDialog.refresh(false);
            // A palette left open when the window closed must not be what
            // greets you when it comes back
            palette.close();
            Backend.checkLauncherEntry();
            Backend.checkAppimageHandler();
        }
    }

    // The same after sitting unused: an open but unfocused window falls back
    // to the Updates tab after a few minutes.
    Timer {
        interval: 3 * 60 * 1000
        running: win.visible && !win.focused
        onTriggered: tabs.currentIndex = 0
    }

    // ── Which tabs exist ────────────────────────────────────────────────────
    // Firmware is a setting, and a tab for something the user switched off is
    // just a dead end. Hiding it makes the bar's positions stop matching the
    // tab numbers, so everything else speaks in stable ids and only the bar
    // itself works in positions.
    readonly property bool firmwareEnabled: firmware !== null
    readonly property var tabIds: firmwareEnabled ? [0, 1, 2, 3, 4] : [0, 1, 2, 4]
    readonly property int currentTab: tabIds[Math.min(tabs.currentIndex, tabIds.length - 1)]
    // Where a hidden tab waits to slide in from: the side it sits on in the
    // tab bar, seen from the tab now showing. A pure binding on currentTab,
    // so it is settled before the switch — a direction set in the tab bar's
    // handler raced the visibility bindings on the same index, and a tab
    // came in from whichever side the switch before it had gone.
    function tabEntryOffset(id) {
        return tabIds.indexOf(id) > tabIds.indexOf(currentTab) ? 40 : -40;
    }

    // Switching firmware off while looking at it would silently land you on
    // whatever slid into that position — go somewhere deliberate instead
    onFirmwareEnabledChanged: {
        if (!firmwareEnabled && tabs.currentIndex >= tabIds.length)
            tabs.currentIndex = 0;
    }

    // Opening an app that is already open should bring it to you, not appear
    // to do nothing because the window sits behind three others. A Wayland
    // window cannot raise itself and the window API has no call for it, so
    // the compositor is asked instead; where we cannot ask, the surface is
    // re-mapped, which every compositor treats as a window that just opened.
    function activate() {
        if (!visible) {
            visible = true;
            return;
        }
        if (minimized)
            minimized = false;
        if (focused)
            return;
        if (CompositorService.isNiri) {
            const match = (NiriService.windows || []).find(w => w.title === win.title);
            if (match) {
                NiriService.focusWindow(match.id);
                return;
            }
        }
        if (CompositorService.isHyprland) {
            Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "title:^" + win.title + "$"]);
            return;
        }
        visible = false;
        Qt.callLater(() => win.visible = true);
    }

    // Back to the bare window: every popup, panel and dialog closed. The
    // screenshots set up one scene after another, and each has to start
    // from the same place for the previous one not to show through.
    function closeAllPopups() {
        settingsOpen = false;
        aboutOpen = false;
        palette.close();
        sourcesDialog.close();
        newsDialog.close();
        logDialog.close();
        updatesDialog.close();
        const install = tabView(2);
        if (install && install.closeDialogs)
            install.closeDialogs();
    }

    readonly property bool updateDetailsLoading: updatesDialog.loading

    function openSourcesDialog() {
        sourcesDialog.open();
    }

    function openPalette() {
        palette.open();
    }

    // Rebuild the tabs that keep what they loaded, so a language switch
    // reaches them too; the one showing comes back by itself through openTab
    function reloadTabs() {
        for (const loader of [installedLoader, installLoader, firmwareLoader, logLoader])
            loader.active = false;
    }

    // The loaded view behind a tab id, for the handful of places that drive a
    // tab from outside it
    function tabView(id) {
        switch (id) {
        case 1:
            return installedLoader.item;
        case 2:
            return installLoader.item;
        case 3:
            return firmwareLoader.item;
        case 4:
            return logLoader.item;
        }
        return null;
    }

    // An AppImage — or a .flatpak or .flatpakref — opened from the file
    // manager. It lands on the Install tab, which already owns installing
    // one; the dialog there reads which of them it is.
    function openAppimageFile(path) {
        if (!path)
            return;
        activate();
        openTab(2);
        // The view may have only just been created by openTab, so hand the
        // file over once it exists rather than at this instant
        Qt.callLater(() => {
            const view = tabView(2);
            if (view && view.offerAppimageFile)
                view.offerAppimageFile(path);
        });
    }

    function openTab(id) {
        visible = true;
        const position = tabIds.indexOf(id);
        if (position === -1)
            return;
        tabs.currentIndex = position;
        if (id === 1)
            installedLoader.active = true;
        if (id === 2)
            installLoader.active = true;
        if (id === 3)
            firmwareLoader.active = true;
        if (id === 4)
            logLoader.active = true;
        focusCurrentTab();
    }

    // Jump from a finished run to its own entry in the log, where the full
    // per-package detail and the tools' own words live.
    function openLatestLogEntry() {
        openTab(4);
        Qt.callLater(() => {
            if (logLoader.item)
                logLoader.item.expandNewest();
        });
    }

    // Move keyboard focus into the freshly shown tab; tabs with a search
    // field get input focus on that field directly.
    function focusCurrentTab() {
        Qt.callLater(() => {
            switch (win.currentTab) {
            case 1:
                if (installedLoader.item)
                    installedLoader.item.focusSearch();
                break;
            case 2:
                if (installLoader.item)
                    installLoader.item.focusSearch();
                break;
            case 3:
                if (firmwareLoader.item)
                    firmwareLoader.item.focusList();
                break;
            case 4:
                if (logLoader.item)
                    logLoader.item.focusSearch();
                break;
            default:
                cardsList.forceActiveFocus();
                break;
            }
        });
    }

    function classify(pkg) {
        if (pkg.repo === "appimage")
            return "1 · Applications";
        if (pkg.repo === "firmware")
            return "4 · Firmware";
        if (pkg.repo !== "flatpak")
            return store.isHeld(pkg) ? "6 · Held packages" : "2 · System packages";
        const name = pkg.name || "";
        const runtime = /\.(Locale|Debug|Sources)$/.test(name)
            || /\.(Platform|Sdk)($|\.)/.test(name)
            || name.indexOf(".GL.") !== -1
            || name.indexOf(".VAAPI.") !== -1
            || name.indexOf(".codecs") !== -1
            || name.indexOf(".ffmpeg") !== -1;
        return runtime ? "3 · Runtimes & extensions" : "1 · Applications";
    }

    function _guessRepo(name) {
        return (name || "").split(".").length >= 3 ? "flatpak" : "system";
    }

    function _sortRows(rows) {
        rows.sort((a, b) => {
            if (a.category !== b.category)
                return a.category < b.category ? -1 : 1;
            // Among finished rows the failures go first — they are the ones
            // still asking something of you (no-op outside a run)
            const failedA = a.failed ? 0 : 1;
            const failedB = b.failed ? 0 : 1;
            if (failedA !== failedB)
                return failedA - failedB;
            const nameA = (store.meta[a.key] && store.meta[a.key].name) || a.pkg.name;
            const nameB = (store.meta[b.key] && store.meta[b.key].name) || b.pkg.name;
            return nameA.localeCompare(nameB);
        });
        return rows;
    }

    // Pending updates: live service data, or the widget's persisted snapshot
    // right after a restart (until the daemon has state again)
    readonly property var pendingUpdates: widgetRoot ? widgetRoot.pendingUpdates : (SystemUpdateService.availableUpdates || [])

    // Live list of pending updates (idle view)
    readonly property var updateRows: {
        const updates = win.pendingUpdates;
        const seen = new Set();
        const rows = [];
        for (const pkg of updates) {
            const key = store.keyFor(pkg);
            if (seen.has(key))
                continue;
            seen.add(key);
            const category = classify(pkg);
            if (!showRuntimes && category === "3 · Runtimes & extensions")
                continue;
            rows.push({
                pkg: pkg,
                key: key,
                category: category,
                ignored: false
            });
        }
        for (const fw of (firmware ? firmware.updates : []) || []) {
            rows.push({
                pkg: {
                    name: fw.name,
                    repo: "firmware",
                    fromVersion: fw.current,
                    toVersion: fw.next
                },
                key: "firmware/" + fw.name,
                category: "4 · Firmware",
                ignored: false,
                fwInfo: fw
            });
        }
        for (const ai of (widgetRoot ? widgetRoot.appimageUpdates : []) || []) {
            rows.push({
                pkg: {
                    name: ai.id,
                    displayName: ai.name,
                    repo: "appimage",
                    fromVersion: ai.current,
                    toVersion: ai.latest
                },
                key: "appimage/" + ai.id,
                category: "1 · Applications",
                ignored: false,
                aiInfo: ai
            });
        }

        // DMS plugins: the fifth kind of software this window manages, and
        // the only one that lives in the shell running it. The daemon says
        // which have a newer build in the registry; what it does not say is
        // how big that is, so these rows carry versions and nothing else.
        for (const formula of (widgetRoot ? widgetRoot.brewUpdates : []) || []) {
            rows.push({
                pkg: formula,
                key: "brew/" + formula.name,
                category: "5 · Homebrew",
                ignored: false
            });
        }
        for (const plugin of (widgetRoot ? widgetRoot.pluginUpdates : []) || []) {
            rows.push({
                pkg: plugin,
                key: "plugin/" + plugin.name,
                category: "5 · DMS plugins",
                ignored: false
            });
        }
        for (const name of SettingsData.updaterIgnoredPackages || []) {
            const repo = _guessRepo(name);
            const pkg = {
                name: name,
                repo: repo,
                fromVersion: "",
                toVersion: ""
            };
            rows.push({
                pkg: pkg,
                key: store.keyFor(pkg),
                category: "6 · Held packages",
                ignored: true
            });
        }
        return _sortRows(rows);
    }

    // Snapshot of the running/finished run: keeps every queued item visible
    // with its own state (queued / downloading / installing / done / failed),
    // even while the daemon refreshes the live list mid-run.
    // During a run the list regroups by what is happening to each package
    // rather than by what kind of package it is. Sorted by source, the few
    // rows actually being worked on sit scattered among hundreds of queued
    // ones; grouped by state, they are the first thing on screen.
    readonly property var runRows: {
        const rows = [];
        for (const item of engine.runItems || []) {
            const state = engine.itemStates[item.key] || null;
            const status = state ? state.status : "pending";
            let category = "2 · Waiting";
            if (status === "active")
                category = "1 · In progress";
            else if (status === "confirming")
                category = "3 · Confirming";
            else if (status === "done" || status === "error")
                category = "4 · Completed";
            rows.push({
                pkg: item.pkg,
                key: item.key,
                category: category,
                ignored: false,
                failed: status === "error"
            });
        }
        return _sortRows(rows);
    }

    readonly property bool showingRun: engine.phase !== "idle" && runRows.length > 0
    readonly property var visibleRows: {
        if (!showingRun)
            return updateRows;
        // The run view focuses on the live queue, but held updates that sit
        // out this run shouldn't vanish from the overview — keep their
        // section below the queue.
        const runKeys = new Set(runRows.map(row => row.key));
        return runRows.concat(updateRows.filter(row => row.category === "6 · Held packages" && !runKeys.has(row.key)));
    }

    // Flat list model with explicit header rows. This sidesteps ListView's
    // section attachment (which mis-assigned headers) and lets headers carry
    // their own hover actions.
    // Sections whose heading is the name of a source. A chip repeating it on
    // every row underneath is the heading again in smaller type — the reader
    // has just read it. Everywhere else it stays: Applications holds Flatpaks
    // and AppImages together, Held holds anything at all, and during a run the
    // groups are In progress and Waiting, where what a row *is* is the one
    // thing the heading no longer says.
    readonly property var sourceNamedCategories: ["2 · System packages", "4 · Firmware", "5 · Homebrew", "5 · DMS plugins"]

    // What the list shows. categorySections is recomputed on every progress
    // event of a run, because the run's rows are grouped by their state. It
    // used to be the list's model, and a ListView handed a new array throws
    // every delegate away and starts again at the top: during an update that
    // happened several times a second, so a flick never finished and the
    // list kept jumping back up (9092 rebuilds in one replayed run of 104
    // packages). The rows read their progress live from the engine, so
    // nothing needs rebuilding for that.
    //
    // The list's model is now a ListModel of category names, kept in step
    // with inserts, moves and removals, so the view itself is never reset.
    // Each category's rows sit in sectionByCategory, and a category whose
    // contents did not change keeps the very same object — its rows stay
    // built. Only the group a package has just left or entered rebuilds.
    property var shownSections: []
    property var sectionByCategory: ({})
    property string _sectionsSignature: ""

    ListModel {
        id: sectionModel
    }

    function _groupSignature(group) {
        return JSON.stringify([group.category, group.title, group.count, group.collapsed, group.repeatsHeading,
            group.items.map(row => [row.key, row.failed === true, row.ignored === true,
                (row.pkg && row.pkg.fromVersion) || "", (row.pkg && row.pkg.toVersion) || ""])]);
    }

    function _refreshSections() {
        const next = categorySections;
        const signatures = next.map(group => _groupSignature(group));
        const signature = signatures.join("\n");
        if (signature === _sectionsSignature)
            return;
        _sectionsSignature = signature;
        const previous = sectionByCategory;
        const byCategory = {};
        next.forEach((group, i) => {
            const kept = previous[group.category];
            byCategory[group.category] = (kept && kept._signature === signatures[i]) ? kept : Object.assign({
                _signature: signatures[i]
            }, group);
        });
        sectionByCategory = byCategory;
        shownSections = next.map(group => byCategory[group.category]);
        const order = next.map(group => group.category);
        for (let i = 0; i < order.length; i++) {
            if (i < sectionModel.count && sectionModel.get(i).category === order[i])
                continue;
            let found = -1;
            for (let k = i + 1; k < sectionModel.count; k++) {
                if (sectionModel.get(k).category === order[i]) {
                    found = k;
                    break;
                }
            }
            if (found >= 0)
                sectionModel.move(found, i, 1);
            else
                sectionModel.insert(i, {
                    category: order[i]
                });
        }
        while (sectionModel.count > order.length)
            sectionModel.remove(sectionModel.count - 1);
    }

    onCategorySectionsChanged: _refreshSections()

    readonly property var categorySections: {
        const counts = {};
        const sectionRepo = {};
        for (const row of visibleRows) {
            const repo = (row.pkg && row.pkg.repo) || "system";
            sectionRepo[row.category] = sectionRepo[row.category] === undefined ? repo : (sectionRepo[row.category] === repo ? repo : "*");
        }
        for (const row of visibleRows)
            counts[row.category] = (counts[row.category] || 0) + 1;
        const collapsible = ["6 · Held packages", "4 · Completed"];
        const groups = [];
        const groupMap = {};
        for (const row of visibleRows) {
            const cat = row.category || "";
            if (!groupMap[cat]) {
                const grp = {
                    category: cat,
                    title: Tr.t(cat.substring(4)),
                    count: counts[cat] || 0,
                    collapsible: collapsible.indexOf(cat) !== -1,
                    collapsed: collapsible.indexOf(cat) !== -1 && collapsedCats[cat] === true,
                    repeatsHeading: sourceNamedCategories.indexOf(cat) !== -1 && sectionRepo[cat] !== "*",
                    items: []
                };
                groupMap[cat] = grp;
                groups.push(grp);
            }
            groupMap[cat].items.push(row);
        }
        return groups;
    }

    // Whether the footer has anything to offer. "Deferred" counts as busy:
    // the click already committed a run and is waiting on the pre-run check,
    // so the button flips to Cancel immediately. Between a finished run and
    // its trailing check the stale list would re-offer Update All for a few
    // seconds — that window is suppressed.
    readonly property bool updateAllBusy: engine.running || engine.deferred
    readonly property bool showUpdateAll: {
        if (updateAllBusy)
            return true;
        const settling = engine.phase !== "idle" && SystemUpdateService.isChecking;
        return effectiveCount > 0 && !settling;
    }

    // ── Command palette ─────────────────────────────────────────────────────
    // Searches what the window already holds, so results appear as you type
    // with no process to wait for. Anything that would need a repository
    // search is handed to the Install tab rather than reimplemented here.
    readonly property var paletteResults: {
        const query = palette.query.trim().toLowerCase();
        const out = [];
        const add = (group, icon, title, subtitle, colour, kind, payload) => {
            out.push({
                group: group,
                icon: icon,
                title: title,
                subtitle: subtitle || "",
                colour: colour,
                kind: kind,
                payload: payload
            });
        };
        const hit = text => query === "" || Ui.matchesWords((text || "").toLowerCase(), query);

        // Commands first: with an empty field the palette should be a menu,
        // not a blank page
        const commands = [
            {
                title: Tr.t("Check for updates"),
                icon: "refresh",
                kind: "check"
            },
            {
                title: Tr.t("Update All"),
                icon: "download",
                kind: "updateAll"
            },
            {
                title: Tr.t("Updates"),
                icon: "deployed_code_update",
                kind: "tab",
                payload: 0
            },
            {
                title: Tr.t("Installed"),
                icon: "apps",
                kind: "tab",
                payload: 1
            },
            {
                title: Tr.t("Install"),
                icon: "storefront",
                kind: "tab",
                payload: 2
            },
            {
                title: Tr.t("Firmware"),
                icon: "memory",
                kind: "tab",
                payload: 3
            },
            {
                title: Tr.t("Log"),
                icon: "history",
                kind: "tab",
                payload: 4
            },
            {
                title: Tr.t("Software sources"),
                icon: "database",
                kind: "sources"
            },
            {
                title: Tr.t("Arch Linux news"),
                icon: "campaign",
                kind: "news"
            },
            {
                title: Tr.t("Plugin settings"),
                icon: "settings",
                kind: "settings"
            },
            {
                title: Tr.t("Open GitHub page"),
                icon: "open_in_new",
                kind: "url",
                payload: win.githubUrl
            }
        ];
        for (const command of commands) {
            if (command.kind === "tab" && win.tabIds.indexOf(command.payload) === -1)
                continue;
            if (command.kind === "updateAll" && !win.showUpdateAll)
                continue;
            // Nothing to open on a distribution that publishes no such feed
            if (command.kind === "news" && !newsDialog.supported)
                continue;
            if (hit(command.title))
                add(Tr.t("Commands"), command.icon, command.title, "", Theme.primary, command.kind, command.payload);
        }

        if (query !== "") {
            let shown = 0;
            for (const row of win.updateRows) {
                if (shown >= 6)
                    break;
                const name = win.store.stripArch(row.pkg.name);
                const info = win.store.infoFor(row.pkg);
                const label = (info && info.name) ? info.name : name;
                if (!hit(label + " " + name))
                    continue;
                shown++;
                add(Tr.t("Updates"), "deployed_code_update", label, Ui.versionLabel(row.pkg.toVersion), Theme.primary, "update", row);
            }

            shown = 0;
            const installed = installedLoader.item ? installedLoader.item.filteredItems : [];
            for (const item of installed) {
                if (shown >= 6)
                    break;
                if (item.type === "header" || !hit(item.name + " " + item.id))
                    continue;
                shown++;
                add(Tr.t("Installed"), item.kind === "flatpak" ? "apps" : (item.kind === "appimage" ? "package_2" : "memory"), item.name, item.version || "", Theme.success, "installed", item);
            }

            // The palette shows only the first few matches of each kind, and
            // the repositories are not in memory at all; hand the query to the
            // tab whose job that is instead of duplicating its search
            const typed = palette.query.trim();
            const handOff = [
                {
                    tab: 1,
                    title: Tr.t("Search \"%1\" in Installed").arg(typed)
                },
                {
                    tab: 2,
                    title: Tr.t("Search \"%1\" in Install").arg(typed)
                },
                {
                    tab: 4,
                    title: Tr.t("Search \"%1\" in Log").arg(typed)
                }
            ];
            for (const target of handOff) {
                if (win.tabIds.indexOf(target.tab) === -1)
                    continue;
                add(Tr.t("Commands"), "search", target.title, "", Theme.secondary, "search", {
                    tab: target.tab,
                    text: typed
                });
            }
        }
        return out;
    }

    function runPaletteResult(index) {
        const item = win.paletteResults[index];
        if (!item)
            return;
        palette.close();
        switch (item.kind) {
        case "check":
            SystemUpdateService.checkForUpdates();
            if (win.firmware)
                win.firmware.check();
            break;
        case "updateAll":
            win.engine.start({});
            break;
        case "tab":
            win.openTab(item.payload);
            break;
        case "settings":
            win.settingsOpen = true;
            break;
        case "sources":
            sourcesDialog.open();
            break;
        // From the palette this is the archive: someone asking for it by name
        // wants the announcement from last spring, not only today's
        case "news":
            newsDialog.open(true);
            break;
        case "url":
            Qt.openUrlExternally(item.payload);
            break;
        case "update":
            win.openTab(0);
            win.openUpdateDetails(item.payload, win.store.infoFor(item.payload.pkg));
            break;
        case "installed":
            win.openTab(1);
            if (installedLoader.item)
                installedLoader.item.openDetails(item.payload);
            break;
        case "search":
            win.openTab(item.payload.tab);
            // The tab may have only just been created by openTab, so hand the
            // query over once it exists rather than at this instant
            Qt.callLater(() => {
                const view = win.tabView(item.payload.tab);
                if (view && view.setQuery)
                    view.setQuery(item.payload.text);
            });
            break;
        }
    }

    // Section headers carry the same iconography the rows use, so a group is
    // recognisable before its title is read. The run groups say what is
    // happening; the idle sections say what kind of software it is.
    function categoryIcon(category) {
        switch (category) {
        case "1 · In progress":
            return "sync";
        case "2 · Waiting":
            return "schedule";
        case "3 · Confirming":
            return "fact_check";
        case "4 · Completed":
            return "check_circle";
        case "2 · System packages":
            return "memory";
        case "3 · Runtimes & extensions":
            return "extension";
        case "4 · Firmware":
            return "developer_board";
        case "5 · DMS plugins":
            return "extension";
        case "5 · Homebrew":
            return "local_drink";
        case "6 · Held packages":
            return "lock";
        default:
            return "apps";
        }
    }

    function categoryColor(category) {
        switch (category) {
        case "2 · Waiting":
            return Theme.surfaceVariantText;
        case "4 · Completed":
            return Theme.success;
        case "6 · Held packages":
            return Theme.warning;
        default:
            return Theme.primary;
        }
    }

    // A firmware section whose every update waits for the power adapter has
    // nothing its button could install
    function sectionUpdatable(category) {
        if (category === "4 · Firmware")
            return ((firmware ? firmware.installable : []) || []).length > 0;
        return ["1 · Applications", "2 · System packages", "3 · Runtimes & extensions"].includes(category);
    }

    function sectionUpdate(category) {
        if (engine.running)
            return;
        // A section's button updates that section. AppImages, plugins and
        // Homebrew join a run unless told otherwise, so both of these used to
        // update all three along with what the button said
        if (category === "2 · System packages") {
            engine.start({
                flatpak: false,
                firmware: false,
                appimage: false,
                plugins: false,
                brew: false
            });
            return;
        }
        if (category === "4 · Firmware") {
            engine.start({
                dnf: false,
                flatpak: false,
                appimage: false,
                plugins: false,
                brew: false
            });
            return;
        }
        const ids = visibleRows.filter(row => row.category === category && row.pkg.repo === "flatpak").map(row => row.pkg.name);
        const aiIds = visibleRows.filter(row => row.category === category && row.pkg.repo === "appimage").map(row => row.pkg.name);
        if (ids.length > 0 || aiIds.length > 0)
            engine.start({
                dnf: false,
                firmware: false,
                flatpak: ids.length > 0,
                appimageIds: aiIds,
                flatpakIds: ids
            });
    }

    // Effective pending count: held packages don't count as real updates
    // Follows the widget's count (held excluded)
    readonly property int effectiveCount: {
        if (widgetRoot)
            return widgetRoot.effectiveCount;
        const updates = win.pendingUpdates;
        return updates.filter(pkg => !store.isHeld(pkg)).length + ((firmware ? firmware.updates : []) || []).length;
    }

    readonly property int hiddenRuntimeCount: {
        const updates = win.pendingUpdates;
        if (showRuntimes)
            return 0;
        return updates.filter(pkg => classify(pkg) === "3 · Runtimes & extensions").length;
    }

    function lastCheckedText() {
        const ago = formatAgo(SystemUpdateService.lastCheckUnix);
        return ago ? Tr.t("checked %1").arg(ago) : "";
    }

    function formatIn(unix) {
        if (!unix)
            return "";
        const delta = unix - nowUnix;
        if (delta <= 0)
            return Tr.t("soon");
        if (delta < 3600)
            return Tr.t("in %1m").arg(Math.max(1, Math.round(delta / 60)));
        return Tr.t("in %1h").arg(Math.round(delta / 3600));
    }

    ColumnLayout {
        id: windowContent
        anchors.fill: parent
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingM
        opacity: win.anyPopupShowing ? 0.35 : 1.0
        Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

        // ── Header Container Card (Matches modern UI theme) ─────────────────
        StyledRect {
            Layout.fillWidth: true
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Ui.chipSurface, 0.45)
            border.width: 0
            implicitHeight: headerRow.implicitHeight + Theme.spacingM * 2

            RowLayout {
                id: headerRow
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                // Framed App Icon
                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.08)
                    border.width: 0

                    Image {
                        id: headerLogo
                        anchors.fill: parent
                        anchors.margins: 4
                        source: win.appIconSource
                        sourceSize.width: 80
                        sourceSize.height: 80
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }
                }

                // Title and Status
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Dux Software Depot"
                            font.pixelSize: Theme.fontSizeXLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            visible: win.engine.running || SystemUpdateService.isChecking || win.effectiveCount > 0
                            Layout.preferredHeight: 20
                            Layout.preferredWidth: statusBadgeText.implicitWidth + 16
                            radius: 10
                            color: win.engine.running
                                ? Theme.withAlpha(Theme.primary, 0.22)
                                : (SystemUpdateService.isChecking
                                    ? Theme.withAlpha(Theme.secondary, 0.2)
                                    : Theme.withAlpha(Theme.primary, 0.16))

                            StyledText {
                                id: statusBadgeText
                                anchors.centerIn: parent
                                text: win.engine.running ? Tr.t("Updating") : (SystemUpdateService.isChecking ? Tr.t("Checking") : (win.effectiveCount + " " + Tr.t("new")))
                                font.pixelSize: Theme.fontSizeSmall - 2
                                font.weight: Font.Medium
                                color: win.engine.running ? Theme.primary : (SystemUpdateService.isChecking ? Theme.secondary : Theme.primary)
                            }
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            let countText;
                            if (win.engine.running)
                                countText = Tr.t("updating…");
                            else if (SystemUpdateService.isChecking)
                                countText = Tr.t("checking…");
                            else if (win.effectiveCount === 0)
                                countText = Tr.t("up to date");
                            else
                                countText = (win.effectiveCount === 1 ? Tr.t("%1 update available") : Tr.t("%1 updates available")).arg(win.effectiveCount);
                            const checked = win.lastCheckedText();
                            return countText + (checked ? " · " + checked : "");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                // Header actions: standard icon buttons (Search, Refresh, Settings, Close)
                RowLayout {
                    id: headerButtons
                    spacing: 4

                    DankTooltipV2 {
                        id: headerTooltip
                    }

                    // 1. Search
                    Rectangle {
                        id: headerSearchBtn
                        width: 36
                        height: 36
                        readonly property bool isActive: !!palette.showing
                        property bool isHovered: searchMa.containsMouse
                        z: (isActive || isHovered) ? 3 : 1

                        // Round at rest, squarer while pressed or switched on —
                        // the Expressive shape change for a toggle
                        radius: (searchMa.pressed || isActive) ? Theme.cornerRadius : (height / 2)
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        readonly property string kind: isActive ? "iconSelected" : "icon"
                        color: Ui.buttonFill(kind, isHovered)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: searchMa.pressed ? 0.92 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple {
                            id: searchRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.buttonInk(headerSearchBtn.kind)
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "search"
                            size: 20
                            color: Ui.buttonInk(headerSearchBtn.kind)
                        }

                        MouseArea {
                            id: searchMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: headerTooltip.show(Tr.t("Search everything") + " · Ctrl+K", parent, 0, 4, "bottom")
                            onExited: headerTooltip.hide()
                            onPressed: (m) => searchRip.trigger(m.x, m.y)
                            onClicked: {
                                headerTooltip.hide();
                                if (palette.showing)
                                    palette.close();
                                else
                                    palette.open();
                            }
                        }
                    }

                    // 2. Refresh
                    Rectangle {
                        id: windowRefreshButton
                        readonly property bool isActive: SystemUpdateService.isChecking
                        readonly property bool btnEnabled: !SystemUpdateService.isChecking && !win.engine.running
                        width: 36
                        height: 36
                        property bool isHovered: refreshMa.containsMouse && btnEnabled
                        z: (isActive || isHovered) ? 3 : 1

                        // Round at rest, squarer while pressed or switched on —
                        // the Expressive shape change for a toggle
                        radius: (refreshMa.pressed || isActive) ? Theme.cornerRadius : (height / 2)
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        readonly property string kind: isActive ? "iconSelected" : "icon"
                        color: Ui.buttonFill(kind, isHovered)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: refreshMa.pressed ? 0.92 : 1.0
                        opacity: btnEnabled || isActive ? 1.0 : 0.4
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple {
                            id: refreshRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.buttonInk(windowRefreshButton.kind)
                        }

                        DankIcon {
                            id: refreshIcon
                            anchors.centerIn: parent
                            name: "refresh"
                            size: 20
                            // The default glyph rendering snaps to the pixel
                            // grid and turns jagged once rotated; while it
                            // spins it is drawn as a distance field instead
                            smoothTransform: SystemUpdateService.isChecking && Ui.busyMotion
                            color: Ui.buttonInk(windowRefreshButton.kind)

                            RotationAnimator on rotation {
                                from: 0
                                to: 360
                                duration: Ui.busyCycle
                                loops: Animation.Infinite
                                running: SystemUpdateService.isChecking && Ui.busyMotion

                                onRunningChanged: {
                                    if (!running)
                                        refreshIcon.rotation = 0;
                                }
                            }
                        }

                        MouseArea {
                            id: refreshMa
                            anchors.fill: parent
                            hoverEnabled: windowRefreshButton.btnEnabled
                            cursorShape: windowRefreshButton.btnEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onEntered: {
                                if (windowRefreshButton.btnEnabled)
                                    headerTooltip.show(Tr.t("Check for updates"), parent, 0, 4, "bottom");
                            }
                            onExited: headerTooltip.hide()
                            onPressed: (m) => {
                                if (windowRefreshButton.btnEnabled)
                                    refreshRip.trigger(m.x, m.y);
                            }
                            onClicked: {
                                if (windowRefreshButton.btnEnabled) {
                                    headerTooltip.hide();
                                    SystemUpdateService.checkForUpdates();
                                    if (win.firmware)
                                        win.firmware.check();
                                }
                            }
                        }
                    }

                    // 3. Settings
                    Rectangle {
                        id: headerSettingsBtn
                        width: 36
                        height: 36
                        readonly property bool isActive: win.settingsOpen
                        property bool isHovered: settingsMa.containsMouse
                        z: (isActive || isHovered) ? 3 : 1

                        // Round at rest, squarer while pressed or switched on —
                        // the Expressive shape change for a toggle
                        radius: (settingsMa.pressed || isActive) ? Theme.cornerRadius : (height / 2)
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        readonly property string kind: isActive ? "iconSelected" : "icon"
                        color: Ui.buttonFill(kind, isHovered)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: settingsMa.pressed ? 0.92 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple {
                            id: settingsRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.buttonInk(headerSettingsBtn.kind)
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "settings"
                            size: 20
                            color: Ui.buttonInk(headerSettingsBtn.kind)
                        }

                        MouseArea {
                            id: settingsMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: headerTooltip.show(Tr.t("Settings & Info"), parent, 0, 4, "bottom")
                            onExited: headerTooltip.hide()
                            onPressed: (m) => settingsRip.trigger(m.x, m.y)
                            onClicked: {
                                headerTooltip.hide();
                                win.settingsOpen = !win.settingsOpen;
                            }
                        }
                    }

                    // 4. Close
                    Rectangle {
                        id: headerCloseBtn
                        width: 36
                        height: 36
                        readonly property bool isActive: false
                        property bool isHovered: closeMa.containsMouse
                        z: isHovered ? 3 : 1

                        radius: closeMa.pressed ? Theme.cornerRadius : (height / 2)
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        // A standard icon button with a red state layer, since it closes
                        color: isHovered ? Theme.withAlpha(Theme.error, 0.12) : Ui.buttonFill("icon", false)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: closeMa.pressed ? 0.92 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple {
                            id: closeRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.failColor
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            name: "close"
                            size: 20
                            color: headerCloseBtn.isHovered ? Ui.failColor : Ui.buttonInk("icon")
                        }

                        MouseArea {
                            id: closeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: headerTooltip.show(Tr.t("Close"), parent, 0, 4, "bottom")
                            onExited: headerTooltip.hide()
                            onPressed: (m) => closeRip.trigger(m.x, m.y)
                            onClicked: {
                                headerTooltip.hide();
                                win.visible = false;
                            }
                        }
                    }
                }
            }
        }

        // ── Unsupported OS warning (not a Fedora-based distro) ──────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.osIncompatiblePretty !== ""
            implicitHeight: osWarnRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.14)

            RowLayout {
                id: osWarnRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "warning"
                    size: 20
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("This app is built for Fedora-based systems. You appear to be running %1 — system package features may not work correctly.").arg(win.osIncompatiblePretty)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── Experimental-backend notice (Debian/Ubuntu, Arch) ───────────────
        Rectangle {
            Layout.fillWidth: true
            visible: Backend.backendId !== "dnf"
            implicitHeight: aptNoticeRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.secondary, 0.14)

            RowLayout {
                id: aptNoticeRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "science"
                    size: 20
                    color: Theme.secondary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("%1 support is experimental — please report anything that misbehaves.").arg(Backend.systemRepoLabel)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    implicitWidth: aptIssueButton.width
                    implicitHeight: aptIssueButton.height

                    DankButton {
                        id: aptIssueButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        iconName: "bug_report"
                        iconSize: 14
                        text: Tr.t("Report an issue")
                        backgroundColor: Ui.buttonFill("tonal", false)
                        textColor: Ui.buttonInk("tonal")
                        onClicked: Qt.openUrlExternally(win.githubUrl + "/issues")
                    }
                }
            }
        }

        // ── Missing requirements ────────────────────────────────────────────
        // What the plugin needs from the distro and does not have, each with
        // the package that fixes it. Two kinds live here: the package-manager
        // bindings, without which no system package can be touched at all,
        // and the AppStream catalog, without which apps merely look poorer.
        // Both are separate distro packages that a default install can lack,
        // and both used to be invisible.
        Rectangle {
            Layout.fillWidth: true
            visible: Backend.missingRequirements.length > 0
            implicitHeight: requirementsColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            readonly property color accent: Backend.missingRequirements.some(r => r.blocking) ? Theme.error : Theme.warning
            color: Theme.withAlpha(accent, 0.12)

            ColumnLayout {
                id: requirementsColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                Repeater {
                    model: Backend.missingRequirements

                    delegate: ColumnLayout {
                        id: requirementRow

                        required property var modelData

                        readonly property bool installing: Backend.installingRequirement === modelData.id

                        Layout.fillWidth: true
                        spacing: Theme.spacingXS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            DankIcon {
                                name: requirementRow.modelData.blocking ? "error" : "info"
                                size: 20
                                color: requirementRow.modelData.blocking ? Theme.error : Theme.warning
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: {
                                    const pkg = requirementRow.modelData.package;
                                    if (requirementRow.installing)
                                        return Tr.t("Installing %1…").arg(pkg);
                                    if (requirementRow.modelData.blocking)
                                        return Tr.t("%1 could not be loaded — system packages cannot be installed or updated until it can.").arg(pkg);
                                    if (requirementRow.modelData.id === "flatpak")
                                        return Tr.t("%1 is missing — Flatpak apps cannot be updated or installed without it.").arg(pkg);
                                    return Tr.t("%1 is missing — app names, icons and release notes stay limited without it.").arg(pkg);
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                            }

                            Item {
                                visible: Backend.installingRequirement === ""
                                implicitWidth: requirementInstallButton.width
                                implicitHeight: requirementInstallButton.height

                                DankButton {
                                    id: requirementInstallButton
                                    buttonHeight: 28
                                    horizontalPadding: Theme.spacingM
                                    iconName: "download"
                                    iconSize: 14
                                    text: Tr.t("Install")
                                    backgroundColor: Ui.buttonFill(requirementRow.modelData.blocking ? "filled" : "tonal", false)
                                    textColor: Ui.buttonInk(requirementRow.modelData.blocking ? "filled" : "tonal")
                                    onClicked: Backend.installRequirement(requirementRow.modelData.id, requirementRow.modelData.package)
                                }
                            }
                        }

                        // The helper's own words. Without them a report of
                        // "missing" is unfalsifiable — and it was wrong at
                        // least once, on a machine where the package was
                        // installed but a virtualenv's python could not see it
                        StyledText {
                            Layout.fillWidth: true
                            visible: (requirementRow.modelData.detail || "") !== ""
                            text: requirementRow.modelData.detail || ""
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }

                        // The same install as a command, for anyone who would
                        // rather watch it happen in a terminal
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: requirementHint.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.surfaceVariant, 0.6)

                            StyledText {
                                id: requirementHint
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                text: Backend.installHintFor(requirementRow.modelData.package)
                                font.family: Theme.monoFontFamily
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                wrapMode: Text.WrapAnywhere
                            }
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: Backend.requirementInstallError !== ""
                    text: Backend.requirementInstallError
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.error
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
            }
        }

        // ── Launcher entry offer ────────────────────────────────────────────
        // Enabling a plugin cannot write to the applications directory, so
        // the app is reachable only from the bar until someone follows a
        // README step. Offered once, on the tab you land on; declining is
        // remembered, and the switch in settings stays for either direction.
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && Backend.launcherEntryChecked && !Backend.launcherEntryPresent && !(win.widgetRoot && win.widgetRoot.launcherPromptDone)
            implicitHeight: launcherColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.secondary, 0.14)

            ColumnLayout {
                id: launcherColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    DankIcon {
                        name: "rocket_launch"
                        size: 20
                        color: Theme.secondary
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Backend.launcherEntryBusy ? Tr.t("Adding to the launcher…") : Tr.t("Open Dux Software Depot from your app launcher? A desktop entry and icon are placed in your own home directory.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }

                    Item {
                        visible: !Backend.launcherEntryBusy
                        implicitWidth: launcherAddButton.width
                        implicitHeight: launcherAddButton.height

                        DankButton {
                            id: launcherAddButton
                            buttonHeight: 28
                            horizontalPadding: Theme.spacingM
                            iconName: "add"
                            iconSize: 14
                            text: Tr.t("Add")
                            backgroundColor: Ui.buttonFill("filled", false)
                            textColor: Ui.buttonInk("filled")
                            onClicked: {
                                Backend.installLauncherEntry();
                                PluginService.savePluginData("dankSoftwareDepot", "launcherPromptDone", true);
                            }
                        }
                    }

                    // Closing it is an answer too: the offer does not return,
                    // and the switch in settings is where it lives afterwards
                    DankActionButton {
                        visible: !Backend.launcherEntryBusy
                        buttonSize: 28
                        iconName: "close"
                        iconSize: 16
                        iconColor: Theme.surfaceVariantText
                        tooltipText: Tr.t("Dismiss")
                        onClicked: PluginService.savePluginData("dankSoftwareDepot", "launcherPromptDone", true)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: Backend.launcherEntryError !== ""
                    text: Backend.launcherEntryError
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.error
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
            }
        }

        // ── Plugin self-update banner ───────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.selfUpdateVersion !== "" && win.selfUpdateVersion !== win.selfUpdateDismissedVersion
            implicitHeight: selfUpdateColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.12)

            ColumnLayout {
                id: selfUpdateColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    Image {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        source: win.appIconSource
                        sourceSize.width: 44
                        sourceSize.height: 44
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }

                    StyledText {
                        Layout.fillWidth: true
                        textFormat: Text.StyledText
                        text: Tr.t("Dux Software Depot %1 is available").arg("<b>" + win.selfUpdateVersion + "</b>")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    // Wrapper Item: DankButton sizes itself via `width`,
                    // which the RowLayout would ignore and cramp the label
                    Item {
                        Layout.preferredWidth: selfUpdateButton.width
                        Layout.preferredHeight: selfUpdateButton.height

                        DankButton {
                            id: selfUpdateButton
                            buttonHeight: 30
                            iconName: "download"
                            iconSize: 14
                            horizontalPadding: Theme.spacingM
                            enabled: !win.selfUpdateBusy
                            text: win.selfUpdateBusy ? Tr.t("Updating…") : Tr.t("Update and reload shell")
                            backgroundColor: Theme.buttonBg
                            textColor: Theme.buttonText
                            onClicked: {
                                win.selfUpdateBusy = true;
                                // Detached: the shell reload below kills our
                                // own process tree mid-flight otherwise
                                Quickshell.execDetached(["sh", "-c", "dms plugins update dankSoftwareDepot && dms restart"]);
                            }
                        }
                    }

                    DankActionButton {
                        buttonSize: 28
                        iconName: "close"
                        iconSize: 16
                        iconColor: Theme.surfaceVariantText
                        tooltipText: Tr.t("Dismiss")
                        onClicked: PluginService.savePluginData("dankSoftwareDepot", "selfUpdateDismissedVersion", win.selfUpdateVersion)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: win._selfUpdateSections > 1
                    text: Tr.t("%1 releases since yours").arg(win._selfUpdateSections)
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.DemiBold
                    color: Theme.surfaceVariantText
                }

                // Several releases' notes can be long, and cutting them off
                // hides exactly the fixes someone skipped. Bounded height with
                // a scrollbar instead: the banner stays a banner, and the
                // notes stay complete.
                DankFlickable {
                    id: selfUpdateNotesView

                    Component.onCompleted: Ui.softenScrollbar(selfUpdateNotesView)
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(selfUpdateNotesText.implicitHeight, 220)
                    visible: win.selfUpdateNotes !== ""
                    clip: true
                    contentHeight: selfUpdateNotesText.implicitHeight
                    // A drag inside a Flickable is a scroll, and it is decided
                    // by the same few pixels of movement that start a text
                    // selection — so the notes could be selected only by
                    // winning a race against their own viewport. Nothing here
                    // needs drag-to-scroll: this one is driven by the wheel
                    // handler and the scrollbar, both of which set contentY
                    // themselves and go on working with the drag switched off.
                    interactive: false

                    SelectableText {
                        id: selfUpdateNotesText

                        width: selfUpdateNotesView.width
                        textFormat: Text.RichText
                        text: win.selfUpdateNotes
                        // Release notes are read, not glanced at, and this is
                        // the one banner people are asked to act on
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // ── Reboot recommendation banner ────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.widgetRoot !== null && win.widgetRoot.rebootRecommended
            implicitHeight: rebootRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.14)

            RowLayout {
                id: rebootRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "restart_alt"
                    size: 22
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("A computer restart is recommended to finish applying updates.")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: windowRebootButton.width
                    Layout.preferredHeight: windowRebootButton.height

                    DankButton {
                        id: windowRebootButton
                        buttonHeight: 32
                        iconName: "restart_alt"
                        iconSize: 15
                        text: (win.widgetRoot && win.widgetRoot.confirmReboot) ? Tr.t("Confirm restart?") : Tr.t("Restart now")
                        backgroundColor: (win.widgetRoot && win.widgetRoot.confirmReboot) ? Theme.error : Theme.buttonBg
                        textColor: (win.widgetRoot && win.widgetRoot.confirmReboot) ? Ui.onColor(Theme.error) : Theme.buttonText
                        onClicked: win.widgetRoot.requestReboot()
                    }
                }

                DankActionButton {
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    tooltipText: Tr.t("Dismiss")
                    onClicked: win.widgetRoot.dismissReboot()
                }
            }
        }

        // ── Failed-check banner ─────────────────────────────────────────────
        // With nothing pending, the Updates tab says "Check failed" itself.
        // With a list on screen it said nothing, and a list from a check that
        // failed halfway is the one most likely to be missing something: the
        // daemon keeps the rows of the backends that answered and the last
        // known rows of the one that did not. A Flatpak check that died on a
        // prompt read as "no Flatpak updates" for weeks that way (#36).
        Rectangle {
            Layout.fillWidth: true
            visible: SystemUpdateService.hasError && !SystemUpdateService.isChecking && win.pendingUpdates.length > 0
            implicitHeight: checkFailedRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.error, 0.12)

            RowLayout {
                id: checkFailedRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "error"
                    size: 22
                    color: Theme.error
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Check failed") + " · " + Tr.t("This list may be incomplete.")
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }

                    // The raw service error can be long — bounded, as in the
                    // empty state
                    StyledText {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: SystemUpdateService.errorMessage || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Ui.failColor
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                }

                DankButton {
                    buttonHeight: 32
                    iconName: "refresh"
                    iconSize: 15
                    text: Tr.t("Check for updates")
                    onClicked: SystemUpdateService.checkForUpdates()
                }
            }
        }

        // ── Tabs ────────────────────────────────────────────────────────────
        DankTabBar {
            id: tabs
            Layout.fillWidth: true
            // The active-tab indicator draws ~10px below the bar's bounds, so
            // reserve extra space between the bar and the tab content.
            Layout.bottomMargin: Theme.spacingL
            // Taller than the content so the hover highlight gets internal padding
            tabHeight: 52
            // Built from the same list of ids the rest of the window uses, so
            // a hidden tab cannot make the two disagree
            model: win.tabIds.map(id => {
                switch (id) {
                case 1:
                    return {
                        text: Tr.t("Installed"),
                        icon: "apps"
                    };
                case 2:
                    return {
                        text: Tr.t("Install"),
                        icon: "storefront"
                    };
                case 3:
                    return {
                        text: Tr.t("Firmware"),
                        icon: "memory"
                    };
                case 4:
                    return {
                        text: Tr.t("Log"),
                        icon: "history"
                    };
                default:
                    return {
                        text: Tr.t("Updates"),
                        icon: "deployed_code_update"
                    };
                }
            })

            // The shared tab bar does carry a state layer, but at surfaceTint
            // 0.08 it is invisible against this window. Draw a clearer one on
            // top. One bar-wide HoverHandler drives a single sliding
            // highlight: per-tab handlers latched their hovered state when
            // the pointer left along certain paths, leaving every visited
            // tab lit. A HoverHandler never swallows clicks, so the bar
            // keeps handling those itself.
            HoverHandler {
                id: tabsHoverHandler
            }

            Rectangle {
                id: tabHoverOverlay

                readonly property int tabCount: Math.max(1, tabs.model.length)
                readonly property real tabWidth: (tabs.width - tabs.spacing * Math.max(0, tabCount - 1)) / tabCount
                // Follow the pointer only while hovered, so the highlight
                // fades out in place instead of jumping to the first tab
                property int hoverIndex: 0
                readonly property real pointerX: tabsHoverHandler.point.position.x

                onPointerXChanged: {
                    if (tabsHoverHandler.hovered)
                        hoverIndex = Math.max(0, Math.min(tabCount - 1, Math.floor(pointerX / (tabWidth + tabs.spacing))));
                }

                x: hoverIndex * (tabWidth + tabs.spacing)
                y: 0
                width: tabWidth
                height: tabs.tabHeight
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.primary, 0.14)
                opacity: tabsHoverHandler.hovered ? 1 : 0

                Behavior on x {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }
            }

            onTabClicked: index => {
                currentIndex = index;
            }

            onCurrentIndexChanged: {
                // Derived from currentIndex right here, not read off
                // win.currentTab: that is a binding on this very property and
                // is not guaranteed to have caught up while this handler runs.
                // Reading it stale activated the previous tab's loader and
                // left the new tab blank until it was clicked twice.
                const id = win.tabIds[Math.min(currentIndex, win.tabIds.length - 1)];
                if (id === 1)
                    installedLoader.active = true;
                if (id === 2)
                    installLoader.active = true;
                if (id === 3) {
                    // Re-scan hardware on every visit; first activation scans
                    // via Component.onCompleted
                    const rescan = firmwareLoader.active;
                    firmwareLoader.active = true;
                    if (rescan && firmwareLoader.item)
                        firmwareLoader.item.reload();
                }
                if (id === 4)
                    logLoader.active = true;
                win.focusCurrentTab();
            }
        }

        // ── What is going on, said under the tabs rather than over them ─────
        // Every strip below belongs to the Updates tab and appears and vanishes
        // with it. Above the tab bar, each appearance pushed the tabs down and
        // each switch to another tab let them spring back — the row you were
        // aiming at moved while you were aiming at it. Underneath, the tabs
        // hold still and the strips take their space from the list instead.
        // ── Compact status strip while updates are pending ──────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && !win.dashboardMode && !win.showingRun && !SystemUpdateService.isChecking && win.effectiveCount > 0
            implicitHeight: statusStripRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.08)

            RowLayout {
                id: statusStripRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                Rectangle {
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    radius: 13
                    color: Theme.isLightMode ? Theme.primary : "transparent"
                    visible: stripLogo.status === Image.Ready

                    Image {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        source: stripLogo.source
                        sourceSize.width: 40
                        sourceSize.height: 40
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }
                }

                Image {
                    id: stripLogo
                    visible: false
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    source: (win.dashboard && win.dashboard.dankLogo) ? "file://" + win.dashboard.dankLogo : ""
                    sourceSize.width: 44
                    sourceSize.height: 44
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }

                DankIcon {
                    visible: stripLogo.status !== Image.Ready
                    name: "deployed_code_update"
                    size: 20
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        const parts = [(win.effectiveCount === 1 ? Tr.t("%1 update available") : Tr.t("%1 updates available")).arg(win.effectiveCount)];
                        if (win.widgetRoot && win.widgetRoot.updateSizeText !== "")
                            parts.push(win.widgetRoot.updateSizeText);
                        const checked = win.lastCheckedText();
                        if (checked)
                            parts.push(checked);
                        return parts.join(" · ");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                // How many of them close a hole. The number was already being
                // worked out and never said out loud.
                StyledText {
                    visible: win.widgetRoot !== null && win.widgetRoot.securityCount > 0
                    text: {
                        const total = win.widgetRoot ? win.widgetRoot.securityCount : 0;
                        const held = win.widgetRoot ? win.widgetRoot.heldSecurityCount : 0;
                        const base = total === 1 ? Tr.t("1 security fix") : Tr.t("%1 security fixes").arg(total);
                        return held > 0 ? base + " · " + Tr.t("%1 held back").arg(held) : base;
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: (win.widgetRoot && win.widgetRoot.heldSecurityCount > 0) ? Ui.failColor : Theme.error
                }
            }
        }

        // ── Manual-pass progress (Install all now / single overrides) ──────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.singleBusyKey !== ""
            implicitHeight: manualRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.08)

            RowLayout {
                id: manualRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankSpinner {
                    size: 22
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Installing updates…")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: win.singleUpdateStatus !== ""
                        text: win.singleUpdateStatus
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // ── End-of-life components (no longer maintained upstream) ─────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.eolShown.length > 0
            implicitHeight: eolRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.error, 0.10)

            RowLayout {
                id: eolRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "warning"
                    size: 18
                    color: Theme.error
                }

                StyledText {
                    Layout.fillWidth: true
                    // One sentence per runtime or app, with its version: a
                    // runtime's extensions (Mesa, the VAAPI driver, its
                    // Locale) arrive folded into it, and the apps that still
                    // run on it are what keep it here.
                    text: win.eolShown.map(r => {
                        const name = r.kind === "runtime" && r.branch ? (r.appName || r.id) + " " + r.branch : (r.appName || r.id);
                        if (r.eolRebase)
                            return Tr.t("%1 is no longer maintained; its successor is %2.").arg(name).arg(r.eolRebase.split("/")[1] || r.eolRebase);
                        if (r.kind !== "runtime")
                            return Tr.t("%1 is no longer maintained.").arg(name);
                        if ((r.usedBy || []).length > 0)
                            return Tr.t("%1 is no longer maintained. Still used by %2, until it moves to a newer version.").arg(name).arg(r.usedBy.join(", "));
                        return Tr.t("%1 is no longer maintained, and no installed app uses it any more.").arg(name);
                    }).join("\n")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                DankActionButton {
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    tooltipText: Tr.t("Dismiss")
                    onClicked: win.dismissEol()
                }
            }
        }

        // ── Newer Fedora release available ──────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.widgetRoot !== null && win.widgetRoot.distroUpgrade !== null && win.widgetRoot.distroUpgrade.available === true
            implicitHeight: distroRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.10)

            RowLayout {
                id: distroRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "rocket_launch"
                    size: 18
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("A new Fedora release is available: Fedora %1.").arg(win.widgetRoot && win.widgetRoot.distroUpgrade ? win.widgetRoot.distroUpgrade.latest : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: distroInfoButton.width
                    Layout.preferredHeight: distroInfoButton.height

                    DankButton {
                        id: distroInfoButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        iconName: "open_in_new"
                        iconSize: 13
                        text: Tr.t("Learn more")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        onClicked: Qt.openUrlExternally("https://docs.fedoraproject.org/en-US/quick-docs/upgrading-fedora-offline/")
                    }
                }
            }
        }

        // ── Arch has said something ─────────────────────────────────────────
        // Only when there is something unread. An announcement that has been
        // true since spring is not news, and a banner that is always there is
        // one you stop reading — which would defeat the single case this
        // exists for: the update that needs a hand before it will go through.
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && newsDialog.unread > 0
            implicitHeight: newsRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.12)

            RowLayout {
                id: newsRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "campaign"
                    size: 18
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: newsDialog.unread === 1 ? Tr.t("Arch Linux has published a news item.")
                                                  : Tr.t("Arch Linux has published %1 news items.").arg(newsDialog.unread)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: newsReadButton.width
                    Layout.preferredHeight: newsReadButton.height

                    DankButton {
                        id: newsReadButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        iconName: "campaign"
                        iconSize: 13
                        text: Tr.t("Read")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        onClicked: newsDialog.open(false)
                    }
                }
            }
        }


        // ── Installed tab (lazy) ────────────────────────────────────────────
        Loader {
            id: installedLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 1
            active: false
            opacity: visible ? 1.0 : 0.0
            x: visible ? 0 : win.tabEntryOffset(1)
            Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }

            sourceComponent: InstalledView {
                store: win.store
                engine: win.engine
                logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
                brewFormulae: win.widgetRoot ? win.widgetRoot.brewInstalled : []
                refreshSerial: win.softwareSerial
                overlayParent: windowOverlayLayer
                onSoftwareMutated: win.softwareSerial++
                onStagedChange: {
                    if (win.widgetRoot)
                        win.widgetRoot.noteStagedChange();
                }
            }
        }

        // Loaded shortly after the window opens rather than on the click that
        // asks for it. Behind that tab sit five processes, a 2 MB index and
        // the parse of it, and doing all of that on the click puts it in front
        // of the first keystroke — the tab is opened to type in it. Two
        // seconds is long enough for the window itself to have drawn, so the
        // warm-up competes with nothing the user is looking at.
        Timer {
            interval: 2000
            running: win.visible && !installLoader.active
            onTriggered: installLoader.active = true
        }

        // ── Install tab (lazy, warmed above) ────────────────────────────────
        Loader {
            id: installLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 2
            active: false
            opacity: visible ? 1.0 : 0.0
            x: visible ? 0 : win.tabEntryOffset(2)
            Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }

            sourceComponent: InstallView {
                logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
                refreshSerial: win.softwareSerial
                overlayParent: windowOverlayLayer
                onSoftwareMutated: win.softwareSerial++
                hasBrew: win.widgetRoot ? win.widgetRoot.brewSupported === true : false
                onSourcesRequested: sourcesDialog.open()
                onStagedChange: {
                    if (win.widgetRoot)
                        win.widgetRoot.noteStagedChange();
                }
            }
        }

        // ── Firmware tab (lazy) ─────────────────────────────────────────────
        Loader {
            id: firmwareLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 3
            active: false
            opacity: visible ? 1.0 : 0.0
            x: visible ? 0 : win.tabEntryOffset(3)
            Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }

            sourceComponent: FirmwareView {
                firmware: win.firmware
            }
        }

        // ── Log tab (lazy) ──────────────────────────────────────────────────
        Loader {
            id: logLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 4
            active: false
            opacity: visible ? 1.0 : 0.0
            x: visible ? 0 : win.tabEntryOffset(4)
            Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }

            sourceComponent: LogView {
                logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
                refreshSerial: win.softwareSerial
                onPackageActivated: item => win.openLogPackageDetails(item)
            }
        }

        // ── Progress panel (only while a run adds information) ──────────────
        Rectangle {
            id: resultPanel

            Layout.fillWidth: true
            // Verifying is part of the run, so the panel stays for it — it used
            // to fall through every clause here and take the stepper with it,
            // which is how a step became invisible at the moment it was the
            // one being worked on.
            visible: win.currentTab === 0 && (win.engine.running || win.engine.phase === "verifying" || (win.engine.phase !== "idle" && win.engine.failedCount > 0) || win.engine.phase === "done")
            implicitHeight: progressColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Ui.cardSurface
            clip: true

            // A clean result clears itself after a few seconds, which without
            // this reads as the card having been taken away mid-sentence. The
            // line runs out along the bottom edge instead, so the disappearance
            // is something you watched approach rather than something that
            // happened to you. It is absent when the panel is staying —
            // during the run, and after one with something to report.
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                height: 2
                visible: win.engine.autoDismissing
                color: Theme.withAlpha(Theme.primary, 0.45)
                width: resultPanel.width

                NumberAnimation on width {
                    running: win.engine.autoDismissing
                    from: resultPanel.width
                    to: 0
                    duration: win.engine.autoDismissMs
                    easing.type: Easing.Linear
                }
            }

            ColumnLayout {
                id: progressColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                PhaseIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    // Shown for as long as the panel is. The last two steps
                    // are steps like the others: verification is work with
                    // nobody at the controls — the engine is no longer running
                    // but there is a step left to pulse on — and Done is the
                    // stepper's own conclusion, which it used to leave before
                    // reaching.
                    step: win.engine.phaseStep
                    running: win.engine.running || win.engine.phase === "verifying"
                    failed: win.engine.failedCount > 0
                }

                // No overall progress bar: with parallel downloads and mixed
                // phases an aggregate fraction is more misleading than
                // helpful — the per-package rows below carry the progress.
                RowLayout {
                    Layout.fillWidth: true

                    BusyText {
                        text: win.engine.phaseLabel
                        pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: (win.engine.running && win.engine.currentItem) ? "·  " + win.store.prettyId(win.engine.currentItem) : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    // A run that ends with failures ends in the "failed"
                    // phase, so this summary has to cover that phase too —
                    // its failure half used to be unreachable
                    StyledText {
                        visible: !win.engine.running && (win.engine.phase === "done" || win.engine.phase === "failed")
                        text: Tr.t("%1 updated").arg(win.engine.completedCount) + (win.engine.failedCount > 0 ? " · " + Tr.t("%1 failed").arg(win.engine.failedCount) : "")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: win.engine.failedCount > 0 ? Ui.failColor : Theme.success
                    }

                    // Whatever happens to this panel — dismissed, or swept
                    // away by the shell reloading — the log keeps the run
                    // Wrapper Item: DankButton sizes itself through `width`, which a layout does not read
                    Item {
                        Layout.preferredWidth: viewInLogButton.width
                        Layout.preferredHeight: viewInLogButton.height
                        // On the wrapper, not read off the button: `visible`
                        // reads back as false whenever a parent's is, so a
                        // wrapper asking its child latches shut the first time
                        // the condition is false — which here is at startup
                        visible: !win.engine.running && win.engine.phase !== "idle" && win.engine.failedCount > 0

                        DankButton {
                            id: viewInLogButton
                            buttonHeight: 26
                            horizontalPadding: Theme.spacingM
                            iconName: "history"
                            iconSize: 14
                            text: Tr.t("View in log")
                            backgroundColor: Ui.buttonFill("tonal", false)
                            textColor: Ui.buttonInk("tonal")
                            onClicked: win.openLatestLogEntry()
                        }
                    }

                    DankActionButton {
                        visible: !win.engine.running && win.engine.phase !== "idle"
                        buttonSize: 24
                        iconName: "close"
                        iconSize: 15
                        iconColor: Theme.surfaceVariantText
                        tooltipText: Tr.t("Dismiss result")
                        onClicked: win.engine.dismiss()
                    }
                }

                // Download phase details: sizes, speed, item counts
                BusyText {
                    Layout.fillWidth: true
                    visible: win.engine.running && win.engine.progressDetail !== ""
                    text: win.engine.progressDetail
                    pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }
        }

        // ── Update list (a heading per category, like Installed) ──────────────
        DankListView {
            id: cardsList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            // A category is set apart by the height of its heading, not by a
            // container around it
            spacing: 2
            visible: win.currentTab === 0 && (win.shownSections.length > 0 || win.dashboardMode)
            opacity: visible ? 1.0 : 0.0
            x: visible ? 0 : win.tabEntryOffset(0)
            Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Component.onCompleted: {
                Ui.softenScrollbar(cardsList);
                win._refreshSections();
            }
            header: win.dashboardMode ? dashboardHeaderComponent : null

            Connections {
                target: win.engine

                function onRunningChanged() {
                    if (!win.engine.running)
                        return;
                    cardsList.positionViewAtBeginning();
                    Qt.callLater(() => cardsList.positionViewAtBeginning());
                }
            }

            onContentYChanged: {
                const maxY = Math.max(originY, originY + contentHeight - height);
                if (contentY > maxY)
                    contentY = maxY;
            }

            model: sectionModel
            // Build every category, not only those on screen. There are a
            // handful, and each one already builds all of its rows; with only
            // some of them built the list guessed its own height from the
            // ones it had, and the scrollbar grew and shrank while scrolling.
            cacheBuffer: 100000

            // The heading of the category being scrolled through stays at the
            // top, as in Installed and Install. Each item is a whole category,
            // so every row is a heading.
            StickyHeader {
                id: updatesSticky

                view: cardsList
                rows: win.shownSections
                headingOf: row => row || ""
                barHeight: 48

                content: Component {
                    Item {
                        id: stickyBar
                        anchors.fill: parent

                        property var rowData: updatesSticky.heading || ({})
                        readonly property bool updatable: !win.engine.running && win.singleBusyKey === "" && win.sectionUpdatable(rowData.category || "")

                        HoverHandler {
                            id: stickyHover
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: stickyBar.rowData.collapsible === true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: win.toggleCategory(stickyBar.rowData.category)
                        }

                        RowLayout {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: win.categoryIcon(stickyBar.rowData.category || "")
                                size: 20
                                color: win.categoryColor(stickyBar.rowData.category || "")
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: stickyBar.rowData.title || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Rectangle {
                                implicitWidth: stickyCount.implicitWidth + 14
                                implicitHeight: 20
                                radius: 10
                                color: Theme.withAlpha(win.categoryColor(stickyBar.rowData.category || ""), 0.15)
                                Layout.alignment: Qt.AlignVCenter

                                StyledText {
                                    id: stickyCount
                                    anchors.centerIn: parent
                                    text: String(stickyBar.rowData.count || 0)
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    font.weight: Font.Medium
                                    color: win.categoryColor(stickyBar.rowData.category || "")
                                }
                            }

                            DankIcon {
                                visible: stickyBar.rowData.collapsible === true
                                name: stickyBar.rowData.collapsed === true ? "expand_more" : "expand_less"
                                size: 16
                                color: Theme.surfaceVariantText
                                Layout.alignment: Qt.AlignVCenter
                            }
                        }

                        DankButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: stickyBar.updatable && stickyHover.hovered
                            buttonHeight: 26
                            iconName: "download"
                            iconSize: 14
                            horizontalPadding: Theme.spacingM
                            text: Tr.t("Update these")
                            backgroundColor: Ui.buttonFill("tonal", false)
                            textColor: Ui.buttonInk("tonal")
                            onClicked: win.sectionUpdate(stickyBar.rowData.category)
                        }
                    }
                }
            }

            delegate: Item {
                id: catContainer
                required property string category
                readonly property var modelData: win.sectionByCategory[category] || ({
                        category: category,
                        items: []
                    })

                width: cardsList.width
                implicitHeight: catCol.implicitHeight
                clip: true

                readonly property bool updatable: !win.engine.running && win.singleBusyKey === "" && win.sectionUpdatable(modelData.category || "")

                ColumnLayout {
                    id: catCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: Theme.spacingS

                    // Category heading, the same height as Installed's
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 48

                        HoverHandler {
                            id: catHeaderHover
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: catContainer.modelData.collapsible === true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: win.toggleCategory(catContainer.modelData.category)
                        }

                        RowLayout {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: win.categoryIcon(catContainer.modelData.category || "")
                                size: 20
                                color: win.categoryColor(catContainer.modelData.category || "")
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: catContainer.modelData.title || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Rectangle {
                                implicitWidth: headerCount.implicitWidth + 14
                                implicitHeight: 20
                                radius: 10
                                color: Theme.withAlpha(win.categoryColor(catContainer.modelData.category || ""), 0.15)
                                Layout.alignment: Qt.AlignVCenter

                                StyledText {
                                    id: headerCount
                                    anchors.centerIn: parent
                                    text: String(catContainer.modelData.count || 0)
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    font.weight: Font.Medium
                                    color: win.categoryColor(catContainer.modelData.category || "")
                                }
                            }

                            DankIcon {
                                visible: catContainer.modelData.collapsible === true
                                name: catContainer.modelData.collapsed === true ? "expand_more" : "expand_less"
                                size: 16
                                color: Theme.surfaceVariantText
                                Layout.alignment: Qt.AlignVCenter
                            }
                        }

                        DankButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: catContainer.updatable && catHeaderHover.hovered
                            buttonHeight: 26
                            iconName: "download"
                            iconSize: 14
                            horizontalPadding: Theme.spacingM
                            text: Tr.t("Update these")
                            backgroundColor: Ui.buttonFill("tonal", false)
                            textColor: Ui.buttonInk("tonal")
                            onClicked: win.sectionUpdate(catContainer.modelData.category)
                        }
                    }

                    // The category's rows
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: !catContainer.modelData.collapsed
                        spacing: 2

                        Repeater {
                            model: catContainer.modelData.items || []

                            delegate: UpdateCard {
                                id: cardItem
                                required property var modelData
                                required property int index

                                Layout.fillWidth: true
                                active: (updatesDialog.showing && updatesDialog.rowData && updatesDialog.rowData.pkg && modelData.pkg && updatesDialog.rowData.pkg.name === modelData.pkg.name && updatesDialog.rowData.pkg.repo === modelData.pkg.repo)
                                isSectionFirst: index === 0
                                isSectionLast: index === (catContainer.modelData.items.length - 1)
                                showSource: catContainer.modelData.repeatsHeading !== true
                                shellIconPath: (modelData.pkg && win._isShellPkg(modelData.pkg) && win.widgetRoot) ? win.widgetRoot.dankLogoPath : ""
                                pkg: modelData.pkg || ({ name: "", repo: "system" })
                                info: {
                                    if (modelData.aiInfo)
                                        return { name: modelData.aiInfo.name, summary: "AppImage", homepage: modelData.aiInfo.url || "", icon: "", releases: [] };
                                    if (modelData.fwInfo)
                                        return { name: modelData.fwInfo.name, summary: modelData.fwInfo.summary, homepage: modelData.fwInfo.homepage, icon: "", releases: [{ version: modelData.fwInfo.next, date: 0, notesHtml: modelData.fwInfo.notesHtml, newer: true }] };
                                    return win.store.infoFor(modelData.pkg);
                                }
                                itemState: win.engine.stateFor(modelData.pkg)
                                errorDetail: win.engine.runErrorDetails && modelData.pkg ? win.engine.errorDetailFor(modelData.pkg) : ""
                                blockedReason: (modelData.fwInfo && firmware) ? firmware.blockerText(modelData.fwInfo.blocker) : ""
                                advisory: (win.widgetRoot && modelData.pkg) ? (win.widgetRoot.advisories[win.store.stripArch(modelData.pkg.name)] || null) : null
                                store: win.store
                                engineBusy: win.engine.running
                                held: modelData.ignored === true || win.store.isHeld(modelData.pkg)
                                holdReason: modelData.ignored === true ? Tr.t("held by you") : win.store.holdReason(modelData.pkg)
                                isIgnored: modelData.ignored === true
                                canHold: {
                                    if (modelData.ignored === true) return true;
                                    if (!modelData.pkg || modelData.pkg.repo === "firmware") return false;
                                    if (win.store.isHeld(modelData.pkg)) return false;
                                    return SystemUpdateService.canIgnorePackage(modelData.pkg);
                                }
                                showUpdateButton: modelData.pkg && modelData.pkg.repo !== "firmware" && win.singleBusyKey === "" && !win.engine.running && (modelData.ignored !== true)
                                onUpdateRequested: win.runSingleUpdate(modelData)
                                onHoldToggleRequested: win.setHold(modelData.pkg, modelData.ignored !== true)
                                onDetailsRequested: win.openUpdateDetails(modelData, info)
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: dashboardHeaderComponent

            Item {
                width: cardsList.width
                implicitHeight: dashHeaderColumn.implicitHeight + Theme.spacingL

                ColumnLayout {
                    id: dashHeaderColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Theme.spacingL

                    // Hero Card: Dank logo, status, check-on-hover
                    StyledRect {
                        id: heroCard

                        // Pressing this starts a check, and the cursor said so
                        // while the card itself did not: a pointing hand over
                        // a surface that never acknowledged it. It answers in
                        // the same language every row in the app uses — the
                        // primary tint — and only while the
                        // press would actually do something, so it stays
                        // quiet through a check that is already running.
                        readonly property bool actionable: !SystemUpdateService.isChecking && !win.engine.running
                        readonly property bool lit: actionable && windowEmptyArea.containsMouse

                        Layout.fillWidth: true
                        Layout.topMargin: Theme.spacingM
                        implicitHeight: heroRow.implicitHeight + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: lit ? Theme.primaryHover
                                   : Theme.withAlpha(Ui.chipSurface, 0.45)

                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        MouseArea {
                            id: windowEmptyArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: (SystemUpdateService.isChecking || win.engine.running) ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: {
                                if (!SystemUpdateService.isChecking && !win.engine.running)
                                    SystemUpdateService.checkForUpdates();
                            }
                        }

                        RowLayout {
                            id: heroRow
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingL

                            // Wider than the disc it holds: the pulse rings
                            // grow past the disc's edge before they fade, and
                            // they have to land somewhere. 1.87 × the disc is
                            // the ratio the shell's own System Check page uses
                            // between its loading box and the circle inside it.
                            Item {
                                Layout.preferredWidth: Math.round(72 * 1.87)
                                Layout.preferredHeight: Math.round(72 * 1.87)

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 72
                                    height: 72
                                    radius: width / 2
                                    // Light mode: solid primary disc so the white penguin stays visible
                                    color: {
                                        if (Theme.isLightMode)
                                            return windowEmptyArea.containsMouse && !SystemUpdateService.isChecking ? Qt.darker(Theme.primary, 1.15) : Theme.primary;
                                        return windowEmptyArea.containsMouse && !SystemUpdateService.isChecking ? Theme.withAlpha(Theme.primary, 0.12) : Theme.withAlpha(Theme.primary, 0.06);
                                    }

                                    Behavior on color {
                                        ColorAnimation {
                                            duration: Theme.shortDuration
                                        }
                                    }
                                }

                                // A check used to hide the logo behind a spinning
                                // arrow. The shell's own System Check page keeps
                                // its mark and pulses around it instead, which
                                // says the same thing without taking the face of
                                // the app away while it works.
                                PulseRings {
                                    id: heroPulse
                                    anchors.fill: parent
                                    running: SystemUpdateService.isChecking
                                }

                                Image {
                                    id: dankLogoImage
                                    anchors.centerIn: parent
                                    width: 46
                                    height: 46
                                    source: (win.dashboard && win.dashboard.dankLogo) ? "file://" + win.dashboard.dankLogo : ""
                                    // An SVG is rasterised once at sourceSize
                                    // and then scaled like a bitmap. 92 was
                                    // exactly twice the drawn size, which is
                                    // right until the pulse blows it up by a
                                    // tenth on a HiDPI screen — 101 device
                                    // pixels out of a 92-pixel raster, softest
                                    // at the peak of every breath. Ask for
                                    // what the peak actually needs.
                                    sourceSize.width: Math.ceil(width * 1.1 * Screen.devicePixelRatio)
                                    sourceSize.height: Math.ceil(height * 1.1 * Screen.devicePixelRatio)
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    scale: heroPulse.breath
                                    // Hover swaps in the refresh arrow to say the
                                    // click does something — but not mid-check,
                                    // when it does not
                                    visible: status === Image.Ready && (SystemUpdateService.isChecking || !windowEmptyArea.containsMouse)

                                    // The shell's mark in the shell's colour.
                                    // Light mode is left alone on purpose: there
                                    // the disc behind it is solid primary and the
                                    // penguin is white on top of it, so tinting it
                                    // primary would paint it out of sight.
                                    layer.enabled: !Theme.isLightMode
                                    layer.effect: MultiEffect {
                                        colorization: 1.0
                                        colorizationColor: Theme.primary
                                    }
                                }

                                DankIcon {
                                    id: heroStateIcon
                                    anchors.centerIn: parent
                                    visible: !dankLogoImage.visible
                                    // Scaled by the same breath, and a glyph
                                    // hinted to the pixel grid does not survive
                                    // being scaled any better than it survived
                                    // being rotated in the bar pill
                                    smoothTransform: true
                                    scale: heroPulse.breath
                                    name: {
                                        if (SystemUpdateService.isChecking || windowEmptyArea.containsMouse)
                                            return "refresh";
                                        return SystemUpdateService.hasError ? "error" : "task_alt";
                                    }
                                    size: 40
                                    color: {
                                        if (Theme.isLightMode)
                                            return "white";
                                        if (SystemUpdateService.isChecking || windowEmptyArea.containsMouse)
                                            return Theme.primary;
                                        // Up to date is the app's own state, not a
                                        // traffic light: it wears the accent like
                                        // everything else here. A failed check keeps
                                        // its red, which is the one case where the
                                        // colour is carrying the meaning.
                                        return SystemUpdateService.hasError ? Theme.error : Theme.primary;
                                    }
                                }
                            }

                            ColumnLayout {
                                spacing: 2

                                BusyText {
                                    text: {
                                        if (SystemUpdateService.isChecking)
                                            return Tr.t("Checking for updates…");
                                        if (windowEmptyArea.containsMouse)
                                            return Tr.t("Check for updates");
                                        if (SystemUpdateService.hasError)
                                            return Tr.t("Check failed");
                                        return Tr.t("Your system is up to date!");
                                    }
                                    pixelSize: Theme.fontSizeLarge
                                    color: Theme.surfaceText
                                }

                                // The raw service error (curl/dnf output) can be
                                // arbitrarily long — wrap it in a bounded block
                                // instead of letting it stretch the hero row.
                                StyledText {
                                    visible: SystemUpdateService.hasError && !SystemUpdateService.isChecking && !windowEmptyArea.containsMouse
                                    text: SystemUpdateService.errorMessage || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Ui.failColor
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: Math.min(520, win.width - 220)
                                }

                                StyledText {
                                    visible: !SystemUpdateService.isChecking && !SystemUpdateService.hasError && (win.lastUpdateUnix > 0 || SystemUpdateService.nextCheckUnix > 0)
                                    text: {
                                        const parts = [];
                                        if (win.lastUpdateUnix > 0)
                                            parts.push(Tr.t("Last update %1").arg(win.formatAgo(win.lastUpdateUnix)));
                                        const next = win.formatIn(SystemUpdateService.nextCheckUnix);
                                        if (next)
                                            parts.push(Tr.t("next check %1").arg(next));
                                        return parts.join(" · ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }


                            }
                        }
                    }

                    // Cards
                    GridLayout {
                        Layout.fillWidth: true
                        columns: cardsList.width < 640 ? 1 : 2
                        columnSpacing: Theme.spacingM
                        rowSpacing: Theme.spacingM

                        // System info
                        StyledRect {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: systemCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Ui.chipSurface, 0.45)
                            border.width: 0

                            ColumnLayout {
                                id: systemCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "computer"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("System")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                Repeater {
                                    model: {
                                        const dash = win.dashboard || {};
                                        return [
                                            { label: "OS", value: dash.osPretty || SystemUpdateService.distroPretty || "" },
                                            { label: "Host", value: dash.hostname || "" },
                                            { label: "Kernel", value: dash.kernel || "" },
                                            // The shell this window is a part of, as the daemon
                                            // reports itself. A release build says 1.5.2; a git
                                            // build says what it is, at length, and that is the
                                            // honest answer rather than something tidied up
                                            { label: "DMS", value: DMSService.cliVersion || "" },
                                            { label: Tr.t("Uptime"), value: win.formatUptime(dash.uptimeSecs || 0) }
                                        ].filter(row => row.value !== "");
                                    }

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            Layout.preferredWidth: 60
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.value
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        // Status
                        StyledRect {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: statusCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Ui.chipSurface, 0.45)
                            border.width: 0

                            ColumnLayout {
                                id: statusCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "monitor_heart"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("Status")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                Repeater {
                                    model: {
                                        const root = win.widgetRoot;
                                        if (!root)
                                            return [];
                                        const autoLabels = {
                                            "off": Tr.t("Off"),
                                            "notify": Tr.t("Notify only"),
                                            "auto": Tr.t("Auto-install Flatpaks")
                                        };
                                        return [
                                            { label: Tr.t("Held"), value: String((root.heldSystemKeys || []).length + (SettingsData.updaterIgnoredPackages || []).length) },
                                            { label: "End-of-life", value: String((root.eolRefs || []).length) },
                                            { label: Tr.t("Automatic updates"), value: autoLabels[root.autoUpdateMode] || Tr.t("Off") },
                                            { label: "Dux Software Depot", value: win.pluginManifest.version ? "v" + win.pluginManifest.version : "" }
                                        ].filter(row => row.value !== "");
                                    }

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            text: modelData.value
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceText
                                        }
                                    }
                                }
                            }
                        }
                        // Installed software per source
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: installedCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Ui.chipSurface, 0.45)

                            ColumnLayout {
                                id: installedCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                // The card's heading is the way into the tab
                                // it summarises. Handlers rather than a
                                // MouseArea: a filling MouseArea inside a
                                // layout would be laid out as a column of its
                                // own and anchor-clash with it.
                                RowLayout {
                                    spacing: Theme.spacingS

                                    HoverHandler {
                                        id: installedCardHover
                                        cursorShape: Qt.PointingHandCursor
                                    }

                                    TapHandler {
                                        onTapped: win.openTab(1)
                                    }

                                    DankIcon {
                                        name: "apps"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("Installed software")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        font.underline: installedCardHover.hovered
                                        color: installedCardHover.hovered ? Theme.primary : Theme.surfaceText
                                    }

                                    DankIcon {
                                        name: "chevron_right"
                                        size: 16
                                        color: Theme.primary
                                        opacity: installedCardHover.hovered ? 1 : 0

                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: Theme.shortDuration
                                            }
                                        }
                                    }
                                }

                                Repeater {
                                    model: {
                                        const dash = win.dashboard || {};
                                        const copr = dash.coprCount || 0;
                                        // Second row: COPR on Fedora, AUR/foreign on Arch,
                                        // nothing comparable on Debian
                                        return [
                                            { label: Backend.systemRepoLabel, icon: "memory", count: Math.max(0, (dash.rpmTotal || 0) - copr) },
                                            { label: Backend.backendId === "pacman" ? "AUR" : "COPR", icon: "science", count: copr },
                                            { label: "Flatpak", icon: "apps", count: dash.flatpakCount || 0 },
                                            { label: "AppImage", icon: "deployed_code", count: dash.appimageCount || 0 },
                                            // The plugins in the shell this window runs in. Counted
                                            // from the manifests PluginService has already read, so
                                            // this is what is installed rather than what is enabled.
                                            { label: Tr.t("DMS plugins"), icon: "extension", count: Object.keys(PluginService.availablePlugins || {}).length },
                                            // Only on a machine that has brew: a row
                                            // reading "Homebrew 0" on the other ones is
                                            // an answer to a question nobody asked
                                            { label: "Homebrew", icon: "local_drink", count: (win.widgetRoot ? (win.widgetRoot.brewInstalled || []).length : 0) }
                                        ].filter(row => row.label !== "COPR" && row.label !== "AUR" || row.count > 0 || Backend.backendId === "dnf")
                                         .filter(row => row.label !== "Homebrew" || row.count > 0);
                                    }

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: modelData.icon
                                            size: 14
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: String(modelData.count)
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.primary
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 1
                                    color: Theme.withAlpha(Theme.outline, 0.15)
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: Tr.t("Total: %1").arg((win.dashboard ? (win.dashboard.rpmTotal || 0) + (win.dashboard.flatpakCount || 0) + (win.dashboard.appimageCount || 0) : 0) + Object.keys(PluginService.availablePlugins || {}).length + (win.widgetRoot ? (win.widgetRoot.brewInstalled || []).length : 0))
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                        }

                        // Recently updated
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: recentCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Ui.chipSurface, 0.45)

                            ColumnLayout {
                                id: recentCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                // The card's heading is the way into the tab
                                // it summarises. Handlers rather than a
                                // MouseArea: a filling MouseArea inside a
                                // layout would be laid out as a column of its
                                // own and anchor-clash with it.
                                RowLayout {
                                    spacing: Theme.spacingS

                                    HoverHandler {
                                        id: recentCardHover
                                        cursorShape: Qt.PointingHandCursor
                                    }

                                    TapHandler {
                                        onTapped: win.openTab(4)
                                    }

                                    DankIcon {
                                        name: "history"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("Recently updated")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        font.underline: recentCardHover.hovered
                                        color: recentCardHover.hovered ? Theme.primary : Theme.surfaceText
                                    }

                                    DankIcon {
                                        name: "chevron_right"
                                        size: 16
                                        color: Theme.primary
                                        opacity: recentCardHover.hovered ? 1 : 0

                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: Theme.shortDuration
                                            }
                                        }
                                    }
                                }

                                ListView {
                                    id: recentList

                                    // Five visible rows (one fewer than before) keeps
                                    // this card level with the installed-software one;
                                    // the rest of the 50 entries scrolls.
                                    readonly property int rowHeight: 24

                                    Layout.fillWidth: true
                                    Layout.preferredHeight: rowHeight * Math.min(5, count)
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: (win.dashboard && win.dashboard.recent) ? win.dashboard.recent : []

                                    delegate: Item {
                                        required property var modelData

                                        width: ListView.view.width
                                        height: recentList.rowHeight

                                        RowLayout {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingS

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: modelData.name
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                text: win.formatAgo(modelData.ts)
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceVariantText
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // A year read back out of the action log. Spanning
                        // both columns: it is sentences, not a column of
                        // numbers like the four cards above.
                        RetrospectCard {
                            Layout.fillWidth: true
                            Layout.columnSpan: parent.columns
                            log: win.widgetRoot ? (win.widgetRoot.actionLogger.entries || []) : []
                        }
                    }

                    // ── Reclaimable space ───────────────────────────────────
                    // Two piles nobody looks at until a disk fills: packages
                    // pulled in for something since removed, and the download
                    // cache. Shown with their real sizes so the offer is a
                    // fact rather than a suggestion.
                    Rectangle {
                        id: cleanupCard

                        readonly property var scan: win.widgetRoot ? win.widgetRoot.cleanup : null
                        readonly property real total: scan ? ((scan.unneeded.bytes || 0) + (scan.cache.bytes || 0)) : 0

                        // Fifty megabytes is what makes the card worth
                        // appearing. It is not what makes it worth staying:
                        // this card offers two piles, and clearing the larger
                        // one can drop the total under the bar while the other
                        // is still sitting there. The card then vanished
                        // mid-use, taking the second button with it and
                        // leaving no way back to it. So the threshold decides
                        // the first appearance only; after that the card is
                        // here until there is nothing left to offer.
                        property bool engaged: false
                        property var cleanedKinds: []

                        function noteCleanup(kind) {
                            engaged = true;
                            if (cleanedKinds.indexOf(kind) === -1)
                                cleanedKinds = cleanedKinds.concat([kind]);
                        }

                        // A fresh visit starts fresh: the finished rows are
                        // feedback on what just happened, not a record
                        Connections {
                            target: win
                            function onVisibleChanged() {
                                if (!win.visible) {
                                    cleanupCard.engaged = false;
                                    cleanupCard.cleanedKinds = [];
                                }
                            }
                        }

                        Layout.fillWidth: true
                        visible: total > 50 * 1024 * 1024 || (engaged && (total > 0 || cleanedKinds.length > 0))
                        implicitHeight: cleanupColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)

                        ColumnLayout {
                            id: cleanupColumn
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "cleaning_services"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Reclaim space")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                StyledText {
                                    text: win.engine.formatBytes(parent.parent.parent.total)
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.primary
                                }
                            }

                            Repeater {
                                model: {
                                    const scan = win.widgetRoot ? win.widgetRoot.cleanup : null;
                                    if (!scan)
                                        return [];
                                    const rows = [];
                                    if (scan.unneeded.count > 0)
                                        rows.push({
                                            kind: "packages",
                                            label: Tr.t("%1 packages nothing needs any more").arg(scan.unneeded.count),
                                            bytes: scan.unneeded.bytes || 0,
                                            action: Tr.t("Remove")
                                        });
                                    if ((scan.cache.bytes || 0) > 0)
                                        rows.push({
                                            kind: "cache",
                                            label: Tr.t("Downloaded package files, already installed"),
                                            bytes: scan.cache.bytes,
                                            action: Tr.t("Empty")
                                        });
                                    // What was cleared stays on the card as a
                                    // finished row rather than disappearing.
                                    // A row that vanishes on click leaves the
                                    // reader guessing whether it worked, and
                                    // shuffles whatever was under it upward
                                    // just as they reach for it.
                                    for (const kind of cleanupCard.cleanedKinds) {
                                        if (rows.some(row => row.kind === kind))
                                            continue;
                                        rows.push({
                                            kind: kind,
                                            label: kind === "packages" ? Tr.t("Packages nothing needs any more") : Tr.t("Downloaded package files, already installed"),
                                            bytes: 0,
                                            done: true
                                        });
                                    }
                                    return rows;
                                }

                                delegate: RowLayout {
                                    required property var modelData

                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: modelData.done === true ? modelData.label : modelData.label + " · " + win.engine.formatBytes(modelData.bytes)
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: modelData.done === true ? Theme.withAlpha(Theme.surfaceVariantText, 0.7) : Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }

                                    DankIcon {
                                        visible: modelData.done === true
                                        name: "check"
                                        size: 14
                                        color: Theme.success
                                    }

                                    StyledText {
                                        visible: modelData.done === true
                                        text: Tr.t("Cleared")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.success
                                    }

                                    Item {
                                        implicitWidth: cleanupButton.width
                                        implicitHeight: cleanupButton.height
                                        visible: modelData.done !== true

                                        DankButton {
                                            id: cleanupButton
                                            buttonHeight: 26
                                            horizontalPadding: Theme.spacingM
                                            text: (win.widgetRoot && win.widgetRoot.cleanupBusy === modelData.kind) ? Tr.t("Working…") : modelData.action
                                            backgroundColor: Ui.buttonFill("tonal", false)
                                            textColor: Ui.buttonInk("tonal")
                                            enabled: win.widgetRoot !== null && win.widgetRoot.cleanupBusy === ""
                                            onClicked: {
                                                cleanupCard.noteCleanup(modelData.kind);
                                                if (modelData.kind === "packages")
                                                    win.widgetRoot.removeUnneeded();
                                                else
                                                    win.widgetRoot.cleanCache();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Support links ───────────────────────────────────────
                    // Only on the dashboard, where nothing else needs doing
                    SupportChips {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Theme.spacingXS
                        repoUrl: win.githubUrl
                    }
                }
            }
        }

        // ── What Update All would do ────────────────────────────────────────
        // The resolver's answer, shown before the click rather than after the
        // password: how much arrives, what nobody asked for, and what leaves.
        Rectangle {
            id: planStrip

            Layout.fillWidth: true
            readonly property var plan: win.engine.previewPlan
            visible: win.currentTab === 0 && !win.engine.running && win.showUpdateAll && plan !== null
            implicitHeight: planRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(plan && plan.removals > 0 ? Theme.warning : Theme.surfaceVariantText, 0.08)

            RowLayout {
                id: planRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                DankIcon {
                    name: planStrip.plan && planStrip.plan.removals > 0 ? "warning" : "checklist"
                    size: 16
                    color: planStrip.plan && planStrip.plan.removals > 0 ? Theme.warning : Theme.surfaceVariantText
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        const plan = win.engine.previewPlan;
                        if (!plan)
                            return "";
                        const parts = [Tr.t("%1 packages").arg(plan.total), win.engine.formatBytes(plan.downloadBytes)];
                        if (plan.diskDeltaBytes > 0)
                            parts.push(Tr.t("+%1 on disk").arg(win.engine.formatBytes(plan.diskDeltaBytes)));
                        else if (plan.diskDeltaBytes < 0)
                            parts.push(Tr.t("frees %1").arg(win.engine.formatBytes(-plan.diskDeltaBytes)));
                        if (plan.extra > 0)
                            parts.push(Tr.t("%1 pulled in as dependencies").arg(plan.extra));
                        if (plan.removals > 0)
                            parts.push(Tr.t("%1 will be removed: %2").arg(plan.removals).arg(plan.removedNames.slice(0, 3).join(", ")));
                        // Measured here, not guessed: silent while this
                        // machine has not shown enough runs to have an opinion
                        const seconds = win.widgetRoot ? win.widgetRoot.estimateRunSeconds(plan.total) : -1;
                        if (seconds > 0)
                            parts.push(Tr.t("usually about %1 here").arg(win.engine.formatDuration(seconds)));
                        return parts.join(" · ");
                    }
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.hiddenRuntimeCount > 0
            text: (win.hiddenRuntimeCount === 1 ? Tr.t("%1 runtime component hidden (enable in plugin settings) — still included in Update All.") : Tr.t("%1 runtime components hidden (enable in plugin settings) — still included in Update All.")).arg(win.hiddenRuntimeCount)
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        // ── Footer buttons (Dynamic rounded corner styling) ─────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.showUpdateAll
            spacing: Theme.spacingM

            Item {
                Layout.fillWidth: true
            }

            Rectangle {
                id: windowUpdateAllButton
                readonly property bool busyRun: win.updateAllBusy
                readonly property bool isHovered: updateAllMa.containsMouse

                Layout.preferredHeight: 36
                Layout.preferredWidth: updateAllRow.implicitWidth + 32

                // The Updates tab's one filled button; Cancel during a run
                // is tonal with red ink, never a second loud button
                readonly property string kind: busyRun ? "dangerTonal" : "filled"

                radius: updateAllMa.pressed ? (height / 2) : Theme.cornerRadius
                Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                color: Ui.buttonFill(kind, isHovered)
                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                scale: updateAllMa.pressed ? 0.94 : 1.0
                Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                DankRipple {
                    id: updateAllRip
                    anchors.fill: parent
                    cornerRadius: parent.radius
                    rippleColor: Ui.buttonInk(windowUpdateAllButton.kind)
                }

                RowLayout {
                    id: updateAllRow
                    anchors.centerIn: parent
                    spacing: 8

                    DankIcon {
                        name: windowUpdateAllButton.busyRun ? "close" : "download"
                        size: 16
                        color: Ui.buttonInk(windowUpdateAllButton.kind)
                    }

                    StyledText {
                        text: windowUpdateAllButton.busyRun ? Tr.t("Cancel") : (Tr.t("Update All") + ((win.widgetRoot && win.widgetRoot.updateSizeText !== "") ? " · " + win.widgetRoot.updateSizeText : ""))
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Ui.buttonInk(windowUpdateAllButton.kind)
                    }
                }

                MouseArea {
                    id: updateAllMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: (m) => updateAllRip.trigger(m.x, m.y)
                    onClicked: {
                        if (windowUpdateAllButton.busyRun) {
                            win.engine.cancel();
                        } else {
                            win.engine.start({});
                        }
                    }
                }
            }
        }
    }
}
