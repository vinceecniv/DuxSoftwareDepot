import QtQuick
import Quickshell.Io
import qs.Services

// Firmware updates via fwupd (LVFS). Detection through `fwupdmgr
// get-updates --json`; applying runs through the engine (polkit-authed).
Item {
    id: svc

    property bool available: true
    property bool checking: false
    // {deviceId, name, current, next, summary, notesHtml, homepage, urgency,
    //  blocker} — blocker is the fwupd problem keeping it from installing now
    property var updates: []
    // What a run can install at this moment. A blocked update is still
    // pending and still counted; it only waits for its condition.
    readonly property var installable: updates.filter(fw => !fw.blocker)

    readonly property int count: updates.length

    // fwupd lists an update it will not install right now: a BIOS on battery
    // power, a laptop with the lid shut. It says so twice — the device loses
    // its "updatable" flag for "updatable-hidden", and Problems names why —
    // and `fwupdmgr update` then skips the device and exits as if there was
    // nothing to do, which a run took for success. The most actionable
    // reason comes first when there are several.
    readonly property var _problemOrder: ["require-ac-power", "system-power-too-low", "power-too-low", "lid-is-closed", "update-pending", "update-in-progress", "in-use", "unreachable"]

    function _blockerOf(device) {
        const flags = device.Flags || [];
        if (flags.indexOf("updatable") !== -1)
            return "";
        const problems = device.Problems || [];
        for (const code of _problemOrder) {
            if (problems.indexOf(code) !== -1)
                return code;
        }
        if (problems.length > 0)
            return problems[0];
        return flags.indexOf("updatable-hidden") !== -1 ? "unknown" : "";
    }

    function blockerText(code) {
        switch (code) {
        case "":
            return "";
        case "require-ac-power":
            return Tr.t("Plug in the power adapter to install this update.");
        case "system-power-too-low":
            return Tr.t("The battery is too low to install this update. Charge it first.");
        case "power-too-low":
            return Tr.t("The device's battery is too low to install this update.");
        case "lid-is-closed":
            return Tr.t("Open the laptop lid to install this update.");
        case "update-pending":
        case "update-in-progress":
            return Tr.t("An update for this device is already waiting to be installed.");
        case "in-use":
            return Tr.t("The device is in use. Close what is using it to install this update.");
        case "unreachable":
            return Tr.t("The device is not reachable right now.");
        default:
            return Tr.t("fwupd cannot install this update right now.");
        }
    }

    // fwupd release descriptions are appstream-ish XML from LVFS metadata.
    // Reduce to escaped plain text with line breaks — same safety rules as
    // the AppStream release notes.
    function _sanitize(text) {
        if (!text)
            return "";
        let t = text
            .replace(/<li>/gi, "\n• ")
            .replace(/<\/(p|li|ul|ol)>/gi, "\n")
            .replace(/<[^>]*>/g, "");
        t = t.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
        t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return t.split("\n").map(line => line.trim()).filter(line => line.length > 0).join("<br>");
    }

    function check() {
        if (!available || checkProcess.running)
            return;
        checking = true;
        checkProcess.running = true;
    }

    function _parse(text) {
        try {
            const data = JSON.parse(text);
            const found = [];
            for (const device of data.Devices || []) {
                const releases = device.Releases || [];
                if (releases.length === 0)
                    continue;
                const release = releases[0];
                let homepage = "";
                for (const url of release.Urls || []) {
                    homepage = url;
                    break;
                }
                found.push({
                    deviceId: device.DeviceId || "",
                    name: device.Name || "Unknown device",
                    current: device.Version || "",
                    next: release.Version || "",
                    summary: release.Summary || "",
                    notesHtml: _sanitize(release.Description || ""),
                    homepage: homepage,
                    urgency: release.Urgency || "",
                    blocker: _blockerOf(device)
                });
            }
            updates = found;
        } catch (e) {
            updates = [];
        }
    }

    // fwupd re-evaluates its power problems when the adapter goes in or out,
    // but nothing asks it again until the next check — so a card would keep
    // saying "plug in" with the plug in. Asked a moment later, because fwupd
    // hears about the change through UPower too, and not before we do.
    Connections {
        target: BatteryService

        function onIsPluggedInChanged() {
            if (svc.updates.length > 0)
                powerRecheck.restart();
        }
    }

    Timer {
        id: powerRecheck
        interval: 3000
        onTriggered: svc.check()
    }

    Process {
        id: checkProcess
        // Through sh: a binary that cannot be started never reaches
        // onExited, so neither the 127 below nor checking = false happened
        command: ["sh", "-c", "command -v fwupdmgr >/dev/null 2>&1 || exit 127; exec fwupdmgr get-updates --json"]

        stdout: StdioCollector {
            onStreamFinished: svc._parse(text)
        }

        onExited: (exitCode, exitStatus) => {
            svc.checking = false;
            // 127: binary missing → disable quietly. fwupd exits 2 for
            // "nothing to do", which is fine.
            if (exitCode === 127) {
                svc.available = false;
            }
        }
    }
}
