import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// Rich update entry: logo, name, version transition and a live progress bar
// during installation. The summary is left to the details popup: here the
// versions are the point, and a line less keeps the row as low as Installed's. Clicking the card asks the host to open
// the shared details popup (release notes, reviews, actions).
Rectangle {
    id: card

    required property var pkg          // daemon package: {name, repo, fromVersion, toVersion}
    property var info: null            // enrichment: {name, summary, homepage, icon, releases}
    property var itemState: null       // engine: {status, fraction, detail}
    property var store: null
    property bool showUpdateButton: false
    property bool engineBusy: false
    property bool held: false
    property string holdReason: ""
    property string blockedReason: ""  // firmware: why fwupd will not install it now
    property bool isIgnored: false
    property bool canHold: false
    property bool active: false
    // Verbatim tool output behind the short failure reason, revealed on request
    property string errorDetail: ""
    // {type, severity, ids} from updateinfo, null when the update carries no
    // advisory or the distro has none to give
    property var advisory: null

    readonly property bool isSecurity: advisory !== null && advisory.type === "security"

    // updateinfo grades its security advisories, and the grade is the part
    // that decides whether this waits until tonight. It was being fetched and
    // dropped: every fix read "Security", from a moderate library bump to a
    // critical hole in the browser you are reading this in.
    readonly property string severityLabel: {
        if (!isSecurity)
            return "";
        switch ((advisory.severity || "").toLowerCase()) {
        case "critical":
            return Tr.t("Critical");
        case "important":
            return Tr.t("Important");
        case "moderate":
            return Tr.t("Moderate");
        case "low":
            return Tr.t("Low");
        }
        return Tr.t("Security");
    }

    // Only the top two earn the full red. Below that it is still a security
    // fix, but shouting about all of them is how nobody hears any of them.
    readonly property bool isUrgent: isSecurity && ["critical", "important"].indexOf((advisory.severity || "").toLowerCase()) !== -1

    signal updateRequested
    signal holdToggleRequested
    signal detailsRequested

    readonly property string baseName: (pkg.name || "").replace(/\.(x86_64|i686|noarch|aarch64|armv7hl|ppc64le|s390x)$/, "")
    readonly property bool isFlatpak: pkg.repo === "flatpak"
    readonly property bool isAppImage: pkg && pkg.repo === "appimage"
    // Off under a heading that already names the source — see the list that
    // decides it. The card still knows what it is; it just stops saying so
    // twice within one screenful.
    property bool showSource: true
    // AppStream first, then whatever the row was built with: a formula from a
    // tap, a plugin from its manifest and an AppImage all arrive with a name
    // meant to be read, and the card was falling through to the raw one — so
    // the list said dsd/test/dsd-demo while the popup one click away, which
    // asks the store for the same thing, said dsd-demo.
    readonly property string prettyName: (info && info.name) ? info.name : (pkg.displayName || baseName)
    readonly property string homepage: (info && info.homepage) ? info.homepage : ""
    // The packages the shell is made of have no AppStream entry and so no
    // icon of their own, and the generic chip glyph told you nothing about
    // what they are. The host hands over DMS's own logo for those.
    property string shellIconPath: ""
    readonly property string iconPath: (info && info.icon) ? info.icon : shellIconPath
    readonly property var newReleases: {
        if (!info || !info.releases)
            return [];
        const newer = info.releases.filter(r => r.newer && (r.notesHtml || r.version));
        return newer.slice(0, 5);
    }
    readonly property string toVersionDisplay: {
        if (pkg.toVersion)
            return Ui.versionLabel(pkg.toVersion);
        if (newReleases.length > 0 && newReleases[0].version)
            return newReleases[0].version;
        return "";
    }
    readonly property string status: itemState ? itemState.status : "pending"

    color: "transparent"
    opacity: held ? 0.65 : 1
    clip: true

    implicitHeight: contentColumn.implicitHeight + (Theme.spacingS + 2) * 2

    Behavior on implicitHeight {
        NumberAnimation {
            duration: Theme.mediumDuration
            easing.type: Theme.emphasizedEasing
        }
    }

    property bool isSectionFirst: false
    property bool isSectionLast: false

    Rectangle {
        id: cardBg
        anchors.fill: parent

        property real innerRadius: 6
        property real outerRadius: Theme.cornerRadius || 12
        // The pill the rows in every list turn into when pressed or selected.
        // Hover only shades the row (M3 Expressive, as DMS does it, #22)
        property real pillRadius: Math.min(height / 2, 28)
        property bool isHighlighted: cardMa.containsMouse || card.active
        property bool morphed: cardMa.pressed || card.active

        property real tlr: morphed ? pillRadius : (isSectionFirst ? outerRadius : innerRadius)
        property real trr: morphed ? pillRadius : (isSectionFirst ? outerRadius : innerRadius)
        property real blr: morphed ? pillRadius : (isSectionLast ? outerRadius : innerRadius)
        property real brr: morphed ? pillRadius : (isSectionLast ? outerRadius : innerRadius)

        topLeftRadius: tlr
        topRightRadius: trr
        bottomLeftRadius: blr
        bottomRightRadius: brr

        Behavior on topLeftRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
        Behavior on topRightRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
        Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
        Behavior on bottomRightRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

        // The row carries its own surface; state is in the fill, not an
        // outline (issue #28): a failure tints it red, the active row takes
        // the accent (Ui.rowFill).
        color: Ui.rowFill(isHighlighted, card.active, card.status === "error" ? "error" : "")

        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
    }

    DRipple {
        id: cardRip
        anchors.fill: parent
        cornerRadius: cardBg.topLeftRadius
        rippleColor: Theme.primary
    }

    // Clicking the card opens the details popup (buttons sit on top)
    MouseArea {
        id: cardMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: (m) => cardRip.trigger(m.x, m.y)
        onClicked: card.detailsRequested()
    }

    ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        anchors.topMargin: Theme.spacingS + 2
        anchors.bottomMargin: Theme.spacingS + 2
        spacing: Theme.spacingXS

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            // ── Logo ────────────────────────────────────────────────────────
            // The icon slot of every list: 32px, and a tile behind it only
            // when there is no icon to show
            Rectangle {
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                Layout.alignment: Qt.AlignVCenter
                radius: 6
                color: logoImage.status === Image.Ready ? "transparent" : Theme.withAlpha(Ui.chipSurface, 0.6)

                Image {
                    id: logoImage
                    anchors.fill: parent
                    source: card.iconPath ? "file://" + card.iconPath : ""
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
                    visible: logoImage.status !== Image.Ready
                    // A plugin has no icon file to fail to load — it names a
                    // glyph in its manifest, and the generic one stands in
                    // when it names nothing
                    name: card.pkg.repo === "dmsplugin" ? (card.pkg.icon || "extension") : Ui.sourceIcon(card.pkg.repo)
                    size: 18
                    color: Theme.surfaceVariantText
                }
            }

            // ── Name, versions ──────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 2

                StyledText {
                    Layout.fillWidth: true
                    text: card.prettyName
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    // Also shown without version info when there is status text
                    // to carry (hold reason, run status)
                    visible: (card.pkg.fromVersion || card.toVersionDisplay) !== "" || (card.held && card.holdReason !== "") || card.itemState !== null

                    StyledText {
                        visible: (card.pkg.fromVersion || "") !== ""
                        text: card.pkg.fromVersion || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideMiddle
                        Layout.maximumWidth: 200
                    }

                    DIcon {
                        visible: (card.pkg.fromVersion || "") !== "" && card.toVersionDisplay !== ""
                        name: "arrow_forward"
                        size: 12
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: card.toVersionDisplay !== ""
                        text: card.toVersionDisplay
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                        elide: Text.ElideMiddle
                        Layout.maximumWidth: 220
                    }

                    // Run status as text where an icon alone would be unclear
                    StyledText {
                        visible: card.itemState !== null && (card.status === "pending" || card.status === "done" || card.status === "error")
                        text: {
                            switch (card.status) {
                            case "pending":
                                return "· " + Tr.t("queued");
                            case "done":
                                return "· " + Tr.t("completed");
                            case "error":
                                return "· " + Tr.t("failed");
                            default:
                                return "";
                            }
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: card.status === "error" ? Ui.failColor : (card.status === "done" ? Theme.success : Theme.surfaceVariantText)
                    }

                    // Hold reason, e.g. "versionlock (via freerdp)"
                    StyledText {
                        visible: card.held && card.holdReason !== ""
                        text: "· " + card.holdReason
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.warning
                        elide: Text.ElideRight
                        Layout.maximumWidth: 220
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            // ── Chips, actions and status ──────────────────────────────────
            // One cluster packed against the right edge: the chips and the
            // action slot share a row, so they line up with each other
            // instead of drifting apart across the card's right side. The
            // action slot keeps a fixed width whenever the card can show
            // something there, so buttons line up down the list.
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: Theme.spacingXS

                Rectangle {
                    visible: card.held
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: heldChipRow.implicitWidth + 14
                    Layout.preferredHeight: 18
                    radius: 9
                    color: Theme.withAlpha(Theme.warning, 0.18)

                    RowLayout {
                        id: heldChipRow
                        anchors.centerIn: parent
                        spacing: 3

                        DIcon {
                            name: "lock"
                            size: 11
                            color: Theme.warning
                        }

                        StyledText {
                            text: Tr.t("Held")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            font.weight: Font.Medium
                            color: Theme.warning
                        }
                    }
                }

                // Security first: the one distinction that changes whether
                // this can wait until tonight
                Rectangle {
                    visible: card.isSecurity
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: securityChipText.implicitWidth + 14
                    Layout.preferredHeight: 18
                    radius: 9
                    color: card.isUrgent ? Theme.withAlpha(Theme.error, 0.18) : Theme.withAlpha(Theme.warning, 0.18)

                    StyledText {
                        id: securityChipText
                        anchors.centerIn: parent
                        text: card.severityLabel
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Medium
                        color: card.isUrgent ? Ui.failColor : Theme.warning
                    }
                }

                Rectangle {
                    visible: card.showSource
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: repoChipText.implicitWidth + 14
                    Layout.preferredHeight: 18
                    radius: 9
                    color: card.isFlatpak ? Theme.withAlpha(Theme.tertiary, 0.15) : Theme.withAlpha(Theme.secondary, 0.15)

                    StyledText {
                        id: repoChipText
                        anchors.centerIn: parent
                        // "System" is what a package is; a plugin, an
                        // AppImage, a firmware blob and a brew formula are
                        // not, and calling them that was the chip claiming
                        // the wrong thing about where they came from
                        text: Ui.sourceLabel(card.pkg.repo)
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Medium
                        color: card.isFlatpak ? Theme.tertiary : Theme.secondary
                    }
                }

                Item {
                    // Collapses on cards that have neither a button nor a run
                    // status, so the chips stay flush against the edge
                    readonly property bool reserved: card.showUpdateButton || card.itemState !== null
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: reserved ? 28 : 0
                    Layout.preferredHeight: 28

                    DActionButton {
                        anchors.centerIn: parent
                        visible: card.showUpdateButton && card.status === "pending" && !card.engineBusy && !card.isIgnored
                        buttonSize: 28
                        iconName: "download"
                        iconSize: 17
                        iconColor: Theme.primary
                        tooltipText: (card.isFlatpak || card.isAppImage) ? Tr.t("Update only this app") : Tr.t("Update only this package")
                        onClicked: card.updateRequested()
                    }

                    DIcon {
                        anchors.centerIn: parent
                        visible: card.status === "done"
                        name: "check_circle"
                        size: 20
                        color: Theme.success
                    }

                    DIcon {
                        anchors.centerIn: parent
                        visible: card.status === "error"
                        name: "error"
                        size: 20
                        color: Theme.error
                    }
                }

            }
        }

        // ── Live progress ───────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            visible: card.status === "active"
            spacing: 2

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    text: card.itemState ? card.itemState.detail : ""
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 5
                radius: 2.5
                color: Theme.withAlpha(Theme.surfaceVariant, 0.4)

                Rectangle {
                    id: progressFill

                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: 2.5
                    color: Theme.primary
                    width: parent.width * (card.itemState ? Math.max(0.02, card.itemState.fraction) : 0)

                    // The animation is for a bar that grows while you watch
                    // it. A delegate scrolled back into view is not that: it
                    // is created at the width it already had, and animating
                    // to it replays a download that finished minutes ago —
                    // every card, every time the list moves.
                    //
                    // So it is off until the row has drawn once. Qt.callLater
                    // rather than Component.onCompleted, which still runs
                    // inside the frame that sets the initial width.
                    property bool _grown: false
                    Component.onCompleted: Qt.callLater(() => _grown = true)

                    Behavior on width {
                        enabled: progressFill._grown

                        NumberAnimation {
                            duration: Theme.longDuration
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }

        // ── An update fwupd will not install right now ──────────────────────
        // A BIOS waits for the power adapter, and Update all leaves it out
        // until then; without this line it looked like any other update and
        // simply never went away.
        RowLayout {
            Layout.fillWidth: true
            visible: card.blockedReason !== ""
            spacing: Theme.spacingXS

            DIcon {
                Layout.alignment: Qt.AlignTop
                name: "power"
                size: 14
                color: Theme.warning
            }

            StyledText {
                Layout.fillWidth: true
                text: card.blockedReason
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.warning
                wrapMode: Text.WordWrap
            }
        }

        // ── A hold sitting on top of a security fix ─────────────────────────
        // Holding a package back is a legitimate thing this app encourages,
        // right up until the update being held is the one that closes a hole.
        // Nothing said so: the "Held" chip and the "Security" chip sat side by
        // side on the same card and left the reader to draw the conclusion.
        RowLayout {
            Layout.fillWidth: true
            visible: card.held && card.isSecurity
            spacing: Theme.spacingXS

            DIcon {
                Layout.alignment: Qt.AlignTop
                name: "warning"
                size: 14
                color: card.isUrgent ? Ui.failColor : Theme.warning
            }

            StyledText {
                Layout.fillWidth: true
                text: card.isUrgent ? Tr.t("You are holding back a security fix rated %1.").arg(card.severityLabel.toLowerCase()) : Tr.t("You are holding back a security fix.")
                font.pixelSize: Theme.fontSizeSmall - 1
                color: card.isUrgent ? Ui.failColor : Theme.warning
                wrapMode: Text.WordWrap
            }
        }

        // ── Error detail ────────────────────────────────────────────────────
        // The short reason is what the card says; the tool's own words are
        // one click away rather than on display, because they are long,
        // untranslated and only interesting when reporting a problem.
        ColumnLayout {
            Layout.fillWidth: true
            visible: card.status === "error" && card.itemState && (card.itemState.detail || "") !== ""
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS

                StyledText {
                    Layout.fillWidth: true
                    text: card.itemState ? card.itemState.detail : ""
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Ui.failColor
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }

                StyledText {
                    id: errorToggle

                    property bool expanded: false

                    visible: card.errorDetail !== ""
                    text: expanded ? Tr.t("Hide details") : Tr.t("Show details")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.underline: toggleArea.containsMouse
                    color: Ui.failColor

                    MouseArea {
                        id: toggleArea
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: errorToggle.expanded = !errorToggle.expanded
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                visible: errorToggle.expanded && card.errorDetail !== ""
                implicitHeight: rawErrorText.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius / 2
                color: Theme.withAlpha(Theme.surfaceVariant, 0.5)

                SelectableText {
                    id: rawErrorText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingS
                    text: card.errorDetail
                    font.family: Theme.monoFontFamily
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    wrapMode: Text.Wrap
                }
            }
        }

    }
}
