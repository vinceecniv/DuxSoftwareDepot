import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// One result slot with dynamic containerized first/middle/last rounded corners
Item {
    id: slot

    property int index: 0
    property var entry: null
    property bool selected: false
    property bool isFirst: false
    property bool isLast: false

    signal activated
    signal hovered

    readonly property string group: entry ? (entry.group || "") : ""
    property bool showGroup: false

    visible: entry !== null
    height: visible ? (showGroup ? 24 : 0) + 42 : 0

    StyledText {
        id: groupLabel

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: Theme.spacingS
        height: 24
        verticalAlignment: Text.AlignVCenter
        visible: slot.showGroup
        text: slot.group
        font.pixelSize: Theme.fontSizeSmall - 2
        font.weight: Font.DemiBold
        color: Theme.primary
    }

    Rectangle {
        id: body

        readonly property real outerRadius: Theme.cornerRadius
        readonly property real innerRadius: 4
        readonly property real pillRadius: 21
        readonly property bool isHighlighted: slot.selected || rowArea.containsMouse

        property real tlr: isHighlighted ? pillRadius : (slot.isFirst ? outerRadius : innerRadius)
        property real trr: isHighlighted ? pillRadius : (slot.isFirst ? outerRadius : innerRadius)
        property real blr: isHighlighted ? pillRadius : (slot.isLast ? outerRadius : innerRadius)
        property real brr: isHighlighted ? pillRadius : (slot.isLast ? outerRadius : innerRadius)

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 40

        topLeftRadius: tlr
        topRightRadius: trr
        bottomLeftRadius: blr
        bottomRightRadius: brr

        Behavior on topLeftRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
        Behavior on topRightRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
        Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
        Behavior on bottomRightRadius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

        // The row Enter will run is told by its fill alone (issue #28)
        color: isHighlighted
            ? Theme.withAlpha(Theme.primary, slot.selected ? 0.24 : 0.14)
            : Theme.withAlpha(Ui.chipSurface, 0.45)
        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

        scale: rowArea.pressed ? 0.98 : (slot.selected ? 1.01 : 1.0)
        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }

        DRipple {
            id: rowRip
            anchors.fill: parent
            cornerRadius: parent.topLeftRadius
            rippleColor: Theme.primary
        }

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingS

            DIcon {
                name: slot.entry ? (slot.entry.icon || "chevron_right") : "chevron_right"
                size: 18
                color: slot.entry && slot.entry.colour ? slot.entry.colour : (slot.selected ? Theme.primary : Theme.surfaceVariantText)
            }

            StyledText {
                text: slot.entry ? (slot.entry.title || "") : ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: slot.selected ? Font.DemiBold : Font.Normal
                color: slot.selected ? Theme.primary : Theme.surfaceText
                elide: Text.ElideRight
                Layout.maximumWidth: 300
            }

            StyledText {
                Layout.fillWidth: true
                text: slot.entry ? (slot.entry.subtitle || "") : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: slot.hovered()
            onPressed: (m) => rowRip.trigger(m.x, m.y)
            onClicked: slot.activated()
        }
    }
}
