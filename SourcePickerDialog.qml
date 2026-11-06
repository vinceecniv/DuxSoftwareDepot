import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// Which of them do you want?
//
// An app carried by both Fedora and Flathub used to put a button for each in
// every row, and the reader was expected to already know the difference. Two
// buttons is also the loudest a row gets for the least reason: the second one
// is not another action, it is the same action with a footnote nobody wrote
// down. So the row asks once, and the answer is this.
//
// It opens on what the search index already has — which sources exist, and
// what each kind means for the sandbox — because that is instant and it is
// most of the decision. Versions and sizes come from `remote-info` and
// `repoquery`, which are processes, so they arrive a moment later and fill in
// around what is already on screen.
Item {
    id: picker

    property bool showing: false
    property var appData: ({})
    property var info: ({})
    property bool loading: false
    property string busyRef: ""
    readonly property string scriptPath: Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", "")

    signal installRequested(var source)

    // What the index knows, with anything the enrichment has since said about
    // the same source merged over it. Matching on kind and ref rather than on
    // position: the two lists are built by different code from different
    // data, and only one of them is guaranteed to be complete.
    readonly property var origins: {
        const rows = [];
        for (const source of (appData.sources || [])) {
            rows.push({
                kind: source.kind,
                ref: source.ref,
                origin: source.kind === "flatpak" ? "remote" : (source.kind === "copr" ? "copr" : (source.kind === "appimage" ? "appimage" : "distro")),
                detail: source.kind === "flatpak" ? ((source.source || "flathub").charAt(0).toUpperCase() + (source.source || "flathub").slice(1)) : (source.kind === "copr" ? (source.project || "") : ""),
                sandbox: source.kind === "flatpak" ? "flatpak" : "none",
                version: "",
                download: "",
                installed: "",
                _source: source
            });
        }
        for (const enriched of (info.origins || [])) {
            const row = rows.find(candidate => candidate.kind === enriched.kind && candidate.ref === enriched.ref);
            if (row)
                Object.assign(row, enriched);
        }
        return rows;
    }

    // One entry per kind of packaging on offer, in the order the rows are in.
    // Two Coprs are still one explanation.
    readonly property var kindsOffered: {
        const kinds = [];
        for (const origin of origins) {
            const kind = origin.kind === "copr" ? "copr" : origin.kind;
            if (kinds.indexOf(kind) === -1)
                kinds.push(kind);
        }
        return kinds;
    }

    // Each of these is a trade rather than a ranking, so each says what it
    // gives you and what it costs, in that order, and stops there.
    function kindPrimer(kind) {
        switch (kind) {
        case "flatpak":
            return Tr.t("Flatpak: sandboxed and the same on every distribution, usually the newest release from the people who write the app. Larger to download because it brings its own libraries, and it reaches your files only through the permissions listed above.");
        case "copr":
            return Tr.t("Copr: built by an individual on Fedora's build service — often newer than the distribution, and sometimes the only place something exists at all. Nobody vouches for it but its owner.");
        case "appimage":
            return Tr.t("AppImage: a single file you run, installing nothing and changing nothing on the system. No sandbox, and it can only update itself if whoever publishes it keeps doing so.");
        default:
            return Tr.t("%1: packaged by the distribution, updated together with everything else on the machine, and reviewed before it gets in. Versions follow the distribution rather than the app's own releases, and it runs with full access to your system.").arg(Backend.systemRepoLabel);
        }
    }

    function open(data) {
        appData = data;
        info = ({});
        showing = true;
        if ((data.sources || []).some(source => source.kind === "flatpak" || source.kind === "dnf")) {
            loading = true;
            infoProcess.command = [Backend.python, scriptPath, "--appinfo", JSON.stringify({
                id: data.id,
                sources: data.sources || []
            })];
            infoProcess.running = true;
        } else {
            loading = false;
        }
        pickerFocus.forceActiveFocus();
    }

    function close() {
        showing = false;
        busyRef = "";
    }

    Process {
        id: infoProcess

        // NDJSON: the local half arrives first and is marked partial, so the
        // rows fill in twice rather than waiting for the network to finish
        stdout: SplitParser {
            onRead: line => {
                let data = null;
                try {
                    data = JSON.parse(line);
                } catch (e) {
                    return;
                }
                delete data.partial;
                picker.info = Object.assign({}, picker.info, data);
                picker.loading = false;
            }
        }

        onExited: (exitCode, exitStatus) => {
            picker.loading = false;
        }
    }

    anchors.fill: parent
    visible: showing
    z: 100

    Item {
        id: pickerFocus

        Keys.onEscapePressed: picker.close()
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: picker.showing ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
            onClicked: picker.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    Rectangle {
        id: card

        anchors.centerIn: parent
        width: Math.min(560, picker.width - Theme.spacingL * 2)
        implicitHeight: cardColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Ui.cardSurface

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: cardColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Item {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32

                    Image {
                        id: pickerLogo
                        anchors.fill: parent
                        source: picker.appData.iconPath ? (picker.appData.iconPath.indexOf("http") === 0 ? picker.appData.iconPath : "file://" + picker.appData.iconPath) : ""
                        // Rendered at the size it is shown: left to its own, an SVG
                        // logo is drawn at hundreds of pixels and shrunk unfiltered
                        sourceSize.width: width
                        sourceSize.height: height
                        // Themed icons, tuned in TintedIconEffect
                        layer.enabled: Ui.tintAppIcons
                        layer.effect: TintedIconEffect {}
                    }

                    DIcon {
                        anchors.centerIn: parent
                        visible: pickerLogo.status !== Image.Ready
                        name: "apps"
                        size: 22
                        // A package with no icon of its own falls back to this glyph, and a
                        // list of them is most of what an installed-software list is. Left
                        // grey it made the setting look half-applied — the apps with
                        // artwork turned, the ones without stayed as they were.
                        color: Ui.tintAppIcons ? Theme.primary : Theme.surfaceVariantText
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Install %1 from…").arg(picker.appData.name || "")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingXS

                        StyledText {
                            text: Tr.t("The same app, packaged by different people.")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }

                        DSpinner {
                            visible: picker.loading
                            size: 12
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }
                }

                DActionButton {
                    Layout.alignment: Qt.AlignTop
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    onClicked: picker.close()
                }
            }

            // Four sources with an explanation each is taller than a short
            // window, and a picker whose Install buttons are off the bottom
            // edge is worse than the two buttons it replaced. So the body
            // scrolls when it has to and the card stays inside the window.
            DFlickable {
                id: bodyView

                Component.onCompleted: Ui.softenScrollbar(bodyView)
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(bodyColumn.implicitHeight, Math.max(200, picker.height - 220))
                contentHeight: bodyColumn.implicitHeight
                clip: true
                // Same reason as everywhere else here: a drag is a scroll and
                // a selection at the same time, and the versions are text
                // someone will want to copy. The wheel and the bar still work.
                interactive: false

                Column {
                    id: bodyColumn

                    width: bodyView.width
                    spacing: Theme.spacingM

                    OriginComparison {
                        width: parent.width
                        origins: picker.origins
                        showInstall: true
                        busyRef: picker.busyRef

                        onInstallRequested: origin => {
                            picker.busyRef = origin.ref;
                            picker.installRequested(origin._source || origin);
                            picker.close();
                        }
                    }

                    // ── What kind of thing each of them is ───────────────────
                    // The rows above compare this app; this compares the ways
                    // of getting software at all. Someone choosing between
                    // Fedora and Flathub for the first time is not short of
                    // numbers, they are short of the sentence the numbers are
                    // about — and only the kinds actually on offer here are
                    // worth explaining.
                    Rectangle {
                        width: parent.width
                        implicitHeight: primerColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius / 2
                        color: Theme.withAlpha(Theme.surfaceVariant, 0.25)

                        Column {
                            id: primerColumn

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            StyledText {
                                width: parent.width
                                text: Tr.t("What is the difference?")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                            }

                            Repeater {
                                model: picker.kindsOffered

                                delegate: RowLayout {
                                    required property string modelData

                                    width: primerColumn.width
                                    spacing: Theme.spacingS

                                    DIcon {
                                        Layout.alignment: Qt.AlignTop
                                        name: modelData === "flatpak" ? "deployed_code" : (modelData === "appimage" ? "note_add" : "package_2")
                                        size: 14
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        text: picker.kindPrimer(modelData)
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
    }
}
