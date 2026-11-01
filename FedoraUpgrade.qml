import QtQuick
import Quickshell.Io
import qs.Common

// Upgrading Fedora to its next release, from the banner that announces it:
// check what it involves, download it in the background, restart into it.
// scripts/fedora_upgrade.py does the work; this keeps the state, and lives in
// the widget rather than the window so a download keeps going, and keeps
// being reported, after the window is closed.
Item {
    id: upgrade

    // The release to go to (Bodhi's newest), 0 when there is none
    property int target: 0
    // "idle" → "planning" → "planned" → "downloading" → "ready"; "failed"
    // when a download did not finish. "ready" comes from dnf5's state file,
    // so it survives the shell's restart as well as the depot's.
    property string phase: "idle"
    property var plan: null             // the helper's upgrade-plan event
    property string planError: ""
    property string error: ""           // why the download failed
    property string stage: ""           // repos | resolving | testing | stored
    property int index: 0               // packages downloaded …
    property int total: 0               // … of
    property real bytes: 0
    // The release a prepared upgrade goes to — the state file's word for it,
    // which is what will be installed, whatever Bodhi says by now
    property int preparedTarget: 0
    property bool busy: false           // reboot or clean under way
    property bool statusKnown: false

    signal downloaded(int releasever)

    readonly property string helper: Qt.resolvedUrl("scripts/fedora_upgrade.py").toString().replace("file://", "")
    readonly property real fraction: {
        if (phase !== "downloading")
            return 0;
        const planned = plan && plan.ok ? plan.downloadBytes : 0;
        if (planned > 0 && bytes > 0)
            return Math.min(1, bytes / planned);
        return total > 0 ? index / total : 0;
    }

    function refreshStatus() {
        if (!statusProc.running)
            statusProc.running = true;
    }

    function startPlan() {
        if (target <= 0 || phase === "downloading")
            return;
        // Closed and reopened while the first look was still going: that
        // one answers, for the same release
        if (planProc.running) {
            phase = "planning";
            return;
        }
        plan = null;
        planError = "";
        phase = "planning";
        planProc.command = [Backend.python, helper, "plan", String(target)];
        planProc.running = true;
    }

    function startDownload() {
        if (!plan || !plan.ok || downloadProc.running)
            return;
        error = "";
        stage = "";
        index = 0;
        total = 0;
        bytes = 0;
        phase = "downloading";
        const args = [Backend.python, helper, "download", String(plan.releasever)];
        if (plan.allowErasing)
            args.push("--allowerasing");
        downloadProc.command = Backend.privileged(args);
        downloadProc.running = true;
    }

    // A plan the user walked away from is not kept: the next look should
    // be at the repositories as they are then
    function dropPlan() {
        if (phase === "planned" || phase === "planning" || phase === "failed")
            phase = "idle";
        plan = null;
        planError = "";
    }

    function reboot() {
        if (busy || phase !== "ready")
            return;
        busy = true;
        actionProc.command = Backend.privileged(["dnf5", "offline", "reboot", "-y"]);
        actionProc.running = true;
    }

    function cancel() {
        if (busy || phase !== "ready")
            return;
        busy = true;
        actionProc.command = Backend.privileged(["dnf5", "offline", "clean", "-y"]);
        actionProc.running = true;
    }

    Process {
        id: statusProc
        command: [Backend.python, upgrade.helper, "status"]

        stdout: StdioCollector {
            onStreamFinished: {
                let status = null;
                try {
                    status = JSON.parse(text);
                } catch (e) {
                    status = null;
                }
                upgrade.statusKnown = true;
                if (!status)
                    return;
                const prepared = status.prepared === true && parseInt(status.targetReleasever) > (status.current || 0);
                upgrade.preparedTarget = prepared ? parseInt(status.targetReleasever) : 0;
                if (prepared)
                    upgrade.phase = "ready";
                else if (upgrade.phase === "ready")
                    upgrade.phase = "idle";
            }
        }
    }

    Process {
        id: planProc

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event !== "upgrade-plan")
                    return;
                upgrade.plan = event;
                upgrade.planError = event.ok ? "" : (event.error || "");
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (upgrade.phase !== "planning")
                return;
            if (!upgrade.plan || !upgrade.plan.ok) {
                if (upgrade.planError === "")
                    upgrade.planError = Tr.t("exit %1").arg(exitCode);
            }
            upgrade.phase = "planned";
        }
    }

    Process {
        id: downloadProc

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                switch (event.event) {
                case "status":
                    upgrade.stage = event.message || "";
                    break;
                case "progress":
                    upgrade.index = event.index || 0;
                    upgrade.total = event.total || 0;
                    upgrade.bytes = event.totalTransferred || 0;
                    break;
                case "error":
                    upgrade.error = event.message || "";
                    break;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                upgrade.preparedTarget = upgrade.plan ? upgrade.plan.releasever : upgrade.target;
                upgrade.phase = "ready";
                upgrade.downloaded(upgrade.preparedTarget);
            } else {
                // 126/127: pkexec's dialog was dismissed, which is a no
                // rather than a failure
                if (exitCode === 126 || exitCode === 127) {
                    upgrade.phase = "planned";
                    upgrade.error = "";
                } else {
                    if (upgrade.error === "")
                        upgrade.error = Tr.t("exit %1").arg(exitCode);
                    upgrade.phase = "failed";
                }
            }
            upgrade.refreshStatus();
        }
    }

    Process {
        id: actionProc

        onExited: (exitCode, exitStatus) => {
            upgrade.busy = false;
            upgrade.refreshStatus();
        }
    }

    Component.onCompleted: refreshStatus()
}
