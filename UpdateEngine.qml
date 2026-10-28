import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Drives the actual update run and models progress honestly:
//  - system (dnf) packages go through the DMS daemon (polkit auth, cancel
//    support); progress is derived from the daemon's log stream ("[x/y]"
//    step lines, locale-independent).
//  - flatpaks run through scripts/flatpak_helper.py (libflatpak) which
//    reports exact per-operation byte progress.
// Overall progress is weighted by download bytes (flatpak: exact, dnf:
// nominal per-package weight), so the bar tracks real work instead of
// jumping to 99%. ETA comes from an exponentially smoothed completion rate.
Item {
    id: engine

    // ── Public state ─────────────────────────────────────────────────────────
    property bool running: false
    // idle | starting | dnf-download | dnf-install | flatpak | brew | plugins | verifying | done | failed | cancelled
    property string phase: "idle"
    property real overallFraction: 0
    property int etaSeconds: -1
    property string currentItem: ""
    property string currentDetail: ""
    property int failedCount: 0
    property int completedCount: 0
    property int plannedCount: 0
    // key ("flatpak/<appid>" | "system/<basename>") -> {status, fraction, detail}
    // status: pending | active | confirming | done | error
    property var itemStates: ({})
    // Snapshot of the items included in the current/last run: [{pkg, key}]
    property var runItems: []
    // Download-phase details
    property real flatpakBytesDone: 0
    property real flatpakSpeed: 0
    property int opsDone: 0
    property int opsTotal: 0

    // Rich per-phase detail line: sizes, speed and counts
    readonly property string progressDetail: {
        switch (phase) {
        case "dnf-download":
            // Helper pass: aggregate bytes; before the plan arrives the
            // helper is refreshing repo metadata — say so instead of
            // sitting on a silent 0%
            if (_helperPlanBytes > 0)
                return Tr.t("%1 of %2").arg(formatBytes(_helperTransferred)).arg(formatBytes(_helperPlanBytes));
            return _dnfStageY > 0 && _daemonKind === "shell" ? Tr.t("package %1 of %2").arg(Math.min(_dnfStageX + 1, _dnfStageY)).arg(_dnfStageY) : Tr.t("Loading repositories…");
        case "dnf-install":
        case "dms":
            return _dnfStageY > 0 ? Tr.t("step %1 of %2").arg(Math.min(_dnfStageX + 1, _dnfStageY)).arg(_dnfStageY) : "";
        case "flatpak": {
            if (!_flatpakPlanKnown)
                return "";
            let text = Tr.t("%1 of %2").arg(formatBytes(flatpakBytesDone)).arg(formatBytes(_flatpakPlannedBytes));
            if (flatpakSpeed > 10 * 1024)
                text += " · " + formatBytes(flatpakSpeed) + "/s";
            if (opsTotal > 1)
                text += " · " + Tr.t("%1 of %2").arg(Math.min(opsDone + 1, opsTotal)).arg(opsTotal);
            return text;
        }
        default:
            return "";
        }
    }

    signal finished(bool ok)
    // Seconds the run took and how many items it covered, for the host to
    // remember: a forecast from this machine's own history beats a guess.
    signal runMeasured(int seconds, int items)

    property double _runStartedAt: 0

    // Keys ("system/<basename>") of packages held back by dnf config
    // (versionlock/excludepkgs); they are skipped in runs. Bound by the widget.
    property var heldKeys: []
    // Effective pending-update list from the host (live daemon data, or the
    // persisted snapshot right after a restart) — start() must not read the
    // service directly or a run from snapshot state sees an empty list and
    // loses the held exclusions.
    property var pendingUpdates: []

    // Updating DMS/Quickshell packages makes Quickshell live-reload the shell,
    // which tears down this UI mid-run. They are excluded from the first dnf
    // pass and updated in a separate final pass once everything else is done;
    // that transaction runs inside the daemon, so it completes even if the
    // shell reloads while it runs.
    // The dux-* names are the ones Dux Labs suggests packagers move to with
    // 2.0; dms-shell is what Arch and Debian already call it.
    readonly property var shellPackagePattern: /^(dms(-git)?|dms-cli|dms-greeter|dms-shell(-git|-bin)?|dux-shell(-git)?|dux-greeter|quickshell(-git)?)$/

    // FirmwareService instance (bound by the widget); firmware updates run
    // as the last phase via fwupdmgr.
    property var firmwareService: null

    // Pending AppImage updates [{id, name, current, latest, url, size}],
    // bound by the widget; they run in their own phase via scripts/appimage.py.
    property var appimageUpdates: []
    // [{name (plugin id), displayName, repo: "dmsplugin", fromVersion, toVersion}]
    property var pluginUpdates: []
    // [{name (formula), displayName, repo: "brew", fromVersion, toVersion}]
    property var brewUpdates: []
    // rpm base name -> exact download size in bytes (from dnf repoquery),
    // used for per-package byte detail during the download stage
    property var packageSizes: ({})

    // Clear the finished/failed result panel
    function dismiss() {
        autoDismissTimer.stop();
        autoDismissing = false;
        if (!running)
            phase = "idle";
    }

    // Auto-dismiss a fully successful result; failures stay until dismissed.
    // Both published, because a panel that clears itself without warning reads
    // as a panel that was taken away: the card shows the time running out.
    readonly property int autoDismissMs: 8000
    property bool autoDismissing: false

    Timer {
        id: autoDismissTimer
        interval: engine.autoDismissMs
        onTriggered: {
            engine.autoDismissing = false;
            if (!engine.running && engine.phase === "done" && engine.failedCount === 0)
                engine.phase = "idle";
        }
    }

    onPhaseChanged: {
        autoDismissing = phase === "done" && failedCount === 0;
        if (autoDismissing)
            autoDismissTimer.restart();
    }

    // Verification can turn a clean run into one with a failure in it, minutes
    // after the phase said done. The panel stops counting down when that
    // happens — it has something to say now.
    onFailedCountChanged: {
        if (failedCount > 0 && autoDismissing) {
            autoDismissTimer.stop();
            autoDismissing = false;
        }
    }

    // Stepper position: 0 check, 1 download, 2 install, 3 verify, 4 done
    readonly property int phaseStep: {
        switch (phase) {
        case "dnf-download":
            return 1;
        case "dnf-install":
            return 2;
        case "flatpak":
            return _flatpakStillDownloading ? 1 : 2;
        // The daemon pass computes its own stage — a download series, then the
        // transaction — for both kinds of pass; it simply does not set the
        // phase for the shell one, because that phase carries the warning
        // about the reload and should keep saying it. The step is free to be
        // accurate even when the label stays put.
        case "dms":
            return _dnfStage >= 2 ? 2 : 1;
        // Downloading is what the AppImage phase spends its time on, and the
        // helper reports every byte of it; what follows — the icon, the
        // desktop entry, moving the file into place — is the install.
        case "appimage":
            return _appimageDownloading ? 1 : 2;
        case "firmware":
        case "brew":
        case "plugins":
            return 2;
        case "verifying":
            return 3;
        case "done":
        case "failed":
        case "cancelled":
            return 4;
        default:
            return 0;
        }
    }

    readonly property string phaseLabel: {
        switch (phase) {
        case "starting":
            return Tr.t("Preparing update…");
        case "dnf-download":
            return Tr.t("Downloading system packages…");
        case "dnf-install":
            return Tr.t("Installing system packages…");
        case "flatpak":
            return _flatpakStillDownloading ? Tr.t("Downloading Flatpak updates…") : Tr.t("Installing Flatpak updates…");
        case "appimage":
            return Tr.t("Updating AppImages…");
        case "firmware":
            return Tr.t("Updating firmware…");
        case "dms":
            return Tr.t("Updating Dux Shell… (shell may reload)");
        case "brew":
            return Tr.t("Upgrading Homebrew formulae… (building from source can take a while)");
        case "plugins":
            return Tr.t("Updating DMS plugins…");
        case "verifying":
            return Tr.t("Confirming what took effect…");
        case "done":
            return failedCount > 0 ? Tr.t("Finished with issues") : Tr.t("Everything up to date");
        case "failed":
            return Tr.t("Update failed");
        case "cancelled":
            return Tr.t("Update cancelled");
        default:
            return "";
        }
    }

    // ── Tuning ───────────────────────────────────────────────────────────────
    readonly property real dnfPkgWeight: 12 * 1024 * 1024   // nominal bytes per rpm
    readonly property real dnfDownloadShare: 0.45
    readonly property real flatpakFallbackOpWeight: 30 * 1024 * 1024

    // ── Internals ────────────────────────────────────────────────────────────
    property bool _wantDnf: false
    property bool _wantFlatpak: false
    property bool _wantFirmware: false
    property bool _wantShell: false
    property bool _shellDone: true
    property int _shellCount: 0
    property var _shellNames: []
    property var _shellNameToKey: ({})
    // base name -> target EVR, for post-pass verification against rpm
    property var _daemonExpectedEvr: ({})
    // base name -> installed EVR before the pass, for rows with no target
    property var _daemonPreviousEvr: ({})
    property bool _wantAppimage: false
    property bool _wantPlugins: false
    property int _pluginsDone: 0
    property bool _wantBrew: false
    property var _brewItems: []
    property int _brewDone: 0
    property var _appimageItems: []
    property var _aiOps: ({})            // id -> {weight, fraction, done}
    property string _aiCurrentId: ""
    property string _daemonKind: "dnf"    // which daemon pass is active: dnf | shell
    // Whether the shell pass is carrying the whole rpm set rather than only
    // the packages that reload the shell — it says so, rather than announcing
    // Dux Shell while installing somebody else's library
    property var _firmwareItems: []
    property real _firmwareFraction: 0
    property int _firmwareDone: 0
    readonly property real firmwareItemWeight: 50 * 1024 * 1024
    // A plugin is a small git checkout; nominal, since the daemon reports no
    // bytes and the number only has to be the right order of magnitude next
    // to the rpms it shares a progress bar with
    readonly property real pluginItemWeight: 2 * 1024 * 1024
    readonly property real brewItemWeight: 8 * 1024 * 1024
    property var _flatpakIds: []
    property bool _dnfDone: false
    property int _dnfCount: 0
    property int _dnfStage: 0            // 0 not started, 1 download, 2 install
    property int _dnfStageX: 0
    property int _dnfStageY: 0
    property int _dnfLogCursor: 0
    property var _dnfNameToKey: ({})
    property bool _dnfSawUpgrading: false
    property var _flatpakOps: ({})       // ref -> {appid, weight, fraction, done}
    property real _flatpakPlannedBytes: 0
    property bool _flatpakPlanKnown: false
    property int _flatpakOpCount: 0
    // Whether anything in the Flatpak phase is still being fetched. It used to
    // be set from whichever operation spoke last, which is not the same
    // question: libflatpak runs several refs at once, so one reaching
    // "Installing" flipped the stepper to Install while other rows were still
    // counting up their download percentages — visible, and reported.
    //
    // Anything not finished and not yet installing is still coming down, and
    // while that is true of any of them the phase is a download.
    property bool _flatpakStillDownloading: true

    // The AppImage being fetched right now, as opposed to being unpacked into
    // place. A run only ever downloads — an update comes from a release — so
    // this starts true for each item and turns over when the bytes are in.
    property bool _appimageDownloading: true

    function _recomputeFlatpakStage() {
        for (const ref in _flatpakOps) {
            const op = _flatpakOps[ref];
            if (!op.done && !op.installing) {
                _flatpakStillDownloading = true;
                return;
            }
        }
        _flatpakStillDownloading = false;
    }
    property real _rate: 0               // weight units per second (EWMA)
    property real _lastWeightDone: 0
    property int _elapsedSeconds: 0

    function formatBytes(bytes) {
        if (bytes >= 1024 * 1024 * 1024)
            return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB";
        if (bytes >= 1024 * 1024)
            return Math.round(bytes / (1024 * 1024)) + " MB";
        return Math.max(1, Math.round(bytes / 1024)) + " kB";
    }

    function formatEta(seconds) {
        if (seconds < 0)
            return "";
        if (seconds < 60)
            return Tr.t("less than a minute left");
        const mins = Math.round(seconds / 60);
        if (mins < 60)
            return Tr.t("about %1 min left").arg(mins);
        return Tr.t("about %1 h %2 min left").arg(Math.floor(mins / 60)).arg(mins % 60);
    }

    // A bare duration, for sentences that supply their own framing. Cutting
    // the word "left" out of formatEta() only worked in languages that put it
    // last, which is not most of them.
    function formatDuration(seconds) {
        const mins = Math.max(1, Math.round(seconds / 60));
        if (mins < 60)
            return Tr.t("%1 min").arg(mins);
        return Tr.t("%1 h %2 min").arg(Math.floor(mins / 60)).arg(mins % 60);
    }

    // ── What the next run would do ──────────────────────────────────────────
    // The resolver's own answer, fetched unprivileged before anyone clicks:
    // how many packages, how many of them nobody selected, what leaves the
    // disk. Everything here comes from the same `plan` event the run itself
    // uses, so the preview cannot drift from the transaction.
    // null while unknown; otherwise {total, extra, removals, downloadBytes,
    // diskDeltaBytes, removedNames}
    property var previewPlan: null

    Timer {
        id: previewDebounce
        interval: 1500
        onTriggered: engine._startPreview()
    }

    // Re-plan when the pending list settles, never while a run is on: the
    // answer would be stale before it arrived.
    onPendingUpdatesChanged: {
        if (running)
            return;
        previewPlan = null;
        previewDebounce.restart();
    }

    function _startPreview() {
        if (running || previewProcess.running)
            return;
        // A replay's list is a recording of another moment; resolving its
        // names against this machine answered for the few that happen to be
        // pending here ("3 packages" under a list of 104), which describes
        // neither the replay nor the machine
        if (Backend.replaying) {
            previewPlan = null;
            return;
        }
        const names = [];
        const held = new Set(heldKeys || []);
        for (const pkg of pendingUpdates || []) {
            if (pkg.repo === "flatpak" || pkg.repo === "firmware" || pkg.repo === "appimage")
                continue;
            // The helper resolves official repositories only and answers
            // "package not found" for an AUR name; AUR packages ride the
            // daemon pass, which has no plan to preview
            if (pkg.repo === "aur")
                continue;
            if (!held.has("system/" + _stripArch(pkg.name)))
                names.push(pkg.name);
        }
        if (names.length === 0) {
            previewPlan = null;
            return;
        }
        previewProcess._selected = new Set(names.map(n => _stripArch(n)));
        previewProcess.command = Backend.instrument("plan", Backend.planCommand("upgrade", names));
        previewProcess.running = true;
    }

    Process {
        id: previewProcess

        property var _selected: new Set()

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event !== "plan")
                    return;
                let extra = 0;
                let counted = 0;
                const removed = [];
                for (const op of event.ops || []) {
                    const action = op.action || "";
                    // An upgrade resolves to two operations: the new package
                    // arriving and the old one being replaced. The second is
                    // the same package leaving as part of the first — not
                    // something to count, and not something to warn about
                    // either. Counting it turned three updates into "6
                    // packages" underneath a list of three.
                    if (/replac/i.test(action))
                        continue;
                    counted++;
                    if (/remove|obsolet/i.test(action))
                        removed.push(op.name);
                    else if (!previewProcess._selected.has(op.name))
                        extra++;
                }
                engine.previewPlan = {
                    total: counted,
                    extra: extra,
                    removals: removed.length,
                    removedNames: removed,
                    downloadBytes: event.totalDownloadBytes || 0,
                    diskDeltaBytes: event.installDeltaBytes || 0
                };
            }
        }
    }

    // Verbatim failure text for a package, "" when there is none
    function errorDetailFor(pkg) {
        return runErrorDetails[_keyFor(pkg)] || "";
    }

    function stateFor(pkg) {
        return itemStates[_keyFor(pkg)] || null;
    }

    function _keyFor(pkg) {
        let key;
        if (pkg.repo === "flatpak")
            key = "flatpak/" + pkg.name;
        else if (pkg.repo === "firmware")
            key = "firmware/" + pkg.name;
        else if (pkg.repo === "appimage")
            key = "appimage/" + pkg.name;
        else if (pkg.repo === "brew")
            key = "brew/" + pkg.name;
        else
            key = "system/" + _stripArch(pkg.name);
        return key;
    }

    function _stripArch(name) {
        return (name || "").replace(/\.(x86_64|i686|noarch|aarch64|armv7hl|ppc64le|s390x)$/, "");
    }

    function _setItem(key, patch) {
        const updated = Object.assign({}, itemStates);
        updated[key] = Object.assign({}, updated[key] || {
            status: "pending",
            fraction: 0,
            detail: ""
        }, patch);
        itemStates = updated;
    }

    // A run requested while the daemon has no package state (right after its
    // restart) would be a silent no-op: the upgrade command needs a check
    // first. Defer the run, trigger the check (the UI shows its spinner) and
    // start for real when it lands.
    property var _deferredOpts: null
    // True while a requested run waits for the pre-run check — buttons show
    // their cancel state during this window too
    readonly property bool deferred: _deferredOpts !== null

    Connections {
        target: SystemUpdateService
        enabled: engine._deferredOpts !== null

        function onIsCheckingChanged() {
            if (SystemUpdateService.isChecking)
                return;
            const opts = engine._deferredOpts;
            engine._deferredOpts = null;
            if (!SystemUpdateService.hasError)
                Qt.callLater(() => engine.start(opts));
        }
    }

    // ── Run control ──────────────────────────────────────────────────────────
    // Emitted before a run replaces the previous one's items, so anything
    // still holding on to them — the log, waiting for a verification answer
    // that will now never come — can write them down first.
    signal aboutToStart

    function start(opts) {
        if (running)
            return;
        aboutToStart();
        const options = opts || {};
        // A recording is of a run, so it has to be taken from one: the list
        // the window was showing goes in first, because afterwards there is
        // no way back to it — the packages have been installed.
        if (Backend.recording)
            Backend.beginRecording(JSON.stringify({
                backendId: Backend.backendId,
                packages: pendingUpdates || [],
                heldKeys: heldKeys || [],
                packageSizes: packageSizes || ({})
            }));
        // Waiting for the daemon to have state is about the machine, and a
        // replay is not about the machine. It plays what a machine did.
        const daemonHasState = Backend.replaying || SystemUpdateService.lastCheckUnix > 0 || (SystemUpdateService.availableUpdates || []).length > 0;
        if (!daemonHasState && options.dnf !== false && (pendingUpdates || []).some(p => p.repo !== "flatpak")) {
            _deferredOpts = options;
            SystemUpdateService.checkForUpdates();
            return;
        }
        const held = new Set(heldKeys || []);
        const updates = pendingUpdates || [];
        const explicitFlatpak = (options.flatpakIds || []).length > 0;
        const dnfAll = updates.filter(p => p.repo !== "flatpak" && !held.has("system/" + _stripArch(p.name)));
        // Two privileged passes mean two authorisations: the rpm helper runs
        // under pkexec, the DMS packages go through the daemon, and those are
        // different polkit actions. For a while a run carrying both put
        // everything through the daemon to be asked once — on the assumption
        // that such runs were rare.
        //
        // On a machine following dms-git and quickshell-git they are nearly
        // every run, which inverted the trade: the daemon pass is
        // `dnf5 upgrade --refresh -y`, so every update revalidated all
        // repositories and reported progress as "package n of m" instead of
        // the helper's per-package bytes. Seven days of this machine's journal
        // held six daemon passes and not one helper call.
        //
        // So they are separate again. An update that touches both kinds asks
        // twice; everything else — the common case on any machine not tracking
        // the shell's own git builds — asks once, as it always did.
        // The shell's own packages go through the DMS daemon rather than
        // through a process of ours, so there is no stream to record and none
        // to play back. A replay leaves them out of the run altogether rather
        // than starting a real daemon pass in the middle of a simulation, or
        // showing rows that nothing will ever move.
        // AUR updates ride the shell pass on the DMS daemon. The pacman
        // helper resolves official repositories only — libalpm has no AUR —
        // so an AUR name handed to it fails the whole transaction with
        // "package not found". The daemon's AUR backend (paru or yay) is the
        // one that can build and install these, and this is the same pass
        // and the same terminal-wrapped `paru -Syu` the shell's own updater
        // already runs; the plugin adds no AUR building of its own.
        const shellPkgs = (options.dnf !== false && !Backend.replaying) ? dnfAll.filter(p => p.repo === "aur" || shellPackagePattern.test(_stripArch(p.name))) : [];
        const dnfPkgs = dnfAll.filter(p => p.repo !== "aur" && !shellPackagePattern.test(_stripArch(p.name)));
        const flatpakPkgs = updates.filter(p => p.repo === "flatpak");

        _wantDnf = (options.dnf !== false) && dnfPkgs.length > 0;
        _wantShell = shellPkgs.length > 0;
        _flatpakIds = options.flatpakIds || [];
        _wantFlatpak = (options.flatpak !== false) && flatpakPkgs.length > 0;
        // AppImages join full runs and explicit selections; a flatpak-only
        // selection (flatpakIds) leaves them out
        let appimageItems = [];
        if (options.appimageIds && options.appimageIds.length > 0) {
            const wanted = new Set(options.appimageIds);
            appimageItems = (appimageUpdates || []).filter(u => wanted.has(u.id));
        } else if (options.appimage !== false && !explicitFlatpak) {
            appimageItems = (appimageUpdates || []).slice();
        }
        _wantAppimage = appimageItems.length > 0;
        _appimageItems = appimageItems;
        // Blocked firmware (on battery, lid shut) stays out: fwupdmgr skips it
        // without an error, and the run would report it installed
        const firmwareItems = (options.firmware !== false && firmwareService && firmwareService.available) ? (firmwareService.installable || []) : [];
        _wantFirmware = firmwareItems.length > 0;
        _firmwareItems = firmwareItems;
        // Plugins join a full run, like AppImages, and stay out of a run that
        // was asked for a specific list of Flatpaks
        const pluginItems = (options.plugins !== false && !explicitFlatpak) ? (pluginUpdates || []).slice() : [];
        _wantPlugins = pluginItems.length > 0;
        _pluginItems = pluginItems;
        _pluginsDone = 0;
        const brewItems = (options.brew !== false && !explicitFlatpak) ? (brewUpdates || []).slice() : [];
        _wantBrew = brewItems.length > 0;
        _brewItems = brewItems;
        _brewDone = 0;

        if (!_wantDnf && !_wantFlatpak && !_wantFirmware && !_wantShell && !_wantAppimage && !_wantPlugins && !_wantBrew)
            return;

        _dnfDone = !_wantDnf;
        _shellDone = !_wantShell;
        _shellCount = shellPkgs.length;
        _shellNames = shellPkgs.map(p => p.name);
        _daemonKind = "dnf";
        _dnfCount = dnfPkgs.length;
        _dnfStage = 0;
        _dnfStageX = 0;
        _dnfStageY = 0;
        _dnfLogCursor = 0;
        _dnfSawUpgrading = false;
        _flatpakOps = {};
        _flatpakPlannedBytes = 0;
        _flatpakPlanKnown = false;
        _flatpakOpCount = 0;
        _flatpakStillDownloading = true;
        _rate = 0;
        _lastWeightDone = 0;
        _elapsedSeconds = 0;
        failedCount = 0;
        completedCount = 0;
        runErrorDetails = {};
        etaSeconds = -1;
        overallFraction = 0;
        currentItem = "";
        currentDetail = "";

        const states = {};
        const nameMap = {};
        const expectedEvr = {};
        const previousEvr = {};
        const items = [];
        const selectedFlatpak = new Set(_flatpakIds);
        plannedCount = 0;
        for (const pkg of dnfPkgs) {
            if (_wantDnf) {
                const base = _stripArch(pkg.name);
                if (states["system/" + base])
                    continue;
                states["system/" + base] = {
                    status: "pending",
                    fraction: 0,
                    detail: ""
                };
                nameMap[base] = "system/" + base;
                expectedEvr[base] = pkg.toVersion || "";
                previousEvr[base] = pkg.fromVersion || "";
                items.push({
                    pkg: pkg,
                    key: "system/" + base
                });
                plannedCount++;
            }
        }
        for (const pkg of flatpakPkgs) {
            if (!_wantFlatpak)
                continue;
            if (_flatpakIds.length > 0 && !selectedFlatpak.has(pkg.name))
                continue;
            if (states["flatpak/" + pkg.name])
                continue;
            states["flatpak/" + pkg.name] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            items.push({
                pkg: pkg,
                key: "flatpak/" + pkg.name
            });
            plannedCount++;
        }
        const aiOps = {};
        for (const ai of appimageItems) {
            states["appimage/" + ai.id] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            aiOps[ai.id] = {
                weight: Math.max(ai.size || 0, 5 * 1024 * 1024),
                fraction: 0,
                done: false
            };
            items.push({
                pkg: {
                    name: ai.id,
                    displayName: ai.name,
                    repo: "appimage",
                    fromVersion: ai.current,
                    toVersion: ai.latest
                },
                key: "appimage/" + ai.id
            });
            plannedCount++;
        }
        _aiOps = aiOps;
        _aiCurrentId = "";
        for (const fw of firmwareItems) {
            states["firmware/" + fw.name] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            items.push({
                pkg: {
                    name: fw.name,
                    repo: "firmware",
                    fromVersion: fw.current,
                    toVersion: fw.next
                },
                key: "firmware/" + fw.name
            });
            plannedCount++;
        }
        for (const formula of brewItems) {
            states["brew/" + formula.name] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            items.push({
                pkg: formula,
                key: "brew/" + formula.name
            });
            plannedCount++;
        }
        for (const plugin of pluginItems) {
            states["plugin/" + plugin.name] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            items.push({
                pkg: plugin,
                key: "plugin/" + plugin.name
            });
            plannedCount++;
        }
        const shellMap = {};
        for (const pkg of shellPkgs) {
            const base = _stripArch(pkg.name);
            if (states["system/" + base])
                continue;
            states["system/" + base] = {
                status: "pending",
                fraction: 0,
                // Only the shell's own packages reload it; the rest are only
                // travelling with them to save an authorisation
                detail: shellPackagePattern.test(base) ? Tr.t("runs last · reloads the shell") : ""
            };
            shellMap[base] = "system/" + base;
            expectedEvr[base] = pkg.toVersion || "";
            previousEvr[base] = pkg.fromVersion || "";
            items.push({
                pkg: pkg,
                key: "system/" + base
            });
            plannedCount++;
        }
        _shellNameToKey = shellMap;
        _dnfNameToKey = nameMap;
        _daemonExpectedEvr = expectedEvr;
        _daemonPreviousEvr = previousEvr;
        itemStates = states;
        runItems = items;
        _flatpakRunError = "";
        flatpakBytesDone = 0;
        flatpakSpeed = 0;
        opsDone = 0;
        opsTotal = 0;
        _firmwareFraction = 0;
        _firmwareDone = 0;

        running = true;
        phase = "starting";
        _runStartedAt = Date.now();
        etaTimer.start();

        if (_wantDnf) {
            _startHelperUpgrade();
        } else if (_wantFlatpak) {
            _startFlatpak();
        } else if (_wantAppimage) {
            _startAppimage();
        } else if (_wantFirmware) {
            _startFirmware();
        } else {
            _afterFirmware();
        }
    }

    function _afterAppimage() {
        if (_wantFirmware) {
            _startFirmware();
        } else {
            _afterFirmware();
        }
    }

    // ── DMS plugins ─────────────────────────────────────────────────────────
    // The daemon updates one plugin per call and answers when that one is
    // done. There is no byte progress to be had from it, so a plugin row goes
    // from active to done rather than filling up — the same honesty the
    // firmware phase settles for, for the same reason.
    //
    // One at a time: two plugin installs racing each other to rescan the
    // plugin directory is not a thing worth finding out about during someone
    // else's update run.
    property var _pluginItems: []
    property int _pluginIndex: 0

    function _afterFirmware() {
        if (_wantBrew) {
            _startBrew();
        } else if (_wantPlugins) {
            _startPlugins();
        } else if (_wantShell && !_shellDone) {
            _startDaemon("shell");
        } else {
            _finish(failedCount > 0 ? "failed" : "done");
        }
    }

    // ── Homebrew ────────────────────────────────────────────────────────────
    // No privileges, no shell reload, no daemon: one process, one formula at a
    // time, and the events come from reading what brew says it is doing. There
    // are no bytes in that, so a row goes from active to done — and a formula
    // with no bottle is compiled from source, which can take very long and
    // says nothing while it does. The phase label admits that rather than
    // implying a stall.
    function _startBrew() {
        phase = "brew";
        _brewDone = 0;
        const cmd = [Backend.python, Qt.resolvedUrl("scripts/brew_helper.py").toString().replace("file://", ""), "--upgrade"];
        for (const formula of _brewItems)
            cmd.push(formula.name);
        brewProcess.command = Backend.instrument("brew", cmd);
        brewProcess.running = true;
    }

    function _afterBrew() {
        currentItem = "";
        if (_wantPlugins) {
            _startPlugins();
        } else if (_wantShell && !_shellDone) {
            _startDaemon("shell");
        } else {
            _finish(failedCount > 0 ? "failed" : "done");
        }
    }

    Process {
        id: brewProcess

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                const key = event.name ? "brew/" + event.name : "";
                switch (event.event) {
                case "op-start":
                    engine.currentItem = event.name;
                    engine._setItem(key, {
                        status: "active",
                        fraction: 0,
                        detail: ""
                    });
                    break;
                case "op-done":
                    engine._setItem(key, {
                        status: "done",
                        fraction: 1,
                        detail: ""
                    });
                    engine.completedCount++;
                    engine._brewDone++;
                    break;
                case "op-error":
                    engine._setError(key, Tr.t("Homebrew could not upgrade this"), event.message || "");
                    engine.failedCount++;
                    break;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            // Anything still pending never got its own event — brew died
            // before reaching it, or before saying so
            for (const item of engine._brewItems) {
                const state = engine.itemStates["brew/" + item.name] || {};
                if (state.status === "done" || state.status === "error")
                    continue;
                engine._setError("brew/" + item.name, Tr.t("Homebrew could not upgrade this"), "");
                engine.failedCount++;
            }
            engine._afterBrew();
        }
    }

    function _startPlugins() {
        phase = "plugins";
        _pluginIndex = 0;
        _updateNextPlugin();
    }

    function _updateNextPlugin() {
        if (!running)
            return;
        if (_pluginIndex >= _pluginItems.length) {
            _afterPlugins();
            return;
        }
        const item = _pluginItems[_pluginIndex];
        const key = "plugin/" + item.name;
        currentItem = item.displayName || item.name;
        currentDetail = "";
        _setItem(key, {
            status: "active",
            fraction: 0,
            detail: ""
        });
        DMSService.update(item.name, response => {
            if (!engine.running)
                return;
            if (!response || response.error) {
                const detail = (response && response.error)
                    ? (response.error.message || JSON.stringify(response.error))
                    : Tr.t("no answer from the plugin manager");
                engine._setError(key, Tr.t("The plugin was not updated"), detail);
                engine.failedCount++;
            } else {
                engine._setItem(key, {
                    status: "done",
                    fraction: 1,
                    detail: ""
                });
                engine.completedCount++;
                engine._pluginsDone++;
            }
            engine._pluginIndex++;
            engine._updateNextPlugin();
        });
    }

    function _afterPlugins() {
        currentItem = "";
        if (_wantShell && !_shellDone) {
            _startDaemon("shell");
        } else {
            _finish(failedCount > 0 ? "failed" : "done");
        }
    }

    function _startAppimage() {
        phase = "appimage";
        const cmd = [Backend.python, Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--update-ids"];
        for (const ai of _appimageItems)
            cmd.push(ai.id);
        appimageProcess.command = Backend.instrument("appimage", cmd);
        appimageProcess.running = true;
    }

    function _startDaemon(kind) {
        _daemonKind = kind;
        _dnfStage = 0;
        _dnfStageX = 0;
        _dnfStageY = 0;
        _dnfSawUpgrading = false;
        _daemonAttempts = 0;
        _passRequestedAt = Date.now();
        _nudgedBackendCheck = false;
        _helperError = "";
        _helperExitNote = "";
        _sendDaemonUpgrade();
    }

    // ── System pass via rpm_helper.py (libdnf5) ─────────────────────────────
    // The main rpm pass runs through the library helper: real per-package
    // events instead of log scraping, explicit package names instead of an
    // exclude list (dnf pulls dependencies itself). Only the dms/quickshell
    // final pass stays on the daemon — that transaction must survive the
    // shell reload it triggers.
    property string _helperError: ""
    property real _helperPlanBytes: 0
    property real _helperTransferred: 0
    // Verbatim helper output kept for the "what really went wrong" view: the
    // short translated reason on a row is for reading, this is for reporting
    property string _helperStderr: ""
    // How the process ended, for the case where that is the only thing left.
    // A helper killed before it could speak sends no event on stdout and
    // leaves stderr empty, so every row said "the package helper could not
    // start" and its details panel repeated that same sentence and stopped —
    // which is all a reporter could give us (#18). These numbers are not for
    // reading; they are what tells a crash apart from a clean refusal.
    property string _helperExitNote: ""
    property bool _helperSawPlan: false

    // Raw failure text of the last run, per item key, alongside the short
    // reason in itemStates[key].detail. Survives the run so the details
    // popup and the action log can show what the tool actually said.
    property var runErrorDetails: ({})

    function _setError(key, reason, raw) {
        _setItem(key, {
            status: "error",
            detail: reason || Tr.t("failed")
        });
        if (raw && raw !== reason) {
            const updated = Object.assign({}, runErrorDetails);
            updated[key] = raw;
            runErrorDetails = updated;
        }
    }

    Process {
        id: helperProcess

        stdout: SplitParser {
            onRead: line => engine._onHelperEvent(line)
        }

        stderr: StdioCollector {
            onStreamFinished: engine._helperStderr = (text || "").trim()
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running || engine._dnfDone)
                return;
            // A helper that never got as far as a plan did not run a
            // transaction at all — a missing dependency, a refused polkit
            // prompt, a crash. Carry that reason to the rows instead of
            // letting them report a mystery per package.
            if (!engine._helperSawPlan && engine._helperError === "") {
                // A helper that was killed did start, and telling someone it
                // could not sends them looking at their bindings — which is
                // where #18 spent a week, on a machine whose helper ran fine
                // right up to the signal that ended it. QProcess reports that
                // separately from the exit code, so say the true one.
                engine._helperError = exitStatus === 1 ? Tr.t("the package helper crashed")
                    : (exitCode === 126 || exitCode === 127 ? Tr.t("the authorisation was refused")
                       : Tr.t("the package helper could not start"));
                engine._helperExitNote = "helper exited before its plan — exit code " + exitCode + ", exit status " + exitStatus;
            }
            // Success or failure, the rpm database is the arbiter: rows
            // whose target version arrived turn green, the rest carry the
            // helper's error message.
            engine._verifyDaemonPass();
        }
    }

    function _startHelperUpgrade() {
        _daemonKind = "dnf";
        _dnfStage = 0;
        _dnfStageX = 0;
        _dnfStageY = 0;
        _helperError = "";
        _helperStderr = "";
        _helperExitNote = "";
        _helperSawPlan = false;
        _helperPlanBytes = 0;
        _helperTransferred = 0;
        phase = "dnf-download";
        // Known-broken helper: say so once, up front, instead of running a
        // transaction that cannot start and reporting its silence per package
        if (Backend.packageHelperBroken) {
            _helperError = Tr.t("%1 is missing — install it to update system packages").arg(Backend.packageHelperRequirement);
            _helperStderr = Backend.packageHelperError;
            _verifyDaemonPass();
            return;
        }
        helperProcess.command = Backend.instrument("system", Backend.helperCommand("upgrade", Object.keys(_dnfNameToKey)));
        helperProcess.running = true;
    }

    function _onHelperEvent(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (e) {
            return;
        }
        const key = _dnfNameToKey[event.name] || "";
        const state = key ? (itemStates[key] || null) : null;
        switch (event.event) {
        case "plan": {
            _helperSawPlan = true;
            _helperPlanBytes = event.totalDownloadBytes || 0;
            _dnfStage = 1;
            _dnfStageY = 100;
            _dnfStageX = 0;
            break;
        }
        case "op-start": {
            if (!key)
                break;
            currentItem = event.name;
            if (event.phase === "install" || event.phase === "remove") {
                if (_dnfStage !== 2) {
                    _dnfStage = 2;
                    phase = "dnf-install";
                }
                _dnfStageY = event.total || _dnfStageY;
                _dnfStageX = Math.max(0, (event.index || 1) - 1);
                _setItem(key, {
                    status: "active",
                    fraction: Math.max(state ? state.fraction : 0, 0.7),
                    detail: Tr.t("installing")
                });
            } else {
                _setItem(key, {
                    status: "active",
                    detail: Tr.t("downloading")
                });
            }
            break;
        }
        case "progress": {
            const part = Math.min(100, event.percent || 0) / 100;
            if (event.totalTransferred !== undefined) {
                _helperTransferred = Math.max(_helperTransferred, event.totalTransferred);
                if (_helperPlanBytes > 0)
                    _dnfStageX = Math.min(100, Math.round(100 * _helperTransferred / _helperPlanBytes));
            }
            if (!key)
                break;
            if (event.phase === "install" || event.phase === "remove") {
                _setItem(key, {
                    status: "active",
                    fraction: 0.7 + 0.3 * part,
                    detail: Tr.t("installing") + " · " + Math.round(part * 100) + "%"
                });
            } else {
                const fraction = 0.7 * part;
                if (!state || state.fraction < fraction) {
                    let detail = Tr.t("downloading") + " · " + Math.round(part * 100) + "%";
                    if ((event.bytesTotal || 0) > 1024 * 1024)
                        detail += " · " + formatBytes(event.bytesTransferred || 0) + " / " + formatBytes(event.bytesTotal);
                    _setItem(key, {
                        status: "active",
                        fraction: fraction,
                        detail: detail
                    });
                }
            }
            _updateOverall();
            break;
        }
        case "op-done": {
            if (event.totalTransferred !== undefined)
                _helperTransferred = Math.max(_helperTransferred, event.totalTransferred);
            if (!key)
                break;
            if (event.phase === "install" || event.phase === "remove") {
                // rpm is finished with this package. It used to stay
                // "active" with a full bar until the verification pass at
                // the very end, so a run of two hundred kept every row in
                // "In progress" — bars all the way to the right, nothing
                // moving to Completed — and then flipped the lot at once.
                // The verification still has the last word and can turn any
                // of these back into an error.
                _setItem(key, {
                    status: "done",
                    fraction: 1,
                    detail: ""
                });
            } else {
                _setItem(key, {
                    status: "active",
                    fraction: Math.max(state ? state.fraction : 0, 0.7),
                    detail: Tr.t("downloaded")
                });
            }
            _updateOverall();
            break;
        }
        case "op-error": {
            _setError(key || _dnfAdopt(event.name || Tr.t("unknown package")), event.message || Tr.t("failed"), event.message || "");
            break;
        }
        case "done": {
            // A nothing-to-do ending means the helper ran fine but resolved
            // no work — that must not read as "could not start"; the
            // per-package verification supplies the honest per-row outcome.
            if (event.nothingToDo === true)
                _helperSawPlan = true;
            break;
        }
        case "error": {
            _helperError = event.message || "";
            break;
        }
        }
    }

    // When this pass was first requested: the polite waits below (running
    // check, streaming log lines) are capped against this so a confused
    // daemon can delay a pass, but never hang it forever.
    property double _passRequestedAt: 0
    property bool _nudgedBackendCheck: false

    // The daemon can silently refuse an upgrade command fired right after
    // the previous pass finished (it is still winding down). Retry with a
    // short delay until it reports upgrading; give up visibly instead of
    // hanging on a phase that never starts.
    property int _daemonAttempts: 0

    function _sendDaemonUpgrade() {
        // Never fire an upgrade into a running check: the daemon kills the
        // dnf child mid-resolve when the two collide (observed as a pass
        // that "completes" without installing anything). The retry timer
        // re-enters here once the check settles — but a check that never
        // settles must not hang the pass forever.
        if (SystemUpdateService.isChecking && Date.now() - _passRequestedAt < 180000) {
            daemonRetryTimer.restart();
            return;
        }
        const kind = _daemonKind;
        // Shell packages sit out the first pass and run in the final one.
        // Either way the pass is told what to leave alone: the daemon's
        // upgrade command is "upgrade everything pending", so an unbounded
        // final pass would quietly install the packages this run did not
        // pick — including any the earlier pass had just reported as failed,
        // with no progress shown for them. The pass may only touch its own
        // packages; everything else pending is ignored.
        let extraIgnored = [];
        if (kind === "shell") {
            phase = "dms";
            extraIgnored = _otherPendingNames(_shellNames);
        } else if (_wantShell) {
            extraIgnored = _shellNames.slice();
        }
        _daemonAttempts++;
        daemonRetryTimer.restart();
        if (extraIgnored.length > 0) {
            DMSService.sysupdateUpgrade({
                includeFlatpak: false,
                ignored: (SettingsData.updaterIgnoredPackages || []).concat(extraIgnored)
            }, null);
        } else {
            SystemUpdateService.runUpdates({
                includeFlatpak: false
            });
        }
    }

    // Pending system packages other than the ones this pass is for — the
    // ignore list that keeps a daemon pass inside its own scope.
    function _otherPendingNames(passNames) {
        const mine = new Set(passNames || []);
        const names = [];
        for (const pkg of pendingUpdates || []) {
            if (pkg.repo === "flatpak" || pkg.repo === "firmware" || pkg.repo === "appimage")
                continue;
            if (!mine.has(pkg.name))
                names.push(pkg.name);
        }
        return names;
    }

    Timer {
        id: daemonRetryTimer
        // Generous on purpose: a re-send while the daemon's dnf child is
        // still refreshing metadata or resolving (easily 5-15s) kills that
        // child mid-run. Only nudge when the daemon has been silent long
        // past any normal resolve time.
        interval: 20000

        onTriggered: {
            if (!engine.running || engine._dnfSawUpgrading || SystemUpdateService.isUpgrading)
                return;
            // The daemon runs its own refresh after an upgrade pass and
            // refuses commands meanwhile — wait it out without burning
            // attempts, but never past the pass cap
            if (SystemUpdateService.isChecking && Date.now() - engine._passRequestedAt < 180000) {
                daemonRetryTimer.restart();
                return;
            }
            // Right after a pass the daemon can reset its state and refuse
            // upgrades with "no backend selected" until a check re-selects
            // it — trigger that check once and wait it out
            if (!engine._nudgedBackendCheck && /no backend/i.test(SystemUpdateService.errorMessage || "")) {
                engine._nudgedBackendCheck = true;
                SystemUpdateService.checkForUpdates();
                daemonRetryTimer.restart();
                return;
            }
            if (engine._daemonAttempts < 6) {
                engine._sendDaemonUpgrade();
                return;
            }
            // Daemon never picked the pass up: fail it visibly, with the why
            const reason = SystemUpdateService.errorMessage || Tr.t("the update service did not start this pass — try again");
            const map = engine._daemonKind === "shell" ? engine._shellNameToKey : engine._dnfNameToKey;
            for (const base in map)
                engine._setError(map[base], reason, SystemUpdateService.errorMessage || "");
            if (engine._daemonKind === "shell") {
                engine._shellDone = true;
                engine.failedCount += engine._shellCount;
                engine._finish("failed");
            } else {
                engine._dnfDone = true;
                engine.failedCount += engine._dnfCount;
                if (engine._wantFlatpak)
                    engine._startFlatpak();
                else if (engine._wantAppimage)
                    engine._startAppimage();
                else if (engine._wantFirmware)
                    engine._startFirmware();
                else if (engine._wantPlugins)
                    engine._startPlugins();
                else
                    engine._finish("failed");
            }
        }
    }

    function _afterFlatpak() {
        if (_wantAppimage) {
            _startAppimage();
        } else if (_wantFirmware) {
            _startFirmware();
        } else {
            _afterFirmware();
        }
    }

    function _startFirmware() {
        phase = "firmware";
        firmwareProcess.command = Backend.instrument("firmware", ["fwupdmgr", "update", "-y", "--no-reboot-check"]);
        firmwareProcess.running = true;
    }

    function cancel() {
        _deferredOpts = null;
        daemonRetryTimer.stop();
        if (!running)
            return;
        // The helper pass runs as root — we cannot signal it, and aborting
        // an rpm transaction midway would be worse than finishing it. Its
        // late exit is ignored via the running guard; only daemon passes
        // can be cancelled for real.
        if (!helperProcess.running && (!_dnfDone || (_daemonKind === "shell" && !_shellDone))) {
            SystemUpdateService.cancelUpdates();
        }
        if (flatpakProcess.running && flatpakProcess.processId > 0) {
            Quickshell.execDetached(["kill", "-TERM", String(flatpakProcess.processId)]);
        }
        if (firmwareProcess.running && firmwareProcess.processId > 0) {
            Quickshell.execDetached(["kill", "-TERM", String(firmwareProcess.processId)]);
        }
        if (appimageProcess.running && appimageProcess.processId > 0) {
            Quickshell.execDetached(["kill", "-TERM", String(appimageProcess.processId)]);
        }
        _finish("cancelled");
    }

    function _startFlatpak() {
        phase = "flatpak";
        const cmd = [Backend.python, Qt.resolvedUrl("scripts/flatpak_helper.py").toString().replace("file://", ""), "update"];
        for (const id of _flatpakIds)
            cmd.push(id);
        flatpakProcess.command = Backend.instrument("flatpak", cmd);
        flatpakProcess.running = true;
    }

    // ── Confirming that the run took ─────────────────────────────────────────
    // A transaction saying "installed" and the package actually being at its
    // new version are two different claims, and the second one is the one
    // worth making. So the run is not over when the last byte lands — it is
    // over when the package database agrees. Until then the finished items
    // wait in "confirming" rather than being declared done, which is what
    // makes the wait visible instead of hiding behind a list already saying
    // Completed.
    //
    // It used to ask the daemon: trigger a fresh check and read its list of
    // pending updates. That answer is authoritative but expensive — the
    // daemon's check is `dnf5 check-update --refresh`, a full revalidation of
    // every repository, seconds of network at the end of every run. Worse, it
    // is a *different* cache from the one the transaction just wrote, so the
    // work is done twice and neither warms the other, and the list it briefly
    // publishes still holds the packages the run is finishing — which is how
    // a completed run could raise "3 updates available" and then have none.
    //
    // rpm answers the same question locally, in milliseconds, from the
    // database the transaction just changed. Firmware takes effect at the next
    // boot and AppImages are not packages; Flatpaks are settled by libflatpak,
    // which reports an operation done only once it is deployed. So this is
    // about system packages, and it asks the system.
    signal verified(int stuck)

    property bool _verifyPending: false

    function _startVerification() {
        const states = Object.assign({}, itemStates);
        const bases = [];
        for (const item of runItems) {
            const state = states[item.key];
            if (!state || state.status !== "done")
                continue;
            if (item.key.indexOf("system/") !== 0)
                continue;
            states[item.key] = Object.assign({}, state, {
                status: "confirming"
            });
            bases.push(_stripArch(item.pkg.name || ""));
        }
        if (bases.length === 0)
            return false;
        itemStates = states;
        _verifyPending = true;
        verifyTimeout.restart();
        verifyLocalProcess.command = Backend.instrument("verify-local", Backend.installedVersionsCommand(bases));
        verifyLocalProcess.running = true;
        return true;
    }

    // `judge` is false when no usable answer arrived — the query failed, or
    // the timeout fired. Reading nothing would accuse every package of not
    // having installed, so saying nothing is the only honest option left.
    function _resolveVerification(judgeIn, text) {
        let judge = judgeIn;
        if (!_verifyPending)
            return;
        verifyTimeout.stop();
        _verifyPending = false;

        const installed = {};
        for (const line of (text || "").split("\n")) {
            const parts = line.split("\t");
            if (parts.length === 2)
                (installed[parts[0].trim()] = installed[parts[0].trim()] || []).push(parts[1].trim());
        }
        // An answer with nothing in it is not an answer. rpm prints a line
        // per installed package and fails when one is missing, so an empty
        // reading means the query itself went wrong — and treating that as
        // "none of them arrived" would paint a whole successful run red.
        if (judge && Object.keys(installed).length === 0)
            judge = false;
        const noEpoch = v => (v || "").replace(/^\d+:/, "");
        // Rows carry the version they were going to; a row that never named
        // one cannot be judged and keeps the transaction's verdict. A newer
        // build than the row named counts as arrived: the list is as old as
        // its check, and the repositories can move on before the run. The
        // kernel went 7.2.11 -> 7.2.13 under a row that said 7.2.12, and all
        // eight of its packages were reported as not updated.
        const wanted = {};
        for (const item of runItems)
            wanted[item.key] = noEpoch(item.pkg.toVersion || "");
        const bases = {};
        for (const item of runItems)
            bases[item.key] = _stripArch(item.pkg.name || "");

        const states = Object.assign({}, itemStates);
        let stuck = 0;
        for (const key in states) {
            if (states[key].status !== "confirming")
                continue;
            const want = wanted[key] || "";
            const arrived = !judge || want === ""
                || (installed[bases[key]] || []).some(evr => Ui.compareVersions(noEpoch(evr), want) >= 0);
            if (!arrived) {
                states[key] = Object.assign({}, states[key], {
                    status: "error",
                    detail: Tr.t("the package was not updated — try again")
                });
                stuck++;
            } else {
                states[key] = Object.assign({}, states[key], {
                    status: "done"
                });
            }
        }
        itemStates = states;
        if (stuck > 0) {
            failedCount += stuck;
            completedCount = Math.max(0, completedCount - stuck);
        }
        // A result panel dismissed while this was running stays dismissed;
        // the answer is not a reason to put it back on screen
        if (phase === "verifying")
            phase = "done";
        verified(stuck);
    }

    // Seconds, not minutes: this is one rpm query against a local database.
    // If that has not answered by now it is not going to, and a run must not
    // hang on the last word of a formality.
    Timer {
        id: verifyTimeout
        interval: 20000
        repeat: false
        onTriggered: engine._resolveVerification(false, "")
    }

    Process {
        id: verifyLocalProcess

        stdout: StdioCollector {
            onStreamFinished: engine._resolveVerification(true, text)
        }

        onExited: (exitCode, exitStatus) => {
            // A query that could not run says nothing about the packages
            if (exitCode !== 0)
                engine._resolveVerification(false, "");
        }
    }

    function _finish(finalPhase) {
        running = false;
        etaTimer.stop();
        cachePollProcess.running = false;
        phase = finalPhase;
        etaSeconds = -1;
        currentItem = "";
        currentDetail = "";
        if (finalPhase === "done" && failedCount === 0)
            overallFraction = 1;
        if (finalPhase === "done" && _startVerification())
            phase = "verifying";
        // Forced: an unforced refresh that finds a check already running only
        // waits for it and takes its answer, and a check that started while
        // the transaction was still running read the database from before it
        // — the list came back offering what had just been installed.
        DMSService.sysupdateRefresh(true, null);
        // Only a run that finished its work says anything useful about how
        // long that work takes; a cancelled one would drag the estimate down
        if (finalPhase !== "cancelled" && _runStartedAt > 0 && plannedCount > 0)
            runMeasured(Math.round((Date.now() - _runStartedAt) / 1000), plannedCount);
        _runStartedAt = 0;
        finished(finalPhase === "done" && failedCount === 0);
    }

    // ── Weighted progress model ──────────────────────────────────────────────
    readonly property real _firmwareWeightTotal: _wantFirmware ? _firmwareItems.length * firmwareItemWeight : 0
    readonly property real _pluginWeightTotal: _wantPlugins ? _pluginItems.length * pluginItemWeight : 0
    // A formula is a bottle of a few megabytes, or a compile of unknown
    // length. The nominal weight is the first of those, because guessing the
    // second would make the bar wrong in both directions.
    readonly property real _brewWeightTotal: _wantBrew ? _brewItems.length * brewItemWeight : 0
    readonly property real _dnfWeightTotal: _wantDnf ? _dnfCount * dnfPkgWeight : 0
    readonly property real _shellWeightTotal: _wantShell ? _shellCount * dnfPkgWeight : 0
    readonly property real _appimageWeightTotal: {
        if (!_wantAppimage)
            return 0;
        let total = 0;
        for (const id in _aiOps)
            total += _aiOps[id].weight;
        return total;
    }

    function _appimageWeightDone() {
        let done = 0;
        for (const id in _aiOps) {
            const op = _aiOps[id];
            done += op.weight * (op.done ? 1 : op.fraction);
        }
        return done;
    }
    readonly property real _flatpakWeightTotal: {
        if (!_wantFlatpak)
            return 0;
        if (_flatpakPlanKnown)
            return Math.max(_flatpakPlannedBytes, _flatpakOpCount * 1024 * 1024);
        const guess = _flatpakIds.length > 0 ? _flatpakIds.length : (pendingUpdates || []).filter(p => p.repo === "flatpak").length;
        return Math.max(1, guess) * flatpakFallbackOpWeight;
    }

    function _stageFractionNow() {
        if (_dnfStage === 0 || _dnfStageY === 0)
            return 0;
        const stageFraction = Math.min(1, _dnfStageX / _dnfStageY);
        if (_dnfStage === 1)
            return dnfDownloadShare * stageFraction;
        return dnfDownloadShare + (1 - dnfDownloadShare) * stageFraction;
    }

    function _dnfFractionNow() {
        if (!_wantDnf)
            return 0;
        if (_dnfDone)
            return 1;
        return _daemonKind === "dnf" ? _stageFractionNow() : 0;
    }

    function _shellFractionNow() {
        if (!_wantShell)
            return 0;
        if (_shellDone)
            return 1;
        return _daemonKind === "shell" ? _stageFractionNow() : 0;
    }

    function _flatpakWeightDone() {
        let done = 0;
        for (const ref in _flatpakOps) {
            const op = _flatpakOps[ref];
            done += op.weight * (op.done ? 1 : op.fraction);
        }
        return done;
    }

    function _updateOverall() {
        const total = _dnfWeightTotal + _flatpakWeightTotal + _firmwareWeightTotal + _shellWeightTotal + _appimageWeightTotal + _pluginWeightTotal + _brewWeightTotal;
        if (total <= 0)
            return;
        const fbDone = _flatpakWeightDone();
        flatpakBytesDone = fbDone;
        let doneOps = 0, totalOps = 0;
        for (const ref in _flatpakOps) {
            totalOps++;
            if (_flatpakOps[ref].done)
                doneOps++;
        }
        opsDone = doneOps;
        opsTotal = totalOps;
        const done = _dnfFractionNow() * _dnfWeightTotal + fbDone + _firmwareFraction * _firmwareWeightTotal + _shellFractionNow() * _shellWeightTotal + _appimageWeightDone() + _pluginsDone * pluginItemWeight + _brewDone * brewItemWeight;
        overallFraction = Math.min(running ? 0.995 : 1, done / total);
    }

    property real _lastFlatpakBytes: 0

    Timer {
        id: etaTimer
        interval: 1000
        repeat: true
        onTriggered: {
            engine._elapsedSeconds++;
            const fbDelta = Math.max(0, engine.flatpakBytesDone - engine._lastFlatpakBytes);
            engine._lastFlatpakBytes = engine.flatpakBytesDone;
            engine.flatpakSpeed = engine.flatpakSpeed <= 0 ? fbDelta : (0.8 * engine.flatpakSpeed + 0.2 * fbDelta);
            const total = engine._dnfWeightTotal + engine._flatpakWeightTotal + engine._firmwareWeightTotal + engine._shellWeightTotal + engine._appimageWeightTotal;
            const done = engine._dnfFractionNow() * engine._dnfWeightTotal + engine._flatpakWeightDone() + engine._firmwareFraction * engine._firmwareWeightTotal + engine._shellFractionNow() * engine._shellWeightTotal + engine._appimageWeightDone();
            const delta = Math.max(0, done - engine._lastWeightDone);
            engine._lastWeightDone = done;
            engine._rate = engine._rate <= 0 ? delta : (0.85 * engine._rate + 0.15 * delta);
            if (engine._elapsedSeconds >= 5 && engine._rate > total * 0.00005) {
                engine.etaSeconds = Math.round((total - done) / engine._rate);
            } else if (engine._elapsedSeconds > 30 && engine._rate <= 0) {
                engine.etaSeconds = -1;
            }
            engine._updateOverall();
        }
    }

    // ── DNF via the DMS daemon ───────────────────────────────────────────────
    Connections {
        target: SystemUpdateService
        enabled: engine.running && (!engine._dnfDone || !engine._shellDone)

        function onIsUpgradingChanged() {
            if (SystemUpdateService.isUpgrading) {
                engine._dnfSawUpgrading = true;
                daemonRetryTimer.stop();
                if (engine.phase === "starting")
                    engine.phase = "dnf-download";
                return;
            }
            if (!engine._dnfSawUpgrading)
                return;
            // Daemon finished this upgrade pass. On a reported error, fail
            // everything with the reason; on reported success don't take
            // its word for it — a killed or no-op dnf child also exits
            // cleanly. Verify against the rpm database which packages
            // actually reached their target version.
            if (SystemUpdateService.hasError) {
                const map = engine._daemonKind === "shell" ? engine._shellNameToKey : engine._dnfNameToKey;
                for (const base in map)
                    engine._setError(map[base], SystemUpdateService.errorMessage || Tr.t("failed"), SystemUpdateService.errorMessage || "");
                engine._daemonPassDone(0, engine._daemonKind === "shell" ? engine._shellCount : engine._dnfCount);
            } else {
                engine._verifyDaemonPass();
            }
        }

        function onRecentLogChanged() {
            // Streaming log lines prove the daemon is working on this pass
            // even while isUpgrading is still false (metadata refresh and
            // dependency resolution). Re-sending the upgrade command then
            // makes the daemon kill its dnf child mid-resolve — push the
            // retry out while output keeps flowing, but only briefly: the
            // rolling log also carries unrelated trailing output from a
            // previous pass, which must not silence the retry forever.
            if (daemonRetryTimer.running && Date.now() - engine._passRequestedAt < 45000)
                daemonRetryTimer.restart();
            engine._parseDnfLog();
        }
    }

    // ── Post-pass verification ──────────────────────────────────────────────
    Process {
        id: verifyProcess

        stdout: StdioCollector {
            onStreamFinished: engine._applyDaemonVerify(text)
        }
    }

    function _verifyDaemonPass() {
        const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
        const names = Object.keys(map);
        if (names.length === 0) {
            _daemonPassDone(0, 0);
            return;
        }
        verifyProcess.command = Backend.instrument("verify", Backend.installedVersionsCommand(names));
        verifyProcess.running = true;
    }

    function _applyDaemonVerify(text) {
        if (!running)
            return;
        const installed = {};
        for (const line of (text || "").split("\n")) {
            const parts = line.split("\t");
            if (parts.length === 2)
                (installed[parts[0].trim()] = installed[parts[0].trim()] || []).push(parts[1].trim());
        }
        const noEpoch = v => (v || "").replace(/^\d+:/, "");
        const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
        // Verbatim material for the details panel, most specific first: what
        // the tool printed, then how its process ended, then the daemon's
        // rolling log. The middle one exists because the first two used to be
        // empty together, leaving the panel with nothing but the row's own
        // sentence — the whole of what a report could then carry (#18).
        const rawDetail = [_helperStderr, _helperExitNote].filter(s => s !== "").join("\n")
            || _helperError
            || (SystemUpdateService.recentLog || []).slice(-40).join("\n").trim();
        let okCount = 0;
        let failCount = 0;
        for (const base in map) {
            const want = noEpoch(_daemonExpectedEvr[base] || "");
            const have = installed[base] || [];
            // A devel row names no version to arrive at, only that upstream
            // has a newer commit. What can still be checked is that a new
            // build replaced the old one: a version other than the one the
            // pass started from. Unknown target otherwise: nothing to compare
            // against, keep the daemon's success verdict for this row.
            let arrived;
            if (want === Ui.develTarget) {
                const was = noEpoch(_daemonPreviousEvr[base] || "");
                arrived = have.some(evr => noEpoch(evr) !== was);
            } else {
                arrived = want === "" || have.some(evr => Ui.compareVersions(noEpoch(evr), want) >= 0);
            }
            if (arrived) {
                okCount++;
                _setItem(map[base], {
                    status: "done",
                    fraction: 1,
                    detail: "",
                    // What a devel row turned out to be, for the log
                    landed: want === Ui.develTarget ? noEpoch(have[0]) : ""
                });
            } else {
                failCount++;
                // A pass the daemon reported as clean, with the package not
                // there: it has no error to hand over, which is why this row
                // used to open onto an empty details panel. Its own output is
                // still in the rolling log, and that is the only place the
                // reason can be — a dnf that resolved to nothing, a key it
                // wanted importing, a child that was killed mid-transaction.
                //
                // A window rather than a transcript, so it can hold lines from
                // an earlier pass. It is offered as what the update service
                // last said, which is what the details panel is for, and it
                // beats the nothing that was there before.
                _setError(map[base], _helperError || Tr.t("the package was not updated — try again"), rawDetail);
            }
        }
        _daemonPassDone(okCount, failCount);
    }

    function _daemonPassDone(okCount, failCount) {
        completedCount += okCount;
        failedCount += failCount;
        if (_daemonKind === "shell") {
            _shellDone = true;
            _finish(failedCount > 0 ? "failed" : "done");
            return;
        }
        _dnfDone = true;
        if (_wantFlatpak) {
            _startFlatpak();
        } else if (_wantAppimage) {
            _startAppimage();
        } else if (_wantFirmware) {
            _startFirmware();
        } else {
            _afterFirmware();
        }
    }

    // ── Live download bytes from the dnf cache ──────────────────────────────
    // dnf5's piped output only prints a line when a package finishes
    // downloading, so the log cannot show progress inside a package. The
    // daemon downloads into the world-readable dnf cache though: during the
    // download stage the growing .rpm files there give real per-package
    // bytes. Only fresh files count (-mmin -1) so leftovers from earlier
    // runs don't masquerade as progress. dnf 4 (RHEL and its rebuilds)
    // keeps its cache under /var/cache/dnf instead.
    Process {
        id: cachePollProcess

        command: ["sh", "-c", "while true; do find /var/cache/libdnf5 /var/cache/dnf -name '*.rpm' -mmin -1 -printf '%f\\t%s\\t%T@\\n' 2>/dev/null; echo ---; sleep 1; done"]

        stdout: SplitParser {
            onRead: line => engine._onCachePollLine(line)
        }
    }

    property var _cacheBatch: []

    function _onCachePollLine(line) {
        if (line.trim() === "---") {
            const batch = _cacheBatch;
            _cacheBatch = [];
            _applyCacheBatch(batch);
            return;
        }
        const parts = line.split("\t");
        if (parts.length === 3)
            _cacheBatch.push({
                file: parts[0],
                bytes: parseInt(parts[1], 10) || 0,
                mtime: parseFloat(parts[2]) || 0
            });
    }

    function _applyCacheBatch(batch) {
        if (!running || _dnfStage !== 1)
            return;
        const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
        // Newest matching file per package: the cache can hold several
        // versions of the same rpm, only the growing one is the download.
        const newest = {};
        for (const entry of batch) {
            let base = "";
            for (const b in map) {
                if (b.length > base.length && entry.file.indexOf(b + "-") === 0)
                    base = b;
            }
            if (base && (!newest[base] || entry.mtime > newest[base].mtime))
                newest[base] = entry;
        }
        for (const base in newest) {
            const key = map[base];
            const size = (packageSizes || {})[base] || 0;
            if (!key || size <= 0)
                continue;
            const state = itemStates[key];
            if (state && state.status !== "pending" && state.status !== "active")
                continue;
            const pct = Math.min(1, newest[base].bytes / size);
            const fraction = 0.7 * pct;
            if (state && state.fraction >= fraction)
                continue;
            let detail = Tr.t("downloading") + " · " + Math.round(pct * 100) + "%";
            if (size > 1024 * 1024)
                detail += " · " + formatBytes(Math.min(newest[base].bytes, size)) + " / " + formatBytes(size);
            _setItem(key, {
                status: "active",
                fraction: fraction,
                detail: detail
            });
        }
    }

    // Rows whose download completed would keep saying "downloading · 100%"
    // through the silent transaction-test minutes; relabel them once the
    // install stage starts.
    function _markDownloadedRows() {
        for (const key in itemStates) {
            const st = itemStates[key];
            if (st && st.status === "active" && (st.detail || "").indexOf(Tr.t("downloading")) === 0)
                _setItem(key, {
                    detail: Tr.t("downloaded")
                });
        }
    }

    function _parseDnfLog() {
        // The daemon log only drives daemon passes; during the helper pass
        // stray daemon output (its periodic check) must not touch the
        // stage model or phase.
        if (helperProcess.running)
            return;
        const log = SystemUpdateService.recentLog || [];
        // The daemon keeps a rolling window; only look at fresh lines.
        const bracketRe = /\[\s*(\d+)\s*\/\s*(\d+)\s*\]\s*(.*)/;
        for (const line of log.slice(-30)) {
            const match = bracketRe.exec(line);
            if (!match)
                continue;
            const x = parseInt(match[1], 10);
            const y = parseInt(match[2], 10);
            const rest = (match[3] || "").trim();
            if (y <= 0)
                continue;
            if (_dnfStage === 0) {
                _dnfStage = 1;
                _dnfStageY = y;
                if (_daemonKind !== "shell")
                    phase = "dnf-download";
                _cacheBatch = [];
                cachePollProcess.running = true;
            } else if (y !== _dnfStageY && _dnfStage === 1 && _dnfStageX >= Math.max(1, _dnfStageY - 1)) {
                // Step total changed after the download series completed → transaction stage
                _dnfStage = 2;
                _dnfStageY = y;
                if (_daemonKind !== "shell")
                    phase = "dnf-install";
                cachePollProcess.running = false;
                _markDownloadedRows();
            } else if (y !== _dnfStageY) {
                _dnfStageY = y;
            }
            if (x >= _dnfStageX || y !== _dnfStageY) {
                _dnfStageX = Math.min(x, y);
            }
            // Try to map the step line to a package for per-item status
            const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
            const base = _dnfMatchPackage(rest, map);
            if (base) {
                const key = map[base];
                if (currentItem !== base) {
                    currentItem = base;
                }
                currentDetail = _dnfStage === 1 ? Tr.t("downloading") : Tr.t("installing");
                if (key) {
                    // dnf5 step lines carry this item's own percent; map the
                    // row bar to the package's full journey: download fills
                    // 0–70%, the transaction step 70–100%. Lines without a
                    // percent (scriptlets, verify) keep a mid-stage estimate.
                    const pctMatch = /(\d{1,3})\s*%/.exec(rest);
                    const pct = pctMatch ? Math.min(100, parseInt(pctMatch[1], 10)) / 100 : -1;
                    let fraction = _dnfStage === 1 ? (pct >= 0 ? 0.7 * pct : 0.3) : (pct >= 0 ? 0.7 + 0.3 * pct : 0.8);
                    // recentLog is a rolling window that gets rescanned, so
                    // older lines reappear — never move a bar backwards, and
                    // never take a finished row back into progress
                    const prev = itemStates[key];
                    if (prev && (prev.status === "done" || prev.status === "error"))
                        continue;
                    if (prev && prev.fraction > fraction)
                        fraction = prev.fraction;
                    let detail = currentDetail;
                    const size = (packageSizes || {})[base] || 0;
                    if (_dnfStage === 1 && pct >= 1) {
                        // A stage-1 log line only prints when that package's
                        // download completed — say so instead of leaving a
                        // "downloading · 100%" that sits through the wait.
                        detail = Tr.t("downloaded") + (size > 1024 * 1024 ? " · " + formatBytes(size) : "");
                    } else if (pct >= 0) {
                        detail += " · " + Math.round(pct * 100) + "%";
                        // Byte detail like the flatpak rows: repoquery gave the
                        // exact download size, the percent gives the progress.
                        if (_dnfStage === 1 && size > 1024 * 1024)
                            detail += " · " + formatBytes(size * pct) + " / " + formatBytes(size);
                    }
                    // A stage-2 line at 100% is this package's own
                    // transaction step finishing — the same evidence that
                    // fills its bar, so the row belongs in Completed from
                    // here rather than at the end of the whole run
                    _setItem(key, {
                        status: (_dnfStage === 2 && pct >= 1) ? "done" : "active",
                        fraction: fraction,
                        detail: detail
                    });
                }
            }
        }
        _updateOverall();
    }

    function _dnfMatchPackage(text, map) {
        // Prefer the longest matching name: with subpackage families in the
        // run ("abrt" next to "abrt-addon-ccpp") the short base also occurs
        // in the long package's lines, which would drive the wrong row.
        let best = "";
        for (const base in map) {
            if (base.length > best.length && text.indexOf(base) !== -1)
                best = base;
        }
        return best;
    }

    // ── Flatpak via libflatpak helper ────────────────────────────────────────
    Process {
        id: flatpakProcess

        stdout: SplitParser {
            onRead: line => engine._onFlatpakEvent(line)
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            if (exitCode !== 0 && exitCode !== 130) {
                // Not a package's failure but the step's, which used to raise
                // the counter and show nothing at all
                engine.failedCount++;
                engine._setError(engine._flatpakAdopt(Tr.t("Flatpak updates")), engine._flatpakRunError || Tr.t("the Flatpak helper stopped with code %1").arg(exitCode), engine._flatpakRunError || "");
            }
            engine._afterFlatpak();
        }
    }

    // ── AppImages via scripts/appimage.py ────────────────────────────────────
    Process {
        id: appimageProcess

        stdout: SplitParser {
            onRead: line => engine._onAppimageEvent(line)
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            // Mark anything the helper never reported on as failed
            for (const ai of engine._appimageItems) {
                const state = engine.itemStates["appimage/" + ai.id];
                if (state && state.status !== "done" && state.status !== "error") {
                    engine._setItem("appimage/" + ai.id, {
                        status: "error",
                        detail: Tr.t("failed")
                    });
                    engine.failedCount++;
                }
            }
            engine._afterAppimage();
        }
    }

    function _onAppimageEvent(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (e) {
            return;
        }
        switch (event.event) {
        case "ai-start": {
            _aiCurrentId = event.id;
            _appimageDownloading = true;
            currentItem = event.name || event.id;
            _setItem("appimage/" + event.id, {
                status: "active",
                detail: Tr.t("downloading")
            });
            break;
        }
        case "progress": {
            if (_aiCurrentId === "" || phase !== "appimage")
                return;
            const ops = _aiOps;
            if (ops[_aiCurrentId])
                ops[_aiCurrentId].fraction = Math.min(1, (event.percent || 0) / 100);
            _appimageDownloading = (event.percent || 0) < 100;
            currentDetail = (event.percent || 0) + "%";
            _setItem("appimage/" + _aiCurrentId, {
                status: "active",
                fraction: Math.min(1, (event.percent || 0) / 100),
                detail: (event.percent || 0) + "%" + (event.total > 0 ? " · " + formatBytes(event.bytes || 0) + " / " + formatBytes(event.total) : "")
            });
            _updateOverall();
            break;
        }
        case "ai-done": {
            const ops = _aiOps;
            if (ops[event.id]) {
                ops[event.id].done = true;
                ops[event.id].fraction = 1;
            }
            if (event.ok === true) {
                completedCount++;
                _setItem("appimage/" + event.id, {
                    status: "done",
                    fraction: 1,
                    detail: ""
                });
            } else {
                failedCount++;
                _setError("appimage/" + event.id, event.message || Tr.t("failed"), event.message || "");
            }
            _updateOverall();
            break;
        }
        }
    }

    // ── Firmware via fwupdmgr ────────────────────────────────────────────────
    Process {
        id: firmwareProcess

        property string _stderr: ""

        stdout: SplitParser {
            onRead: line => engine._onFirmwareLine(line)
        }

        stderr: StdioCollector {
            onStreamFinished: firmwareProcess._stderr = (text || "").trim()
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            const ok = exitCode === 0 || exitCode === 2;
            for (const fw of engine._firmwareItems) {
                if (ok)
                    engine._setItem("firmware/" + fw.name, {
                        status: "done",
                        fraction: 1,
                        detail: ""
                    });
                else
                    engine._setError("firmware/" + fw.name, Tr.t("fwupdmgr exit %1").arg(exitCode), firmwareProcess._stderr);
            }
            if (ok) {
                engine.completedCount += engine._firmwareItems.length;
                engine._firmwareFraction = 1;
            } else {
                engine.failedCount += engine._firmwareItems.length;
            }
            engine._afterFirmware();
        }
    }

    function _onFirmwareLine(line) {
        // Match the current device by name and track coarse percent progress
        for (const fw of _firmwareItems) {
            if (fw.name && line.indexOf(fw.name) !== -1) {
                currentItem = fw.name;
                _setItem("firmware/" + fw.name, {
                    status: "active",
                    detail: Tr.t("updating")
                });
            }
        }
        const percentMatch = /(\d{1,3})\s*%/.exec(line);
        if (percentMatch) {
            const pct = Math.min(100, parseInt(percentMatch[1], 10)) / 100;
            const total = Math.max(1, _firmwareItems.length);
            if (pct < _firmwareFraction * total - _firmwareDone && _firmwareDone < total - 1) {
                _firmwareDone++;
            }
            _firmwareFraction = Math.min(1, (_firmwareDone + pct) / total);
            if (currentItem) {
                _setItem("firmware/" + currentItem, {
                    status: "active",
                    fraction: pct,
                    detail: percentMatch[1] + "%"
                });
            }
            _updateOverall();
        }
    }

    // A transaction touches refs the pending list never mentioned: extensions,
    // themes, drivers, runtimes pulled along. While they succeed that is
    // nobody's business, but a failure among them used to raise the failed
    // counter and then vanish — no row, no reason, no log entry, and a run
    // that said "1 failed" while every line it showed was green. So a failure
    // without a row gets one.
    // The helper's own words for a transaction-level failure
    property string _flatpakRunError: ""

    // Same for the system helper: it can fail on a package the pending list
    // never showed — a dependency the resolver pulled in
    function _dnfAdopt(name) {
        const key = "system/" + name;
        if (itemStates[key] === undefined) {
            const items = runItems.slice();
            items.push({
                pkg: {
                    name: name,
                    repo: "system"
                },
                key: key
            });
            runItems = items;
        }
        return key;
    }

    function _flatpakAdopt(appid) {
        const key = "flatpak/" + appid;
        if (itemStates[key] === undefined) {
            const items = runItems.slice();
            items.push({
                pkg: {
                    name: appid,
                    repo: "flatpak"
                },
                key: key
            });
            runItems = items;
        }
        return key;
    }

    function _flatpakKeyFor(appid) {
        if (itemStates["flatpak/" + appid] !== undefined)
            return "flatpak/" + appid;
        // Extensions (org.x.App.Locale) roll up into their base app row if
        // the extension itself is not listed separately.
        const parts = appid.split(".");
        while (parts.length > 2) {
            parts.pop();
            const candidate = "flatpak/" + parts.join(".");
            if (itemStates[candidate] !== undefined)
                return candidate;
        }
        return "";
    }

    function _onFlatpakEvent(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (e) {
            return;
        }
        switch (event.event) {
        case "plan": {
            const ops = Object.assign({}, _flatpakOps);
            for (const op of event.ops || []) {
                ops[op.ref] = {
                    appid: op.appid,
                    weight: Math.max(op.downloadBytes || 0, 1024 * 1024),
                    fraction: 0,
                    done: false,
                    installing: false
                };
            }
            _flatpakOps = ops;
            _flatpakOpCount = Object.keys(ops).length;
            let total = 0;
            for (const ref in ops)
                total += ops[ref].weight;
            _flatpakPlannedBytes = total;
            _flatpakPlanKnown = true;
            break;
        }
        case "op-start": {
            currentItem = event.appid;
            const key = _flatpakKeyFor(event.appid);
            if (key)
                _setItem(key, {
                    status: "active",
                    detail: Tr.t("starting")
                });
            break;
        }
        case "progress": {
            const ops = _flatpakOps;
            if (ops[event.ref]) {
                ops[event.ref].fraction = Math.min(1, (event.percent || 0) / 100);
            }
            const isInstallPhase = (event.status || "").toLowerCase().indexOf("install") !== -1 || (event.status || "").toLowerCase().indexOf("deploy") !== -1;
            if (ops[event.ref])
                ops[event.ref].installing = isInstallPhase;
            _recomputeFlatpakStage();
            currentItem = event.appid;
            currentDetail = (event.percent || 0) + "%";
            const key = _flatpakKeyFor(event.appid);
            if (key) {
                _setItem(key, {
                    status: "active",
                    fraction: Math.min(1, (event.percent || 0) / 100),
                    detail: (event.percent || 0) + "%" + (ops[event.ref] && ops[event.ref].weight > 2 * 1024 * 1024 ? " · " + formatBytes(event.bytesTransferred || 0) + " / " + formatBytes(ops[event.ref].weight) : "")
                });
            }
            _updateOverall();
            break;
        }
        case "op-done": {
            const ops = _flatpakOps;
            if (ops[event.ref]) {
                ops[event.ref].done = true;
                ops[event.ref].fraction = 1;
            }
            // One finishing can be the moment the last download ends, and the
            // stage is a statement about all of them
            _recomputeFlatpakStage();
            const key = _flatpakKeyFor(event.appid);
            if (key) {
                // Only mark the row done when all ops mapping to it are done
                let allDone = true;
                for (const ref in ops) {
                    if (_flatpakKeyFor(ops[ref].appid) === key && !ops[ref].done)
                        allDone = false;
                }
                if (allDone) {
                    _setItem(key, {
                        status: "done",
                        fraction: 1,
                        detail: ""
                    });
                    completedCount++;
                }
            }
            _updateOverall();
            break;
        }
        case "error": {
            _flatpakRunError = event.message || "";
            break;
        }
        case "op-error": {
            failedCount++;
            const key = _flatpakKeyFor(event.appid) || _flatpakAdopt(event.appid);
            _setError(key, event.message || Tr.t("failed"), event.message || "");
            // It is not coming down any more either way
            if (_flatpakOps[event.ref])
                _flatpakOps[event.ref].done = true;
            _recomputeFlatpakStage();
            break;
        }
        case "done": {
            // A transaction can fail as a whole — the helper then names the
            // installation it was for, which is no package and would otherwise
            // be counted without ever being shown
            for (const name of event.failed || []) {
                const key = _flatpakKeyFor(name);
                if (key === "" && itemStates["flatpak/" + name] === undefined) {
                    failedCount++;
                    _setError(_flatpakAdopt(name), _flatpakRunError || Tr.t("failed"), _flatpakRunError || "");
                }
            }
            // Final exit handling happens in onExited
            break;
        }
        }
    }
}
