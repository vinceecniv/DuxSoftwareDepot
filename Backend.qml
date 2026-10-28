pragma Singleton
import QtQuick
import Quickshell.Io
import qs.Services

// The package-backend seam: every entry point that is specific to the
// system package manager, in one place. The transaction helpers speak the
// protocol in PROTOCOL.md; which one runs is decided by the detected
// distro family. The metadata layer (search, sizes, changelogs, holds,
// dashboard) is still dnf/Fedora-specific — see PROTOCOL.md's porting
// inventory.
Item {
    id: backend

    // "dnf" (Fedora/RHEL family, default), "apt" (Debian/Ubuntu family),
    // "pacman" (Arch family) or "ostree" (an atomic Fedora: Silverblue,
    // Kinoite, Bazzite, Bluefin — rpm packages, but no rpm transactions)
    property string backendId: "dnf"

    // An atomic system is not a mutable one with a read-only /usr. Nothing
    // installs into the running system; rpm-ostree writes the next boot, and
    // several things below are different because of it rather than despite it.
    readonly property bool atomic: backendId === "ostree"

    // The interpreter every helper runs under.
    //
    // Not the bare name: `pkexec python3 …` resolves python3 through PATH, and
    // on a machine with Homebrew (or pyenv, or conda) first on PATH that means
    // running a user-writable interpreter as root — reported in issue #3,
    // where the polkit prompt read /home/linuxbrew/.linuxbrew/bin/python3.
    // Unprivileged calls gain from it too: the distro's bindings live in the
    // system interpreter, so starting there saves the helpers a hand-over.
    property string python: "python3"

    Process {
        running: true
        command: ["sh", "-c", "for p in /usr/bin/python3 /bin/python3 /usr/local/bin/python3; do [ -x \"$p\" ] && { printf %s \"$p\"; exit 0; }; done; command -v python3"]

        stdout: StdioCollector {
            onStreamFinished: {
                const found = (text || "").trim();
                if (found !== "")
                    backend.python = found;
            }
        }
    }

    // Transaction helper implementing the NDJSON event protocol
    readonly property string packageHelper: Qt.resolvedUrl("scripts/" + (backendId === "apt" ? "apt_helper.py" : (backendId === "pacman" ? "pacman_helper.py" : (atomic ? "ostree_helper.py" : "rpm_helper.py")))).toString().replace("file://", "")

    // ── How a privileged command is authorised ──────────────────────────────
    // pkexec by default: it asks polkit, the DMS agent draws the prompt, and
    // it is the only route that needs nothing configured beforehand.
    //
    // Reported as #14: a machine where sudo has been made passwordless is
    // asked for a password anyway. It is not a bug so much as two
    // authorisation systems — a NOPASSWD line is a rule in sudoers, and
    // pkexec asks polkit, which has never heard of it. The other direction —
    // shipping a polkit rule for this plugin — is not something to offer: the
    // helper such a rule would exempt lives under the user's own config
    // directory, and a password-free root path to a file the user can rewrite
    // is a back door rather than a setting. Sudoers is a decision this user
    // has already made, in a file only root can write, so this defers to that
    // one instead of inventing a second.
    property bool useSudo: PluginService.loadPluginData("dankSoftwareDepot", "useSudo", false) === true

    Connections {
        target: PluginService

        function onPluginDataChanged(pluginId) {
            if (pluginId !== "dankSoftwareDepot")
                return;
            backend.useSudo = PluginService.loadPluginData("dankSoftwareDepot", "useSudo", false) === true;
            backend.simMode = PluginService.loadPluginData("dankSoftwareDepot", "simMode", "");
            backend.simRecording = PluginService.loadPluginData("dankSoftwareDepot", "simRecording", "");
            backend.simSpeed = PluginService.loadPluginData("dankSoftwareDepot", "simSpeed", 1);
        }
    }

    // Whether sudo will answer without asking is decided inside the command
    // itself, a moment before it runs, rather than by a probe here whose
    // answer would already be minutes old. Two things make that necessary:
    //
    // `-n` is not optional. These helpers run without a terminal, so a sudo
    // that decides to ask for a password has nowhere to ask and the run hangs
    // with nothing on screen. With -n it refuses instead, and the refusal is
    // something the command can act on.
    //
    // And the fall-back is gated on a separate `sudo -n true`, not on the
    // exit code of the run: a transaction that failed on its own merits must
    // never be quietly run a second time under pkexec. So the shell asks
    // whether sudo would answer, and hands the whole thing to pkexec when it
    // would not — a machine with narrow sudoers rules, or no sudo at all,
    // ends up exactly where it is today. `exec` either way, so the exit code
    // the callers read is still pkexec's own 126/127 for a refused prompt.
    function privileged(words) {
        if (!useSudo)
            return ["pkexec"].concat(words);
        return ["sh", "-c", "if sudo -n true 2>/dev/null; then exec sudo -n \"$@\"; fi; exec pkexec \"$@\"", "sh"].concat(words);
    }

    // ── Recording a run, and playing it back ────────────────────────────────
    // Nothing the updater window draws comes from the system directly: every
    // phase, row, byte counter and error arrives as NDJSON on some helper's
    // stdout. So a recording of those streams is a recording of everything
    // the window can show, and playing one back puts the whole interface
    // through a real run without root, without a network, and without
    // waiting for a distribution to ship thirty-one updates.
    //
    // Which is what this is for. The visual side of a run could only be
    // worked on when there happened to be something to install, and then
    // only once, because installing it is what makes it stop being pending.
    //
    // The seam is one function: every process the run starts asks
    // instrument() for its command, and gets back either the real one, the
    // real one wrapped in a recorder, or the player reading a recording. The
    // engine above it cannot tell which, and that is the whole design — a
    // simulation that took a different path through the engine would be a
    // simulation of a different program.
    readonly property string simulateHelper: Qt.resolvedUrl("scripts/simulate.py").toString().replace("file://", "")
    readonly property string recordingsRoot: Qt.resolvedUrl("recordings").toString().replace("file://", "")

    // "" (off), "record" (wrap the next run) or "replay" (play simRecording)
    property string simMode: PluginService.loadPluginData("dankSoftwareDepot", "simMode", "")
    property string simRecording: PluginService.loadPluginData("dankSoftwareDepot", "simRecording", "")
    property real simSpeed: PluginService.loadPluginData("dankSoftwareDepot", "simSpeed", 1)

    readonly property bool recording: simMode === "record"
    readonly property bool replaying: simMode === "replay" && simRecording !== ""

    // Only on a working copy. The plugin directory being a symlink is the
    // same test the self-update check makes before refusing to update itself,
    // and it is the honest definition of "this machine is where the plugin is
    // written" — nobody who installed it normally has any use for a recorder.
    property bool developmentInstall: false

    Process {
        running: true
        // ~/.config/dms since Dux Shell 2.0, ~/.config/DankMaterialShell before
        command: ["sh", "-c", "[ -L \"$HOME/.config/dms/plugins/dankSoftwareDepot\" ] || [ -L \"$HOME/.config/DankMaterialShell/plugins/dankSoftwareDepot\" ] && echo yes || echo no"]

        stdout: StdioCollector {
            onStreamFinished: backend.developmentInstall = (text || "").trim() === "yes"
        }
    }

    // Which recording a run is being written into, "" between runs. Kept
    // apart from simRecording — the one picked for playback — because they
    // are different questions, and conflating them meant the plan preview
    // that runs whenever the window opens appended itself to whichever
    // recording happened to be selected. A finished recording is finished.
    property string activeRecording: ""

    function instrument(tag, command) {
        if (recording && activeRecording !== "")
            return [python, simulateHelper, "record", recordingsRoot + "/" + activeRecording, tag, "--"].concat(command);
        if (replaying)
            return [python, simulateHelper, "play", recordingsRoot + "/" + simRecording, tag, "--speed", String(simSpeed)];
        return command;
    }

    // Named for when it was taken, because that is the only thing that tells
    // two recordings of the same machine apart.
    function beginRecording(payload) {
        const now = new Date();
        const pad = n => (n < 10 ? "0" : "") + n;
        activeRecording = "run-" + now.getFullYear() + pad(now.getMonth() + 1) + pad(now.getDate())
            + "-" + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
        beginProcess.command = [python, simulateHelper, "begin", recordingsRoot, activeRecording, payload];
        beginProcess.running = true;
    }

    // One run per arming. Recording every run from here on would fill the
    // disk with the same thing, and the switch says "the next run".
    function finishRecording() {
        if (activeRecording === "")
            return;
        PluginService.savePluginData("dankSoftwareDepot", "simRecording", activeRecording);
        PluginService.savePluginData("dankSoftwareDepot", "simMode", "");
        activeRecording = "";
        refreshRecordings();
    }

    Process {
        id: beginProcess
    }

    // What was pending when the recording was taken. The list the daemon
    // would normally supply is not available afterwards — the packages have
    // been installed — so it travels with the recording.
    property var simPackages: []
    property var simMeta: ({})

    onSimRecordingChanged: _loadSimMeta()
    onSimModeChanged: _loadSimMeta()

    function _loadSimMeta() {
        // Not `replaying`: this runs from the change handlers of the very
        // properties that binding reads, before the binding has caught up.
        // Switching replay on read "not replaying" and loaded nothing, and
        // switching it off read "replaying" and loaded the recording then —
        // which is how the package list was always one change behind.
        if (simMode !== "replay" || simRecording === "") {
            simPackages = [];
            simMeta = ({});
            return;
        }
        // Both halves of this were wrong at once, and they hid each other:
        // assigning `running` on a Process that is already running does
        // nothing, so a second request was dropped — and the first one's
        // answer then arrived after the mode had moved on and overwrote it.
        // A recording that had just been switched away from was loaded, and
        // the one actually selected never was. Stop the old request, and let
        // an answer through only if it is still the answer to the question.
        //
        // Stopping is not instant either: `running = false` then `= true` in
        // one go found the old process still there, so the start was dropped
        // and nothing was loaded at all. That is what the screenshots ran
        // into, switching recordings twice in a row. A running request is
        // stopped, and the new one starts once it has gone.
        metaProcess._for = simRecording;
        metaProcess.command = [python, simulateHelper, "meta", recordingsRoot + "/" + simRecording];
        if (metaProcess.running) {
            metaProcess._restart = true;
            metaProcess.running = false;
            return;
        }
        metaProcess.running = true;
    }

    Process {
        id: metaProcess

        property string _for: ""
        property bool _restart: false

        onRunningChanged: {
            if (!running && _restart) {
                _restart = false;
                running = true;
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim() !== "")
                    backend.simDiagnostic = "stderr: " + text.trim().split("\n").pop();
            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                backend.simDiagnostic = "read " + (text || "").length + " bytes for " + metaProcess._for;
                if (metaProcess._for !== backend.simRecording || backend.simMode !== "replay")
                    return;
                let meta;
                try {
                    meta = JSON.parse(text);
                } catch (e) {
                    return;
                }
                // The answer of a request that was stopped can still arrive;
                // the recording names itself, so it is checked against that
                if (meta && meta.name && meta.name !== backend.simRecording)
                    return;
                backend.simMeta = meta || ({});
                backend.simPackages = (meta && meta.packages) || [];
            }
        }
    }

    // Diagnostics for the simulation layer: which request is in flight, and
    // what the last one answered. Every part of this is asynchronous, so when
    // a replay does not appear this is what says where it stopped.
    property string simDiagnostic: ""

    function simDebug() {
        return "req=" + (metaProcess._for || "-") + " busy=" + metaProcess.running
            + " last=" + (simDiagnostic || "-");
    }

    // The recordings on disk, newest first, for the picker
    property var recordings: []

    function refreshRecordings() {
        listProcess.command = [python, simulateHelper, "list", recordingsRoot];
        listProcess.running = true;
    }

    Process {
        id: listProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    backend.recordings = JSON.parse(text) || [];
                } catch (e) {
                    backend.recordings = [];
                }
            }
        }
    }

    // Command for a privileged helper transaction
    function helperCommand(action, specs) {
        return privileged([python, packageHelper, action].concat(specs));
    }

    // The same install, preceded by adding the Copr the package lives in —
    // one transaction, so one password. Both Fedora helpers take it: layering
    // a Copr package on an atomic system is the same two steps.
    function coprInstallCommand(project, specs) {
        return privileged([python, packageHelper, "install", "--copr", project].concat(specs));
    }

    // Which updates are security fixes. Only the dnf family ships updateinfo
    // in a form we can read locally; elsewhere the answer is "unknown", which
    // the UI shows as no chip rather than as a reassuring absence.
    readonly property bool hasAdvisories: backendId === "dnf"

    function advisoryCommand(names) {
        return [python, packageHelper, "advisories"].concat(names);
    }

    // The same transaction, resolved but not run: no root, no changes, so
    // the consequences can be shown before the password is asked for.
    function planCommand(action, specs) {
        return [python, packageHelper, "plan", action].concat(specs);
    }

    // ── Helper readiness ────────────────────────────────────────────────────
    // The helpers need their package manager's Python bindings, which are a
    // separate package on every distro and are not part of a default install
    // (a Fedora system has dnf5 without python3-libdnf5). Ask the helper
    // itself — unprivileged, no transaction — so a run can say what is
    // missing instead of reporting every package as mysteriously failed.

    // "" while unknown, "ok", or the helper's reason it cannot run
    property string packageHelperStatus: ""
    readonly property bool packageHelperReady: packageHelperStatus === "ok"
    readonly property bool packageHelperBroken: packageHelperStatus !== "" && packageHelperStatus !== "ok"
    readonly property string packageHelperError: packageHelperBroken ? packageHelperStatus : ""

    // The distro package providing what the helper imports, for the hint.
    // The atomic answer is the tool itself: that helper drives a command
    // line, which every image has, rather than bindings it might not.
    // RHEL and its rebuilds have no libdnf5 at all; the helper hands over to
    // dnf 4 there, whose bindings are python3-dnf (#27).
    readonly property string packageHelperRequirement: backendId === "apt" ? "python3-apt" : (backendId === "pacman" ? "pyalpm" : (atomic ? "rpm-ostree" : (rhelFamily ? "python3-dnf" : "python3-libdnf5")))

    // A check asked for while one is running is a check with a *different*
    // answer, because the only thing that changes it is which backend this
    // is, and that is settled a moment after startup: backendId starts at
    // "dnf" and /etc/os-release corrects it. Dropping the second request left
    // an Arch machine holding the verdict of the dnf helper — a banner headed
    // "pyalpm could not be loaded" over a line about python3-libdnf5, on a
    // system with pyalpm installed (#11). It sat there until the Install
    // button happened to ask again.
    //
    // Also reached on atomic Fedora, where /run/ostree-booted moves the same
    // property, and on a slow first boot, which is why it was reported as
    // happening only then: with a warm page cache os-release usually wins the
    // race.
    property bool _selftestStale: false

    function checkPackageHelper() {
        if (selftestProcess.running) {
            _selftestStale = true;
            return;
        }
        _selftestStale = false;
        selftestProcess._reason = "";
        selftestProcess._stderr = "";
        selftestProcess.command = [python, packageHelper, "selftest"];
        selftestProcess.running = true;
    }

    onBackendIdChanged: checkRequirements()
    Component.onCompleted: {
        checkRequirements();
        // Cheap, and it means the first thing that asks for the list — the
        // settings panel, or the IPC entry point — has an answer rather than
        // starting a process and returning before it finishes.
        refreshRecordings();
        // A shell that starts with a replay already selected gets no change
        // signal to load it from — the mode was already what it is.
        _loadSimMeta();
    }

    function checkRequirements() {
        checkPackageHelper();
        checkFlatpakHelper();
        checkAppstream();
    }

    // ── Flatpak readiness ───────────────────────────────────────────────────
    // The Flatpak helper needs PyGObject *and* the Flatpak typelib, which are
    // two packages — and on Debian and Ubuntu the typelib
    // (gir1.2-flatpak-1.0) does not come with flatpak itself. Reported in
    // issue #2: Flatpak updates failed on Ubuntu until it was installed by
    // hand, which nothing told the user to do.
    readonly property string flatpakHelper: Qt.resolvedUrl("scripts/flatpak_helper.py").toString().replace("file://", "")

    property string flatpakHelperStatus: ""
    // Which half the helper found missing: "bindings", "typelib", "absent",
    // or "" when it did not say
    property string flatpakHelperCause: ""

    // A machine without Flatpak is not a machine with a broken plugin. There
    // is nothing to update and nothing to fix, so it is not a requirement —
    // asking such a system to install PyGObject was asking it to make no
    // difference at all (#15).
    readonly property bool flatpakAbsent: flatpakHelperCause === "absent"
    readonly property bool flatpakHelperBroken: flatpakHelperStatus !== "" && flatpakHelperStatus !== "ok" && !flatpakAbsent
    readonly property string flatpakHelperError: flatpakHelperBroken ? flatpakHelperStatus : ""

    // Two packages, two failures, and telling them apart is the whole point:
    // the typelib is not in the PyGObject package on any of these distros —
    // on Arch it comes with flatpak itself, on Debian and Ubuntu it is
    // gir1.2-flatpak-1.0, and on Fedora it is flatpak-libs; neither of those
    // two is pulled in by flatpak (#2). A Fedora that happens to have
    // flatpak-libs got there through something else; Zirconium, a bootc
    // image, ships flatpak without it, and was told to install flatpak. Naming
    // the bindings package for a missing typelib is what #15 reported:
    // "python3-gobject-base is missing" on a machine that had it, where
    // installing it again could not change the answer.
    //
    // Without a cause both are named: one of the two is usually already
    // there, and installing the pair is what fixes it either way.
    readonly property string flatpakRequirement: {
        const bindings = backendId === "apt" ? "python3-gi" : (backendId === "pacman" ? "python-gobject" : "python3-gobject-base");
        const typelib = backendId === "apt" ? "gir1.2-flatpak-1.0" : (backendId === "pacman" ? "flatpak" : "flatpak-libs");
        if (flatpakHelperCause === "bindings")
            return bindings;
        if (flatpakHelperCause === "typelib")
            return typelib;
        return typelib + " " + bindings;
    }

    // Same reason checkPackageHelper keeps one: a check asked for while one
    // is running is asked for because something changed — the requirement was
    // just installed — and dropping it leaves the banner standing over a
    // system that no longer has the problem.
    property bool _flatpakSelftestStale: false

    function checkFlatpakHelper() {
        if (flatpakSelftestProcess.running) {
            _flatpakSelftestStale = true;
            return;
        }
        _flatpakSelftestStale = false;
        flatpakSelftestProcess._reason = "";
        flatpakSelftestProcess._cause = "";
        flatpakSelftestProcess.command = [python, flatpakHelper, "selftest"];
        flatpakSelftestProcess.running = true;
    }

    Process {
        id: flatpakSelftestProcess

        property string _reason: ""
        property string _cause: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "error" && event.message)
                    flatpakSelftestProcess._reason = event.message;
                if (event.event === "error" && event.cause)
                    flatpakSelftestProcess._cause = event.cause;
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (backend._flatpakSelftestStale) {
                backend._flatpakSelftestStale = false;
                Qt.callLater(backend.checkFlatpakHelper);
                return;
            }
            backend.flatpakHelperCause = exitCode === 0 ? "" : _cause;
            backend.flatpakHelperStatus = exitCode === 0 ? "ok" : (_reason || Tr.t("the Flatpak helper could not start"));
        }
    }

    Process {
        id: selftestProcess

        property string _reason: ""
        // Anything the helper said outside the protocol — a traceback, a
        // loader error, the shell's complaint about the interpreter. Last
        // line only: this goes on one detail line under the requirement.
        property string _stderr: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "error" && event.message)
                    selftestProcess._reason = event.message;
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const lines = (text || "").split("\n").map(l => l.trim()).filter(l => l !== "");
                selftestProcess._stderr = lines.length > 0 ? lines[lines.length - 1] : "";
            }
        }

        onExited: (exitCode, exitStatus) => {
            // This answer is about the helper of a backend we have since
            // stopped being. Publishing it would be publishing the thing that
            // was asked about, not the thing that is true.
            if (backend._selftestStale) {
                backend._selftestStale = false;
                Qt.callLater(backend.checkPackageHelper);
                return;
            }
            // A helper that answered inside the protocol is quoted; one that
            // died before it could is quoted from stderr; one that managed
            // neither leaves only the way it ended, and that beats a sentence
            // the reporter cannot add anything to (#18).
            backend.packageHelperStatus = exitCode === 0 ? "ok"
                : (_reason || _stderr
                   || (exitStatus === 1 ? Tr.t("the package helper crashed") : Tr.t("the package helper could not start"))
                      + " — exit " + exitCode + "/" + exitStatus);
        }
    }

    // ── AppStream catalog ───────────────────────────────────────────────────
    // Names, icons, screenshots and release notes for system packages all
    // come from the distro's AppStream catalog, which is its own package and
    // is missing often enough to be worth saying out loud. Unlike the
    // bindings this only makes the app poorer, never broken — the list falls
    // back to package summaries and the icons in the desktop entries.

    // "" while unknown, "ok" or "missing"
    property string appstreamStatus: ""
    readonly property bool appstreamMissing: appstreamStatus === "missing"

    readonly property string appstreamRequirement: backendId === "apt" ? "appstream" : (backendId === "pacman" ? "archlinux-appstream-data" : "appstream-data")

    function checkAppstream() {
        if (catalogStatusProcess.running)
            return;
        catalogStatusProcess.command = [python, Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--catalog-status"];
        catalogStatusProcess.running = true;
    }

    Process {
        id: catalogStatusProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let count = -1;
                try {
                    count = (JSON.parse(text) || {}).catalogs;
                } catch (e) {
                }
                // An unreadable answer is not evidence of a missing catalog
                if (count >= 0)
                    backend.appstreamStatus = count > 0 ? "ok" : "missing";
            }
        }
    }

    // ── Missing requirements ────────────────────────────────────────────────
    // What the plugin needs from the distro and does not have. The window
    // renders one row per entry; `blocking` separates "nothing works" from
    // "less to show".
    readonly property var missingRequirements: {
        const missing = [];
        if (packageHelperBroken)
            missing.push({
                id: "helper",
                blocking: true,
                package: packageHelperRequirement,
                detail: packageHelperError
            });
        if (flatpakHelperBroken)
            missing.push({
                id: "flatpak",
                blocking: false,
                package: flatpakRequirement,
                detail: flatpakHelperError
            });
        if (appstreamMissing)
            missing.push({
                id: "appstream",
                blocking: false,
                package: appstreamRequirement,
                detail: ""
            });
        return missing;
    }

    // ── Installing a missing requirement ────────────────────────────────────
    // Bootstrapping cannot go through the transaction helper — it may be the
    // very thing that is missing — so these installs run the package
    // manager's command line directly. The only place in the plugin that does.

    function _installWords(pkg) {
        // A requirement can name more than one package — the Flatpak bindings
        // are two on Debian — so the string is a list, not an argument
        const names = String(pkg).split(/\s+/).filter(n => n !== "");
        if (backendId === "apt")
            return ["apt-get", "install", "-y"].concat(names);
        if (backendId === "pacman")
            return ["pacman", "-S", "--needed", "--noconfirm"].concat(names);
        // Layered, and in effect after the next boot — there is no other way
        // to add a package to an atomic system
        if (atomic)
            return ["rpm-ostree", "install", "--idempotent"].concat(names);
        return ["dnf", "install", "-y"].concat(names);
    }

    function installHintFor(pkg) {
        return "sudo " + _installWords(pkg).join(" ");
    }

    // id of the requirement being installed, "" when idle
    property string installingRequirement: ""
    // Why the last install failed, "" when there was none
    property string requirementInstallError: ""

    // Somebody has to write this one down. These installs deliberately skip
    // the transaction helper — it may be the very thing that is missing — and
    // in skipping it they skipped the log, which cost more than a missing
    // line: the reconciler works out what changed *outside* this app by
    // comparing install times against the log, so a package this app
    // installed without recording it came back later as a stranger, in the
    // one card whose whole worth is being trusted when it does speak up.
    //
    // A singleton cannot reach the log, so it says what it did and the widget
    // writes it down.
    signal requirementInstalled(string pkg, bool ok, string detail)

    function installRequirement(id, pkg) {
        if (installingRequirement !== "")
            return;
        requirementInstallError = "";
        installingRequirement = id;
        installProcess._pkg = pkg;
        installProcess._output = "";
        installProcess.command = backend.privileged(_installWords(pkg));
        installProcess.running = true;
    }

    Process {
        id: installProcess

        property string _output: ""
        property string _pkg: ""

        stdout: SplitParser {
            onRead: line => {
                const trimmed = (line || "").trim();
                if (trimmed !== "")
                    installProcess._output = trimmed;
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const trimmed = (text || "").trim();
                if (trimmed !== "")
                    installProcess._output = trimmed;
            }
        }

        onExited: (exitCode, exitStatus) => {
            const which = backend.installingRequirement;
            backend.installingRequirement = "";
            if (exitCode !== 0)
                backend.requirementInstallError = exitCode === 126 || exitCode === 127 ? Tr.t("the authorisation was refused") : (_output || Tr.t("the installation failed"));
            backend.requirementInstalled(installProcess._pkg, exitCode === 0, exitCode === 0 ? "" : backend.requirementInstallError);
            // Either way the check, not the exit code, decides — and it has
            // to be the check for the thing that was installed. Sending the
            // Flatpak bindings to the package-helper check re-answered a
            // question nobody had asked and left the Flatpak banner standing
            // over a system that had just fixed it, which is what #15 saw as
            // "clicked Install, nothing changed".
            if (which === "appstream")
                backend.checkAppstream();
            else if (which === "flatpak")
                backend.checkFlatpakHelper();
            else
                backend.checkPackageHelper();
        }
    }

    // Installed-version listing used for post-run verification; both
    // backends print "name<TAB>version" lines.
    function installedVersionsCommand(names) {
        if (backendId === "apt")
            return ["dpkg-query", "-W", "-f", "${Package}\\t${Version}\\n"].concat(names);
        if (backendId === "pacman")
            return ["sh", "-c", "LC_ALL=C pacman -Q " + names.join(" ") + " 2>/dev/null | sed 's/ /\\t/'"];
        return ["rpm", "-q", "--qf", "%{NAME}\\t%{EVR}\\n"].concat(names);
    }

    readonly property string metadataHelper: Qt.resolvedUrl("scripts/pkg_backend.py").toString().replace("file://", "")

    // Full installed inventory as "name<TAB>version<TAB>bytes<TAB>installtime"
    function installedTableCommand() {
        if (backendId === "apt" || backendId === "pacman")
            return [python, metadataHelper, "installed-table"];
        return ["sh", "-c", "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\t%{SIZE}\\t%{INSTALLTIME}\\n' 2>/dev/null | sort"];
    }

    // What could be freed: packages nothing needs any more, and the cache
    function cleanupScanCommand() {
        return [python, metadataHelper, "cleanup-scan"];
    }

    // Emptying the download cache is a plain package-manager chore with no
    // transaction to report, so it does not go through the helper protocol
    function cleanCacheCommand() {
        if (backendId === "apt")
            return privileged(["apt-get", "clean"]);
        if (backendId === "pacman")
            return privileged(["pacman", "-Scc", "--noconfirm"]);
        // rpm-ostree keeps its own caches: -m the rpm-md metadata, -p a
        // deployment staged but not booted into
        if (atomic)
            return privileged(["rpm-ostree", "cleanup", "-m"]);
        return privileged(["dnf", "clean", "packages"]);
    }

    // Did the user ask for this package, and what would miss it if it went
    function provenanceCommand(name) {
        return [python, metadataHelper, "provenance", name];
    }

    // Installed packages that own a launchable desktop entry — the ones a
    // user installed to actually run. Distro-agnostic; the helper branches.
    function desktopOwnersCommand() {
        return [python, metadataHelper, "desktop-owners"];
    }

    // Shell fragment printing one installed package name per line (embedded
    // in compound sh commands)
    readonly property string installedNamesShellFragment: backendId === "apt" ? "dpkg-query -W -f '${Package}\\n' 2>/dev/null" : (backendId === "pacman" ? "pacman -Qq 2>/dev/null" : "rpm -qa --qf '%{NAME}\\n' 2>/dev/null")

    // Available versions for the previous-versions feature. dnf prints
    // plain ascending version lines; the apt path prints a JSON array
    // (newest first, installed flagged) — consumers branch on the shape.
    function availableVersionsCommand(name) {
        if (backendId === "apt" || backendId === "pacman")
            return [python, metadataHelper, "versions", name];
        // An atomic image has no dnf to ask, and no per-package downgrade to
        // offer even if it answered: going back is the previous deployment
        if (atomic)
            return ["true"];
        return ["sh", "-c", "LC_ALL=C dnf -Cq repoquery --qf '%{version}-%{release}\\n' " + name + " 2>/dev/null | sort -uV"];
    }

    // Packages whose update warrants the reboot recommendation
    readonly property var rebootPackagePattern: {
        // Every change is staged for the next boot here, so every change is
        // one the reboot notice is about
        if (atomic)
            return /./;
        if (backendId === "apt")
            return /^(linux-image|linux-firmware|systemd|libc6|dbus|mesa|grub|shim|intel-microcode|amd64-microcode|nvidia)/;
        if (backendId === "pacman")
            return /^(linux(-lts|-zen|-hardened)?$|linux-firmware|systemd|glibc|dbus|mesa|nvidia|amd-ucode|intel-ucode|grub)/;
        return /^(kernel|linux-firmware|systemd|glibc|dbus|mesa|amd-gpu-firmware|intel-gpu-firmware|nvidia|microcode_ctl|shim|grub2)/;
    }

    // Human label of the system package source ("Install from %1")
    readonly property string systemRepoLabel: backendId === "apt" ? "Debian" : (backendId === "pacman" ? "Arch" : (atomic ? "Fedora Atomic" : "Fedora"))

    // ── Software sources ────────────────────────────────────────────────────
    // Which repositories exist, and the few changes worth offering from a UI.
    // Reading is unprivileged; anything that writes to /etc goes through
    // pkexec, and the Flatpak user scope needs neither.
    readonly property string repoHelper: Qt.resolvedUrl("scripts/repo_backend.py").toString().replace("file://", "")

    function repoListCommand() {
        return [python, repoHelper, "list", backendId];
    }

    function repoAdminCommand(args) {
        return privileged([python, repoHelper].concat(args));
    }

    function repoUserCommand(args) {
        return [python, repoHelper].concat(args);
    }

    // What Copr has built for this system, for software that is in no
    // repository the machine has configured yet. Unprivileged: it asks the
    // Copr hub, it changes nothing.
    function coprSearchCommand(query) {
        return [python, repoHelper, "copr-search", query];
    }

    // Copr builds per chroot, and the search asks for this machine's own —
    // fedora-44-x86_64. Only a Fedora (or something built on one: Nobara,
    // Bazzite, Ultramarine) has one. The rest of the dnf family are RHEL and
    // its rebuilds, which name Fedora in ID_LIKE without being it, and would
    // be offered a search that cannot answer.
    property bool fedoraFamily: false
    // RHEL, CentOS Stream, Alma, Rocky: dnf 4 rather than dnf5
    property bool rhelFamily: false
    readonly property bool hasCopr: (backendId === "dnf" || atomic) && fedoraFamily

    // ── Launcher entry ──────────────────────────────────────────────────────
    // Enabling the plugin puts a widget in the bar; it cannot put an entry in
    // the application launcher, because that is a file in the user's data
    // directory and no installer ever runs. Both files ship with the plugin,
    // so the app can place them itself — a README step that has to be
    // repeated on every machine is a step that gets forgotten on most.

    // The plugin's own directory, wherever the shell loaded it from
    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
    readonly property string launcherEntryName: "io.github.vinceecniv.DuxSoftwareDepot.desktop"
    // What the entry and its icon were called as Dank Software Depot. An
    // install that still has them is moved over once: entry, icons, and the
    // .appimage association in mimeapps.list, which names the entry file.
    readonly property string legacyLauncherEntryName: "com.danklinux.dankSoftwareDepot.desktop"
    readonly property string _legacyEntryCleanup: "rm -f \"$apps/" + legacyLauncherEntryName + "\" \"$icons/scalable/apps/dank-software-depot.svg\" \"$icons/symbolic/apps/dank-software-depot-symbolic.svg\""

    // Must match X-DSD-Entry-Version in the .desktop file
    readonly property string launcherEntryVersion: "4"

    property bool launcherEntryPresent: false
    // Until the first check answers, the UI should claim neither state
    property bool launcherEntryChecked: false
    property bool launcherEntryBusy: false
    property string launcherEntryError: ""
    // An entry written by an older version of the plugin. It is rewritten
    // without asking: the user already said yes to having one, and the one
    // they have calls `dms` by a name their launcher may not resolve.
    property bool _launcherEntryRepaired: false

    function checkLauncherEntry() {
        if (launcherCheckProcess.running)
            return;
        launcherCheckProcess._stamp = "";
        // Only the legacy entry there: present, but stale, so it gets rewritten
        launcherCheckProcess.command = ["sh", "-c", "apps=\"$HOME/.local/share/applications\"; f=\"$apps/" + launcherEntryName + "\"; if [ ! -f \"$f\" ]; then [ -f \"$apps/" + legacyLauncherEntryName + "\" ] && echo legacy && exit 0; exit 1; fi; sed -n 's/^X-DSD-Entry-Version=//p' \"$f\" | head -1"];
        launcherCheckProcess.running = true;
    }

    // The icon is installed too: the entry names it, and without it the
    // launcher shows a blank tile next to a perfectly good name. Exec is
    // rewritten to the absolute path of scripts/open.sh — the entry used to
    // call `dms` by name, which a launcher looks up in the session PATH
    // rather than the one a terminal builds, and when it was not there,
    // clicking the entry did nothing whatsoever.
    readonly property string _entryInstallCommand: "set -e; src='" + pluginDir + "'; apps=\"$HOME/.local/share/applications\"; icons=\"$HOME/.local/share/icons/hicolor\"; mkdir -p \"$apps\"; chmod +x \"$src/scripts/open.sh\"; sed \"s|@OPEN@|$src/scripts/open.sh|\" \"$src/" + launcherEntryName + "\" > \"$apps/" + launcherEntryName + "\"; chmod 644 \"$apps/" + launcherEntryName + "\"; install -Dm644 \"$src/assets/icons/dux-software-depot-dark.svg\" \"$icons/scalable/apps/dux-software-depot.svg\"; install -Dm644 \"$src/assets/icons/dux-software-depot-symbolic.svg\" \"$icons/symbolic/apps/dux-software-depot-symbolic.svg\"; " + _legacyEntryCleanup + "; '" + python + "' \"$src/scripts/appimage.py\" --handler-migrate >/dev/null || true; update-desktop-database \"$apps\" 2>/dev/null || true"

    function installLauncherEntry() {
        if (launcherEntryBusy)
            return;
        launcherEntryError = "";
        launcherEntryBusy = true;
        launcherProcess._output = "";
        launcherProcess.command = ["sh", "-c", _entryInstallCommand];
        launcherProcess.running = true;
    }

    function removeLauncherEntry() {
        if (launcherEntryBusy)
            return;
        launcherEntryError = "";
        launcherEntryBusy = true;
        launcherProcess._output = "";
        launcherProcess.command = ["sh", "-c", "apps=\"$HOME/.local/share/applications\"; icons=\"$HOME/.local/share/icons/hicolor\"; rm -f \"$apps/" + launcherEntryName + "\" \"$icons/scalable/apps/dux-software-depot.svg\" \"$icons/symbolic/apps/dux-software-depot-symbolic.svg\"; " + _legacyEntryCleanup + "; update-desktop-database \"$apps\" 2>/dev/null || true"];
        launcherProcess.running = true;
    }

    Process {
        id: launcherCheckProcess

        property string _stamp: ""

        stdout: StdioCollector {
            onStreamFinished: launcherCheckProcess._stamp = text.trim()
        }

        onExited: (exitCode, exitStatus) => {
            backend.launcherEntryPresent = exitCode === 0;
            backend.launcherEntryChecked = true;
            // An entry from before this version names `dms` directly and
            // declares no MIME types — it cannot open the window on a
            // machine whose launcher has a narrower PATH, and it can never
            // be the AppImage handler. Rewrite it once.
            if (exitCode === 0 && _stamp !== backend.launcherEntryVersion && !backend._launcherEntryRepaired) {
                backend._launcherEntryRepaired = true;
                backend.installLauncherEntry();
            }
        }
    }

    Process {
        id: launcherProcess

        property string _output: ""

        stderr: SplitParser {
            onRead: line => launcherProcess._output += (launcherProcess._output === "" ? "" : "\n") + line
        }

        onExited: (exitCode, exitStatus) => {
            backend.launcherEntryBusy = false;
            if (exitCode !== 0)
                backend.launcherEntryError = _output || Tr.t("the launcher entry could not be written");
            backend.checkLauncherEntry();
            backend.checkAppimageHandler();
        }
    }

    // ── Default handler for .appimage files ────────────────────────────────
    // Double-clicking an AppImage lands in this window, which then offers to
    // install it — or to replace the copy already installed. The association
    // is written into the user's own mimeapps.list and taken back out again;
    // it needs the desktop entry to exist, so switching it on writes that
    // too rather than failing on a file nobody told the user about.

    readonly property string appimageScript: pluginDir + "/scripts/appimage.py"

    property bool appimageHandlerDefault: false
    property bool appimageHandlerChecked: false
    property bool appimageHandlerBusy: false
    // Whoever holds the association when it is not us. Something else having
    // claimed .appimage — Gearlever, an archive manager — is a choice
    // somebody made, and the one-time claim below leaves it alone.
    property string appimageHandlerOther: ""

    function checkAppimageHandler() {
        if (handlerStatusProcess.running)
            return;
        handlerStatusProcess.command = [python, appimageScript, "--handler-status"];
        handlerStatusProcess.running = true;
    }

    function setAppimageHandler() {
        if (appimageHandlerBusy)
            return;
        appimageHandlerBusy = true;
        // The entry is (re)written in the same breath: being the default for
        // a file type means nothing without something for it to point at,
        // and an entry from an older version has no MimeType line at all
        handlerProcess.command = ["sh", "-c", _entryInstallCommand + "; python3 '" + appimageScript + "' --handler-set"];
        handlerProcess.running = true;
    }

    function clearAppimageHandler() {
        if (appimageHandlerBusy)
            return;
        appimageHandlerBusy = true;
        handlerProcess.command = [python, appimageScript, "--handler-clear"];
        handlerProcess.running = true;
    }

    Process {
        id: handlerStatusProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let status = null;
                try {
                    status = JSON.parse(text);
                } catch (e) {
                    status = null;
                }
                backend.appimageHandlerDefault = status !== null && status.isDefault === true;
                const held = (status && status.defaults) ? (status.defaults["application/vnd.appimage"] || "") : "";
                backend.appimageHandlerOther = (held === "" || backend.appimageHandlerDefault) ? "" : held;
                backend.appimageHandlerChecked = true;
            }
        }

        onExited: (exitCode, exitStatus) => {
            // No output to parse (python missing, script unreadable): the
            // switch still has to stop saying "checking"
            backend.appimageHandlerChecked = true;
        }
    }

    Process {
        id: handlerProcess

        onExited: (exitCode, exitStatus) => {
            backend.appimageHandlerBusy = false;
            backend.checkAppimageHandler();
            backend.checkLauncherEntry();
        }
    }

    // ostree creates this file when the system booted from a deployment. It
    // is the one answer that does not depend on what the image calls itself:
    // Silverblue says ID=fedora, Bazzite says ID=bazzite, and an ordinary
    // Fedora that happens to have rpm-ostree installed is not atomic at all.
    property bool _ostreeBooted: false

    FileView {
        path: "/run/ostree-booted"

        onLoaded: {
            backend._ostreeBooted = true;
            if (backend.backendId === "dnf")
                backend.backendId = "ostree";
        }

        onLoadFailed: error => {
            backend._ostreeBooted = false;
        }
    }

    FileView {
        path: "/etc/os-release"

        onLoaded: {
            const os = text();
            if (/(^|\n)(ID|ID_LIKE)=.*(debian|ubuntu)/im.test(os))
                backend.backendId = "apt";
            else if (/(^|\n)(ID|ID_LIKE)=.*(arch|manjaro)/im.test(os))
                backend.backendId = "pacman";
            else if (backend._ostreeBooted)
                backend.backendId = "ostree";
            // RHEL and its rebuilds say ID_LIKE="rhel fedora", so naming
            // Fedora is not enough to be one
            backend.rhelFamily = /(^|\n)(ID|ID_LIKE)=.*(rhel|centos)/im.test(os);
            backend.fedoraFamily = /(^|\n)(ID|ID_LIKE)=.*fedora/im.test(os) && !backend.rhelFamily;
        }
    }
}
