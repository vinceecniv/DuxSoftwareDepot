import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// Log tab: chronological history of every action this plugin performed
// (update runs, installs, uninstalls, restores, firmware). Entries are
// collapsed by default and expand to show per-package details.
Item {
    id: view

    property var logger: null

    // An entry written by this version carries {key, args} and is put into
    // words here, in whatever language the interface is in now. One written
    // before that carries only the sentence it was written as, and keeps it:
    // the words were all that was saved, so there is nothing to translate
    // them from.
    function entryTitle(entry) {
        if (!entry)
            return "";
        if (logger && logger.titleOf)
            return logger.titleOf(entry);
        return entry.title || "";
    }
    property string searchText: ""
    property var expandedKeys: ({})

    // Set from the command palette, so a query typed there carries over
    // into the tab that can search it properly
    function setQuery(text) {
        searchField.text = text;
        searchText = text;
        searchField.forceActiveFocus();
    }

    // A package name in the log leads to the same details popup the tabs use:
    // the log is where you notice a version you did not expect, and reading
    // its changelog should not mean finding the package again by hand.
    signal packageActivated(var item)

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    // Open the newest entry, for the jump from a finished run: the thing you
    // came to read should already be open when you arrive.
    function expandNewest() {
        const entries = (logger && logger.entries) || [];
        if (entries.length === 0)
            return;
        const newest = entries[entries.length - 1];
        const updated = Object.assign({}, expandedKeys);
        updated[String(newest.ts) + "/" + (newest.type || "")] = true;
        expandedKeys = updated;
        searchText = "";
        logList.positionViewAtBeginning();
    }

    function iconFor(type) {
        switch (type) {
        case "install":
            return "add_circle";
        case "uninstall":
            return "delete";
        case "downgrade":
            return "history";
        case "update-failed":
        case "install-failed":
            return "error";
        case "update-cancelled":
            return "cancel";
        case "sources":
            return "database";
        case "hold":
            return "lock";
        case "unhold":
            return "lock_open";
        default:
            return "deployed_code_update";
        }
    }

    function colorFor(type) {
        switch (type) {
        case "update-failed":
        case "install-failed":
            return Theme.error;
        case "update-cancelled":
            return Theme.surfaceVariantText;
        case "uninstall":
            return Theme.warning;
        case "sources":
            return Theme.secondary;
        // The colour the held section carries everywhere else
        case "hold":
        case "unhold":
            return Theme.warning;
        default:
            return Theme.primary;
        }
    }

    function formatWhen(ts) {
        const date = new Date(ts * 1000);
        const now = new Date();
        const dayMs = 24 * 3600 * 1000;
        const time = Qt.formatTime(date, "hh:mm");
        if (date.toDateString() === now.toDateString())
            return Tr.t("Today %1").arg(time);
        if (date.toDateString() === new Date(now.getTime() - dayMs).toDateString())
            return Tr.t("Yesterday %1").arg(time);
        return Qt.formatDate(date, "d MMM yyyy") + " " + time;
    }

    function _dayKey(ts) {
        const d = new Date(ts * 1000);
        return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
    }

    function _dayLabel(ts) {
        const now = new Date();
        const d = new Date(ts * 1000);
        if (_dayKey(ts) === (now.getFullYear() + "-" + now.getMonth() + "-" + now.getDate()))
            return Tr.t("Today");
        const yesterday = new Date(now.getTime() - 86400000);
        if (_dayKey(ts) === (yesterday.getFullYear() + "-" + yesterday.getMonth() + "-" + yesterday.getDate()))
            return Tr.t("Yesterday");
        return d.toLocaleDateString(Tr.locale, Locale.LongFormat);
    }

    readonly property var visibleEntries: {
        const all = (logger ? logger.entries : []) || [];
        const needle = searchText.trim().toLowerCase();
        const filtered = [];
        for (let i = all.length - 1; i >= 0; i--) {
            const entry = all[i];
            if (needle !== "") {
                const haystack = (view.entryTitle(entry) + " " + (entry.items || []).map(it => it.name || "").join(" ")).toLowerCase();
                if (!Ui.matchesWords(haystack, needle))
                    continue;
            }
            filtered.push(Object.assign({}, entry));
        }

        // Compute day positions for dynamic rounded corners within each day group
        const result = [];
        let i = 0;
        while (i < filtered.length) {
            const currentDayKey = _dayKey(filtered[i].ts || 0);
            const label = _dayLabel(filtered[i].ts || 0);
            let j = i;
            while (j < filtered.length && _dayKey(filtered[j].ts || 0) === currentDayKey) {
                j++;
            }
            const groupLen = j - i;
            for (let k = i; k < j; k++) {
                const row = filtered[k];
                row.dayLabel = label;
                row.isFirstInDay = (k === i);
                row.isLastInDay = (k === j - 1);
                row.dayGroupSize = groupLen;
                result.push(row);
            }
            i = j;
        }
        return result;
    }

    // What this machine has been through lately: the log already knows, it
    // just never said it out loud.
    readonly property var activity: {
        const all = (logger ? logger.entries : []) || [];
        const cutoff = Date.now() / 1000 - 7 * 86400;
        let updated = 0;
        let installed = 0;
        let removed = 0;
        let runs = 0;
        for (const entry of all) {
            if ((entry.ts || 0) < cutoff)
                continue;
            const type = entry.type || "";
            if (type.indexOf("update") === 0) {
                runs++;
                for (const item of entry.items || []) {
                    if (item.status !== "error")
                        updated++;
                }
            } else if (type === "install") {
                installed += (entry.items || []).length;
            } else if (type === "uninstall") {
                removed += (entry.items || []).length;
            }
        }
        return {
            updated: updated,
            installed: installed,
            removed: removed,
            runs: runs
        };
    }

    // ── What this log cannot account for ────────────────────────────────────
    // The package database knows when everything last arrived; this log knows
    // what the plugin did. The difference is somebody else — dnf-automatic, a
    // terminal, another software centre — and without saying so, a log reads
    // like a complete record when it is only a record of one window.
    property var outside: null
    property bool outsideExpanded: false
    property int refreshSerial: 0

    onRefreshSerialChanged: outsideProcess.running = true

    Process {
        id: outsideProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/reconcile.py").toString().replace("file://", "")]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.outside = JSON.parse(text);
                } catch (e) {
                    view.outside = null;
                }
            }
        }
    }

    Component.onCompleted: {
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(logList);
        outsideProcess.running = true;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        SearchField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: Tr.t("Search the action log…")
            FieldPlaceholder {
                text: Tr.t("Search the action log…")
            }
            leftIconName: "search"
            showClearButton: true
            onTextChanged: view.searchText = text
            Keys.onEscapePressed: event => {
                if (text !== "") {
                    clear();
                } else {
                    event.accepted = false;
                }
            }
        }

        // ── The last seven days at a glance ─────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: view.searchText === "" && (view.activity.updated + view.activity.installed + view.activity.removed) > 0
            implicitHeight: activityRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Ui.chipSurface, 0.45)

            RowLayout {
                id: activityRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingL

                Row {
                    spacing: Theme.spacingXS
                    Layout.alignment: Qt.AlignVCenter

                    DIcon {
                        name: "date_range"
                        size: 16
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: Tr.t("Last 7 days")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Repeater {
                    model: [
                        {
                            value: view.activity.updated,
                            label: Tr.t("updated"),
                            colour: Theme.primary
                        },
                        {
                            value: view.activity.installed,
                            label: Tr.t("installed"),
                            colour: Theme.success
                        },
                        {
                            value: view.activity.removed,
                            label: Tr.t("removed"),
                            colour: Theme.surfaceVariantText
                        }
                    ]

                    delegate: RowLayout {
                        required property var modelData

                        visible: modelData.value > 0
                        spacing: 4

                        StyledText {
                            text: String(modelData.value)
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: modelData.colour
                        }

                        StyledText {
                            text: modelData.label
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                }
            }
        }

        // ── Changed by something that is not this app ───────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: view.searchText === "" && view.outside !== null && (view.outside.packages || 0) > 0
            implicitHeight: outsideColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.10)

            HoverHandler {
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onTapped: view.outsideExpanded = !view.outsideExpanded
            }

            ColumnLayout {
                id: outsideColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                anchors.topMargin: Theme.spacingM
                spacing: Theme.spacingXS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS

                    DIcon {
                        name: "help"
                        size: 18
                        color: Theme.warning
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            const info = view.outside || ({});
                            const count = info.packages || 0;
                            const head = count === 1 ? Tr.t("1 package changed outside this app") : Tr.t("%1 packages changed outside this app").arg(count);
                            return (info.occasions || 0) > 1 ? head + " · " + Tr.t("on %1 occasions").arg(info.occasions) : head;
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        visible: (view.outside ? (view.outside.lastTs || 0) : 0) > 0
                        text: view.formatWhen(view.outside ? view.outside.lastTs : 0)
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    DIcon {
                        name: view.outsideExpanded ? "expand_less" : "expand_more"
                        size: 18
                        color: Theme.surfaceVariantText
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: view.outsideExpanded
                    text: Tr.t("Something other than this app installed or updated them — a terminal, an automatic-update timer, another software centre. Only system packages are compared, and only back to where this log starts.")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: view.outsideExpanded ? ((view.outside || {}).samples || []) : []

                    delegate: RowLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        StyledText {
                            Layout.fillWidth: true
                            text: modelData.name
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.family: Theme.monoFontFamily || "monospace"
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            text: view.formatWhen(modelData.ts)
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }
        }

        StyledRect {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.cornerRadius
            // Holds a list of rows, each already a container
            color: "transparent"
            border.width: 0
            clip: true
            visible: view.visibleEntries.length > 0

            DListView {
                id: logList
                anchors.fill: parent
                anchors.margins: 0
                clip: true
                spacing: 2
                model: view.visibleEntries

            StickyHeader {
                id: logSticky

                view: logList
                rows: view.visibleEntries
                headingOf: row => (row && row.dayLabel) || ""
                barHeight: 48

                content: Component {
                    StyledRect {
                        anchors.fill: parent
                        // No fill: the bar is the list's own heading, pinned.
                        // StickyHeader puts the window surface behind it.
                        color: "transparent"
                        border.width: 0

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 0
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            DIcon {
                                name: "calendar_today"
                                size: 20
                                color: Theme.primary
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: logSticky.heading || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Item { Layout.fillWidth: true }
                        }
                    }
                }
            }

            // A day heading, then the entry on a rail: the log holds a
            // sequence of events, and a stack of identical cards hides that.
            delegate: Column {
                id: entryWrap

                required property var modelData

                width: logList.width
                spacing: Theme.spacingXS

                Item {
                    width: parent.width
                    visible: entryWrap.modelData.isFirstInDay === true && (entryWrap.modelData.dayLabel || "") !== ""
                    height: visible ? dayHeading.implicitHeight + Theme.spacingS : 0

                    Row {
                        id: dayHeading
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        spacing: Theme.spacingXS

                        DIcon {
                            name: "calendar_today"
                            size: 14
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: entryWrap.modelData.dayLabel || ""
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                Item {
                    width: parent.width
                    implicitHeight: entryRow.implicitHeight

                    // The rail runs through the gap to the next entry too, so
                    // the days read as one thread rather than as loose cards
                    Rectangle {
                        x: 5
                        y: 0
                        width: 2
                        height: parent.height + Theme.spacingXS
                        color: Theme.withAlpha(Theme.outline, 0.35)
                    }

                    Rectangle {
                        x: 2
                        y: Theme.spacingM
                        width: 8
                        height: 8
                        radius: 4
                        color: view.colorFor(entryWrap.modelData.type || "")
                    }

                Item {
                    id: entryRow

                    readonly property var modelData: entryWrap.modelData
                    readonly property string entryKey: String(modelData.ts) + "/" + (modelData.type || "")
                    readonly property bool expanded: view.expandedKeys[entryKey] === true
                    readonly property var entryItems: modelData.items || []

                    x: 18
                    width: parent.width - 18
                    implicitHeight: entryColumn.implicitHeight + Theme.spacingS * 2
                    height: implicitHeight
                    Behavior on height { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }

                    Shape {
                        id: entryBg
                        anchors.fill: parent
                        // Inset by half the stroke so the 1px outline lands on
                        // whole pixels inside the row: centred on the row's edge,
                        // the list's clip took its outer half and the left side
                        // all but vanished.
                        anchors.margins: 0.5

                        property real innerRadius: 6
                        property real outerRadius: 12
                        // Hover is a state layer and nothing more, and the shape answers a press
                        // (M3 Expressive, as DMS does it, #22). Expanding is not a reason to round:
                        // DMS keeps an expanded card's corners as they are, and the open entry
                        // already says it is open. Its fill and outline mark it as selected.
                        property bool hovered: entryMa.containsMouse || entryRow.expanded
                        property bool selected: entryRow.expanded
                        property bool morphed: entryMa.pressed
                        property bool isFirst: entryWrap.modelData.isFirstInDay === true
                        property bool isLast: entryWrap.modelData.isLastInDay === true
                        property bool isSingle: isFirst && isLast

                        // The same rounding as every other list: a pill while the row is
                        // short enough to read as one, and a fixed radius once an entry has
                        // expanded, where half the height would be a semicircle.
                        property real tlr: morphed ? Math.min(height / 2, 28) : (isFirst ? outerRadius : innerRadius)
                        property real trr: morphed ? Math.min(height / 2, 28) : (isFirst ? outerRadius : innerRadius)
                        property real blr: morphed ? Math.min(height / 2, 28) : (isLast ? outerRadius : innerRadius)
                        property real brr: morphed ? Math.min(height / 2, 28) : (isLast ? outerRadius : innerRadius)

                        property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                        property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        property color paintColor: Ui.rowFill(hovered, selected)

                        ShapePath {
                            fillColor: entryBg.paintColor
                            strokeColor: "transparent"
                            strokeWidth: -1

                            startX: entryBg.tlrAnim; startY: 0
                            PathLine { x: entryBg.width - entryBg.trrAnim; y: 0 }
                            PathArc { x: entryBg.width; y: entryBg.trrAnim; radiusX: entryBg.trrAnim; radiusY: entryBg.trrAnim; direction: PathArc.Clockwise }
                            PathLine { x: entryBg.width; y: entryBg.height - entryBg.brrAnim }
                            PathArc { x: entryBg.width - entryBg.brrAnim; y: entryBg.height; radiusX: entryBg.brrAnim; radiusY: entryBg.brrAnim; direction: PathArc.Clockwise }
                            PathLine { x: entryBg.blrAnim; y: entryBg.height }
                            PathArc { x: 0; y: entryBg.height - entryBg.blrAnim; radiusX: entryBg.blrAnim; radiusY: entryBg.blrAnim; direction: PathArc.Clockwise }
                            PathLine { x: 0; y: entryBg.tlrAnim }
                            PathArc { x: entryBg.tlrAnim; y: 0; radiusX: entryBg.tlrAnim; radiusY: entryBg.tlrAnim; direction: PathArc.Clockwise }
                        }
                    }

                    DRipple {
                        id: entryRip
                        anchors.fill: parent
                        cornerRadius: entryBg.tlrAnim
                        rippleColor: Theme.primary
                    }

                    MouseArea {
                        id: entryMa
                        anchors.fill: parent
                        enabled: entryRow.entryItems.length > 0
                        hoverEnabled: true
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onPressed: (m) => entryRip.trigger(m.x, m.y)
                        onClicked: {
                            const updated = Object.assign({}, view.expandedKeys);
                            updated[entryRow.entryKey] = !entryRow.expanded;
                            view.expandedKeys = updated;
                        }
                    }

                // The row grows to its new height over an animation while its content
                // is already at full size; without this the opened part drew outside
                // the row, over its neighbours. Inside the outline, so that stays whole.
                Item {
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true

                    ColumnLayout {
                        id: entryColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: Theme.spacingS - 1
                        anchors.leftMargin: Theme.spacingS - 1
                        anchors.rightMargin: Theme.spacingS - 1
                        spacing: Theme.spacingXS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            DIcon {
                                name: view.iconFor(entryRow.modelData.type)
                                size: 20
                                color: view.colorFor(entryRow.modelData.type)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                StyledText {
                                    Layout.fillWidth: true
                                    text: view.entryTitle(entryRow.modelData)
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    text: view.formatWhen(entryRow.modelData.ts || 0)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }

                            DIcon {
                                visible: entryRow.entryItems.length > 0
                                name: entryRow.expanded ? "expand_less" : "expand_more"
                                size: 18
                                color: Theme.surfaceVariantText
                            }
                        }

                        // Expanded details: one row per package
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 32
                            visible: entryRow.expanded
                            spacing: 2

                            Repeater {
                                model: entryRow.expanded ? entryRow.entryItems : []

                                delegate: ColumnLayout {
                                    id: itemRow

                                    required property var modelData
                                    // The tool's own words behind a failed row —
                                    // kept out of sight until asked for
                                    property bool showError: false
                                    readonly property string rawError: modelData.error || ""

                                    Layout.fillWidth: true
                                    spacing: 1

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        DIcon {
                                            // Three outcomes, not two. A row that
                                            // is neither done nor failed — a run
                                            // torn down by the shell reloading
                                            // leaves those — used to be drawn with
                                            // the same green tick as a success,
                                            // which is how an entry could show
                                            // three ticks over a title saying two.
                                            name: itemRow.modelData.status === "error" ? "error"
                                                : (itemRow.modelData.status === "done" ? "check_circle" : "schedule")
                                            size: 13
                                            color: itemRow.modelData.status === "error" ? Theme.error
                                                : (itemRow.modelData.status === "done" ? Theme.success : Theme.surfaceVariantText)
                                        }

                                        StyledText {
                                            // Entries written before the log kept
                                            // ids have only a display name. A name
                                            // without spaces is a package name in
                                            // practice, so those still lead
                                            // somewhere; "GNU Image Manipulation
                                            // Program" would lead nowhere and stays
                                            // plain text.
                                            readonly property bool linkable: (itemRow.modelData.id || "") !== "" || /^\S{2,}$/.test(itemRow.modelData.name || "")

                                            text: itemRow.modelData.name || ""
                                            font.pixelSize: Theme.fontSizeSmall
                                            wrapMode: Text.NoWrap
                                            font.underline: linkable && nameArea.containsMouse
                                            color: linkable && nameArea.containsMouse ? Theme.primary : Theme.surfaceText
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: 260

                                            MouseArea {
                                                id: nameArea
                                                anchors.fill: parent
                                                anchors.margins: -2
                                                enabled: parent.linkable
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: view.packageActivated(itemRow.modelData)
                                            }
                                        }

                                        StyledText {
                                            visible: (itemRow.modelData.from || "") !== "" || (itemRow.modelData.to || "") !== ""
                                            text: {
                                                const to = Ui.versionLabel(itemRow.modelData.to);
                                                if ((itemRow.modelData.from || "") !== "" && to !== "")
                                                    return itemRow.modelData.from + " → " + to;
                                                return to || itemRow.modelData.from || "";
                                            }
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            // StyledText wraps by default, so a
                                            // long version used to break at the
                                            // arrow while the row still had room to
                                            // its right. The fix for that was to
                                            // fill the width and cap the fill at
                                            // the text's natural size — but a cap
                                            // has to be measured, and every way of
                                            // measuring it came out a little short:
                                            // "8.1.4087.64-1 → 8.1.4087.66-1" lost
                                            // its arrow, "4.2.1" came out as "4…1".
                                            //
                                            // There is nothing to cap. A spacer
                                            // further along this row already takes
                                            // the slack, so this can simply be its
                                            // own width and shrink — that is what
                                            // minimumWidth 0 is for — on the day the
                                            // row genuinely cannot fit it.
                                            wrapMode: Text.NoWrap
                                            elide: Text.ElideMiddle
                                            Layout.minimumWidth: 0
                                        }

                                        StyledText {
                                            visible: (itemRow.modelData.reason || "") !== ""
                                            text: "· " + (itemRow.modelData.reason || "")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.error
                                            wrapMode: Text.NoWrap
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: 260
                                        }

                                        Item {
                                            Layout.fillWidth: true
                                        }

                                        StyledText {
                                            visible: itemRow.rawError !== ""
                                            text: itemRow.showError ? Tr.t("Hide details") : Tr.t("Show details")
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                            font.underline: rawToggleArea.containsMouse
                                            color: Theme.error

                                            MouseArea {
                                                id: rawToggleArea
                                                anchors.fill: parent
                                                anchors.margins: -4
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: itemRow.showError = !itemRow.showError
                                            }
                                        }

                                        StyledText {
                                            visible: (itemRow.modelData.source || "") !== ""
                                            text: Tr.t(itemRow.modelData.source || "")
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 21
                                        Layout.bottomMargin: Theme.spacingXS
                                        visible: itemRow.showError && itemRow.rawError !== ""
                                        implicitHeight: rawErrorLabel.implicitHeight + Theme.spacingS * 2
                                        radius: Theme.cornerRadius / 2
                                        color: Theme.withAlpha(Theme.surfaceVariant, 0.5)

                                        SelectableText {
                                            id: rawErrorLabel
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.margins: Theme.spacingS
                                            text: itemRow.rawError
                                            font.family: Theme.monoFontFamily
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.Wrap
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
        }
        }

        // Empty state
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.visibleEntries.length === 0

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: view.searchText.trim() !== "" ? "search_off" : "history"
                    size: 48
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: view.searchText.trim() !== "" ? Tr.t("No log entries match \"%1\"").arg(view.searchText.trim()) : Tr.t("No actions logged yet")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: view.searchText.trim() === ""
                    text: Tr.t("Updates, installs and removals will appear here (kept for two years)")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.7)
                }
            }
        }
    }
}
