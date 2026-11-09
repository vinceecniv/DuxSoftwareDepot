import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets

// Firmware inventory tab: all devices fwupd knows about, which ones support
// firmware updates, current versions, and release notes on demand.
Item {
    id: view

    property var firmware: null      // FirmwareService (optional)

    // A handful of devices fits on one screen: no search field, the list
    // itself takes the keyboard.
    function focusList() {
        deviceList.forceActiveFocus();
    }

    property var devices: []         // {deviceId, name, vendor, version, updatable, plugin}
    property bool loading: true
    // Why there is no list: "missing" when fwupd is not installed, else
    // fwupd's own message. Empty while the list is fine.
    property string error: ""
    property var releasesByDevice: ({})  // deviceId -> [{version, notesHtml}] | "loading"

    Component.onCompleted: {
        reload();
        Ui.softenScrollbar(deviceList);
    }

    function reload() {
        loading = true;
        error = "";
        devicesProcess.running = true;
    }

    // Device-type icon from the fwupd name/plugin
    function deviceIcon(dev) {
        const hay = ((dev.name || "") + " " + (dev.plugin || "")).toLowerCase();
        if (hay.indexOf("fingerprint") !== -1 || hay.indexOf("goodix") !== -1 || hay.indexOf("synaptics_prometheus") !== -1)
            return "fingerprint";
        if (hay.indexOf("camera") !== -1 || hay.indexOf("webcam") !== -1)
            return "photo_camera";
        if (hay.indexOf("touchpad") !== -1 || hay.indexOf("trackpad") !== -1 || hay.indexOf("synaptics") !== -1 || hay.indexOf("elan") !== -1)
            return "touch_app";
        if (hay.indexOf("keyboard") !== -1)
            return "keyboard";
        if (hay.indexOf("mouse") !== -1 || hay.indexOf("unifying") !== -1 || hay.indexOf("receiver") !== -1 || hay.indexOf("logitech") !== -1)
            return "mouse";
        if (hay.indexOf("bluetooth") !== -1)
            return "bluetooth";
        if (hay.indexOf("wifi") !== -1 || hay.indexOf("wireless") !== -1 || hay.indexOf("wlan") !== -1 || hay.indexOf("network") !== -1 || hay.indexOf("ethernet") !== -1)
            return "wifi";
        if (hay.indexOf("nvme") !== -1 || hay.indexOf("ssd") !== -1 || hay.indexOf("scsi") !== -1 || hay.indexOf("disk") !== -1 || hay.indexOf("storage") !== -1 || hay.indexOf("card") !== -1 && hay.indexOf("gb") !== -1)
            return "hard_drive";
        if (hay.indexOf("sd card") !== -1 || hay.indexOf("mmc") !== -1)
            return "sd_card";
        if (hay.indexOf("battery") !== -1)
            return "battery_full";
        if (hay.indexOf("display") !== -1 || hay.indexOf("monitor") !== -1 || hay.indexOf("panel") !== -1 || hay.indexOf("edp") !== -1)
            return "monitor";
        if (hay.indexOf("audio") !== -1 || hay.indexOf("speaker") !== -1 || hay.indexOf("sound") !== -1)
            return "volume_up";
        if (hay.indexOf("tpm") !== -1 || hay.indexOf("bootguard") !== -1 || hay.indexOf(" ca ") !== -1 || hay.indexOf("secure") !== -1 || hay.indexOf("dbx") !== -1 || hay.indexOf("kek") !== -1 || hay.indexOf("uefi_db") !== -1 || hay.indexOf("uefi_pk") !== -1)
            return "security";
        if (hay.indexOf("thunderbolt") !== -1 || hay.indexOf("usb4") !== -1)
            return "bolt";
        if (hay.indexOf("dock") !== -1 || hay.indexOf("hub") !== -1 || hay.indexOf("usb") !== -1)
            return "usb";
        if (hay.indexOf("cpu") !== -1 || hay.indexOf("core") !== -1 || hay.indexOf("ryzen") !== -1 || hay.indexOf("processor") !== -1 || hay.indexOf("microcode") !== -1)
            return "memory";
        if (hay.indexOf("gpu") !== -1 || hay.indexOf("graphics") !== -1 || hay.indexOf("radeon") !== -1 || hay.indexOf("geforce") !== -1)
            return "smart_display";
        return "developer_board";
    }

    function _sanitize(text) {
        if (firmware)
            return firmware._sanitize(text);
        if (!text)
            return "";
        let t = text.replace(/<li>/gi, "\n• ").replace(/<\/(p|li|ul|ol)>/gi, "\n").replace(/<[^>]*>/g, "");
        t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return t.split("\n").map(line => line.trim()).filter(line => line.length > 0).join("<br>");
    }

    readonly property var sortedDevices: {
        const rows = devices.slice();
        rows.sort((a, b) => {
            if (a.updatable !== b.updatable)
                return a.updatable ? -1 : 1;
            return a.name.localeCompare(b.name);
        });
        return rows;
    }

    readonly property int updatableCount: devices.filter(dev => dev.updatable).length

    function loadReleases(deviceId) {
        if (releasesByDevice[deviceId] !== undefined)
            return;
        const updated = Object.assign({}, releasesByDevice);
        updated[deviceId] = "loading";
        releasesByDevice = updated;
        releasesProcess._target = deviceId;
        releasesProcess.command = ["fwupdmgr", "get-releases", deviceId, "--json"];
        releasesProcess.running = true;
    }

    Process {
        id: devicesProcess
        // Through sh, so a missing fwupdmgr still ends in onExited: a binary
        // that cannot be started gets neither that nor onStreamFinished, and
        // the spinner below turned forever (fwupd is optional on Arch)
        command: ["sh", "-c", "command -v fwupdmgr >/dev/null 2>&1 || exit 127; exec fwupdmgr get-devices --json"]

        stdout: StdioCollector {
            onStreamFinished: {
                const found = [];
                try {
                    const data = JSON.parse(text);
                    // With --json, fwupd reports a failure on stdout too
                    if (data.Error)
                        view.error = data.Error.Message || "error";
                    for (const dev of data.Devices || []) {
                        if (!dev.Name)
                            continue;
                        const flags = dev.Flags || [];
                        found.push({
                            deviceId: dev.DeviceId || "",
                            name: dev.Name,
                            vendor: dev.Vendor || "",
                            version: dev.Version || "",
                            plugin: dev.Plugin || "",
                            // fwupd swaps "updatable" for "updatable-hidden"
                            // while it will not install (a BIOS on battery
                            // power); the device still supports updates
                            updatable: flags.indexOf("updatable") !== -1 || flags.indexOf("updatable-hidden") !== -1,
                            blocked: flags.indexOf("updatable-hidden") !== -1,
                            needsPower: (dev.Problems || []).indexOf("require-ac-power") !== -1 || (dev.Problems || []).indexOf("system-power-too-low") !== -1
                        });
                    }
                } catch (e) {
                }
                view.devices = found;
                view.loading = false;
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 127)
                view.error = "missing";
            // 2 is fwupd's "nothing to do"
            else if (exitCode !== 0 && exitCode !== 2 && view.error === "")
                view.error = "error";
            view.loading = false;
        }
    }

    Process {
        id: releasesProcess

        property string _target: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const releases = [];
                try {
                    const data = JSON.parse(text);
                    for (const rel of (data.Releases || []).slice(0, 4)) {
                        releases.push({
                            version: rel.Version || "",
                            notesHtml: view._sanitize(rel.Description || ""),
                            summary: rel.Summary || ""
                        });
                    }
                } catch (e) {
                }
                const updated = Object.assign({}, view.releasesByDevice);
                updated[releasesProcess._target] = releases;
                view.releasesByDevice = updated;
            }
        }

        onExited: (exitCode, exitStatus) => {
            // get-releases fails for devices without LVFS metadata
            if (exitCode !== 0 && view.releasesByDevice[releasesProcess._target] === "loading") {
                const updated = Object.assign({}, view.releasesByDevice);
                updated[releasesProcess._target] = [];
                view.releasesByDevice = updated;
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        // Informative banner when firmware updates are disabled in settings:
        // the inventory below still works, but updates are not checked or run.
        Rectangle {
            Layout.fillWidth: true
            visible: view.firmware === null
            implicitHeight: disabledRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.12)

            RowLayout {
                id: disabledRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DIcon {
                    name: "info"
                    size: 18
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Firmware updates are disabled in the plugin settings — this inventory is informational only; firmware is not checked or updated.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: firmwareEnableButton.width
                    Layout.preferredHeight: firmwareEnableButton.height

                    DButton {
                        id: firmwareEnableButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        text: Tr.t("Enable")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        onClicked: PluginService.savePluginData("dankSoftwareDepot", "includeFirmware", true)
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: !view.loading && view.error === ""
            text: Tr.t("%1 devices · %2 support firmware updates (fwupd/LVFS)").arg(view.devices.length).arg(view.updatableCount)
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        StyledRect {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.cornerRadius
            // The device rows carry their own surface
            color: "transparent"
            border.width: 0
            clip: true
            visible: !view.loading && view.error === ""

            DListView {
                id: deviceList
                anchors.fill: parent
                anchors.margins: 0
                clip: true
                populate: Transition {
                    NumberAnimation { properties: "opacity,y"; from: 0; duration: Theme.longDuration; easing.type: Easing.OutCubic }
                }
                add: Transition {
                    NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: Theme.mediumDuration; easing.type: Easing.OutBack }
                }
                spacing: 2
                model: view.sortedDevices

                delegate: Item {
                    id: deviceRow

                    required property var modelData
                    required property int index

                    readonly property var releases: view.releasesByDevice[modelData.deviceId]
                    property bool expanded: false
                    readonly property int totalCount: view.sortedDevices.length
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast: index === totalCount - 1

                    width: deviceList.width
                    implicitHeight: deviceContent.implicitHeight + (Theme.spacingS + 2) * 2
                    height: implicitHeight
                    opacity: modelData.updatable ? 1 : 0.75
                    // No clip on the row itself. The hover outline is a 1px stroke
                    // centred on the row's edge, so clipping cut away its outer half
                    // and the highlight stopped short of running round. The list and
                    // its container clip, which is where the log does it too, and the
                    // log's rows expand just as these do.

                    Behavior on implicitHeight {
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }

                    Shape {
                        id: devBg
                        anchors.fill: parent
                        // Inset by half the stroke so the 1px outline lands on
                        // whole pixels inside the row: centred on the row's edge,
                        // the list's clip took its outer half and the left side
                        // all but vanished.
                        anchors.margins: 0.5

                        property real innerRadius: 6
                        property real outerRadius: 12
                        // Hover is a state layer and nothing more, and the shape answers a press
                        // (M3 Expressive, as DMS does it, #22). Expanding is not a reason to round:
                        // DMS keeps an expanded card's corners as they are, and the open entry
                        // already says it is open. Its fill and outline mark it as selected.
                        property bool hovered: devMa.containsMouse || deviceRow.expanded
                        property bool selected: deviceRow.expanded
                        property bool morphed: devMa.pressed

                        property real tlr: morphed ? Math.min(height / 2, 28) : (deviceRow.isFirst ? outerRadius : innerRadius)
                        property real trr: morphed ? Math.min(height / 2, 28) : (deviceRow.isFirst ? outerRadius : innerRadius)
                        property real blr: morphed ? Math.min(height / 2, 28) : (deviceRow.isLast ? outerRadius : innerRadius)
                        property real brr: morphed ? Math.min(height / 2, 28) : (deviceRow.isLast ? outerRadius : innerRadius)

                        property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        // The same resting fill as every other list. This
                        // row used to shade itself by whether the device was
                        // updatable, which left three different appearances
                        // on one page and made the hover barely a change at
                        // all. The green chip already says which are.
                        property color paintColor: Ui.rowFill(hovered, selected)

                        ShapePath {
                            fillColor: devBg.paintColor
                            strokeColor: "transparent"
                            strokeWidth: -1

                            startX: devBg.tlrAnim; startY: 0
                            PathLine { x: devBg.width - devBg.trrAnim; y: 0 }
                            PathArc { x: devBg.width; y: devBg.trrAnim; radiusX: devBg.trrAnim; radiusY: devBg.trrAnim; direction: PathArc.Clockwise }
                            PathLine { x: devBg.width; y: devBg.height - devBg.brrAnim }
                            PathArc { x: devBg.width - devBg.brrAnim; y: devBg.height; radiusX: devBg.brrAnim; radiusY: devBg.brrAnim; direction: PathArc.Clockwise }
                            PathLine { x: devBg.blrAnim; y: devBg.height }
                            PathArc { x: 0; y: devBg.height - devBg.blrAnim; radiusX: devBg.blrAnim; radiusY: devBg.blrAnim; direction: PathArc.Clockwise }
                            PathLine { x: 0; y: devBg.tlrAnim }
                            PathArc { x: devBg.tlrAnim; y: 0; radiusX: devBg.tlrAnim; radiusY: devBg.tlrAnim; direction: PathArc.Clockwise }
                        }
                    }

                    DRipple {
                        id: devRip
                        anchors.fill: parent
                        cornerRadius: devBg.tlrAnim
                        rippleColor: Theme.primary
                    }

                    // Free row space toggles the release list (updatable devices)
                    MouseArea {
                        id: devMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: deviceRow.modelData.updatable
                        cursorShape: deviceRow.modelData.updatable ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onPressed: (m) => devRip.trigger(m.x, m.y)
                        onClicked: {
                            deviceRow.expanded = !deviceRow.expanded;
                            if (deviceRow.expanded)
                                view.loadReleases(deviceRow.modelData.deviceId);
                        }
                    }

                // The row grows to its new height over an animation while its content
                // is already at full size; without this the opened part drew outside
                // the row, over its neighbours. Inside the outline, so that stays whole.
                Item {
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true

                    ColumnLayout {
                        id: deviceContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingS - 1
                        spacing: Theme.spacingS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            DIcon {
                                name: view.deviceIcon(deviceRow.modelData)
                                size: 22
                                color: deviceRow.modelData.updatable ? Theme.primary : Theme.surfaceVariantText
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                StyledText {
                                    Layout.fillWidth: true
                                    text: deviceRow.modelData.name
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: {
                                        const parts = [];
                                        if (deviceRow.modelData.vendor)
                                            parts.push(deviceRow.modelData.vendor);
                                        if (deviceRow.modelData.version)
                                            parts.push("firmware " + deviceRow.modelData.version);
                                        return parts.join(" · ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            Rectangle {
                                visible: deviceRow.modelData.updatable && !deviceRow.modelData.blocked
                                Layout.preferredWidth: updatableChip.implicitWidth + 14
                                Layout.preferredHeight: 18
                                radius: 9
                                color: Theme.withAlpha(Theme.success, 0.15)

                                StyledText {
                                    id: updatableChip
                                    anchors.centerIn: parent
                                    text: Tr.t("Updatable")
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: Theme.success
                                }
                            }

                            Rectangle {
                                visible: deviceRow.modelData.blocked
                                Layout.preferredWidth: blockedChip.implicitWidth + 14
                                Layout.preferredHeight: 18
                                radius: 9
                                color: Theme.withAlpha(Theme.warning, 0.15)

                                StyledText {
                                    id: blockedChip
                                    anchors.centerIn: parent
                                    text: deviceRow.modelData.needsPower ? Tr.t("Needs power adapter") : Tr.t("Not updatable right now")
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: Theme.warning
                                }
                            }

                            DActionButton {
                                buttonSize: 26
                                iconName: deviceRow.expanded ? "expand_less" : "expand_more"
                                iconSize: 16
                                iconColor: Theme.surfaceVariantText
                                enabled: deviceRow.modelData.updatable
                                opacity: deviceRow.modelData.updatable ? 1 : 0
                                tooltipText: Tr.t("Firmware releases")
                                onClicked: {
                                    deviceRow.expanded = !deviceRow.expanded;
                                    if (deviceRow.expanded)
                                        view.loadReleases(deviceRow.modelData.deviceId);
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: deviceRow.expanded
                            spacing: Theme.spacingS

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: Theme.withAlpha(Theme.outline, 0.15)
                            }

                            StyledText {
                                visible: deviceRow.releases === "loading"
                                text: Tr.t("Loading firmware releases…")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                visible: Array.isArray(deviceRow.releases) && deviceRow.releases.length === 0
                                text: Tr.t("No firmware releases published on LVFS for this device.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            Repeater {
                                model: Array.isArray(deviceRow.releases) ? deviceRow.releases : []

                                delegate: ColumnLayout {
                                    id: releaseEntry

                                    required property var modelData
                                    required property int index

                                    Layout.fillWidth: true
                                    spacing: 2

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        Rectangle {
                                            Layout.preferredWidth: relVersion.implicitWidth + 14
                                            Layout.preferredHeight: 18
                                            radius: 9
                                            color: Theme.withAlpha(Theme.primary, 0.12)

                                            StyledText {
                                                id: relVersion
                                                anchors.centerIn: parent
                                                text: releaseEntry.modelData.version || "—"
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                font.weight: Font.Medium
                                                color: Theme.primary
                                            }
                                        }

                                        StyledText {
                                            visible: releaseEntry.index === 0 && releaseEntry.modelData.version === deviceRow.modelData.version
                                            text: Tr.t("installed")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.success
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            visible: (releaseEntry.modelData.summary || "") !== ""
                                            text: releaseEntry.modelData.summary
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }

                                    SelectableText {
                                        Layout.fillWidth: true
                                        visible: (releaseEntry.modelData.notesHtml || "") !== ""
                                        text: releaseEntry.modelData.notesHtml
                                        textFormat: Text.RichText
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        }

        // No list to show: fwupd is not installed, or it answered with an
        // error. Said, rather than an empty list that reads as "no devices".
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !view.loading && view.error !== ""

            Column {
                anchors.centerIn: parent
                width: Math.min(parent.width - Theme.spacingL * 2, 460)
                spacing: Theme.spacingM

                DIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: view.error === "missing" ? "memory" : "error"
                    size: 40
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: view.error === "missing" ? Tr.t("fwupd is not installed, so there is no firmware to show. Install the fwupd package, then try again.") : Tr.t("fwupd could not read the device list.")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                SelectableText {
                    width: parent.width
                    visible: view.error !== "missing" && view.error !== "error"
                    horizontalAlignment: Text.AlignHCenter
                    text: view.error
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                DButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    buttonHeight: 32
                    horizontalPadding: Theme.spacingM
                    text: Tr.t("Try again")
                    backgroundColor: Theme.buttonBg
                    textColor: Theme.buttonText
                    onClicked: view.reload()
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.loading

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DSpinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                    size: 40
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Tr.t("Reading device list…")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
