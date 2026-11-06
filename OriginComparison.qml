import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// The same app, offered several ways, put side by side.
//
// Merging Fedora, Flathub, Copr and AppImage into one entry is what makes
// software findable here; it also quietly hides a decision. This is that
// decision handed back: which version, how big, out of whose hands it came,
// and how much of the machine it gets.
//
// Used in two places — inside the details popup, where it is one section
// among many, and as the body of the picker that opens when a single Install
// button has more than one thing it could mean. Neither the labels nor the
// judgement live at those call sites, so the two cannot drift apart.
Column {
    id: root

    // Entries as enrich.py --appinfo emits them, optionally thinned down to
    // what the search index already knows while the rest is still loading
    property var origins: []
    property bool showInstall: false
    property bool installEnabled: true
    property string busyRef: ""
    // Refs of the sources actually on the machine. An app carried by both
    // Fedora and Flathub gets one "Installed" chip in the header and that
    // chip does not say which of the two it means — which is the one thing
    // someone looking at this list wants to know before touching anything.
    property var installedRefs: []

    signal installRequested(var origin)

    spacing: Theme.spacingXS

    function originLabel(origin) {
        switch (origin.origin) {
        case "distro":
            return Backend.systemRepoLabel;
        case "copr":
            return origin.detail ? "Copr · " + origin.detail : "Copr";
        case "appimage":
            return "AppImage";
        default:
            return origin.detail || "";
        }
    }

    // What the reader is actually deciding between: how much of the machine
    // it gets, and out of whose hands it came. A sandbox with nine holes in
    // it is still a sandbox; an rpm is the machine, however well built.
    function trustLine(origin) {
        const parts = [];
        if (origin.sandbox === "flatpak")
            parts.push(origin.permissions !== undefined ? Tr.t("Sandboxed · %1 permissions").arg(origin.permissions) : Tr.t("Sandboxed"));
        else
            parts.push(Tr.t("Full system access"));
        switch (origin.origin) {
        case "distro":
            parts.push(Tr.t("built by %1").arg(Backend.systemRepoLabel));
            break;
        case "copr":
            parts.push(Tr.t("built by an individual"));
            break;
        case "third-party":
            parts.push(Tr.t("third-party repository"));
            break;
        case "remote":
            if (origin.verified === true)
                parts.push(Tr.t("verified publisher"));
            else if (origin.verified === false)
                parts.push(Tr.t("unverified publisher"));
            break;
        }
        return parts.join(" · ");
    }

    // Versions from two packagers are not comparable strings — "3.0.23" and
    // "3.0.23-10.fc44" are the same release, and the rpm tail is the build
    // rather than a higher number. So compare the leading dotted digits and
    // nothing else, and say nothing at all when that comes out level.
    function versionRank(version) {
        const match = (version || "").match(/\d+(\.\d+)*/);
        return match ? match[0].split(".").map(Number) : [];
    }

    readonly property string newestVersion: {
        let best = "";
        let bestRank = [];
        for (const origin of origins) {
            const rank = versionRank(origin.version);
            if (rank.length === 0)
                continue;
            let newer = bestRank.length === 0;
            for (let i = 0; !newer && i < Math.max(rank.length, bestRank.length); i++) {
                const a = rank[i] || 0;
                const b = bestRank[i] || 0;
                if (a !== b) {
                    newer = a > b;
                    break;
                }
            }
            if (newer) {
                best = origin.version;
                bestRank = rank;
            }
        }
        // Level pegging is not a winner: every source on the same release
        // would otherwise be crowned, which tells the reader nothing
        let leaders = 0;
        for (const origin of origins) {
            const rank = versionRank(origin.version);
            if (rank.length > 0 && rank.join(".") === bestRank.join("."))
                leaders++;
        }
        return leaders === 1 ? best : "";
    }

    Repeater {
        id: origRepeater
        model: root.origins

        delegate: Item {
            id: origDelegate
            required property var modelData
            required property int index

            readonly property bool isFirst: index === 0
            readonly property bool isLast: index === root.origins.length - 1
            readonly property bool newest: (modelData.version || "") !== "" && modelData.version === root.newestVersion && root.origins.length > 1
            readonly property bool here: root.installedRefs.indexOf(modelData.ref) !== -1

            readonly property real outerRadius: 16
            readonly property real innerRadius: 6

            property real tlr: origMa.containsMouse ? 18 : (isFirst ? outerRadius : innerRadius)
            property real trr: origMa.containsMouse ? 18 : (isFirst ? outerRadius : innerRadius)
            property real blr: origMa.containsMouse ? 18 : (isLast ? outerRadius : innerRadius)
            property real brr: origMa.containsMouse ? 18 : (isLast ? outerRadius : innerRadius)

            Behavior on tlr { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutCubic } }
            Behavior on trr { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutCubic } }
            Behavior on blr { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutCubic } }
            Behavior on brr { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutCubic } }

            width: root.width
            implicitHeight: originColumn.implicitHeight + Theme.spacingS * 2

            Shape {
                id: origBg
                anchors.fill: parent
                layer.enabled: true
                layer.samples: 4
                smooth: true

                ShapePath {
                    fillColor: Ui.rowFill(origMa.containsMouse, false, here ? "success" : "", Theme.withAlpha(Ui.chipSurfaceNested, 0.45))
                    strokeColor: "transparent"
                    strokeWidth: -1
                    joinStyle: ShapePath.RoundJoin

                    startX: 0
                    startY: origDelegate.tlr

                    PathArc { x: origDelegate.tlr; y: 0; radiusX: origDelegate.tlr; radiusY: origDelegate.tlr }
                    PathLine { x: origDelegate.width - origDelegate.trr; y: 0 }
                    PathArc { x: origDelegate.width; y: origDelegate.trr; radiusX: origDelegate.trr; radiusY: origDelegate.trr }
                    PathLine { x: origDelegate.width; y: origDelegate.height - origDelegate.brr }
                    PathArc { x: origDelegate.width - origDelegate.brr; y: origDelegate.height; radiusX: origDelegate.brr; radiusY: origDelegate.brr }
                    PathLine { x: origDelegate.blr; y: origDelegate.height }
                    PathArc { x: 0; y: origDelegate.height - origDelegate.blr; radiusX: origDelegate.blr; radiusY: origDelegate.blr }
                    PathLine { x: 0; y: origDelegate.tlr }
                }
            }

            MouseArea {
                id: origMa
                anchors.fill: parent
                hoverEnabled: true
            }

            Column {
                id: originColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: 3

                RowLayout {
                    width: parent.width
                    spacing: Theme.spacingS

                    DIcon {
                        name: modelData.kind === "flatpak" ? "deployed_code" : (modelData.kind === "appimage" ? "note_add" : "package_2")
                        size: 15
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: root.originLabel(modelData)
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    SelectableText {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        visible: (modelData.version || "") !== ""
                        text: modelData.version || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }

                    // Nothing to fill the row with while the versions are
                    // still being fetched, and a row with no taker for the
                    // leftover width spreads it between its items
                    Item {
                        Layout.fillWidth: true
                        visible: (modelData.version || "") === ""
                    }

                    Rectangle {
                        visible: here
                        Layout.preferredWidth: installedChip.implicitWidth + 14
                        Layout.preferredHeight: 18
                        radius: 9
                        color: Theme.withAlpha(Theme.success, 0.18)

                        StyledText {
                            id: installedChip
                            anchors.centerIn: parent
                            text: Tr.t("Installed")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.success
                        }
                    }

                    // Only ever on one of them, and only when there is
                    // something to be newer than — a lone source is not winning
                    Rectangle {
                        visible: newest
                        Layout.preferredWidth: newestChip.implicitWidth + 14
                        Layout.preferredHeight: 18
                        radius: 9
                        color: Theme.withAlpha(Theme.primary, 0.15)

                        StyledText {
                            id: newestChip
                            anchors.centerIn: parent
                            text: Tr.t("Newest")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.primary
                        }
                    }

                    Item {
                        Layout.preferredWidth: pickButton.width
                        Layout.preferredHeight: pickButton.height
                        visible: root.showInstall && !here

                        DButton {
                            id: pickButton

                            buttonHeight: 26
                            horizontalPadding: Theme.spacingM
                            iconName: "download"
                            iconSize: 13
                            text: root.busyRef === modelData.ref ? Tr.t("Working…") : Tr.t("Install")
                            backgroundColor: Theme.buttonBg
                            textColor: Theme.buttonText
                            enabled: root.installEnabled && root.busyRef === ""
                            onClicked: root.installRequested(modelData)
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: text !== ""
                    text: {
                        const parts = [];
                        if (modelData.download)
                            parts.push(Tr.t("%1 download").arg(modelData.download));
                        if (modelData.installed)
                            parts.push(Tr.t("%1 installed").arg(modelData.installed));
                        return parts.join(" · ");
                    }
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }

                RowLayout {
                    width: parent.width
                    spacing: Theme.spacingXS

                    DIcon {
                        name: modelData.sandbox === "flatpak" ? "shield" : "lock_open_right"
                        size: 13
                        color: modelData.sandbox === "flatpak" ? Theme.surfaceVariantText : Theme.warning
                    }

                    StyledText {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        text: root.trustLine(modelData)
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: modelData.sandbox === "flatpak" ? Theme.surfaceVariantText : Theme.warning
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }

    StyledText {
        width: root.width
        visible: root.origins.length > 1
        text: Tr.t("Sizes are the package itself — dependencies and runtimes come on top.")
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.withAlpha(Theme.surfaceVariantText, 0.75)
        wrapMode: Text.WordWrap
    }
}
