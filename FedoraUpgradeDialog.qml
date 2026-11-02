import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// What upgrading to the next Fedora release involves, asked before anything
// is downloaded: how much, what has to go, which repositories have no build
// for it yet. The banner's "Upgrade…" opens it; FedoraUpgradeJob, in
// UpdaterWidget.qml, does the work.
Item {
    id: dialog

    property var upgrade: null          // the widget's FedoraUpgradeJob
    // System updates still waiting. Fedora's advice is to install them
    // before upgrading, so it is said — but not enforced: an update held
    // back by a third-party package pinned to the old build (RPM Fusion's
    // libheif-freeworld, waiting on its rebuild) cannot be installed at all,
    // and would otherwise keep the upgrade locked until someone else acts.
    // The plan is what decides whether the upgrade can go through.
    property int pendingSystem: 0

    property bool animActive: false
    readonly property bool showing: animActive || closeTimer.running

    readonly property var plan: upgrade ? upgrade.plan : null
    readonly property bool planning: upgrade !== null && upgrade.phase === "planning"
    readonly property bool planOk: plan !== null && plan.ok === true
    readonly property int release: planOk ? plan.releasever : (upgrade ? upgrade.target : 0)
    readonly property bool canDownload: planOk && upgrade.phase === "planned"

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

    function open() {
        if (!upgrade)
            return;
        closeTimer.stop();
        animActive = true;
        // A plan from earlier in this session still stands; anything else is
        // asked again, against the repositories as they are now
        if (!(upgrade.phase === "planned" && planOk && plan.releasever === upgrade.target))
            upgrade.startPlan();
    }

    function close() {
        if (!animActive)
            return;
        animActive = false;
        closeTimer.restart();
    }

    function accept() {
        if (!canDownload)
            return;
        upgrade.startDownload();
        animActive = false;
        closeTimer.restart();
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

    onAnimActiveChanged: {
        // Walking away is a no: the plan is not kept for later
        if (!animActive && upgrade && upgrade.phase !== "downloading")
            upgrade.dropPlan();
    }

    anchors.fill: parent
    visible: showing
    z: 9999

    Rectangle {
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
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 520)
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
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    radius: 10
                    color: Theme.withAlpha(Theme.primary, 0.15)
                    DankIcon {
                        anchors.centerIn: parent
                        name: "rocket_launch"
                        size: 18
                        color: Theme.primary
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Upgrade to Fedora %1").arg(dialog.release)
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

            BusyText {
                Layout.fillWidth: true
                visible: dialog.planning
                text: Tr.t("Checking what the upgrade to Fedora %1 involves…").arg(dialog.release)
                pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
            }

            // Could not be worked out at all — Fedora's own repositories
            // unreachable, or a conflict even removing packages cannot solve
            Rectangle {
                Layout.fillWidth: true
                visible: !dialog.planning && dialog.plan !== null && !dialog.planOk
                implicitHeight: planErrorText.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.error, 0.12)

                SelectableText {
                    id: planErrorText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingM
                    text: Tr.t("The upgrade cannot go ahead: %1").arg(dialog.upgrade ? dialog.upgrade.planError : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: !dialog.planning && dialog.planOk
                text: dialog.planOk ? Tr.t("%1 to download · %2 packages").arg(dialog.formatBytes(dialog.plan.downloadBytes)).arg(dialog.plan.counts.upgrade + dialog.plan.counts.install + dialog.plan.counts.downgrade) : ""
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                color: Theme.surfaceText
                wrapMode: Text.WordWrap
            }

            Repeater {
                // The things worth knowing before saying yes, most pressing
                // first; each one a tinted line of its own
                model: {
                    if (dialog.planning || !dialog.planOk)
                        return [];
                    const notes = [];
                    if (dialog.pendingSystem > 0)
                        notes.push({
                            icon: "system_update_alt",
                            warn: true,
                            text: Tr.t("Install the waiting updates first — Fedora advises upgrading from an up-to-date system.")
                        });
                    const repos = dialog.plan.unavailableRepos || [];
                    if (repos.length > 0)
                        notes.push({
                            icon: "cloud_off",
                            warn: true,
                            text: Tr.t("No Fedora %1 build yet: %2. Their packages stay at the current version until these repositories catch up.").arg(dialog.release).arg(repos.map(r => r.name).join(", "))
                        });
                    const removed = dialog.plan.removed || [];
                    if (removed.length > 0)
                        notes.push({
                            icon: "delete",
                            warn: true,
                            text: Tr.t("To make the upgrade possible, these packages are removed: %1").arg(removed.join(", "))
                        });
                    notes.push({
                        icon: "info",
                        warn: false,
                        text: Tr.t("The download runs in the background and your system keeps working as it is. Nothing changes until you restart to upgrade.")
                    });
                    return notes;
                }

                delegate: Rectangle {
                    id: note
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: noteRow.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: note.modelData.warn ? Theme.withAlpha(Theme.warning, 0.12) : Theme.withAlpha(Theme.surface, 0.5)

                    RowLayout {
                        id: noteRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        DankIcon {
                            Layout.alignment: Qt.AlignTop
                            name: note.modelData.icon
                            size: 16
                            color: note.modelData.warn ? Theme.warning : Theme.surfaceVariantText
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: note.modelData.text
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
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

                DankButton {
                    buttonHeight: 32
                    horizontalPadding: Theme.spacingM
                    text: Tr.t("Cancel")
                    backgroundColor: Ui.buttonFill("tonal", false)
                    textColor: Ui.buttonInk("tonal")
                    onClicked: dialog.close()
                }

                DankButton {
                    buttonHeight: 32
                    horizontalPadding: Theme.spacingM
                    iconName: "download"
                    iconSize: 14
                    text: Tr.t("Download")
                    enabled: dialog.canDownload
                    backgroundColor: Theme.buttonBg
                    textColor: Theme.buttonText
                    onClicked: dialog.accept()
                }
            }
        }
    }
}
