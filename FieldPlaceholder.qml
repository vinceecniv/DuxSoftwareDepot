import QtQuick
import qs.Common
import qs.Widgets

// The hint that stays while the field is empty.
//
// DMS's DTextField hides its own placeholder the moment the field takes
// focus — `visible: text.length === 0 && !textInput.activeFocus` — so clicking
// into an empty field removes the one sentence explaining what belongs in it,
// at exactly the moment somebody is deciding what to type. There is no
// property to turn that off, and the label is internal to the component.
//
// So this fills in the case the component leaves out: empty *and* focused.
// The two never overlap, which is what makes the hint look continuous rather
// than like a second label appearing.
//
// Dropped inside a DTextField as a child, taking its padding, font and
// colour from the field so the text lands in the same place the field's own
// placeholder was standing:
//
//     DTextField {
//         placeholderText: searchHint
//         FieldPlaceholder { text: searchHint }
//     }
//
// It draws over the input but accepts no mouse events, so the field is still
// the thing you click and the cursor still blinks where it should.
Item {
    id: hint

    property var field: parent
    property string text: ""

    property bool _focused: false

    anchors.fill: parent
    visible: _focused && field !== null && ((field.text || "").length === 0)

    Connections {
        target: hint.field
        ignoreUnknownSignals: true

        // The field's own activeFocus stays false — the focus lives on an
        // input inside it — so the component's signal is the way to know
        function onFocusStateChanged(hasFocus) {
            hint._focused = hasFocus;
        }
    }

    StyledText {
        anchors.fill: parent
        anchors.leftMargin: hint.field ? hint.field.leftPadding : Theme.spacingM
        anchors.rightMargin: hint.field ? hint.field.rightPadding : Theme.spacingS
        anchors.topMargin: hint.field ? hint.field.topPadding : 0
        anchors.bottomMargin: hint.field ? hint.field.bottomPadding : 0
        text: hint.text
        font: hint.field ? hint.field.font : font
        color: hint.field ? hint.field.placeholderColor : Theme.surfaceVariantText
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
