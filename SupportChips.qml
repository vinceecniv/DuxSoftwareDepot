import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// The three quiet links: vote for the plugin, star the repository, and the
// tool it was built with. Deliberately understated — a plugin asking for
// votes and stars should not outshout the software it reports on.
//
// One component, because they now live in two places: the dashboard, where
// nothing else needs doing, and the About popup, where someone has already
// gone looking for who made this.
// A grid rather than a row, because three chips side by side need about 500
// pixels and the About card is 420 wide — the third one hung over its edge.
// A host that is short of width sets `columns: 1` and gets them stacked.
GridLayout {
    // The repository the star chip points at; the About popup passes the one
    // it already reads out of plugin.json
    property string repoUrl: "https://github.com/vinceecniv/DuxSoftwareDepot"

    // A layout computes its own implicit height and overwrites anything set
    // here, so a parent that sizes itself from implicitHeight cannot learn it
    // from us. Hosts that need the number take these and put them on a plain
    // wrapper Item — the same trick this codebase uses for DButton.
    readonly property int chipHeight: 26
    readonly property int chipCount: 3

    // Where a chip sits in its cell. Centred suits the dashboard, where the
    // cards above are centred too; a card whose text and buttons all start at
    // the left margin wants Qt.AlignLeft, or the chips read as a stray block.
    property int chipAlignment: Qt.AlignHCenter

    columns: chipCount
    columnSpacing: Theme.spacingS
    rowSpacing: Theme.spacingXS

    Repeater {
        model: [
            {
                text: Tr.t("Upvote plugin in Directory"),
                icon: "thumb_up",
                accent: Theme.primary,
                url: "https://github.com/duxlabs-dev/dux-plugin-registry/issues/720"
            },
            {
                text: Tr.t("Star on GitHub"),
                icon: "star",
                accent: Theme.warning,
                url: repoUrl
            },
            {
                text: Tr.t("Built with Vito"),
                // Vito's own mark, drawn rather than
                // loaded: as bars it inherits the chip's
                // colour and hover like the other two,
                // which a bitmap or a gradient could not
                bars: true,
                icon: "",
                // Vito's own gradient, coral into violet
                gradientFrom: "#FF6B5E",
                gradientTo: "#7C3AED",
                accent: Theme.tertiary,
                url: "https://vito.talk"
            }
        ]

        delegate: Rectangle {
            id: supportChip

            required property var modelData

            Layout.alignment: chipAlignment
            implicitWidth: supportChipRow.implicitWidth + Theme.spacingM * 2
            implicitHeight: chipHeight
            radius: height / 2
            color: chipHover.hovered ? Theme.withAlpha(Theme.surfaceVariantText, 0.16) : Theme.withAlpha(Theme.surfaceVariantText, 0.08)

            HoverHandler {
                id: chipHover
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onTapped: Qt.openUrlExternally(supportChip.modelData.url)
            }

            RowLayout {
                id: supportChipRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                // Takes its own colour and fills in on
                // hover — enough to feel alive, while the
                // chip stays quiet at rest
                DIcon {
                    visible: supportChip.modelData.icon !== ""
                    name: supportChip.modelData.icon
                    size: 13
                    filled: chipHover.hovered
                    color: chipHover.hovered ? supportChip.modelData.accent : Theme.surfaceVariantText

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shortDuration
                        }
                    }
                }

                // Vito's five bars, at the proportions of
                // its own mark (12 wide on a 20 pitch,
                // 20/36/56/36/20 tall)
                Row {
                    visible: supportChip.modelData.bars === true
                    spacing: 2
                    Layout.alignment: Qt.AlignVCenter

                    Repeater {
                        model: [4, 7, 11, 7, 4]

                        delegate: Rectangle {
                            required property int modelData
                            required property int index

                            width: 2.5
                            height: modelData
                            radius: 1.25
                            // Five separate bars cannot share one fill, so each
                            // takes its own point along Vito's gradient — the
                            // blend reads across the mark as one sweep
                            color: chipHover.hovered ? Ui.mix(supportChip.modelData.gradientFrom, supportChip.modelData.gradientTo, index / 4) : Theme.surfaceVariantText

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }
                        }
                    }
                }

                StyledText {
                    text: supportChip.modelData.text
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
