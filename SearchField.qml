import QtQuick
import qs.Common
import qs.DCommon.Widgets

// The search bar at the top of a tab.
//
// Fully rounded, as M3 Expressive draws a search bar, where a form field keeps
// the regular input radius.
//
// And quiet until it is used. A tab hands its search field the focus as soon
// as it opens, so that typing searches straight away — which with the stock
// field meant every tab opened with a lit outline and icon, for a field nobody
// had touched yet. The focus stays; the highlight waits for the first
// character, and goes again when the field is cleared.
DTextField {
    readonly property bool typing: text.length > 0

    cornerRadius: height / 2
    focusedBorderColor: typing ? Theme.primary : normalBorderColor
    focusedBorderWidth: typing ? 2 : borderWidth
    leftIconFocusedColor: typing ? Theme.primary : leftIconColor
}
