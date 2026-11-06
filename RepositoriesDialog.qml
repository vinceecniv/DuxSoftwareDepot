import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets

// Where software comes from, in one place: the repositories the system is
// configured with, the Flatpak remotes, and the handful of extra sources most
// people end up wanting anyway.
//
// Changes are deliberately narrow. Enabling and disabling an existing
// repository, adding the well-known third-party sources and adding or
// removing a Copr are the operations that are safe to express as a button;
// hand-writing a repository definition is not, and stays a job for a text
// editor.
Item {
    id: dialog

    property var logger: null

    property bool animActive: false
    readonly property bool showing: animActive || closeTimer.running
    property var sourceData: ({})
    property bool loading: false
    property bool busy: false
    property string busyLabel: ""
    property string error: ""
    property bool showNoise: false
    property string confirmId: ""

    readonly property bool writable: sourceData.writable === true
    readonly property var repos: sourceData.repos || []
    readonly property var remotes: (sourceData.flatpak || []).filter(r => !r.local)
    readonly property var suggestions: (sourceData.suggestions || []).filter(s => !s.present)
    readonly property var flatpakCatalog: sourceData.flatpakCatalog || []

    readonly property var visibleRepos: repos.filter(r => dialog.showNoise || (!r.noise && !r.testing))

    Timer {
        id: closeTimer
        interval: 220
        repeat: false
    }

    function open() {
        closeTimer.stop();
        animActive = true;
        error = "";
        confirmId = "";
        refresh();
    }

    function close() {
        if (!animActive) return;
        animActive = false;
        closeTimer.restart();
    }

    function refresh() {
        if (listProcess.running)
            return;
        loading = true;
        listProcess._output = "";
        listProcess.command = Backend.repoListCommand();
        listProcess.running = true;
    }

    // Every change runs the same way: a command, a spinner, a refreshed list.
    // The label is what the log and the busy line say it was.
    // logLabel is {key, args}: the same sentence as logTitle, kept in pieces so
    // the log can be read back in whatever language the interface is in later
    function _run(command, label, logTitle, logLabel) {
        if (busy)
            return;
        error = "";
        busy = true;
        busyLabel = label;
        adminProcess._label = logTitle || "";
        adminProcess._logLabel = logLabel || null;
        adminProcess._detail = "";
        adminProcess._code = "";
        adminProcess._chroot = "";
        adminProcess.command = command;
        adminProcess.running = true;
    }

    function setRepoEnabled(repo, enabled) {
        _run(Backend.repoAdminCommand([enabled ? "enable" : "disable", repo.id]), enabled ? Tr.t("Enabling %1…").arg(repo.id) : Tr.t("Disabling %1…").arg(repo.id), enabled ? Tr.t("Enabled the %1 repository").arg(repo.id) : Tr.t("Disabled the %1 repository").arg(repo.id), {
            key: enabled ? "Enabled the %1 repository" : "Disabled the %1 repository",
            args: [repo.id]
        });
    }

    function addCopr(project) {
        const cleaned = project.trim();
        if (cleaned === "")
            return;
        _run(Backend.repoAdminCommand(["copr-enable", cleaned]), Tr.t("Adding %1…").arg(cleaned), Tr.t("Added the Copr %1").arg(cleaned), {
            key: "Added the Copr %1",
            args: [cleaned]
        });
    }

    function removeCopr(project) {
        _run(Backend.repoAdminCommand(["copr-remove", project]), Tr.t("Removing %1…").arg(project), Tr.t("Removed the Copr %1").arg(project), {
            key: "Removed the Copr %1",
            args: [project]
        });
    }

    function addRemote(url) {
        const cleaned = url.trim();
        if (cleaned === "")
            return;
        // The name is left to the helper: a .flatpakrepo file names the remote
        // it describes, so asking for one as well would be asking twice
        _run(Backend.repoUserCommand(["flatpak-add", "", cleaned]), Tr.t("Adding %1…").arg(cleaned), Tr.t("Added a Flatpak remote from %1").arg(cleaned), {
            key: "Added a Flatpak remote from %1",
            args: [cleaned]
        });
    }

    function addCatalogRemote(entry) {
        _run(Backend.repoUserCommand(["flatpak-add", entry.name, entry.url]), Tr.t("Adding %1…").arg(entry.title), Tr.t("Added the Flatpak remote %1").arg(entry.title), {
            key: "Added the Flatpak remote %1",
            args: [entry.title]
        });
    }

    // Said here rather than in the helper, so it can be translated
    function remoteDetail(name) {
        switch (name) {
        case "flathub":
            return Tr.t("The Flatpak store most applications publish to.");
        case "flathub-beta":
            return Tr.t("Test builds of the same applications, before they reach Flathub.");
        case "fedora":
            return Tr.t("Fedora's own Flatpaks, built from the packages the distribution maintains.");
        case "gnome-nightly":
            return Tr.t("Daily builds of GNOME applications, straight from development.");
        case "kdeapps":
            return Tr.t("Daily builds of KDE applications, straight from development.");
        }
        return "";
    }

    function addSuggestion(entry) {
        const title = dialog.suggestionTitle(entry);
        _run(Backend.repoAdminCommand(["rpmfusion"].concat(entry.flavours || [])), Tr.t("Adding %1…").arg(title), Tr.t("Added %1").arg(title), {
            key: "Added %1",
            args: [title]
        });
    }

    function removeRemote(remote) {
        _run(remote.scope === "system" ? Backend.repoAdminCommand(["flatpak-remove", remote.name, "system"]) : Backend.repoUserCommand(["flatpak-remove", remote.name, "user"]), Tr.t("Removing %1…").arg(remote.name), Tr.t("Removed the Flatpak remote %1").arg(remote.name), {
            key: "Removed the Flatpak remote %1",
            args: [remote.name]
        });
    }

    function suggestionTitle(entry) {
        if (entry.id === "rpmfusion-free")
            return Tr.t("RPM Fusion (free)");
        if (entry.id === "rpmfusion-nonfree")
            return Tr.t("RPM Fusion (nonfree)");
        return Tr.t("RPM Fusion");
    }

    function suggestionDetail(entry) {
        if (entry.id === "rpmfusion-free")
            return Tr.t("Codecs and media software Fedora cannot ship itself.");
        if (entry.id === "rpmfusion-nonfree")
            return Tr.t("Hardware drivers and software with redistribution restrictions.");
        return Tr.t("Codecs, media software and hardware drivers Fedora cannot ship itself. Adds both repositories: most of nonfree builds on free.");
    }

    function repoLabel(repo) {
        if (repo.kind === "copr" && repo.project !== "")
            return repo.project;
        return repo.name !== "" ? repo.name : repo.id;
    }

    anchors.fill: parent
    visible: showing
    z: 120

    Shortcut {
        sequence: "Escape"
        enabled: dialog.showing
        onActivated: dialog.close()
    }

    onShowingChanged: {
        if (showing)
            dialogFocus.forceActiveFocus();
    }

    Item {
        id: dialogFocus

        Keys.onEscapePressed: dialog.close()
    }

    Process {
        id: listProcess

        property string _output: ""

        stdout: SplitParser {
            onRead: line => listProcess._output += line
        }

        onExited: (exitCode, exitStatus) => {
            dialog.loading = false;
            if (exitCode !== 0) {
                dialog.error = Tr.t("The list of sources could not be read.");
                return;
            }
            try {
                dialog.sourceData = JSON.parse(listProcess._output);
            } catch (e) {
                dialog.error = Tr.t("The list of sources could not be read.");
            }
        }
    }

    // "fedora-44-x86_64" said the way people say it
    function chrootLabel(chroot) {
        const parts = /^fedora-([^-]+)-(.+)$/.exec(chroot);
        if (!parts)
            return chroot;
        return (parts[1] === "rawhide" ? Tr.t("Fedora Rawhide") : "Fedora " + parts[1]) + " (" + parts[2] + ")";
    }

    Process {
        id: adminProcess

        property string _label: ""
        property var _logLabel: null
        property string _detail: ""
        property string _code: ""
        property string _chroot: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "op-error" || event.event === "error") {
                    adminProcess._detail = event.detail || event.message || "";
                    adminProcess._code = event.code || "";
                    adminProcess._chroot = event.chroot || "";
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            dialog.busy = false;
            dialog.busyLabel = "";
            dialog.confirmId = "";
            if (exitCode === 126 || exitCode === 127) {
                // pkexec's own refusal, which is not a failure of the change
                dialog.error = Tr.t("The authorisation was refused.");
            } else if (exitCode !== 0) {
                // dnf answers the chroot case with the project's entire chroot
                // list, mostly EPEL, which buries the one fact that matters
                if (adminProcess._code === "copr-no-chroot")
                    dialog.error = Tr.t("This Copr has no builds for %1.").arg(dialog.chrootLabel(adminProcess._chroot));
                else
                    dialog.error = adminProcess._detail !== "" ? adminProcess._detail : Tr.t("The change could not be made.");
            } else if (dialog.logger && adminProcess._label !== "") {
                dialog.logger.record("sources", adminProcess._label, [], 0, adminProcess._logLabel);
            }
            dialog.refresh();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    StyledRect {
        id: sheet

        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 760)
        height: Math.min(parent.height - Theme.spacingXL * 2, 640)
        radius: Theme.cornerRadius + 4
        color: Ui.cardSurface
        border.width: 0
        scale: dialog.animActive ? 1.0 : 0.94
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on scale { NumberAnimation { duration: dialog.animActive ? 320 : 200; easing.type: dialog.animActive ? Easing.OutBack : Easing.InQuad } }
        Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => wheel.accepted = true
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                DIcon {
                    name: "database"
                    size: 22
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Software sources")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                DSpinner {
                    visible: dialog.busy || dialog.loading
                    size: 18
                }

                DActionButton {
                    buttonSize: 30
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    onClicked: dialog.close()
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: dialog.busyLabel !== ""
                text: dialog.busyLabel
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                visible: dialog.error !== ""
                text: dialog.error
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
            }

            // Distros other than Fedora are listed but not changed here
            StyledText {
                Layout.fillWidth: true
                visible: !dialog.writable && !dialog.loading
                text: Tr.t("Sources are shown for reference on this distribution. Changing them from here is only supported on the dnf family.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Flickable {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: content
                    width: scroll.width
                    spacing: Theme.spacingM

                    // ── Sources worth having (Container Card) ───────────────
                    StyledRect {
                        Layout.fillWidth: true
                        visible: dialog.suggestions.length > 0
                        radius: Theme.cornerRadius
                        // The rows inside carry their own surface
                        color: "transparent"
                        border.width: 0
                        implicitHeight: suggCol.implicitHeight + Theme.spacingM * 2

                        ColumnLayout {
                            id: suggCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "recommend"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Not configured yet")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }
                            }

                            Repeater {
                                model: dialog.suggestions

                                delegate: Item {
                                    id: suggestionCard
                                    required property var modelData
                                    required property int index

                                    readonly property int totalCount: dialog.suggestions.length
                                    readonly property bool isFirst: index === 0
                                    readonly property bool isLast: index === totalCount - 1

                                    Layout.fillWidth: true
                                    implicitHeight: suggestionRow.implicitHeight + Theme.spacingM * 2

                                    Shape {
                                        id: suggBg
                                        anchors.fill: parent

                                        property real innerRadius: 6
                                        property real outerRadius: 12
                                        property bool hovered: suggMa.containsMouse
                                        // The shape answers a press, not the pointer passing over (#22)
                                        property bool morphed: suggMa.pressed

                                        property real tlr: morphed ? (height / 2) : (suggestionCard.isFirst ? outerRadius : innerRadius)
                                        property real trr: morphed ? (height / 2) : (suggestionCard.isFirst ? outerRadius : innerRadius)
                                        property real blr: morphed ? (height / 2) : (suggestionCard.isLast ? outerRadius : innerRadius)
                                        property real brr: morphed ? (height / 2) : (suggestionCard.isLast ? outerRadius : innerRadius)

                                        property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                                        ShapePath {
                                            fillColor: Ui.rowFill(suggBg.hovered, false)
                                            strokeColor: "transparent"
                                            strokeWidth: -1

                                            startX: suggBg.tlrAnim; startY: 0
                                            PathLine { x: suggBg.width - suggBg.trrAnim; y: 0 }
                                            PathArc { x: suggBg.width; y: suggBg.trrAnim; radiusX: suggBg.trrAnim; radiusY: suggBg.trrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: suggBg.width; y: suggBg.height - suggBg.brrAnim }
                                            PathArc { x: suggBg.width - suggBg.brrAnim; y: suggBg.height; radiusX: suggBg.brrAnim; radiusY: suggBg.brrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: suggBg.blrAnim; y: suggBg.height }
                                            PathArc { x: 0; y: suggBg.height - suggBg.blrAnim; radiusX: suggBg.blrAnim; radiusY: suggBg.blrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: 0; y: suggBg.tlrAnim }
                                            PathArc { x: suggBg.tlrAnim; y: 0; radiusX: suggBg.tlrAnim; radiusY: suggBg.tlrAnim; direction: PathArc.Clockwise }
                                        }
                                    }

                                    MouseArea {
                                        id: suggMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }

                                    RowLayout {
                                        id: suggestionRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM

                                        DIcon {
                                            name: "extension"
                                            size: 20
                                            color: Theme.primary
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: dialog.suggestionTitle(suggestionCard.modelData)
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.DemiBold
                                                color: Theme.surfaceText
                                            }

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: dialog.suggestionDetail(suggestionCard.modelData)
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }

                                        Item {
                                            implicitWidth: suggestionButton.width
                                            implicitHeight: suggestionButton.height

                                            DButton {
                                                id: suggestionButton
                                                buttonHeight: 28
                                                horizontalPadding: Theme.spacingM
                                                iconName: "add"
                                                iconSize: 14
                                                text: Tr.t("Add")
                                                enabled: !dialog.busy
                                                backgroundColor: Theme.buttonBg
                                                textColor: Theme.buttonText
                                                onClicked: dialog.addSuggestion(suggestionCard.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Flatpak remotes (Container Card) ─────────────────────
                    StyledRect {
                        Layout.fillWidth: true
                        visible: dialog.remotes.length > 0
                        radius: Theme.cornerRadius
                        // The rows inside carry their own surface
                        color: "transparent"
                        border.width: 0
                        implicitHeight: remotesCol.implicitHeight + Theme.spacingM * 2

                        ColumnLayout {
                            id: remotesCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "deployed_code"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Flatpak remotes (%1)").arg(dialog.remotes.length)
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }
                            }

                            Repeater {
                                model: dialog.remotes

                                delegate: Item {
                                    id: remoteRow
                                    required property var modelData
                                    required property int index

                                    readonly property int totalCount: dialog.remotes.length
                                    readonly property bool isFirst: index === 0
                                    readonly property bool isLast: index === totalCount - 1

                                    Layout.fillWidth: true
                                    implicitHeight: remoteInnerRow.implicitHeight + Theme.spacingS * 2

                                    Shape {
                                        id: remoteBg
                                        anchors.fill: parent

                                        property real innerRadius: 6
                                        property real outerRadius: 12
                                        property bool hovered: remoteMa.containsMouse
                                        // The shape answers a press, not the pointer passing over (#22)
                                        property bool morphed: remoteMa.pressed

                                        property real tlr: morphed ? (height / 2) : (remoteRow.isFirst ? outerRadius : innerRadius)
                                        property real trr: morphed ? (height / 2) : (remoteRow.isFirst ? outerRadius : innerRadius)
                                        property real blr: morphed ? (height / 2) : (remoteRow.isLast ? outerRadius : innerRadius)
                                        property real brr: morphed ? (height / 2) : (remoteRow.isLast ? outerRadius : innerRadius)

                                        property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                                        ShapePath {
                                            fillColor: Ui.rowFill(remoteBg.hovered, false)
                                            strokeColor: "transparent"
                                            strokeWidth: -1

                                            startX: remoteBg.tlrAnim; startY: 0
                                            PathLine { x: remoteBg.width - remoteBg.trrAnim; y: 0 }
                                            PathArc { x: remoteBg.width; y: remoteBg.trrAnim; radiusX: remoteBg.trrAnim; radiusY: remoteBg.trrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: remoteBg.width; y: remoteBg.height - remoteBg.brrAnim }
                                            PathArc { x: remoteBg.width - remoteBg.brrAnim; y: remoteBg.height; radiusX: remoteBg.brrAnim; radiusY: remoteBg.brrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: remoteBg.blrAnim; y: remoteBg.height }
                                            PathArc { x: 0; y: remoteBg.height - remoteBg.blrAnim; radiusX: remoteBg.blrAnim; radiusY: remoteBg.blrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: 0; y: remoteBg.tlrAnim }
                                            PathArc { x: remoteBg.tlrAnim; y: 0; radiusX: remoteBg.tlrAnim; radiusY: remoteBg.tlrAnim; direction: PathArc.Clockwise }
                                        }
                                    }

                                    MouseArea {
                                        id: remoteMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }

                                    RowLayout {
                                        id: remoteInnerRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.margins: Theme.spacingS
                                        spacing: Theme.spacingM

                                        DIcon {
                                            name: "cloud_done"
                                            size: 18
                                            color: Theme.primary
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: remoteRow.modelData.title !== "" ? remoteRow.modelData.title : remoteRow.modelData.name
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: remoteRow.modelData.url
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }
                                        }

                                        Rectangle {
                                            implicitWidth: scopeLabel.implicitWidth + Theme.spacingS * 2
                                            implicitHeight: 20
                                            radius: height / 2
                                            color: Theme.withAlpha(Theme.primary, 0.15)

                                            StyledText {
                                                id: scopeLabel
                                                anchors.centerIn: parent
                                                text: remoteRow.modelData.scope === "user" ? Tr.t("user") : Tr.t("system")
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                font.weight: Font.Medium
                                                color: Theme.primary
                                            }
                                        }

                                        DActionButton {
                                            buttonSize: 28
                                            iconName: "delete"
                                            iconSize: 15
                                            enabled: !dialog.busy
                                            iconColor: dialog.confirmId === "remote:" + remoteRow.modelData.name + remoteRow.modelData.scope ? Theme.error : Theme.surfaceVariantText
                                            tooltipText: dialog.confirmId === "remote:" + remoteRow.modelData.name + remoteRow.modelData.scope ? Tr.t("Click again to confirm") : Tr.t("Remove")
                                            onClicked: {
                                                const key = "remote:" + remoteRow.modelData.name + remoteRow.modelData.scope;
                                                if (dialog.confirmId === key)
                                                    dialog.removeRemote(remoteRow.modelData);
                                                else
                                                    dialog.confirmId = key;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Well-known Flatpak sources (Container Card) ─────────
                    StyledRect {
                        Layout.fillWidth: true
                        visible: dialog.flatpakCatalog.length > 0
                        radius: Theme.cornerRadius
                        // The rows inside carry their own surface
                        color: "transparent"
                        border.width: 0
                        implicitHeight: catalogCol.implicitHeight + Theme.spacingM * 2

                        ColumnLayout {
                            id: catalogCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "storefront"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Well-known Flatpak sources")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }
                            }

                            Repeater {
                                model: dialog.flatpakCatalog

                                delegate: Item {
                                    id: catalogRow
                                    required property var modelData
                                    required property int index

                                    readonly property int totalCount: dialog.flatpakCatalog.length
                                    readonly property bool isFirst: index === 0
                                    readonly property bool isLast: index === totalCount - 1

                                    Layout.fillWidth: true
                                    implicitHeight: catalogInnerRow.implicitHeight + Theme.spacingS * 2

                                    Shape {
                                        id: catBg
                                        anchors.fill: parent

                                        property real innerRadius: 6
                                        property real outerRadius: 12
                                        property bool hovered: catMa.containsMouse
                                        // The shape answers a press, not the pointer passing over (#22)
                                        property bool morphed: catMa.pressed

                                        property real tlr: morphed ? (height / 2) : (catalogRow.isFirst ? outerRadius : innerRadius)
                                        property real trr: morphed ? (height / 2) : (catalogRow.isFirst ? outerRadius : innerRadius)
                                        property real blr: morphed ? (height / 2) : (catalogRow.isLast ? outerRadius : innerRadius)
                                        property real brr: morphed ? (height / 2) : (catalogRow.isLast ? outerRadius : innerRadius)

                                        property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                                        ShapePath {
                                            fillColor: Ui.rowFill(catBg.hovered, false)
                                            strokeColor: "transparent"
                                            strokeWidth: -1

                                            startX: catBg.tlrAnim; startY: 0
                                            PathLine { x: catBg.width - catBg.trrAnim; y: 0 }
                                            PathArc { x: catBg.width; y: catBg.trrAnim; radiusX: catBg.trrAnim; radiusY: catBg.trrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: catBg.width; y: catBg.height - catBg.brrAnim }
                                            PathArc { x: catBg.width - catBg.brrAnim; y: catBg.height; radiusX: catBg.brrAnim; radiusY: catBg.brrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: catBg.blrAnim; y: catBg.height }
                                            PathArc { x: 0; y: catBg.height - catBg.blrAnim; radiusX: catBg.blrAnim; radiusY: catBg.blrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: 0; y: catBg.tlrAnim }
                                            PathArc { x: catBg.tlrAnim; y: 0; radiusX: catBg.tlrAnim; radiusY: catBg.tlrAnim; direction: PathArc.Clockwise }
                                        }
                                    }

                                    MouseArea {
                                        id: catMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }

                                    RowLayout {
                                        id: catalogInnerRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.margins: Theme.spacingS
                                        spacing: Theme.spacingM

                                        DIcon {
                                            name: catalogRow.modelData.present ? "check_circle" : "store"
                                            size: 18
                                            color: catalogRow.modelData.present ? Theme.success : Theme.primary
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: catalogRow.modelData.title
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: dialog.remoteDetail(catalogRow.modelData.name)
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }

                                        Rectangle {
                                            visible: catalogRow.modelData.present
                                            implicitWidth: addedBadge.implicitWidth + Theme.spacingS * 2
                                            implicitHeight: 20
                                            radius: height / 2
                                            color: Theme.withAlpha(Theme.success, 0.15)

                                            StyledText {
                                                id: addedBadge
                                                anchors.centerIn: parent
                                                text: Tr.t("Added")
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                font.weight: Font.Medium
                                                color: Theme.success
                                            }
                                        }

                                        Item {
                                            visible: !catalogRow.modelData.present
                                            implicitWidth: catalogButton.width
                                            implicitHeight: catalogButton.height

                                            DButton {
                                                id: catalogButton
                                                buttonHeight: 28
                                                horizontalPadding: Theme.spacingM
                                                iconName: "add"
                                                iconSize: 14
                                                text: Tr.t("Add")
                                                enabled: !dialog.busy
                                                backgroundColor: Theme.buttonBg
                                                textColor: Theme.buttonText
                                                onClicked: dialog.addCatalogRemote(catalogRow.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Add a Flatpak remote (Container Card) ────────────────
                    StyledRect {
                        Layout.fillWidth: true
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)
                        border.width: 0
                        implicitHeight: addRemoteCol.implicitHeight + Theme.spacingM * 2

                        ColumnLayout {
                            id: addRemoteCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "add_link"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Add a Flatpak remote")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingM

                                DTextField {
                                    id: remoteField
                                    Layout.fillWidth: true
                                    placeholderText: Tr.t("Address of a .flatpakrepo file")
                                    FieldPlaceholder {
                                        text: Tr.t("Address of a .flatpakrepo file")
                                    }
                                    leftIconName: "link"
                                    onAccepted: {
                                        dialog.addRemote(text);
                                        text = "";
                                    }
                                }

                                Item {
                                    implicitWidth: remoteButton.width
                                    implicitHeight: remoteButton.height

                                    DButton {
                                        id: remoteButton
                                        buttonHeight: 30
                                        horizontalPadding: Theme.spacingM
                                        iconName: "add"
                                        iconSize: 14
                                        text: Tr.t("Add")
                                        enabled: !dialog.busy && remoteField.text.trim() !== ""
                                        backgroundColor: Theme.buttonBg
                                        textColor: Theme.buttonText
                                        onClicked: {
                                            dialog.addRemote(remoteField.text);
                                            remoteField.text = "";
                                        }
                                    }
                                }
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: Tr.t("For anything not listed above. Added for you alone, so it needs no password.")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // ── Configured repositories (Container Card) ────────────
                    StyledRect {
                        Layout.fillWidth: true
                        radius: Theme.cornerRadius
                        // The rows inside carry their own surface
                        color: "transparent"
                        border.width: 0
                        implicitHeight: reposCol.implicitHeight + Theme.spacingM * 2

                        ColumnLayout {
                            id: reposCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingM

                                DIcon {
                                    name: "inventory_2"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: Tr.t("Repositories (%1)").arg(dialog.visibleRepos.length)
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }

                                Item {
                                    implicitWidth: noiseButton.width
                                    implicitHeight: noiseButton.height

                                    DButton {
                                        id: noiseButton
                                        buttonHeight: 26
                                        horizontalPadding: Theme.spacingM
                                        iconName: dialog.showNoise ? "visibility_off" : "visibility"
                                        iconSize: 14
                                        text: dialog.showNoise ? Tr.t("Hide debug/source repos") : Tr.t("Show debug/source repos")
                                        backgroundColor: Ui.buttonFill("tonal", false)
                                        textColor: Ui.buttonInk("tonal")
                                        onClicked: dialog.showNoise = !dialog.showNoise
                                    }
                                }
                            }

                            Repeater {
                                model: dialog.visibleRepos

                                delegate: Item {
                                    id: repoRow
                                    required property var modelData
                                    required property int index

                                    readonly property bool isDistro: modelData.kind === "distro"
                                    readonly property string confirmKey: "repo:" + modelData.id
                                    readonly property bool awaitingConfirm: dialog.confirmId === confirmKey
                                    readonly property int totalCount: dialog.visibleRepos.length
                                    readonly property bool isFirst: index === 0
                                    readonly property bool isLast: index === totalCount - 1

                                    Layout.fillWidth: true
                                    implicitHeight: repoInnerRow.implicitHeight + Theme.spacingS * 2

                                    Shape {
                                        id: repoBg
                                        anchors.fill: parent

                                        property real innerRadius: 6
                                        property real outerRadius: 12
                                        property bool hovered: repoMa.containsMouse
                                        // The shape answers a press, not the pointer passing over (#22)
                                        property bool morphed: repoMa.pressed

                                        property real tlr: morphed ? (height / 2) : (repoRow.isFirst ? outerRadius : innerRadius)
                                        property real trr: morphed ? (height / 2) : (repoRow.isFirst ? outerRadius : innerRadius)
                                        property real blr: morphed ? (height / 2) : (repoRow.isLast ? outerRadius : innerRadius)
                                        property real brr: morphed ? (height / 2) : (repoRow.isLast ? outerRadius : innerRadius)

                                        property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                        property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                                        ShapePath {
                                            fillColor: Ui.rowFill(repoBg.hovered, false)
                                            strokeColor: "transparent"
                                            strokeWidth: -1

                                            startX: repoBg.tlrAnim; startY: 0
                                            PathLine { x: repoBg.width - repoBg.trrAnim; y: 0 }
                                            PathArc { x: repoBg.width; y: repoBg.trrAnim; radiusX: repoBg.trrAnim; radiusY: repoBg.trrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: repoBg.width; y: repoBg.height - repoBg.brrAnim }
                                            PathArc { x: repoBg.width - repoBg.brrAnim; y: repoBg.height; radiusX: repoBg.brrAnim; radiusY: repoBg.brrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: repoBg.blrAnim; y: repoBg.height }
                                            PathArc { x: 0; y: repoBg.height - repoBg.blrAnim; radiusX: repoBg.blrAnim; radiusY: repoBg.blrAnim; direction: PathArc.Clockwise }
                                            PathLine { x: 0; y: repoBg.tlrAnim }
                                            PathArc { x: repoBg.tlrAnim; y: 0; radiusX: repoBg.tlrAnim; radiusY: repoBg.tlrAnim; direction: PathArc.Clockwise }
                                        }
                                    }

                                    MouseArea {
                                        id: repoMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                    }

                                    RowLayout {
                                        id: repoInnerRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.margins: Theme.spacingS
                                        spacing: Theme.spacingM

                                        DIcon {
                                            name: repoRow.modelData.kind === "copr" ? "person" : (repoRow.isDistro ? "verified" : "public")
                                            size: 18
                                            color: repoRow.isDistro ? Theme.primary : Theme.surfaceVariantText
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: dialog.repoLabel(repoRow.modelData)
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: repoRow.awaitingConfirm ? Tr.t("This is part of the distribution — click the switch again to confirm.") : repoRow.modelData.id
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                color: repoRow.awaitingConfirm ? Theme.warning : Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }
                                        }

                                        DActionButton {
                                            visible: repoRow.modelData.kind === "copr" && repoRow.modelData.project !== ""
                                            buttonSize: 28
                                            iconName: "delete"
                                            iconSize: 15
                                            enabled: !dialog.busy && dialog.writable
                                            iconColor: dialog.confirmId === "copr:" + repoRow.modelData.project ? Theme.error : Theme.surfaceVariantText
                                            tooltipText: dialog.confirmId === "copr:" + repoRow.modelData.project ? Tr.t("Click again to confirm") : Tr.t("Remove")
                                            onClicked: {
                                                const key = "copr:" + repoRow.modelData.project;
                                                if (dialog.confirmId === key)
                                                    dialog.removeCopr(repoRow.modelData.project);
                                                else
                                                    dialog.confirmId = key;
                                            }
                                        }

                                        Item {
                                            implicitWidth: 52
                                            implicitHeight: 30

                                            DToggle {
                                                anchors.fill: parent
                                                hideText: true
                                                checked: repoRow.modelData.enabled
                                                enabled: dialog.writable && !dialog.busy
                                                onToggled: checked => {
                                                    if (!checked && repoRow.isDistro && !repoRow.awaitingConfirm) {
                                                        dialog.confirmId = repoRow.confirmKey;
                                                        return;
                                                    }
                                                    dialog.setRepoEnabled(repoRow.modelData, checked);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Add a Copr (Container Card) ─────────────────────────
                    StyledRect {
                        Layout.fillWidth: true
                        visible: dialog.writable
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)
                        border.width: 0
                        implicitHeight: addCoprCol.implicitHeight + Theme.spacingM * 2

                        ColumnLayout {
                            id: addCoprCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "person_add"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Add a Copr")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingM

                                DTextField {
                                    id: coprField
                                    Layout.fillWidth: true
                                    placeholderText: Tr.t("owner/project")
                                    FieldPlaceholder {
                                        text: Tr.t("owner/project")
                                    }
                                    leftIconName: "person_add"
                                    onAccepted: {
                                        dialog.addCopr(text);
                                        text = "";
                                    }
                                }

                                Item {
                                    implicitWidth: coprButton.width
                                    implicitHeight: coprButton.height

                                    DButton {
                                        id: coprButton
                                        buttonHeight: 30
                                        horizontalPadding: Theme.spacingM
                                        iconName: "add"
                                        iconSize: 14
                                        text: Tr.t("Add")
                                        enabled: !dialog.busy && coprField.text.trim() !== ""
                                        backgroundColor: Theme.buttonBg
                                        textColor: Theme.buttonText
                                        onClicked: {
                                            dialog.addCopr(coprField.text);
                                            coprField.text = "";
                                        }
                                    }
                                }
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: Tr.t("Copr repositories are built by individuals, not by the distribution. Their packages are as trustworthy as their owner.")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }
        }
    }
}
