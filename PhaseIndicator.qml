import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// Material stepper visualizing the update phases:
// Check → Download → Install → Verify → Done. The active step pulses.
Item {
    id: root

    property int step: 0            // 0.._steps.length - 1
    property bool running: false
    property bool failed: false
    property bool compact: false

    readonly property var _steps: [
        { icon: "search", label: Tr.t("Check") },
        { icon: "download", label: Tr.t("Download") },
        { icon: "deployed_code_update", label: Tr.t("Install") },
        { icon: "fact_check", label: Tr.t("Verify") },
        { icon: failed ? "error" : "check_circle", label: Tr.t("Done") }
    ]
    readonly property int _lastStep: _steps.length - 1
    readonly property int circleSize: compact ? 26 : 34
    readonly property int lineWidth: compact ? 22 : 40

    implicitWidth: stepsRow.implicitWidth
    implicitHeight: stepsRow.implicitHeight

    Row {
        id: stepsRow
        spacing: Theme.spacingXS
        anchors.horizontalCenter: parent.horizontalCenter

        Repeater {
            model: root._steps.length * 2 - 1

            delegate: Item {
                id: element

                required property int index
                readonly property bool isLine: index % 2 === 1
                readonly property int stepIndex: Math.floor(index / 2)
                readonly property bool stepDone: stepIndex < root.step || (root.step === root._lastStep && !root.running)
                readonly property bool stepActive: stepIndex === root.step && root.running

                width: isLine ? root.lineWidth : root.circleSize
                height: root.circleSize + (root.compact ? 0 : 16)

                Rectangle {
                    visible: element.isLine
                    anchors.verticalCenter: circleSlot.verticalCenter
                    width: parent.width
                    height: 2
                    radius: 1
                    color: element.stepDone ? Theme.buttonBg : Theme.outlineVariant

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.mediumDuration
                        }
                    }
                }

                Item {
                    id: circleSlot
                    visible: !element.isLine
                    width: root.circleSize
                    height: root.circleSize

                    Rectangle {
                        id: circle
                        anchors.fill: parent
                        radius: width / 2
                        color: element.stepDone ? Theme.buttonBg : (element.stepActive ? Theme.primaryContainer : "transparent")
                        border.width: element.stepDone || element.stepActive ? 0 : 2
                        border.color: Theme.outlineVariant

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.mediumDuration
                            }
                        }

                        SequentialAnimation on scale {
                            running: element.stepActive && Ui.busyMotion
                            loops: Animation.Infinite
                            alwaysRunToEnd: true

                            NumberAnimation {
                                from: 1
                                to: 1.12
                                duration: Ui.busyCycle * 0.7
                                easing.type: Easing.InOutQuad
                            }
                            NumberAnimation {
                                from: 1.12
                                to: 1
                                duration: Ui.busyCycle * 0.7
                                easing.type: Easing.InOutQuad
                            }
                        }
                    }

                    DIcon {
                        anchors.centerIn: parent
                        name: element.isLine ? "" : root._steps[element.stepIndex].icon
                        size: root.circleSize * 0.55
                        filled: element.stepDone || element.stepActive
                        color: {
                            if (element.stepIndex === 3 && root.failed)
                                return Theme.error;
                            if (element.stepDone)
                                return Theme.buttonText;
                            if (element.stepActive)
                                return Theme.primary;
                            return Theme.surfaceText;
                        }
                    }
                }

                StyledText {
                    visible: !element.isLine && !root.compact
                    anchors.top: circleSlot.bottom
                    anchors.topMargin: 2
                    anchors.horizontalCenter: circleSlot.horizontalCenter
                    text: element.isLine ? "" : root._steps[element.stepIndex].label
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: element.stepDone || element.stepActive ? Theme.surfaceText : Theme.surfaceVariantText
                }
            }
        }
    }
}
