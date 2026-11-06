import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// Arch Linux news, which is the one distribution announcement stream in scope
// that regularly says "do this by hand before you upgrade".
//
// It stays out of the way on purpose. The feed always has something in it, and
// something that has been true since spring is not news — so nothing appears
// until an item shows up that has not been read, and the first fetch on a new
// install marks the backlog read rather than opening with eleven interruptions
// nobody missed. The archive is another matter: an announcement explains the
// state a machine is in long after it stopped being new, so everything ever
// seen stays readable here, including the items that have since scrolled off
// the feed.
Item {
    id: dialog

    property bool showing: false
    // False on every distribution that publishes nothing of this kind, which
    // is all of them except the Arch family
    property bool supported: false
    property var items: []
    property int unread: 0
    property bool loading: false
    property string error: ""
    // The banner is about what is new; opening the archive shows everything
    property bool showAll: false

    readonly property string scriptPath: Qt.resolvedUrl("scripts/arch_news.py").toString().replace("file://", "")
    readonly property var visibleItems: showAll ? (items || []) : (items || []).filter(i => i.unread)

    signal changed()

    function refresh(force) {
        if (listProcess.running)
            return;
        loading = true;
        listProcess.command = force ? [Backend.python, scriptPath, "--list", "--refresh"]
                                    : [Backend.python, scriptPath, "--list"];
        listProcess.running = true;
    }

    function open(all) {
        showAll = all === true;
        showing = true;
        expandedId = "";
        refresh(false);
    }

    function close() {
        showing = false;
    }

    // Reading is the act that clears it: closing the dialog after having had
    // the items in front of you counts, pressing nothing at all does not
    function markAllRead() {
        markProcess.command = [Backend.python, scriptPath, "--mark-all-read"];
        markProcess.running = true;
    }

    property string expandedId: ""

    Process {
        id: listProcess

        stdout: StdioCollector {
            onStreamFinished: {
                dialog.loading = false;
                try {
                    const data = JSON.parse(text);
                    dialog.supported = data.supported === true;
                    dialog.items = data.items || [];
                    dialog.unread = data.unread || 0;
                    dialog.error = data.error || "";
                } catch (e) {
                    dialog.supported = false;
                    dialog.items = [];
                    dialog.unread = 0;
                }
                dialog.changed();
            }
        }
    }

    Process {
        id: markProcess

        onExited: (code, status) => dialog.refresh(false)
    }

    anchors.fill: parent
    visible: showing
    z: 120

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: dialog.showing ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    Rectangle {
        id: newsSheet
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 640)
        height: Math.min(parent.height - Theme.spacingXL * 2, sheetColumn.implicitHeight + Theme.spacingL * 2)
        radius: Theme.cornerRadius
        color: Ui.chipSurface
        scale: dialog.showing ? 1.0 : 0.94
        opacity: dialog.showing ? 1.0 : 0.0
        Behavior on scale { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutBack } }
        Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => wheel.accepted = true
        }

        Keys.onEscapePressed: dialog.close()

        ColumnLayout {
            id: sheetColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                DIcon {
                    name: "campaign"
                    size: 22
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Arch Linux news")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                DActionButton {
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    tooltipText: Tr.t("Dismiss")
                    onClicked: dialog.close()
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: dialog.error !== ""
                text: Tr.t("Could not reach the news feed — showing what was already here.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            StyledText {
                Layout.fillWidth: true
                visible: dialog.visibleItems.length === 0 && !dialog.loading
                text: dialog.showAll ? Tr.t("Nothing here yet.") : Tr.t("Nothing new.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Math.min(420, contentHeight)
                clip: true
                spacing: Theme.spacingS
                model: dialog.visibleItems

                delegate: Rectangle {
                    id: newsRow

                    required property var modelData

                    readonly property bool expanded: dialog.expandedId === modelData.id

                    width: ListView.view ? ListView.view.width : 0
                    implicitHeight: itemColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: modelData.unread ? Theme.withAlpha(Theme.primary, 0.10) : Ui.cardSurface

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: dialog.expandedId = newsRow.expanded ? "" : newsRow.modelData.id
                    }

                    ColumnLayout {
                        id: itemColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingS

                            StyledText {
                                Layout.fillWidth: true
                                text: newsRow.modelData.title || ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: newsRow.modelData.unread ? Font.Bold : Font.Normal
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                text: newsRow.modelData.published > 0 ? new Date(newsRow.modelData.published * 1000).toLocaleDateString(Tr.locale, Locale.ShortFormat) : ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            DIcon {
                                name: newsRow.expanded ? "expand_less" : "expand_more"
                                size: 16
                                color: Theme.surfaceVariantText
                            }
                        }

                        SelectableText {
                            Layout.fillWidth: true
                            visible: newsRow.expanded
                            text: newsRow.modelData.html || ""
                            textFormat: Text.RichText
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        DButton {
                            visible: newsRow.expanded && (newsRow.modelData.url || "") !== ""
                            buttonHeight: 26
                            horizontalPadding: Theme.spacingM
                            iconName: "open_in_new"
                            iconSize: 13
                            text: Tr.t("Read on archlinux.org")
                            backgroundColor: Ui.buttonFill("tonal", false)
                            textColor: Ui.buttonInk("tonal")
                            onClicked: Qt.openUrlExternally(newsRow.modelData.url)
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS

                DButton {
                    visible: !dialog.showAll
                    buttonHeight: 28
                    horizontalPadding: Theme.spacingM
                    iconName: "history"
                    iconSize: 13
                    text: Tr.t("Older news")
                    backgroundColor: Ui.buttonFill("tonal", false)
                    textColor: Ui.buttonInk("tonal")
                    onClicked: dialog.showAll = true
                }

                Item {
                    Layout.fillWidth: true
                }

                DButton {
                    visible: dialog.unread > 0
                    buttonHeight: 28
                    horizontalPadding: Theme.spacingM
                    iconName: "mark_email_read"
                    iconSize: 13
                    text: Tr.t("Mark all as read")
                    // What the dialog is for: the one filled button
                    backgroundColor: Theme.buttonBg
                    textColor: Theme.buttonText
                    onClicked: dialog.markAllRead()
                }
            }
        }
    }
}
