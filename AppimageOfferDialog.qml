import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import qs.Common
import qs.Modals.FileBrowser
import qs.Widgets

// Installing an AppImage from a file, asked in one place — and a Flatpak
// file too, since the file manager and the picker hand over whatever they
// are given (#41). What the file is comes from its bytes, not its name.
Item {
    id: dialog

    property bool animActive: false
    readonly property bool showing: animActive || closeTimer.running

    Timer {
        id: closeTimer
        interval: 220
        repeat: false
    }

    Shortcut {
        sequence: "Escape"
        enabled: dialog.showing
        onActivated: dialog.close()
    }

    // Path or URL as typed, picked or handed over
    property string source: ""
    property var info: null            // inspection of a local file, or null
    property bool inspecting: false
    property bool failed: false
    property bool busy: false          // an install this dialog started
    // "flatpak" once appimage.py has said the file is a bundle or a
    // .flatpakref; it is then read and installed by flatpak_helper.py
    property string fileKind: ""
    readonly property bool isFlatpak: fileKind === "flatpak"

    // args for scripts/appimage.py, and the name to show while it runs
    signal installRequested(var args, string label)
    signal flatpakInstallRequested(string path, string label, string appid, string icon)

    readonly property string scriptPath: Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", "")
    readonly property string flatpakHelper: Qt.resolvedUrl("scripts/flatpak_helper.py").toString().replace("file://", "")
    readonly property bool sourceIsUrl: /^https?:\/\//.test(source.trim())
    readonly property var installedMatch: (!isFlatpak && info && info.installed) ? info.installed : null
    readonly property bool flatpakInstalled: isFlatpak && info !== null && !!info.installed
    // The very build that is installed, or a .flatpakref for an app that is
    // here already: nothing for Install to do
    readonly property bool nothingToDo: flatpakInstalled && info.installed.current === true
    readonly property string iconSource: {
        if (!info)
            return "";
        if (info.icon)
            return "file://" + info.icon;
        return /^https?:\/\//.test(info.iconUrl || "") ? info.iconUrl : "";
    }

    function open() {
        source = "";
        info = null;
        failed = false;
        fileKind = "";
        closeTimer.stop();
        animActive = true;
        sourceField.text = "";
        sourceField.forceActiveFocus();
    }

    function openWithFile(path) {
        source = path;
        sourceField.text = path;
        info = null;
        failed = false;
        closeTimer.stop();
        animActive = true;
        inspect();
    }

    function close() {
        if (!animActive)
            return;
        animActive = false;
        inspecting = false;
        closeTimer.restart();
    }

    function accept() {
        const target = source.trim();
        if (target === "" || inspecting || failed || busy)
            return;

        if (isFlatpak) {
            if (!info || nothingToDo)
                return;
            // The progress line takes a bare path or a URL
            dialog.flatpakInstallRequested(info.path, info.name || info.appid, info.appid || "", iconSource.replace(/^file:\/\//, ""));
            dialog.close();
            return;
        }

        let label = "AppImage";
        if (info && info.name)
            label = info.name;
        else if (sourceIsUrl)
            label = target.split("/").pop().replace(/\.AppImage$/i, "") || "AppImage";

        // scripts/appimage.py takes its mode as a --flag, and replacing an
        // AppImage that is already installed is its own mode: an --install
        // over the top leaves the old one behind.
        if (installedMatch && installedMatch.id)
            dialog.installRequested(["--replace", installedMatch.id, target], label);
        else
            dialog.installRequested(["--install", target, (info && info.name) ? info.name : ""], label);
        dialog.close();
    }

    // Only a local file can be looked into; a URL is a download first and an
    // AppImage afterwards, so it is offered as it stands
    function inspect() {
        const path = source.trim();
        // A reading under way answers for this file; clearing what it is
        // about to fill in would leave a Flatpak's answer looking like an
        // AppImage's
        if (inspectProc.running || flatpakInspectProc.running)
            return;
        info = null;
        failed = false;
        fileKind = "";
        if (path === "" || sourceIsUrl)
            return;
        inspecting = true;
        inspectProc.command = [Backend.python, scriptPath, "--inspect", path];
        inspectProc.running = true;
    }

    Timer {
        id: inspectDebounce
        interval: 350
        repeat: false
        onTriggered: dialog.inspect()
    }

    Process {
        id: inspectProc

        stdout: StdioCollector {
            onStreamFinished: {
                let result = null;
                try {
                    result = JSON.parse(text);
                } catch (e) {
                    result = null;
                }
                if (result && result.ok) {
                    dialog.fileKind = "appimage";
                    dialog.info = result;
                } else if (result && (result.kind === "flatpak-bundle" || result.kind === "flatpakref")) {
                    dialog.fileKind = "flatpak";
                    flatpakInspectProc.command = [Backend.python, dialog.flatpakHelper, "inspect-file", dialog.source.trim()];
                    flatpakInspectProc.running = true;
                } else {
                    dialog.failed = true;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            // Handed over: the second reading decides
            if (dialog.isFlatpak)
                return;
            dialog.inspecting = false;
            if (dialog.info === null)
                dialog.failed = true;
        }
    }

    Process {
        id: flatpakInspectProc

        stdout: StdioCollector {
            onStreamFinished: {
                let result = null;
                try {
                    result = JSON.parse(text);
                } catch (e) {
                    result = null;
                }
                if (result && result.ok) {
                    dialog.fileKind = "flatpak";
                    dialog.info = result;
                } else {
                    dialog.failed = true;
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            dialog.inspecting = false;
            if (dialog.info === null)
                dialog.failed = true;
        }
    }

    Loader {
        id: pickerLoader
        active: false
        sourceComponent: Component {
            FileBrowserModal {
                browserTitle: Tr.t("Select an AppImage")
                fileExtensions: ["*.AppImage", "*.appimage", "*.flatpak", "*.flatpakref", "*.*"]
                onFileSelected: path => {
                    dialog.source = path;
                    sourceField.text = path;
                    dialog.inspect();
                }
            }
        }
    }

    anchors.fill: parent
    visible: showing
    z: 9999

    Rectangle {
        id: dim
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
        }
    }

    StyledRect {
        id: appimageSheet
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 480)
        height: sheetColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius + 4
        color: Ui.cardSurface

        scale: dialog.animActive ? 1.0 : 0.94
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on scale {
            NumberAnimation {
                duration: dialog.animActive ? 320 : 200
                easing.type: dialog.animActive ? Easing.OutBack : Easing.InQuad
                easing.overshoot: 1.15
            }
        }
        Behavior on opacity {
            NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad }
        }

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => wheel.accepted = true
        }

        ColumnLayout {
            id: sheetColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Rectangle {
                    width: 32
                    height: 32
                    radius: 10
                    color: Theme.withAlpha(Theme.primary, 0.15)
                    DankIcon {
                        anchors.centerIn: parent
                        name: dialog.isFlatpak ? "deployed_code" : "note_add"
                        size: 18
                        color: Theme.primary
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: dialog.isFlatpak ? Tr.t("Install a Flatpak") : Tr.t("Install an AppImage")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                DankActionButton {
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    tooltipText: Tr.t("Dismiss")
                    onClicked: dialog.close()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS

                DankTextField {
                    id: sourceField
                    Layout.fillWidth: true
                    placeholderText: Tr.t("Path or URL of an .AppImage…")
                    FieldPlaceholder {
                        text: Tr.t("Path or URL of an .AppImage…")
                    }
                    showClearButton: true
                    onTextChanged: {
                        dialog.source = text;
                        dialog.info = null;
                        dialog.failed = false;
                        dialog.fileKind = "";
                        inspectDebounce.restart();
                    }
                    onAccepted: dialog.accept()
                }

                DankActionButton {
                    buttonSize: 34
                    iconName: "folder_open"
                    iconSize: 18
                    iconColor: Theme.primary
                    tooltipText: Tr.t("Choose an AppImage file")
                    onClicked: {
                        pickerLoader.active = true;
                        if (pickerLoader.item)
                            pickerLoader.item.open();
                    }
                }
            }

            // Info Card
            Rectangle {
                Layout.fillWidth: true
                visible: dialog.inspecting || dialog.info !== null || dialog.failed
                implicitHeight: infoRow.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: dialog.failed ? Theme.withAlpha(Theme.error, 0.12) : Theme.withAlpha(Theme.surface, 0.5)

                RowLayout {
                    id: infoRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingM

                    Image {
                        id: appIcon
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        source: dialog.iconSource
                        sourceSize.width: 80
                        sourceSize.height: 80
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: 10
                        color: dialog.failed ? Theme.withAlpha(Theme.error, 0.15) : Theme.withAlpha(Theme.primary, 0.15)
                        visible: !appIcon.visible

                        DankIcon {
                            anchors.centerIn: parent
                            name: dialog.failed ? "error" : "deployed_code"
                            size: 22
                            color: dialog.failed ? Theme.error : Theme.primary
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (dialog.failed)
                                    return dialog.isFlatpak ? Tr.t("That file could not be read as a Flatpak.") : Tr.t("That file could not be read as an AppImage.");
                                if (dialog.inspecting || !dialog.info)
                                    return dialog.isFlatpak ? Tr.t("Reading the Flatpak…") : Tr.t("Reading the AppImage…");
                                const version = dialog.info.version || "";
                                return version !== "" ? (dialog.info.name || "") + " " + version : (dialog.info.name || "");
                            }
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: dialog.info !== null && !dialog.failed
                            text: {
                                if (!dialog.info)
                                    return "";
                                const size = dialog.formatBytes(dialog.info.sizeBytes);
                                let line;
                                if (dialog.isFlatpak) {
                                    // The repository a .flatpakref adds is said before it is added
                                    const host = (dialog.info.url || "").replace(/^https?:\/\//, "").split("/")[0];
                                    if (dialog.nothingToDo)
                                        line = Tr.t("This one is already installed.");
                                    else if (dialog.flatpakInstalled)
                                        line = Tr.t("You already have this one — replace it with this build?");
                                    else if (dialog.info.kind === "ref" && /^https?:/.test(dialog.info.url || "") && host !== "")
                                        line = Tr.t("Install this Flatpak from %1?").arg(host);
                                    else
                                        line = Tr.t("Install this Flatpak?");
                                    // A .flatpakref is a few lines of text; its size says nothing
                                    return (size !== "" && dialog.info.kind === "bundle") ? line + " · " + size : line;
                                }
                                line = dialog.installedMatch ? Tr.t("You already have this one — replace it with this build?") : Tr.t("Install this AppImage into your AppImages folder?");
                                return size !== "" ? line + " · " + size : line;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacingXS
                spacing: Theme.spacingS

                Item {
                    Layout.fillWidth: true
                }

                // Two separate actions, not a connected group: Cancel is
                // tonal, Install the one filled button. Pressing turns a
                // button into a pill (Ui.buttonFill has the emphasis rules).
                Rectangle {
                    id: cancelBtn
                    width: cancelRow.implicitWidth + 24
                    height: 32
                    property bool isHovered: cancelMa.containsMouse

                    radius: cancelMa.pressed ? (height / 2) : Theme.cornerRadius
                    Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                    color: Ui.buttonFill("tonal", isHovered)
                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                    scale: cancelMa.pressed ? 0.94 : 1.0
                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                    DankRipple {
                        id: cancelRip
                        anchors.fill: parent
                        cornerRadius: parent.radius
                        rippleColor: Ui.buttonInk("tonal")
                    }

                    RowLayout {
                        id: cancelRow
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            name: "close"
                            size: 14
                            color: Ui.buttonInk("tonal")
                        }

                        StyledText {
                            text: Tr.t("Cancel")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Ui.buttonInk("tonal")
                        }
                    }

                    MouseArea {
                        id: cancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: (m) => cancelRip.trigger(m.x, m.y)
                        onClicked: dialog.close()
                    }
                }

                Rectangle {
                    id: acceptBtn
                    readonly property bool btnEnabled: dialog.source.trim() !== "" && !dialog.inspecting && !dialog.failed && !dialog.busy && !dialog.nothingToDo
                    width: acceptRow.implicitWidth + 24
                    height: 32
                    property bool isHovered: acceptMa.containsMouse && btnEnabled

                    radius: acceptMa.pressed ? (height / 2) : Theme.cornerRadius
                    Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                    color: Ui.buttonFill("filled", isHovered)
                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                    scale: acceptMa.pressed ? 0.94 : 1.0
                    opacity: btnEnabled ? 1.0 : 0.5
                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }
                    Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }

                    DankRipple {
                        id: acceptRip
                        anchors.fill: parent
                        cornerRadius: parent.radius
                        rippleColor: Ui.buttonInk("filled")
                    }

                    RowLayout {
                        id: acceptRow
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            name: (dialog.installedMatch || dialog.flatpakInstalled) ? "sync" : "download"
                            size: 14
                            color: Ui.buttonInk("filled")
                        }

                        StyledText {
                            text: (dialog.installedMatch || dialog.flatpakInstalled) ? Tr.t("Replace") : Tr.t("Install")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Ui.buttonInk("filled")
                        }
                    }

                    MouseArea {
                        id: acceptMa
                        anchors.fill: parent
                        hoverEnabled: acceptBtn.btnEnabled
                        cursorShape: acceptBtn.btnEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onPressed: (m) => {
                            if (acceptBtn.btnEnabled)
                                acceptRip.trigger(m.x, m.y);
                        }
                        onClicked: {
                            if (acceptBtn.btnEnabled)
                                dialog.accept();
                        }
                    }
                }
            }
        }
    }

    function formatBytes(bytes) {
        if (!bytes || bytes <= 0)
            return "";
        if (bytes >= 1e9)
            return (bytes / 1e9).toFixed(1) + " GB";
        if (bytes >= 1e6)
            return Math.round(bytes / 1e6) + " MB";
        return Math.max(1, Math.round(bytes / 1e3)) + " kB";
    }
}
