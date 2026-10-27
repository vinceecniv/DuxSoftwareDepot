import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Dux Software Depot — DankBar widget.
// The pill shows the update count (or live progress during an update run).
// Clicking opens a compact popout; the full experience lives in the
// standalone window (UpdaterWindow).
PluginComponent {
    id: root

    // ── Settings ─────────────────────────────────────────────────────────────
    readonly property bool hideWhenUpToDate: pluginData.hideWhenUpToDate === true
    readonly property bool showRuntimes: pluginData.showRuntimes === true
    readonly property bool confirmBeforeUpdate: pluginData.confirmBeforeUpdate === true
    readonly property bool pillOpensWindow: pluginData.pillOpensWindow === true
    readonly property bool includeFirmware: pluginData.includeFirmware !== false
    // The offer to place a launcher entry is made once; declining it is a
    // decision, not something to be asked again on the next window open
    readonly property bool launcherPromptDone: pluginData.launcherPromptDone === true

    // The .appimage association is never claimed on our own: it is the
    // switch under Settings, off until someone turns it on. A plugin that made
    // itself the handler for a file type on first run was deciding for the
    // user what double-clicking a download does (dms-plugin-registry#720).

    property bool confirmArmed: false

    // Last known update list, persisted across restarts: the daemon loses
    // its in-memory state when it restarts (reboot, dms restart) and only
    // repopulates at its next check — until the service has real state the
    // snapshot is shown, so previously found updates reappear immediately.
    readonly property bool _serviceHasState: SystemUpdateService.lastCheckUnix > 0 || (SystemUpdateService.availableUpdates || []).length > 0
    readonly property var pendingUpdates: {
        // A replay shows what was pending when the recording was taken. The
        // machine has moved on — those packages are installed — so the live
        // list would be the one thing in a simulated run that is not part of
        // the simulation.
        const raw = Backend.replaying ? (Backend.simPackages || [])
            : (_serviceHasState ? (SystemUpdateService.availableUpdates || []) : ((pluginData.updatesSnapshot || {}).packages || []));
        // The daemon can name the same package twice — one entry per
        // repository carrying it, which for a package in two enabled Coprs is
        // two. The list has always collapsed those, because it keys its rows
        // by package; the count above it did not, and the two disagreed on
        // screen: "4 updates" over a list of three.
        const seen = new Set();
        const out = [];
        for (const pkg of raw) {
            const key = store.keyFor(pkg);
            if (seen.has(key))
                continue;
            seen.add(key);
            if (!Backend.replaying && _justUpdated(key, pkg.toVersion))
                continue;
            out.push(pkg);
        }
        return out;
    }

    // ── What the last run just installed ────────────────────────────────────
    // A list shown after a run must not offer again what that run has just
    // installed. The refresh before a transaction and the check after it are
    // meant to see to that, but the check is the daemon's, and the daemon can
    // answer from what it knew before the run — then a row that the run
    // reported as done, and that verification confirmed, came straight back
    // as pending. So every list here also leaves out what the last run did,
    // as a safety net under the check rather than instead of it.
    //
    // key -> {to: target version, at: ms}. With a target version only that
    // version is hidden: a newer one released since is a real update. A row
    // that never named one (a Flatpak's is often "?") is hidden until a check
    // that finished after the run, and succeeded, has had its say — a fixed
    // quarter of an hour let it come back while the daemon still answered
    // from before. An entry goes once such a check no longer reports it, or
    // after a day; it is persisted, because the DMS pass reloads the shell
    // and with it this plugin.
    readonly property var _succeeded: Backend.replaying ? ({}) : (pluginData.justUpdated || {})
    readonly property int _succeededMs: 24 * 3600 * 1000

    function _justUpdated(key, toVersion) {
        const entry = _succeeded[key];
        if (!entry)
            return false;
        const noEpoch = v => String(v || "").replace(/^\d+:/, "");
        const want = noEpoch(entry.to);
        const offered = noEpoch(toVersion);
        if (want === "" || offered === "" || offered === "?")
            return (SystemUpdateService.lastCheckUnix || 0) * 1000 <= (entry.at || 0) || SystemUpdateService.hasError;
        return want === offered;
    }

    function _rememberSucceeded() {
        const done = [];
        for (const item of engine.runItems || []) {
            const state = engine.itemStates[item.key];
            if (state && state.status === "done")
                done.push({
                    key: item.key,
                    to: (item.pkg && item.pkg.toVersion) || ""
                });
        }
        _addSucceeded(done, Date.now());
    }

    // [{key, to}] that arrived, as of `at` (ms): the end of the run, or for a
    // run that ended in the shell's reload, the moment it handed over to it
    function _addSucceeded(done, at) {
        if (Backend.replaying || done.length === 0)
            return;
        const map = Object.assign({}, _succeeded);
        for (const item of done)
            map[item.key] = {
                to: item.to || "",
                at: at
            };
        _saveSucceeded(map);
    }

    // `present` holds the keys the daemon's latest list reports; null when
    // only expiry applies. A key is only dropped for being absent when that
    // list is from a check that started after the run — the stale answer is
    // exactly the one this exists for.
    function _pruneSucceeded(present) {
        const keys = Object.keys(_succeeded);
        if (keys.length === 0)
            return;
        const now = Date.now();
        const checkedMs = (SystemUpdateService.lastCheckUnix || 0) * 1000;
        const map = {};
        for (const key of keys) {
            const entry = _succeeded[key];
            if (now - (entry.at || 0) >= _succeededMs)
                continue;
            const daemonKind = key.indexOf("system/") === 0 || key.indexOf("flatpak/") === 0;
            if (present && daemonKind && checkedMs > (entry.at || 0) && !present.has(key))
                continue;
            map[key] = entry;
        }
        if (Object.keys(map).length !== keys.length)
            _saveSucceeded(map);
    }

    function _saveSucceeded(map) {
        PluginService.savePluginData("dankSoftwareDepot", "justUpdated", map);
    }

    Timer {
        interval: 60000
        repeat: true
        running: Object.keys(root._succeeded).length > 0
        onTriggered: root._pruneSucceeded(null)
    }

    // ── A list older than the last run ──────────────────────────────────────
    // Every run ends by asking the daemon for a forced check, and usually
    // that is the end of it. Not when the run updated the shell itself: the
    // daemon is restarted with it, and it keeps its list on disk. Killed in
    // the seconds between installing and clearing that list, it came back
    // with the list from before the run, and with it a check time from
    // before the run — real state, as far as anyone could tell, so nothing
    // asked again until the daily check. Twelve hours later "Update all"
    // ran the morning's updates a second time.
    //
    // So a list from a check older than the last run is stale by
    // definition, and gets a check of its own. Not at once: the run's own
    // check is usually on its way. And again a few times, because the daemon
    // ignores a refresh while it is still finishing an upgrade.
    readonly property bool _listOlderThanRun: !Backend.replaying && SystemUpdateService.lastCheckUnix > 0
        && SystemUpdateService.lastCheckUnix < lastUpdateUnix
    property int _staleChecks: 0

    on_ListOlderThanRunChanged: _staleChecks = 0

    Timer {
        interval: 15000
        repeat: true
        running: root._listOlderThanRun && !engine.running && root._staleChecks < 8
        onTriggered: {
            if (SystemUpdateService.isChecking || SystemUpdateService.isUpgrading)
                return;
            root._staleChecks++;
            DMSService.sysupdateRefresh(true, null);
        }
    }

    // Held packages (dnf versionlock/excludes) never count as real updates
    readonly property var heldSystemKeys: {
        const keys = [];
        for (const pkg of pendingUpdates) {
            if (store.isHeld(pkg))
                keys.push(store.keyFor(pkg));
        }
        return keys;
    }

    readonly property int effectiveCount: {
        let count = 0;
        for (const pkg of pendingUpdates) {
            if (!store.isHeld(pkg))
                count++;
        }
        if (includeFirmware)
            count += (firmware.updates || []).length;
        count += (appimageUpdates || []).length;
        count += (pluginUpdates || []).length;
        count += (brewUpdates || []).length;
        return count;
    }

    FirmwareService {
        id: firmware
    }

    // Own app icon (Claude-designed), following the active light/dark theme
    readonly property url appIconSource: Qt.resolvedUrl("assets/icons/dux-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg")

    // DMS penguin logo from the running shell's assets (path changes per
    // version). Dux Shell 2.0 unpacks the shell under dms-shell/, older
    // versions under danklinux-shell/ — which can linger after an upgrade
    // until the next reboot, so the current name is asked first.
    property string dankLogoPath: ""

    Process {
        id: dankLogoProcess
        running: true
        command: ["sh", "-c", "for d in dms-shell danklinux-shell; do ls \"$XDG_RUNTIME_DIR\"/$d/*/assets/danklogo.svg 2>/dev/null; done | head -1"]

        stdout: StdioCollector {
            onStreamFinished: root.dankLogoPath = text.trim()
        }
    }

    // ── Update-size estimate (upper bound; flatpak sizes are full downloads)
    property var updateSizes: null
    readonly property string updateSizeText: {
        let total = (updateSizes && updateSizes.totalBytes > 0) ? updateSizes.totalBytes : 0;
        for (const ai of appimageUpdates || [])
            total += ai.size || 0;
        return total > 0 ? ("≤ " + engine.formatBytes(total)) : "";
    }

    Timer {
        id: sizesDebounce
        interval: 3000
        onTriggered: root._refreshSizes()
    }

    function _refreshSizes() {
        const flatpaks = [];
        const rpms = [];
        for (const pkg of pendingUpdates) {
            if (store.isHeld(pkg))
                continue;
            if (pkg.repo === "flatpak")
                flatpaks.push(pkg.name);
            else
                rpms.push(store.stripArch(pkg.name));
        }
        if (flatpaks.length === 0 && rpms.length === 0) {
            updateSizes = null;
            return;
        }
        sizesProcess.command = [Backend.python, Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--update-sizes", JSON.stringify({
            flatpak: flatpaks,
            rpm: rpms
        })];
        sizesProcess.running = true;
    }

    Process {
        id: sizesProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.updateSizes = JSON.parse(text);
                } catch (e) {
                    root.updateSizes = null;
                }
            }
        }
    }

    // ── Holds outside the daemon's own list ─────────────────────────────────
    // A hold is a name in DMS's ignored list. The daemon reads that list for
    // the packages it reports, so a held rpm or Flatpak never reaches us; but
    // DMS plugins, Homebrew formulae and AppImages are found by us, not by the
    // daemon, and nothing removed the held ones. They stayed in their own
    // section beside the Held line, counted in the badge, and Update all
    // updated them (#30). Every list below is filtered here, once, so the
    // count, the rows and the run all agree.
    readonly property var heldNames: new Set(SettingsData.updaterIgnoredPackages || [])

    // ── Pending AppImage updates (GitHub releases via scripts/appimage.py) ──
    property var _appimageFound: []
    readonly property var appimageUpdates: _appimageFound.filter(u => !heldNames.has(u.id) && !_justUpdated("appimage/" + u.id, u.latest))

    Process {
        id: appimageCheckProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--check-updates"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root._appimageFound = JSON.parse(text);
                } catch (e) {
                    root._appimageFound = [];
                }
            }
        }
    }

    // ── Homebrew ────────────────────────────────────────────────────────────
    // Brew sits beside the distribution's own package manager rather than
    // instead of it, so it is a kind of software here, like Flatpak and
    // AppImages — not a fourth entry in the dnf/apt/pacman list, which are
    // mutually exclusive and chosen by the machine.
    //
    // Absent on nearly every machine, and asking a program that is not there
    // costs a process start per check, so the answer to "is there a brew" is
    // remembered and the rest only runs when it is yes.
    property bool brewSupported: false
    property var _brewFound: []
    readonly property var brewUpdates: _brewFound.filter(f => !heldNames.has(f.name) && !_justUpdated("brew/" + f.name, f.toVersion))
    property var brewInstalled: []

    readonly property string brewScript: Qt.resolvedUrl("scripts/brew_helper.py").toString().replace("file://", "")

    function refreshBrew(refresh) {
        if (brewProcess.running)
            return;
        brewProcess.command = refresh ? [Backend.python, brewScript, "--state", "--refresh"]
                                      : [Backend.python, brewScript, "--state"];
        brewProcess.running = true;
    }

    Process {
        id: brewProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    root.brewSupported = data.supported === true;
                    root.brewInstalled = data.installed || [];
                    // A pinned formula is brew's own word for held, and it
                    // means what held means here: leave this one alone
                    root._brewFound = (data.outdated || []).filter(row => row.pinned !== true).map(row => ({
                        name: row.name,
                        displayName: row.displayName || row.name,
                        repo: "brew",
                        fromVersion: row.fromVersion || "",
                        toVersion: row.toVersion || ""
                    }));
                } catch (e) {
                    root.brewSupported = false;
                    root._brewFound = [];
                    root.brewInstalled = [];
                }
            }
        }
    }

    // ── DMS plugin updates ──────────────────────────────────────────────────
    // The daemon already works out which installed plugins the registry has a
    // newer build of — the same `hasUpdate` flag Settings → Plugins counts its
    // "Available Updates" from. A software centre that reports on four kinds
    // of software and stays quiet about the fifth, which is sitting in the
    // same shell it is running in, is being arbitrary about it.
    //
    // Answering it needs daemon API 8; older ones do not carry the flag, and a
    // missing flag would read as "nothing to update" rather than as "cannot
    // say", so the whole section stays away instead.
    readonly property bool pluginUpdatesSupported: DMSService.dmsAvailable && DMSService.apiVersion >= 8

    readonly property var pluginUpdates: {
        if (!pluginUpdatesSupported)
            return [];
        const out = [];
        for (const plugin of (DMSService.installedPlugins || [])) {
            if (plugin.hasUpdate !== true)
                continue;
            const id = plugin.id || plugin.name || "";
            // Ourselves, deliberately: this plugin already offers its own
            // update from its own release notes, and replacing the code that
            // is running the transaction, during the transaction, is the one
            // case the DMS packages get a separate final pass for.
            if (id === "" || id === "dankSoftwareDepot")
                continue;
            if (heldNames.has(id))
                continue;
            const manifest = (PluginService.availablePlugins || {})[id] || {};
            const pkg = {
                name: id,
                repo: "dmsplugin",
                fromVersion: manifest.version || plugin.version || "",
                // The daemon names the two commits, not a version; the new
                // version comes from the plugin.json upstream once
                // plugin_notes.py has read it
                diffUrl: plugin.diffUrl || "",
                path: plugin.path || ""
            };
            const notes = store.pluginNotes[store.pluginNotesKey(pkg)] || null;
            const toVersion = plugin.latestVersion || plugin.newVersion || (notes && notes.toVersion !== pkg.fromVersion ? (notes.toVersion || "") : "");
            if (_justUpdated("plugin/" + id, toVersion))
                continue;
            out.push({
                name: id,
                displayName: plugin.name || manifest.name || id,
                repo: "dmsplugin",
                fromVersion: pkg.fromVersion,
                toVersion: toVersion,
                diffUrl: pkg.diffUrl,
                path: pkg.path,
                // A plugin's manifest names a Material Symbols glyph rather
                // than shipping an image, so its "icon" is a word. Ours says
                // deployed_code_update; Quick Capture's says screenshot_region
                icon: manifest.icon || plugin.icon || ""
            });
        }
        return out;
    }

    function refreshPluginUpdates() {
        if (pluginUpdatesSupported)
            DMSService.listInstalled();
    }

    // Asked ahead of the popup, so the card can show the version it goes to;
    // a handful of plugins at most, and each answer is kept for a day. Also
    // from Component.onCompleted: after a reload the daemon's list is there
    // already, and a binding's first value emits no change.
    function _prefetchPluginNotes() {
        for (const plugin of pluginUpdates)
            store.fetchPluginNotes(plugin);
    }

    onPluginUpdatesChanged: _prefetchPluginNotes()

    // ── AppStream search index, warmed out of sight ─────────────────────────
    // The index is a cache keyed by the catalogs' fingerprint, and everything
    // that reads AppStream waits on it: the Install tab, and the details popup
    // for any app. Rebuilding it takes seconds, and it goes stale exactly when
    // appstream-data comes down with an update — so the bill would otherwise
    // arrive with the next popup, as a spinner. Warming it costs nothing when
    // it is still valid.
    Process {
        id: warmIndexProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--warm-index"]
    }

    function _warmSearchIndex() {
        if (!warmIndexProcess.running)
            warmIndexProcess.running = true;
    }

    Timer {
        // Late enough that a shell start is not competing with XML parsing
        interval: 20000
        running: true
        repeat: false
        onTriggered: root._warmSearchIndex()
    }

    // ── End-of-life components (flatpak refs the remote stopped maintaining)
    property var eolRefs: []

    Process {
        id: eolProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/flatpak_helper.py").toString().replace("file://", ""), "eol"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.eolRefs = JSON.parse(text);
                } catch (e) {
                    root.eolRefs = [];
                }
            }
        }
    }

    // ── Newer Fedora release available? (Bodhi, cached daily)
    property var distroUpgrade: null

    Process {
        id: distroProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--distro-upgrade"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.distroUpgrade = JSON.parse(text);
                } catch (e) {
                }
            }
        }
    }

    Timer {
        interval: 4000
        running: true
        onTriggered: {
            eolProcess.running = true;
            distroProcess.running = true;
            appimageCheckProcess.running = true;
            root.refreshCleanup();
        }
    }

    // ── Automatic updates: off | notify | auto (auto-install flatpaks) ──────
    // A fresh install starts at "notify": finding updates and saying nothing
    // is the one behaviour nobody asks for. An explicit "off" is stored and
    // kept.
    readonly property string autoUpdateMode: pluginData.autoUpdateMode || "notify"
    property int _lastNotifiedCount: 0

    // One desktop notification, from the two places that have something to
    // announce. Clicking the body (action "default") or the Open button opens
    // the window: notify-send --action waits and prints the chosen action, and
    // the detached shell turns that into the plugin's own IPC call.
    function notify(summary, body) {
        const iconFile = Qt.resolvedUrl("assets/icons/dux-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg").toString().replace("file://", "");
        // One action, not two: `default` is what a click on the body triggers,
        // and naming a second one only added a duplicate button next to it.
        // The body line is optional — an empty argument would draw an empty
        // line, so the two shapes are separate calls.
        Quickshell.execDetached(["sh", "-c", "if [ -n \"$4\" ]; then chosen=$(notify-send -a 'Dux Software Depot' -i \"$1\" -A default=\"$2\" \"$3\" \"$4\"); else chosen=$(notify-send -a 'Dux Software Depot' -i \"$1\" -A default=\"$2\" \"$3\"); fi; [ -n \"$chosen\" ] && dms ipc call dankSoftwareDepot open", "notify", iconFile, Tr.t("Open"), summary, body || ""]);
    }

    // A new version of the plugin deserves the same courtesy as new packages:
    // the banner is only seen by someone who happens to open the window.
    // Announced once per version — the check runs at every shell start, and a
    // notification repeated on every restart is a notification switched off.
    function notifyPluginUpdate(version, releases) {
        if (version === "" || autoUpdateMode === "off")
            return;
        if ((pluginData.selfUpdateNotifiedVersion || "") === version)
            return;
        PluginService.savePluginData("dankSoftwareDepot", "selfUpdateNotifiedVersion", version);
        // The notification already carries the app's name and icon above the
        // text; repeating it in the summary only spent the width the summary
        // has, and it has little
        notify(Tr.t("Version %1 is available").arg(version), releases > 1 ? Tr.t("%1 releases since yours").arg(releases) : "");
    }

    function _afterCheck() {
        // A check that lands while a run is still going, or in the seconds
        // after it, is looking at the list the run is in the middle of
        // emptying — including the packages it just installed. Announcing
        // those as new updates is how a finished run could end with "3 updates
        // available" and a list that is empty a moment later.
        //
        // Bounded by time rather than by the result panel: a failed run stays
        // on screen until someone dismisses it, and that must not be a reason
        // to stop reporting updates for the rest of the day.
        if (engine.running || engine.phase === "verifying" || SystemUpdateService.isUpgrading)
            return;
        if (Date.now() < _quietNotificationsUntil)
            return;
        const count = effectiveCount;
        if (count === 0) {
            _lastNotifiedCount = 0;
            return;
        }
        if (autoUpdateMode === "off")
            return;
        if (count !== _lastNotifiedCount) {
            _lastNotifiedCount = count;
            notify((count === 1 ? Tr.t("%1 update available") : Tr.t("%1 updates available")).arg(count));
        }
        if (autoUpdateMode === "auto" && !engine.running && !SystemUpdateService.isUpgrading) {
            const hasFlatpaks = root.pendingUpdates.some(pkg => pkg.repo === "flatpak");
            if (hasFlatpaks)
                engine.start({
                    dnf: false,
                    firmware: false
                });
        }
    }

    // The bootstrap installs — the package-manager bindings, the AppStream
    // catalog — go around the transaction helper by design, and so around
    // everything that would have logged them. This is where they land instead.
    Connections {
        target: Backend

        function onRequirementInstalled(pkg, ok, detail) {
            if (!actionLog)
                return;
            const label = {
                key: ok ? "Installed %1" : "Could not install %1",
                args: [pkg]
            };
            actionLog.record(ok ? "install" : "install-failed", actionLog.titleOf({
                label: label
            }), [
                {
                    name: pkg,
                    id: pkg,
                    repo: "system",
                    from: "",
                    to: "",
                    source: "System",
                    status: ok ? "done" : "error",
                    reason: ok ? "" : detail,
                    error: ok ? "" : detail
                }
            ], 0, label);
        }
    }

    Connections {
        target: SystemUpdateService

        function onIsCheckingChanged() {
            // Piggy-back a firmware check on every daemon check
            if (!SystemUpdateService.isChecking && root.includeFirmware)
                firmware.check();
            if (!SystemUpdateService.isChecking) {
                appimageCheckProcess.running = true;
                // And the plugins, for the same reason: one check answers for
                // every kind of software this window reports on
                root.refreshPluginUpdates();
                // Brew's own index is refreshed at most every six hours; the
                // helper decides, because `brew update` is a git fetch and a
                // check is not the place to spend one
                root.refreshBrew(true);
                Qt.callLater(() => root._afterCheck());
            }
        }
    }

    Ref {
        service: SystemUpdateService
    }

    MetadataStore {
        id: store
        persistedHeldMap: pluginData.heldPackages || ({})

        onEnriched: {
            // Persist the held map so held packages are known before the
            // async enrichment of the next check/session completes
            const current = store.currentHeldMap();
            if (JSON.stringify(current) !== JSON.stringify(pluginData.heldPackages || {}))
                PluginService.savePluginData("dankSoftwareDepot", "heldPackages", current);
        }
    }

    readonly property int lastUpdateUnix: pluginData.lastUpdateUnix || 0

    // ── Reboot recommendation ───────────────────────────────────────────────
    // Set when a run updated core system components (kernel/systemd/glibc/…)
    // or firmware; cleared automatically after a reboot (boot id changes).
    property string _bootId: ""
    readonly property bool rebootRecommended: {
        const flag = pluginData.rebootFlag;
        return !!(flag && flag.recommended && _bootId !== "" && flag.bootId === _bootId);
    }
    property bool confirmReboot: false

    readonly property var _rebootPackagePattern: Backend.rebootPackagePattern

    Process {
        id: bootIdProcess
        command: ["cat", "/proc/sys/kernel/random/boot_id"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root._bootId = text.trim()
        }
    }

    function _evaluateReboot() {
        let needed = false;
        for (const item of engine.runItems || []) {
            const state = engine.itemStates[item.key];
            if (!state || state.status !== "done")
                continue;
            if (item.pkg.repo === "firmware") {
                needed = true;
            } else if (item.pkg.repo !== "flatpak" && _rebootPackagePattern.test(store.stripArch(item.pkg.name))) {
                needed = true;
            }
        }
        if (needed && _bootId !== "") {
            PluginService.savePluginData("dankSoftwareDepot", "rebootFlag", {
                bootId: _bootId,
                recommended: true
            });
        }
    }

    // A transaction that only exists in the next deployment. On an atomic
    // system that is every install and every removal, so the tabs say so
    // rather than each inventing its own way to explain it.
    function noteStagedChange() {
        if (_bootId === "")
            return;
        PluginService.savePluginData("dankSoftwareDepot", "rebootFlag", {
            bootId: _bootId,
            recommended: true
        });
    }

    function dismissReboot() {
        PluginService.savePluginData("dankSoftwareDepot", "rebootFlag", {});
        confirmReboot = false;
    }

    function requestReboot() {
        if (!confirmReboot) {
            confirmReboot = true;
            rebootConfirmTimer.restart();
            return;
        }
        Quickshell.execDetached(["systemctl", "reboot"]);
    }

    Timer {
        id: rebootConfirmTimer
        interval: 6000
        onTriggered: root.confirmReboot = false
    }

    // ── Check progress estimate ─────────────────────────────────────────────
    // The daemon reports no granular progress while refreshing, so we
    // estimate from the (cached, smoothed) duration of previous checks.
    readonly property int estCheckSecs: pluginData.checkDurationSecs || 45
    property real checkFraction: 0
    property int checkElapsedSecs: 0
    property double _checkStartMs: 0

    Timer {
        id: checkProgressTimer
        interval: 500
        repeat: true
        onTriggered: {
            const elapsed = (Date.now() - root._checkStartMs) / 1000;
            root.checkElapsedSecs = Math.floor(elapsed);
            root.checkFraction = Math.min(0.95, elapsed / Math.max(5, root.estCheckSecs));
        }
    }

    Connections {
        target: SystemUpdateService

        function onIsCheckingChanged() {
            if (SystemUpdateService.isChecking) {
                root._checkStartMs = Date.now();
                root.checkElapsedSecs = 0;
                root.checkFraction = 0;
                checkProgressTimer.start();
            } else {
                checkProgressTimer.stop();
                if (root._checkStartMs > 0) {
                    const duration = (Date.now() - root._checkStartMs) / 1000;
                    if (duration > 3)
                        PluginService.savePluginData("dankSoftwareDepot", "checkDurationSecs", Math.round(0.7 * root.estCheckSecs + 0.3 * duration));
                    root._checkStartMs = 0;
                }
                root.checkFraction = 0;
            }
        }
    }

    function formatAgo(unix) {
        if (!unix)
            return "";
        const delta = Math.max(0, Math.floor(Date.now() / 1000) - unix);
        if (delta < 90)
            return Tr.t("just now");
        if (delta < 3600)
            return Tr.t("%1m ago").arg(Math.round(delta / 60));
        if (delta < 86400)
            return Tr.t("%1h ago").arg(Math.round(delta / 3600));
        return Tr.t("%1d ago").arg(Math.round(delta / 86400));
    }

    ActionLog {
        id: actionLog
    }

    readonly property var actionLogger: actionLog

    // ── Shell-pass log survival ─────────────────────────────────────────────
    // Updating dms/quickshell reloads the shell before the run can write its
    // log entry (and the per-app dms route has no completion hook at all).
    // Stash the planned entry beforehand; the next start verifies against
    // the rpm database what actually arrived and writes the swallowed entry
    // with its original timestamp.
    function _stashShellRunLog(shellPkgs, doneItems) {
        PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {
            ts: Math.floor(Date.now() / 1000),
            items: doneItems || [],
            shell: shellPkgs.map(pkg => ({
                base: store.stripArch(pkg.name),
                name: store.displayName(pkg),
                from: pkg.fromVersion || "",
                to: pkg.toVersion || ""
            }))
        });
    }

    function _stashFromEngine() {
        const shellPkgs = [];
        const doneItems = [];
        for (const ri of engine.runItems || []) {
            const base = store.stripArch(ri.pkg.name);
            const isShell = ri.pkg.repo !== "flatpak" && ri.pkg.repo !== "firmware" && ri.pkg.repo !== "appimage" && engine.shellPackagePattern.test(base);
            if (isShell) {
                shellPkgs.push(ri.pkg);
                continue;
            }
            const st = engine.itemStates[ri.key] || {};
            const isSystem = ri.pkg.repo !== "flatpak" && ri.pkg.repo !== "firmware" && ri.pkg.repo !== "appimage";
            const item = {
                name: store.displayName(ri.pkg),
                // The id the package is known by, so the log can lead back to
                // it: the name above is for reading, not for looking up
                id: ri.pkg.name || "",
                repo: ri.pkg.repo || "",
                from: ri.pkg.fromVersion || "",
                to: ri.pkg.toVersion || "",
                source: Ui.sourceName(ri.pkg.repo),
                status: st.status || "",
                reason: st.status === "error" ? (st.detail || "") : "",
                error: engine.runErrorDetails[ri.key] || ""
            };
            // The shell pass runs after this snapshot is taken; a system row
            // that failed before it may still arrive. Carry the package name
            // so the replay can ask the package database instead of
            // preserving a verdict that the rest of the run has outrun.
            if (isSystem)
                item.base = base;
            doneItems.push(item);
        }
        if (shellPkgs.length > 0)
            _stashShellRunLog(shellPkgs, doneItems);
    }

    // ── Reclaimable space ───────────────────────────────────────────────────
    // {unneeded: {count, bytes, names}, cache: {bytes}} — null until scanned
    property var cleanup: null
    property string cleanupBusy: ""   // "" | packages | cache

    function refreshCleanup() {
        if (cleanupScanProcess.running)
            return;
        cleanupScanProcess.command = Backend.cleanupScanCommand();
        cleanupScanProcess.running = true;
    }

    Process {
        id: cleanupScanProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.cleanup = JSON.parse(text);
                } catch (e) {
                    root.cleanup = null;
                }
                if (root._pendingCleanupLog === "")
                    return;
                const freed = root._cleanupBefore - root._cleanupTotal();
                const title = root._pendingCleanupLog;
                const label = root._pendingCleanupLabel;
                const items = root._pendingCleanupItems;
                root._pendingCleanupLog = "";
                root._pendingCleanupLabel = null;
                root._pendingCleanupItems = [];
                if (freed > 0) {
                    const sized = label ? Object.assign({}, label, {
                        suffix: engine.formatBytes(freed)
                    }) : null;
                    actionLog.record("uninstall", title + " · " + engine.formatBytes(freed), items, 0, sized);
                }
            }
        }
    }

    // Cleanups are logged by what they freed, not by whether the command
    // exited cleanly: `dnf clean packages` returns 0 with nothing to clean,
    // and an action log that reports emptying an empty cache is lying.
    property real _cleanupBefore: 0
    property string _pendingCleanupLog: ""
    property var _pendingCleanupLabel: null
    property var _pendingCleanupItems: []

    function _cleanupTotal() {
        if (!cleanup)
            return 0;
        return (cleanup.unneeded.bytes || 0) + (cleanup.cache.bytes || 0);
    }

    function removeUnneeded() {
        const names = (cleanup && cleanup.unneeded) ? cleanup.unneeded.names : [];
        if (names.length === 0 || cleanupBusy !== "")
            return;
        cleanupBusy = "packages";
        _cleanupBefore = _cleanupTotal();
        _pendingCleanupLog = Tr.t("Removed %1 unneeded packages").arg(names.length);
        _pendingCleanupLabel = {
            key: "Removed %1 unneeded packages",
            args: [names.length]
        };
        _pendingCleanupItems = names.map(n => ({
                    name: n,
                    from: "",
                    to: "",
                    source: "System",
                    status: "done"
                }));
        cleanupProcess.command = Backend.helperCommand("remove", names);
        cleanupProcess.running = true;
    }

    function cleanCache() {
        if (cleanupBusy !== "")
            return;
        cleanupBusy = "cache";
        _cleanupBefore = _cleanupTotal();
        _pendingCleanupLog = Tr.t("Emptied the package cache");
        _pendingCleanupLabel = {
            key: "Emptied the package cache",
            args: []
        };
        _pendingCleanupItems = [];
        cleanupProcess.command = Backend.cleanCacheCommand();
        cleanupProcess.running = true;
    }

    Process {
        id: cleanupProcess

        onExited: (exitCode, exitStatus) => {
            root.cleanupBusy = "";
            if (exitCode !== 0)
                root._pendingCleanupLog = "";
            // The rescan decides what actually happened
            root.refreshCleanup();
        }
    }

    // ── How long this usually takes here ────────────────────────────────────
    // Seconds per package, measured on this machine. Package counts vary far
    // more than per-package cost does, so the rate is what generalises — and
    // the median ignores the one run that hit a slow mirror.
    readonly property var runHistory: (pluginData.runHistory || [])

    function _recordRun(seconds, items) {
        if (items <= 0 || seconds <= 0)
            return;
        const history = runHistory.slice();
        history.push({
            seconds: seconds,
            items: items
        });
        // Ten runs is enough to be representative and few enough to follow a
        // machine that got faster
        PluginService.savePluginData("dankSoftwareDepot", "runHistory", history.slice(-10));
    }

    // Estimated seconds for a run of `items` packages, -1 when this machine
    // has not shown us enough yet
    function estimateRunSeconds(items) {
        const rates = runHistory.filter(r => r.items > 0).map(r => r.seconds / r.items).sort((a, b) => a - b);
        if (rates.length < 2 || items <= 0)
            return -1;
        const median = rates.length % 2 ? rates[(rates.length - 1) / 2] : (rates[rates.length / 2 - 1] + rates[rates.length / 2]) / 2;
        return Math.round(median * items);
    }

    // ── Update severity ─────────────────────────────────────────────────────
    // name -> {type, severity, ids}. Without this every update looks equally
    // urgent, which is another way of saying none of them do.
    property var advisories: ({})

    readonly property int securityCount: {
        let count = 0;
        for (const pkg of pendingUpdates) {
            const adv = advisories[store.stripArch(pkg.name)];
            if (adv && adv.type === "security")
                count++;
        }
        return count;
    }

    // Of those, the ones that will not be installed because they are being
    // held. A count of security fixes is reassuring in the wrong direction if
    // some of them are never going to run.
    readonly property int heldSecurityCount: {
        let count = 0;
        for (const pkg of pendingUpdates) {
            const adv = advisories[store.stripArch(pkg.name)];
            if (adv && adv.type === "security" && store.isHeld(pkg))
                count++;
        }
        return count;
    }

    Timer {
        id: advisoryDebounce
        interval: 2000
        onTriggered: root._refreshAdvisories()
    }

    function _refreshAdvisories() {
        if (!Backend.hasAdvisories || advisoryProcess.running)
            return;
        const names = [];
        for (const pkg of pendingUpdates) {
            if (pkg.repo !== "flatpak" && pkg.repo !== "firmware" && pkg.repo !== "appimage")
                names.push(store.stripArch(pkg.name));
        }
        if (names.length === 0) {
            advisories = {};
            return;
        }
        advisoryProcess.command = Backend.advisoryCommand(names);
        advisoryProcess.running = true;
    }

    Process {
        id: advisoryProcess

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "advisories")
                    root.advisories = event.packages || ({});
            }
        }
    }

    // ── Failure reasons outlive the run panel ───────────────────────────────
    // A package that failed is still a pending update, so it comes back in
    // the list — but the reason lived only in the engine, which the shell
    // reload after a dms pass throws away. Exactly the runs where knowing
    // why matters most. Persist the failures and hand them back to the
    // engine at the next start, so the card keeps carrying its own story.
    function _saveFailures() {
        const failures = [];
        for (const ri of engine.runItems || []) {
            const state = engine.itemStates[ri.key] || {};
            if (state.status !== "error")
                continue;
            failures.push({
                key: ri.key,
                name: ri.pkg.name || "",
                detail: state.detail || "",
                error: engine.runErrorDetails[ri.key] || ""
            });
        }
        PluginService.savePluginData("dankSoftwareDepot", "lastRunFailures", failures.length > 0 ? {
            ts: Math.floor(Date.now() / 1000),
            items: failures
        } : {});
    }

    property bool _restoredFailures: false
    // Keys restored from a previous run — pruned once the package stops
    // being a pending update, never touched while a run is live
    property var _restoredKeys: []

    function _restoreFailures() {
        if (_restoredFailures || Object.keys(pluginData || {}).length === 0)
            return;
        _restoredFailures = true;
        const saved = pluginData.lastRunFailures;
        const items = (saved && saved.items) || [];
        if (items.length === 0)
            return;
        const states = Object.assign({}, engine.itemStates);
        const details = Object.assign({}, engine.runErrorDetails);
        const keys = [];
        for (const item of items) {
            states[item.key] = {
                status: "error",
                fraction: 0,
                detail: item.detail || ""
            };
            if (item.error)
                details[item.key] = item.error;
            keys.push(item.key);
        }
        engine.itemStates = states;
        engine.runErrorDetails = details;
        _restoredKeys = keys;
    }

    // A restored failure is only true until the package is updated by
    // something else; once it is no longer pending, drop the verdict.
    function _pruneRestoredFailures() {
        if (_restoredKeys.length === 0 || engine.running || !_serviceHasState)
            return;
        const pending = new Set((pendingUpdates || []).map(pkg => store.keyFor(pkg)));
        // Only system and flatpak keys are answerable from this list;
        // firmware and AppImages have their own sources
        const stale = _restoredKeys.filter(key => (key.startsWith("system/") || key.startsWith("flatpak/")) && !pending.has(key));
        if (stale.length === 0)
            return;
        const states = Object.assign({}, engine.itemStates);
        const details = Object.assign({}, engine.runErrorDetails);
        for (const key of stale) {
            delete states[key];
            delete details[key];
        }
        engine.itemStates = states;
        engine.runErrorDetails = details;
        _restoredKeys = _restoredKeys.filter(key => pending.has(key));
        if (_restoredKeys.length === 0)
            PluginService.savePluginData("dankSoftwareDepot", "lastRunFailures", {});
    }

    property bool _replayedPendingLog: false
    // Set between a run finishing and its verification answering
    property bool _logAwaitingVerification: false
    // Set when a run ends: the daemon's own list takes a check or two to
    // catch up with what just happened, and until it has, it is not news
    property double _quietNotificationsUntil: 0

    onPluginDataChanged: {
        _replayPendingRunLog();
        _restoreFailures();
    }

    function _replayPendingRunLog() {
        // An empty object means the host hasn't delivered the settings yet
        if (_replayedPendingLog || Object.keys(pluginData || {}).length === 0)
            return;
        _replayedPendingLog = true;
        const stash = pluginData.pendingShellRunLog;
        if (!stash || !(stash.shell || []).length)
            return;
        // Ask about the shell packages and about every system row the run did
        // not see finish — the shell pass sits between the two moments and can
        // have changed the answer.
        //
        // Every row, not only the failed ones. The healing below was widened
        // to cover anything still pending and this list was not, so the
        // pending rows were healed against an answer nobody had asked for:
        // 34 packages that were on disk, in the log as unfinished, under a
        // title counting the three the run happened to witness.
        const names = [];
        const want = base => {
            if (base && names.indexOf(base) === -1)
                names.push(base);
        };
        for (const s of stash.shell || [])
            want(s.base);
        for (const it of stash.items || []) {
            if (it.status !== "done")
                want(it.base);
        }
        replayVerifyProcess.command = Backend.installedVersionsCommand(names);
        replayVerifyProcess.running = true;
    }

    Process {
        id: replayVerifyProcess

        stdout: StdioCollector {
            onStreamFinished: {
                const stash = root.pluginData.pendingShellRunLog || {};
                const installed = {};
                for (const line of (text || "").split("\n")) {
                    const parts = line.split("\t");
                    if (parts.length === 2)
                        (installed[parts[0].trim()] = installed[parts[0].trim()] || []).push(parts[1].trim());
                }
                const noEpoch = v => (v || "").replace(/^\d+:/, "");
                const arrived = (base, to) => {
                    const want = noEpoch(to);
                    return want !== "" && (installed[base] || []).some(evr => noEpoch(evr) === want);
                };
                // A row that failed before the shell pass but carries its
                // target version now did arrive — the log records what the
                // system says, not what the run last believed.
                const items = (stash.items || []).map(it => {
                    // Any row the run did not see finish, not only the ones it
                    // saw fail. The stash is taken when the shell pass begins,
                    // so packages still in flight are recorded as pending —
                    // and they are exactly the ones the reload stops us from
                    // hearing about. The package database knows.
                    if (it.status === "done" || !it.base || !arrived(it.base, it.to))
                        return it;
                    const fixed = Object.assign({}, it, {
                        status: "done"
                    });
                    delete fixed.reason;
                    delete fixed.error;
                    return fixed;
                });
                for (const s of stash.shell || []) {
                    items.push({
                        name: s.name,
                        id: s.base || s.name,
                        repo: "system",
                        from: s.from,
                        to: s.to,
                        source: "System",
                        status: arrived(s.base, s.to) ? "done" : "error"
                    });
                }
                let done = 0;
                let failed = 0;
                for (const it of items) {
                    if (it.status === "done")
                        done++;
                    else if (it.status === "error")
                        failed++;
                }
                // The run's end never came — the reload took it — so what it
                // installed is remembered here instead, under the keys the
                // engine gives its rows: anything not of a kind of its own is
                // a system package
                const prefix = {
                    flatpak: "flatpak/",
                    appimage: "appimage/",
                    brew: "brew/",
                    dmsplugin: "plugin/"
                };
                root._addSucceeded(items.filter(it => it.status === "done" && it.repo !== "firmware").map(it => ({
                    key: prefix[it.repo] ? prefix[it.repo] + (it.id || "") : "system/" + (it.base || store.stripArch(it.id || "")),
                    to: it.to || ""
                })), (stash.ts || 0) * 1000);
                // The tail of a torn-down run can carry nothing at all. The
                // normal writer already refuses that case; this one wrote it,
                // which is where the stray "0 packages updated" came from.
                if (items.length === 0) {
                    PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {});
                    return;
                }
                const type = failed > 0 ? "update-failed" : "update";
                const key = failed > 0 ? "Update finished with issues (%1 failed)" : (done === 1 ? "Updated %1 package" : "Updated %1 packages");
                const count = failed > 0 ? failed : done;
                actionLog.record(type, Tr.t(key).arg(count), items, stash.ts || 0, {
                    key: key,
                    args: [count]
                });
                if (done > 0 && (stash.ts || 0) > (root.pluginData.lastUpdateUnix || 0))
                    PluginService.savePluginData("dankSoftwareDepot", "lastUpdateUnix", stash.ts);
                PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {});
            }
        }
    }

    function _logRun() {
        if (!engine.runItems || engine.runItems.length === 0)
            return;
        const items = engine.runItems.map(ri => {
            const st = engine.itemStates[ri.key] || {};
            // The plugin manager says which plugins have a newer build but
            // never which version that is, so a plugin row was recorded with
            // where it came from and a blank where it arrived. By the time a
            // run is written down the manifest on disk has been re-read, and
            // it knows: ask it, and take the answer only when it really is a
            // different version from the one this started at.
            // A devel row went to "the latest commit"; the verification
            // read which version that was.
            let landedAt = st.landed || ri.pkg.toVersion || "";
            if (landedAt === "" && ri.pkg.repo === "dmsplugin" && st.status === "done") {
                const manifest = (PluginService.availablePlugins || {})[ri.pkg.name] || {};
                if ((manifest.version || "") !== "" && manifest.version !== ri.pkg.fromVersion)
                    landedAt = manifest.version;
            }
            return {
                name: store.displayName(ri.pkg),
                // The id and the repo travel with the entry so the log can
                // lead back to what it is about. Without them a line is a
                // string: "Quick Capture" has a space in it, which is what
                // the fallback heuristic uses to tell a display name from a
                // package name, so the entry stopped being clickable.
                id: ri.pkg.name || "",
                repo: ri.pkg.repo || "",
                from: ri.pkg.fromVersion || "",
                to: landedAt,
                source: Ui.sourceName(ri.pkg.repo),
                status: st.status || "",
                // Short reason for reading, tool output for reporting
                reason: st.status === "error" ? (st.detail || "") : "",
                error: engine.runErrorDetails[ri.key] || ""
            };
        });
        // A run always has items; an empty list means this is the tail of a
        // torn-down run (the shell reload), whose real entry the replay
        // writes. Logging it would leave a stray "0 packages updated".
        if (items.length === 0)
            return;
        let type = "update";
        let label = {
            key: engine.completedCount === 1 ? "Updated %1 package" : "Updated %1 packages",
            args: [engine.completedCount]
        };
        if (engine.phase === "cancelled") {
            type = "update-cancelled";
            label = {
                key: "Update cancelled (%1 of %2 done)",
                args: [engine.completedCount, engine.plannedCount]
            };
        } else if (engine.failedCount > 0) {
            type = "update-failed";
            label = {
                key: "Update finished with issues (%1 failed)",
                args: [engine.failedCount]
            };
        }
        actionLog.record(type, actionLog.titleOf({
            label: label
        }), items, 0, label);
        // The run survived to its normal logging — the stashed entry for a
        // possible shell reload is not needed anymore
        PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {});
    }

    UpdateEngine {
        id: engine
        heldKeys: root.heldSystemKeys
        pendingUpdates: root.pendingUpdates
        packageSizes: (root.updateSizes && root.updateSizes.rpmSizes) || ({})
        firmwareService: root.includeFirmware ? firmware : null
        appimageUpdates: root.appimageUpdates
        pluginUpdates: root.pluginUpdates
        brewUpdates: root.brewUpdates

        // The dms pass is about to reload the shell — stash the log entry
        // and the failure reasons it would otherwise swallow
        onPhaseChanged: {
            if (Backend.replaying)
                return;
            if (phase === "dms") {
                root._stashFromEngine();
                root._saveFailures();
            }
        }

        onRunMeasured: (seconds, items) => {
            // A replay's duration is the recording's duration, possibly
            // divided by a playback speed. Letting it into the estimate would
            // teach the window that updates take four seconds.
            if (!Backend.replaying)
                root._recordRun(seconds, items);
        }

        onFinished: ok => {
            root.confirmArmed = false;
            // Nothing a simulation does happened. It must not reach the
            // action log, the reboot notice, the failure list that survives a
            // restart, or the "last updated" time — every one of those is a
            // record of the machine, and the machine did not do this.
            if (Backend.replaying)
                return;
            // The verification pass is part of the run and part of the
            // recording, so a run that ends into it is not finished being
            // recorded yet — the same reason the log entry waits.
            if (engine.phase !== "verifying")
                Backend.finishRecording();
            root._quietNotificationsUntil = Date.now() + 30000;
            root._saveFailures();
            // A run that finishes into verification has every system and
            // Flatpak row sitting at "confirming" — that is what verification
            // is: done, pending confirmation. Writing the log here recorded
            // that moment as the outcome, which is a grey clock next to a
            // package that installed perfectly. It waits for the answer now,
            // which is also what makes "still offered as an update after the
            // run" reach the log as the failure it is.
            root._logAwaitingVerification = engine.phase === "verifying";
            if (!root._logAwaitingVerification) {
                root._logRun();
                root._rememberSucceeded();
            }
            eolProcess.running = true;
            // A run is the one thing that changes the AppStream catalogs, so
            // this is where the index is most likely to have just gone stale
            root._warmSearchIndex();
            if (engine.completedCount > 0) {
                PluginService.savePluginData("dankSoftwareDepot", "lastUpdateUnix", Math.floor(Date.now() / 1000));
                // The reboot notice reads the per-package states, and a run
                // that ends in verification has not settled them yet: every
                // row still says "verifying" and none says "done", so nothing
                // ever matched the kernel pattern and the notice was never
                // raised. The log already waits for that answer; this has to
                // wait for the same one. Left eager, it silently stopped
                // working the day the log learned to wait.
                if (!root._logAwaitingVerification)
                    root._evaluateReboot();
            }
        }

        // The answer the log entry was waiting for. A package the check still
        // finds pending failed after the run believed it had finished, so the
        // persisted failures need saying again — otherwise the reason is gone
        // at the next shell reload — and the entry is written now, with that
        // failure in it rather than a row saying "confirming".
        onVerified: stuck => {
            if (Backend.replaying)
                return;
            Backend.finishRecording();
            root._rememberSucceeded();
            if (stuck > 0)
                root._saveFailures();
            if (!root._logAwaitingVerification)
                return;
            root._logAwaitingVerification = false;
            root._logRun();
            // Now the rows say what they are, so the kernel in them can be
            // seen. This is the same moment the log is written, for the same
            // reason.
            if (engine.completedCount > 0)
                root._evaluateReboot();
        }
    }

    UpdaterWindow {
        id: updaterWindow
        store: store
        engine: engine
        widgetRoot: root
        firmware: root.includeFirmware ? firmware : null
        showRuntimes: root.showRuntimes
        lastUpdateUnix: root.lastUpdateUnix
        checkFraction: root.checkFraction
        checkElapsedSecs: root.checkElapsedSecs
        estCheckSecs: root.estCheckSecs
    }

    IpcHandler {
        target: "dankSoftwareDepot"

        function open(): void {
            // Always land on the Updates tab — also when the window was
            // already open on another tab (notification click)
            updaterWindow.activate();
            updaterWindow.openTab(0);
        }

        function close(): void {
            updaterWindow.visible = false;
        }

        function toggle(): void {
            updaterWindow.toggle();
        }

        function tab(index: int): void {
            updaterWindow.activate();
            updaterWindow.openTab(index);
        }

        // Sent by the desktop entry when an .appimage file is opened with
        // this app — see scripts/open.sh
        function openAppimage(path: string): void {
            updaterWindow.openAppimageFile(path);
        }

        function updateFlatpakOne(appid: string): void {
            engine.start({
                dnf: false,
                flatpak: true,
                flatpakIds: [appid]
            });
        }

        function updateAll(): void {
            engine.start({});
        }

        function check(): void {
            store.refresh(SystemUpdateService.availableUpdates);
            SystemUpdateService.checkForUpdates();
            if (root.includeFirmware)
                firmware.check();
        }
    }

    // ── Development entry points ────────────────────────────────────────────
    // Recording and replaying a run is a tool for working on this plugin, not
    // a feature of it, so it is not offered to people who installed it. The
    // settings panel already hides its section; this hides the other half,
    // which would otherwise be listed for everyone by `dms ipc show`. A
    // separate target rather than a guard inside each function: an `enabled`
    // that is false registers nothing at all, so there is nothing to find.
    IpcHandler {
        target: "dankSoftwareDepotDev"
        enabled: Backend.developmentInstall

        // Play a recorded run through the real interface. Here rather than
        // only behind the gear because the loop this exists for is: change
        // the QML, reload the plugin, watch the run again — and a loop with
        // a mouse click in it is a slower loop. An empty name stops.
        function simulate(name: string): string {
            if (name === "" || name === "off" || name === "stop") {
                PluginService.savePluginData("dankSoftwareDepot", "simMode", "");
                return "simulation off";
            }
            if (engine.running)
                return "a run is already going";
            PluginService.savePluginData("dankSoftwareDepot", "simRecording", name);
            PluginService.savePluginData("dankSoftwareDepot", "simMode", "replay");
            updaterWindow.activate();
            updaterWindow.openTab(0);
            updaterWindow.startSimulation();
            return "playing " + name;
        }

        // Arm the recorder: the next update run is written to recordings/.
        function record(on: string): string {
            const wanted = on !== "off" && on !== "false" && on !== "0";
            PluginService.savePluginData("dankSoftwareDepot", "simMode", wanted ? "record" : "");
            return wanted ? "the next run will be recorded" : "recording off";
        }

        // What the simulation layer thinks is going on. Every part of it is
        // asynchronous — the mode is stored, the package list is read back
        // from disk, the run is started once that arrives — so when a replay
        // does not appear, this says which of those three stalled.
        function simstatus(): string {
            return "mode=" + (Backend.simMode || "off")
                + " recording=" + (Backend.simRecording || "-")
                + " active=" + (Backend.activeRecording || "-")
                + " packages=" + ((Backend.simPackages || []).length)
                + " speed=" + Backend.simSpeed
                + " running=" + engine.running
                + " phase=" + engine.phase
                + " root=" + Backend.recordingsRoot
                + " | " + Backend.simDebug();
        }

        // Scroll a list down at a fixed speed and time every frame:
        // `bench installed 1500` (px/s), then `benchresult` once it has run.
        function bench(name: string, speed: int): string {
            return Ui.bench(name, speed);
        }

        function benchresult(): string {
            return Ui.benchResult;
        }

        // The README screenshots, in English, over a recording built from the
        // action log. scripts/screenshots.py is what calls this — it builds
        // those recordings, sizes the window and frames the result; the JSON
        // is ScreenshotDirector.start's options.
        function shots(options: string): string {
            if (!screenshotLoader.item)
                return "screenshots are only available on a working copy";
            let opts;
            try {
                opts = JSON.parse(options);
            } catch (e) {
                return "options must be JSON: " + e;
            }
            return screenshotLoader.item.start(opts);
        }

        function shotstatus(): string {
            const item = screenshotLoader.item;
            return item ? (item.running ? "running " : "") + item.status + (item.running ? "" : " | " + item.written.join(" ")) : "unavailable";
        }

        function recordings(): string {
            Backend.refreshRecordings();
            const rows = (Backend.recordings || []).map(r => r.name + " (" + r.packages + " packages, " + r.seconds + "s, " + (r.tags || []).join("+") + ")");
            return rows.length > 0 ? rows.join("\n") : "nothing recorded yet in " + Backend.recordingsRoot;
        }
    }

    Loader {
        id: screenshotLoader
        active: Backend.developmentInstall
        sourceComponent: ScreenshotDirector {
            window: updaterWindow
        }
    }

    // Persist the current list (only when it comes from real daemon state)
    // so it can be shown right away after the next restart. Triggered on
    // both signals because the service assigns availableUpdates before
    // lastCheckUnix — either alone can fire while the other is still stale.
    function _saveUpdatesSnapshot() {
        if (SystemUpdateService.lastCheckUnix <= 0)
            return;
        PluginService.savePluginData("dankSoftwareDepot", "updatesSnapshot", {
            ts: Math.floor(Date.now() / 1000),
            packages: (SystemUpdateService.availableUpdates || []).slice(0, 500)
        });
    }

    Connections {
        target: SystemUpdateService

        function onAvailableUpdatesChanged() {
            root._pruneSucceeded(new Set((SystemUpdateService.availableUpdates || []).map(pkg => store.keyFor(pkg))));
            store.refresh(SystemUpdateService.availableUpdates);
            sizesDebounce.restart();
            root._saveUpdatesSnapshot();
        }

        function onLastCheckUnixChanged() {
            root._saveUpdatesSnapshot();
        }
    }

    Component.onCompleted: {
        _applyPillVisibility();
        if (pendingUpdates.length > 0)
            store.refresh(pendingUpdates);
        _prefetchPluginNotes();
    }

    // pluginData (and with it the persisted snapshot) loads after component
    // completion, so run enrichment (names, icons) whenever the restored
    // list actually lands — otherwise snapshot rows show generic icons.
    onPendingUpdatesChanged: {
        if (!_serviceHasState && pendingUpdates.length > 0) {
            store.refresh(pendingUpdates);
            _reconcileSnapshot();
        }
        _pruneRestoredFailures();
        advisoryDebounce.restart();
    }

    // A restored snapshot can contain updates installed in the last moments
    // before a shell reload (the DMS pass updates the daemon itself, so no
    // post-run save could happen). Drop every rpm whose target version is
    // already installed.
    function _reconcileSnapshot() {
        const pkgs = (pluginData.updatesSnapshot || {}).packages || [];
        const names = [];
        for (const pkg of pkgs) {
            if (pkg.repo !== "flatpak")
                names.push(store.stripArch(pkg.name));
        }
        if (names.length === 0)
            return;
        snapshotPruneProcess.command = ["rpm", "-q", "--qf", "%{NAME}\\t%{EVR}\\n"].concat(names);
        snapshotPruneProcess.running = true;
    }

    Process {
        id: snapshotPruneProcess

        stdout: StdioCollector {
            onStreamFinished: {
                const installed = {};
                for (const line of text.split("\n")) {
                    const parts = line.split("\t");
                    if (parts.length === 2)
                        installed[parts[0].trim()] = parts[1].trim();
                }
                const noEpoch = v => String(v || "").replace(/^\d+:/, "");
                const snap = root.pluginData.updatesSnapshot || {};
                const pkgs = snap.packages || [];
                const keep = pkgs.filter(pkg => {
                    if (pkg.repo === "flatpak")
                        return true;
                    const evr = installed[store.stripArch(pkg.name)];
                    return !evr || noEpoch(evr) !== noEpoch(pkg.toVersion);
                });
                if (keep.length !== pkgs.length)
                    PluginService.savePluginData("dankSoftwareDepot", "updatesSnapshot", {
                        ts: snap.ts || 0,
                        packages: keep
                    });
            }
        }
    }

    // And rebuild real daemon state without user action: when it comes up
    // empty (it forgets its list on restart), trigger a check ourselves.
    Timer {
        interval: 8000
        running: true

        onTriggered: {
            if (!root._serviceHasState && !SystemUpdateService.isChecking)
                SystemUpdateService.checkForUpdates();
        }
    }

    // The daemon already knows the update list but only pushes state on
    // changes; ask for it explicitly so the pill is correct right after a
    // shell (re)start instead of showing 0 until the next check.
    Timer {
        id: initialStateTimer
        interval: 2000
        running: true
        repeat: false
        onTriggered: {
            SystemUpdateService.requestState();
            // Without a refresh: this is only asking what brew already knows,
            // so the section is there from the start rather than after the
            // first check. On a machine without brew it is one process that
            // says no and never runs again until the next check.
            root.refreshBrew(false);
        }
    }

    Connections {
        target: SystemUpdateService

        function onSysupdateAvailableChanged() {
            if (SystemUpdateService.sysupdateAvailable)
                SystemUpdateService.requestState();
        }
    }

    function requestUpdateAll() {
        if (engine.running)
            return;
        if (confirmBeforeUpdate && !confirmArmed) {
            confirmArmed = true;
            confirmTimer.restart();
            return;
        }
        confirmArmed = false;
        engine.start({});
    }

    Timer {
        id: confirmTimer
        interval: 5000
        onTriggered: root.confirmArmed = false
    }

    // ── What the pill does when it is activated ─────────────────────────────
    // DankBar has a "hover popouts" setting, and a widget that names a
    // pillClickAction gets that action on hover as well — DMS calls the same
    // function for both, with the same arguments, so there is nothing here
    // that can tell them apart.
    //
    // For a widget that opens a popout that is fine: DMS can see its own
    // popouts, knows the one it asked for is already up, and stops asking.
    // This window is not one of them. It is a window, DMS never learns it
    // opened, and it asks again at every hover tick — against a toggle, which
    // answers open, closed, open, closed for as long as the pointer rests on
    // the pill.
    //
    // So with hover popouts on, the pill only ever opens. Closing by clicking
    // the pill again is not something that configuration can offer anyway:
    // every click is preceded by the hover that would reopen it. Without the
    // setting — the default — nothing changes.
    readonly property bool barHoverPopouts: (barConfig && barConfig.hoverPopouts === true) || false

    function activatePill() {
        if (!barHoverPopouts) {
            updaterWindow.toggle();
            return;
        }
        // Deliberately not activate(): that focuses, and a hover tick every
        // 150ms would take the keyboard away from whatever is under the
        // pointer, over and over.
        if (!updaterWindow.visible)
            updaterWindow.visible = true;
    }

    pillClickAction: root.pillOpensWindow ? (() => root.activatePill()) : null

    // Right-click opens the window whatever a left click does: the popout
    // and the window are a click apart either way. DMS never calls this on
    // hover, so it can bring the window forward rather than only show it.
    pillRightClickAction: () => updaterWindow.activate()

    // ── Bar pills ────────────────────────────────────────────────────────────
    readonly property bool _busy: SystemUpdateService.isChecking || engine.running
    readonly property string _pillText: {
        if (engine.running)
            return engine.plannedCount > 0 ? engine.completedCount + "/" + engine.plannedCount : "";
        if (SystemUpdateService.isChecking)
            return "";
        return root.effectiveCount.toString();
    }
    readonly property color _pillColor: {
        if (engine.running)
            return Theme.primary;
        if (root.rebootRecommended)
            return Theme.warning;
        if (SystemUpdateService.hasError)
            return Theme.error;
        return root.effectiveCount > 0 ? Theme.primary : Theme.surfaceVariantText;
    }
    readonly property string _pillIcon: {
        if (engine.running)
            return "downloading";
        if (SystemUpdateService.isChecking)
            return "refresh";
        if (root.rebootRecommended)
            return "restart_alt";
        if (SystemUpdateService.hasError)
            return "release_alert";
        return root.effectiveCount > 0 ? "deployed_code_update" : "check_circle";
    }

    // Whether the bar pill should be on screen at all. "Hide when up to date"
    // means exactly this and nothing else: a pill that has nothing to report
    // stays out of the bar until it has.
    readonly property bool pillWanted: !hideWhenUpToDate || root.effectiveCount > 0 || engine.running || SystemUpdateService.isChecking

    visibilityCommand: ""

    // Asked of the host rather than bound to its `conditionVisible`, which
    // was doing nothing at all (#12). The host only consults that property
    // when a visibilityCommand is set — with none, it returns true and, worse,
    // assigns `conditionVisible = true` itself, which breaks any binding a
    // plugin puts on it. setVisibilityOverride is the way a plugin says this,
    // and it means the same thing in every DMS that has plugins.
    function _applyPillVisibility() {
        if (typeof setVisibilityOverride === "function")
            setVisibilityOverride(pillWanted);
    }

    onPillWantedChanged: _applyPillVisibility()

    popoutWidth: 480
    popoutHeight: 0

    // Popout list: run snapshot while running, otherwise pending minus held
    readonly property var popoutModel: {
        if (engine.phase !== "idle" && (engine.runItems || []).length > 0)
            return engine.runItems.map(item => item.pkg);
        const rows = pendingUpdates.filter(pkg => !store.isHeld(pkg));
        if (includeFirmware) {
            for (const fw of firmware.updates || []) {
                rows.push({
                    name: fw.name,
                    repo: "firmware",
                    fromVersion: fw.current,
                    toVersion: fw.next
                });
            }
        }
        for (const ai of appimageUpdates || []) {
            rows.push({
                name: ai.id,
                displayName: ai.name,
                repo: "appimage",
                fromVersion: ai.current,
                toVersion: ai.latest
            });
        }
        // Counted in the header and the pill all along, but never listed:
        // with only a plugin update pending, the popout said "1 update
        // ready" above "Your system is up to date!"
        for (const plugin of pluginUpdates || [])
            rows.push(plugin);
        for (const formula of brewUpdates || [])
            rows.push(formula);
        return rows;
    }
    readonly property int heldCount: heldSystemKeys.length

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                id: hPillIcon
                // Spins during a check: distance-field rendering survives
                // rotation, the default pixel-grid hinting does not. Only
                // while spinning, as DMS does it: at rest the native glyph
                // is the sharper of the two
                smoothTransform: SystemUpdateService.isChecking && Ui.busyMotion
                name: root._pillIcon
                color: root._pillColor
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter

                RotationAnimator on rotation {
                    from: 0
                    to: 360
                    duration: Ui.busyCycle
                    loops: Animation.Infinite
                    running: SystemUpdateService.isChecking && Ui.busyMotion

                    onRunningChanged: {
                        if (!running)
                            hPillIcon.rotation = 0;
                    }
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root._pillText
                color: root._pillColor
                font.pixelSize: Theme.fontSizeMedium
                visible: root._pillText !== "0" && root._pillText !== ""
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                id: vPillIcon
                // Spins during a check: distance-field rendering survives
                // rotation, the default pixel-grid hinting does not. Only
                // while spinning, as DMS does it: at rest the native glyph
                // is the sharper of the two
                smoothTransform: SystemUpdateService.isChecking && Ui.busyMotion
                name: root._pillIcon
                color: root._pillColor
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter

                RotationAnimator on rotation {
                    from: 0
                    to: 360
                    duration: Ui.busyCycle
                    loops: Animation.Infinite
                    running: SystemUpdateService.isChecking && Ui.busyMotion

                    onRunningChanged: {
                        if (!running)
                            vPillIcon.rotation = 0;
                    }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root._pillText
                color: root._pillColor
                font.pixelSize: Theme.fontSizeSmall
                visible: root._pillText !== "0" && root._pillText !== ""
            }
        }
    }

    // ── Compact popout ───────────────────────────────────────────────────────
    popoutContent: Component {
        PopoutComponent {
            id: popoutContainer
            headerText: ""
            detailsText: ""
            showCloseButton: false

            Column {
                id: mainCol
                width: parent.width
                spacing: Theme.spacingM
                topPadding: 0
                bottomPadding: 2

                // --- Header Card ---
                StyledRect {
                    width: parent.width
                    height: 68
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                    border.width: 0

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingM

                        Rectangle {
                            width: 38
                            height: 38
                            radius: width / 2
                            color: Theme.withAlpha(Theme.primary, 0.2)
                            Layout.alignment: Qt.AlignVCenter

                            Image {
                                id: popoutHeaderLogo
                                anchors.centerIn: parent
                                width: 24
                                height: 24
                                source: root.appIconSource
                                sourceSize.width: 48
                                sourceSize.height: 48
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                visible: status === Image.Ready
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                visible: !popoutHeaderLogo.visible
                                name: "system_update"
                                size: 20
                                color: Theme.primary
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 0

                            StyledText {
                                text: "Dux Software Depot"
                                font.bold: true
                                font.pixelSize: Theme.fontSizeLarge
                                color: Theme.surfaceText
                            }

                            Item {
                                Layout.fillWidth: true
                                height: popoutStatusText.implicitHeight
                                clip: true

                                StyledText {
                                    id: popoutStatusText
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: SystemUpdateService.hasError ? Ui.failColor : Theme.primary
                                    font.family: "Monospace"
                                    opacity: 0.85

                                    property string targetText: {
                                        if (engine.running)
                                            return engine.phaseLabel;
                                        if (SystemUpdateService.isChecking)
                                            return Tr.t("Checking…");
                                        if (SystemUpdateService.hasError)
                                            return Tr.t("Check failed");
                                        const count = root.effectiveCount;
                                        return count === 0 ? Tr.t("Up to date") : (count === 1 ? Tr.t("%1 update ready") : Tr.t("%1 updates ready")).arg(count);
                                    }

                                    Component.onCompleted: text = targetText
                                    onTargetTextChanged: {
                                        if (text !== targetText)
                                            flipAnim.restart();
                                    }

                                    SequentialAnimation {
                                        id: flipAnim

                                        ParallelAnimation {
                                            NumberAnimation { target: popoutStatusText; property: "opacity"; to: 0; duration: Theme.shortDuration }
                                            NumberAnimation { target: popoutStatusText; property: "y"; to: 8; duration: Theme.shortDuration; easing.type: Easing.InQuad }
                                        }
                                        PropertyAction { target: popoutStatusText; property: "text"; value: popoutStatusText.targetText }
                                        ParallelAnimation {
                                            NumberAnimation { target: popoutStatusText; property: "opacity"; to: 0.85; duration: Theme.shortDuration }
                                            NumberAnimation { target: popoutStatusText; property: "y"; to: 0; duration: Theme.shortDuration; easing.type: Easing.OutQuad }
                                        }
                                    }
                                }
                            }
                        }

                        // Header actions: two standard icon buttons, side by side
                        // rather than joined — they are separate actions (#28)
                        Row {
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Theme.spacingXS

                            // Refresh: switched on while a check or run is going
                            Rectangle {
                                id: headerRefreshBtn
                                property bool isHovered: refreshMa.containsMouse
                                property bool isBusy: SystemUpdateService.isChecking || engine.running

                                width: 38
                                height: 38

                                readonly property string kind: isBusy ? "iconSelected" : "icon"
                                color: Ui.buttonFill(kind, isHovered)

                                radius: refreshMa.pressed || isBusy ? (height / 2) : Theme.cornerRadius
                                Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                scale: refreshMa.pressed ? 0.92 : 1.0
                                Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                                DankRipple { id: refreshRip; anchors.fill: parent; cornerRadius: parent.radius; rippleColor: Ui.buttonInk(headerRefreshBtn.kind) }

                                DankIcon {
                                    id: refreshBtnIcon
                                    name: "refresh"
                                    size: 20
                                    color: Ui.buttonInk(headerRefreshBtn.kind)
                                    anchors.centerIn: parent
                                    // Distance-field only while turned: sharp at rest,
                                    // and not jagged mid-turn
                                    smoothTransform: headerRefreshBtn.isBusy || rotation !== 0
                                    rotation: (headerRefreshBtn.isBusy) ? 0 : (headerRefreshBtn.isHovered ? 180 : 0)

                                    Behavior on rotation {
                                        NumberAnimation { duration: Theme.popoutAnimationDuration; easing.type: Easing.OutBack }
                                    }

                                    RotationAnimation on rotation {
                                        from: 0; to: 360; duration: Ui.busyCycle; loops: Animation.Infinite
                                        running: headerRefreshBtn.isBusy && Ui.busyMotion
                                    }
                                }

                                MouseArea {
                                    id: refreshMa
                                    anchors.fill: parent
                                    hoverEnabled: !headerRefreshBtn.isBusy
                                    cursorShape: headerRefreshBtn.isBusy ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    onPressed: (m) => refreshRip.trigger(m.x, m.y)
                                    onClicked: {
                                        if (!headerRefreshBtn.isBusy)
                                            SystemUpdateService.checkForUpdates();
                                    }
                                }
                            }

                            // Open the window
                            Rectangle {
                                id: headerOpenBtn
                                property bool isHovered: openMa.containsMouse

                                width: 38
                                height: 38

                                color: Ui.buttonFill("icon", isHovered)

                                radius: openMa.pressed ? (height / 2) : Theme.cornerRadius
                                Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                scale: openMa.pressed ? 0.92 : 1.0
                                Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                                DankRipple { id: openRip; anchors.fill: parent; cornerRadius: parent.radius; rippleColor: Ui.buttonInk("icon") }

                                DankIcon {
                                    id: openBtnIcon
                                    name: "open_in_new"
                                    size: 20
                                    color: Ui.buttonInk("icon")
                                    anchors.centerIn: parent
                                    smoothTransform: true
                                    rotation: headerOpenBtn.isHovered ? 45 : 0
                                    Behavior on rotation {
                                        NumberAnimation { duration: Theme.popoutAnimationDuration; easing.type: Easing.OutBack }
                                    }
                                }

                                MouseArea {
                                    id: openMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: (m) => openRip.trigger(m.x, m.y)
                                    onClicked: {
                                        root.closePopout();
                                        updaterWindow.visible = true;
                                    }
                                }
                            }
                        }
                    }
                }

                // Reboot recommendation banner
                StyledRect {
                    id: popoutRebootBanner
                    width: parent.width
                    visible: root.rebootRecommended
                    height: visible ? 40 : 0
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.warning, 0.14)

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingXS
                        spacing: Theme.spacingS

                        DankIcon { name: "restart_alt"; size: 17; color: Theme.warning }
                        StyledText { Layout.fillWidth: true; text: Tr.t("Computer restart recommended"); font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceText; elide: Text.ElideRight }
                        DankButton {
                            buttonHeight: 26
                            horizontalPadding: Theme.spacingM
                            text: root.confirmReboot ? Tr.t("Confirm?") : Tr.t("Restart")
                            backgroundColor: root.confirmReboot ? Theme.error : Theme.buttonBg
                            textColor: root.confirmReboot ? Ui.onColor(Theme.error) : Theme.buttonText
                            onClicked: root.requestReboot()
                        }
                    }
                }

                // Progress block while running
                StyledRect {
                    id: popoutProgress
                    width: parent.width
                    visible: engine.phase !== "idle"
                    height: visible ? progressContent.implicitHeight + Theme.spacingM * 2 : 0
                    radius: Theme.cornerRadius
                    color: Ui.cardSurface
                    border.width: 0

                    Column {
                        id: progressContent
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        PhaseIndicator {
                            anchors.horizontalCenter: parent.horizontalCenter
                            step: engine.phaseStep
                            running: engine.running || engine.phase === "verifying"
                            failed: engine.failedCount > 0
                            compact: true
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                if (engine.running) {
                                    const current = engine.currentItem ? " · " + store.prettyId(engine.currentItem) : "";
                                    return engine.phaseLabel + current;
                                }
                                if (engine.phase === "done")
                                    return Tr.t("%1 updated").arg(engine.completedCount) + (engine.failedCount > 0 ? ", " + Tr.t("%1 failed").arg(engine.failedCount) : "");
                                return engine.phaseLabel;
                            }
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            elide: Text.ElideMiddle
                            horizontalAlignment: Text.AlignHCenter
                        }

                        StyledText {
                            width: parent.width
                            visible: engine.running && engine.progressDetail !== ""
                            text: engine.progressDetail
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                // --- Updates List Section Container ---
                StyledRect {
                    id: updatesListContainer
                    width: parent.width
                    visible: root.popoutModel.length > 0
                    height: Math.min(300, 34 + (root.popoutModel.length * 44) + Theme.spacingM * 2)
                    radius: Theme.cornerRadius
                    // The rows it holds are containers already; a box around
                    // them is a tonal level the popout cannot afford at this
                    // size. The header card above it still has one.
                    color: "transparent"
                    border.width: 0

                    Column {
                        id: compactContentCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        // Section Header
                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingXS

                            DankIcon { name: "system_update"; size: 14; color: Theme.surfaceText }
                            StyledText { text: Tr.t("Available Updates"); font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Bold; color: Theme.surfaceText; Layout.fillWidth: true }
                            Rectangle {
                                visible: root.effectiveCount > 0
                                Layout.preferredHeight: 18
                                Layout.preferredWidth: updateBadgeText.implicitWidth + 12
                                radius: 9
                                color: Theme.withAlpha(Theme.primary, 0.2)
                                StyledText { id: updateBadgeText; anchors.centerIn: parent; text: String(root.effectiveCount); font.pixelSize: Theme.fontSizeSmall - 2; font.weight: Font.Bold; color: Theme.primary }
                            }
                        }

                        DankListView {
                            id: compactList
                            Component.onCompleted: Ui.softenScrollbar(compactList)
                            width: parent.width
                            height: Math.max(0, parent.height - 30)
                            clip: true
                            spacing: 2
                            model: root.popoutModel

                            delegate: Item {
                                id: compactRow

                                required property var modelData
                                required property int index

                                readonly property var info: store.infoFor(modelData)
                                readonly property var itemState: engine.stateFor(modelData)
                                readonly property string displayName: store.displayName(modelData)
                                readonly property int totalCount: root.popoutModel.length
                                readonly property bool isFirst: index === 0
                                readonly property bool isLast: index === totalCount - 1
                                readonly property bool isActive: (updaterWindow && updaterWindow.updatesDialog && updaterWindow.updatesDialog.showing && updaterWindow.updatesDialog.rowData && updaterWindow.updatesDialog.rowData.pkg && updaterWindow.updatesDialog.rowData.pkg.name === modelData.name)

                                width: compactList.width
                                height: 42

                                Rectangle {
                                    id: dlBg
                                    anchors.fill: parent

                                    property real innerRadius: 6
                                    property real outerRadius: 12
                                    // Hover is a state layer and nothing more; the shape answers a press, and
                                    // stays changed while the row is selected (M3 Expressive, as DMS does it, #22)
                                    property bool hovered: rowMa.containsMouse || compactRow.isActive
                                    property bool morphed: rowMa.pressed || compactRow.isActive

                                    property real tlr: morphed ? 21 : (isFirst ? outerRadius : innerRadius)
                                    property real trr: morphed ? 21 : (isFirst ? outerRadius : innerRadius)
                                    property real blr: morphed ? 21 : (isLast ? outerRadius : innerRadius)
                                    property real brr: morphed ? 21 : (isLast ? outerRadius : innerRadius)

                                    topLeftRadius: tlr
                                    topRightRadius: trr
                                    bottomLeftRadius: blr
                                    bottomRightRadius: brr

                                    Behavior on topLeftRadius { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }
                                    Behavior on topRightRadius { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }
                                    Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }
                                    Behavior on bottomRightRadius { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }

                                    // The active row takes the accent in its fill, not an
                                    // outline (#28)
                                    color: Ui.rowFill(hovered, compactRow.isActive)

                                    Behavior on color { ColorAnimation { duration: Theme.popoutAnimationDuration } }
                                }

                                DankRipple {
                                    id: dlRip
                                    anchors.fill: parent
                                    cornerRadius: dlBg.topLeftRadius
                                    rippleColor: Theme.primary
                                }

                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPressed: (m) => dlRip.trigger(m.x, m.y)
                                    onClicked: {
                                        root.closePopout();
                                        updaterWindow.openUpdateDetails({ pkg: compactRow.modelData }, compactRow.info);
                                    }
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingS

                                    Item {
                                        id: rowThumb
                                        width: 28
                                        height: 28
                                        Layout.alignment: Qt.AlignVCenter

                                        Rectangle {
                                            anchors.fill: parent
                                            color: Ui.cardSurface
                                            radius: height / 2
                                        }

                                        Image {
                                            id: rowLogo
                                            anchors.fill: parent
                                            source: (compactRow.info && compactRow.info.icon) ? "file://" + compactRow.info.icon : ""
                                            // Rendered at the size it is shown: left to its own, an SVG
                                            // logo is drawn at hundreds of pixels and shrunk unfiltered
                                            sourceSize.width: width
                                            sourceSize.height: height
                                            layer.enabled: Ui.tintAppIcons
                                            layer.effect: TintedIconEffect {}
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            visible: rowLogo.status !== Image.Ready
                                            name: compactRow.modelData.repo === "dmsplugin" ? (compactRow.modelData.icon || "extension") : (compactRow.modelData.repo === "flatpak" ? "apps" : Ui.sourceIcon(compactRow.modelData.repo))
                                            size: 16
                                            color: rowMa.containsMouse ? Theme.primary : (Ui.tintAppIcons ? Theme.primary : Theme.surfaceVariantText)
                                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                                        }
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        text: compactRow.displayName
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: rowMa.containsMouse ? Theme.surfaceText : Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                                    }

                                    Item {
                                        id: statusIndicator
                                        width: 90
                                        height: 20
                                        Layout.alignment: Qt.AlignVCenter

                                        StyledText {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: !compactRow.itemState || compactRow.itemState.status === "pending"
                                            text: Ui.versionLabel(compactRow.modelData.toVersion) || (compactRow.info && compactRow.info.releases && compactRow.info.releases.length > 0 && compactRow.info.releases[0].newer ? compactRow.info.releases[0].version : "")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.primary
                                            elide: Text.ElideMiddle
                                            width: parent.width
                                            horizontalAlignment: Text.AlignRight
                                        }

                                        StyledText {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: compactRow.itemState && compactRow.itemState.status === "active"
                                            text: compactRow.itemState ? Math.round((compactRow.itemState.fraction || 0) * 100) + "%" : ""
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.weight: Font.Medium
                                            color: Theme.primary
                                        }

                                        DankIcon {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: compactRow.itemState && compactRow.itemState.status === "done"
                                            name: "check_circle"
                                            size: 16
                                            color: Theme.success
                                        }

                                        DankIcon {
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: compactRow.itemState && compactRow.itemState.status === "error"
                                            name: "error"
                                            size: 16
                                            color: Ui.failColor
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Empty state
                StyledRect {
                    id: popoutEmptyContainer
                    width: parent.width
                    height: 240
                    visible: root.popoutModel.length === 0
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                    border.width: 0

                    MouseArea {
                        id: emptyStateArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: SystemUpdateService.isChecking ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: {
                            if (!SystemUpdateService.isChecking && !engine.running)
                                SystemUpdateService.checkForUpdates();
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        Item {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.round(48 * 1.87)
                            height: Math.round(48 * 1.87)

                            Rectangle {
                                anchors.centerIn: parent
                                width: 48
                                height: 48
                                radius: width / 2
                                color: {
                                    if (Theme.isLightMode)
                                        return emptyStateArea.containsMouse && !SystemUpdateService.isChecking ? Qt.darker(Theme.primary, 1.15) : Theme.primary;
                                    return emptyStateArea.containsMouse && !SystemUpdateService.isChecking ? Theme.withAlpha(Theme.primary, 0.12) : "transparent";
                                }

                                Behavior on color { ColorAnimation { duration: Theme.shortDuration } }
                            }

                            PulseRings {
                                id: popoutPulse
                                anchors.fill: parent
                                running: SystemUpdateService.isChecking
                            }

                            Image {
                                id: popoutLogoImage
                                anchors.centerIn: parent
                                width: 34
                                height: 34
                                source: root.dankLogoPath !== "" ? "file://" + root.dankLogoPath : ""
                                sourceSize.width: 68
                                sourceSize.height: 68
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                scale: popoutPulse.breath
                                visible: status === Image.Ready && (SystemUpdateService.isChecking || !emptyStateArea.containsMouse)
                            }

                            DankIcon {
                                id: popoutEmptyIcon
                                anchors.centerIn: parent
                                visible: !popoutLogoImage.visible
                                scale: popoutPulse.breath
                                name: (SystemUpdateService.isChecking || emptyStateArea.containsMouse) ? "refresh" : "task_alt"
                                size: 40
                                color: {
                                    if (Theme.isLightMode)
                                        return "white";
                                    if (SystemUpdateService.isChecking || emptyStateArea.containsMouse)
                                        return Theme.primary;
                                    return Theme.success;
                                }
                            }
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: {
                                if (SystemUpdateService.isChecking)
                                    return Tr.t("Checking for updates…");
                                if (emptyStateArea.containsMouse)
                                    return Tr.t("Check for updates");
                                return Tr.t("Your system is up to date!");
                            }
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: emptyStateArea.containsMouse && !SystemUpdateService.isChecking && root.lastUpdateUnix > 0
                            text: Tr.t("Updated %1").arg(root.formatAgo(root.lastUpdateUnix))
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                // Footer actions: Update All is the popout's one filled button,
                // Details sits beside it as a tonal one (#28)
                Row {
                    id: popoutButtons
                    width: parent.width
                    height: 42
                    spacing: Theme.spacingS
                    visible: (root.effectiveCount > 0 && !(engine.phase !== "idle" && !engine.running && SystemUpdateService.isChecking)) || engine.running

                    // Update All / Cancel / Confirm
                    Rectangle {
                        id: updateAllBtn
                        property bool isHovered: updateAllMa.containsMouse
                        readonly property bool busyRun: engine.running || engine.deferred
                        readonly property string btnText: {
                            if (busyRun)
                                return Tr.t("Cancel");
                            if (root.confirmArmed)
                                return Tr.t("Confirm?");
                            return Tr.t("Update All") + (root.updateSizeText !== "" ? " · " + root.updateSizeText : "");
                        }
                        readonly property string btnIcon: busyRun ? "close" : (root.confirmArmed ? "help" : "download")
                        // Cancelling a run stays tonal (red ink): a filled red
                        // button for the whole of a run would shout
                        readonly property string kind: busyRun ? "dangerTonal" : (root.confirmArmed ? "warning" : "filled")
                        readonly property color btnBaseColor: Ui.buttonInk(kind)

                        width: (parent.width - parent.spacing) / 2
                        height: parent.height

                        color: Ui.buttonFill(kind, isHovered)

                        radius: updateAllMa.pressed ? (height / 2) : Theme.cornerRadius
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: updateAllMa.pressed ? 0.94 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple { id: updateAllRip; anchors.fill: parent; cornerRadius: parent.radius; rippleColor: updateAllBtn.btnBaseColor }

                        MouseArea {
                            id: updateAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => updateAllRip.trigger(m.x, m.y)
                            onClicked: {
                                if (updateAllBtn.busyRun) {
                                    engine.cancel();
                                } else {
                                    root.requestUpdateAll();
                                }
                            }
                        }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: updateAllBtn.btnIcon
                                size: 18
                                color: updateAllBtn.btnBaseColor
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: updateAllBtn.btnText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.DemiBold
                                color: updateAllBtn.btnBaseColor
                                Layout.alignment: Qt.AlignVCenter
                            }
                        }
                    }

                    // Details
                    Rectangle {
                        id: detailsBtn
                        property bool isHovered: detailsMa.containsMouse

                        width: (parent.width - parent.spacing) / 2
                        height: parent.height

                        color: Ui.buttonFill("tonal", isHovered)

                        radius: detailsMa.pressed ? (height / 2) : Theme.cornerRadius
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: detailsMa.pressed ? 0.94 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple { id: detailsRip; anchors.fill: parent; cornerRadius: parent.radius; rippleColor: Ui.buttonInk("tonal") }

                        MouseArea {
                            id: detailsMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => detailsRip.trigger(m.x, m.y)
                            onClicked: {
                                root.closePopout();
                                updaterWindow.visible = true;
                            }
                        }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: "open_in_new"
                                size: 18
                                color: Ui.buttonInk("tonal")
                                Layout.alignment: Qt.AlignVCenter
                                rotation: detailsBtn.isHovered ? 45 : 0
                                Behavior on rotation { NumberAnimation { duration: Theme.popoutAnimationDuration; easing.type: Easing.OutBack } }
                                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                            }

                            StyledText {
                                text: Tr.t("Details")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.DemiBold
                                color: Ui.buttonInk("tonal")
                                Layout.alignment: Qt.AlignVCenter
                                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                            }
                        }
                    }
                }
            }
        }
    }
}
