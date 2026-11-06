import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets

// A year, read back out of the action log.
//
// The Log tab's strip says what happened lately; this answers a different
// and more interesting question — how much went through here, how often, how
// long the quiet stretches were, and what you keep updating. All of it is
// counted from the log itself, which means it can only speak for as far back
// as the log goes, and says so rather than presenting a fortnight as a year.
//
// It stays away until there is a stretch worth looking back over: a fresh
// install should not be handed a solemn annual report of its first evening.
Item {
    id: card

    property var log: []
    readonly property int periodDays: 365

    readonly property var stats: {
        const all = log || [];
        const cutoff = Date.now() / 1000 - periodDays * 86400;
        let updated = 0;
        let installed = 0;
        let removed = 0;
        let failed = 0;
        let earliest = 0;
        let biggestRun = 0;
        let biggestRunTs = 0;
        const runTimes = [];
        const months = ({});
        const packages = ({});

        for (const entry of all) {
            const ts = entry.ts || 0;
            if (ts < cutoff)
                continue;
            if (earliest === 0 || ts < earliest)
                earliest = ts;
            const type = entry.type || "";
            const items = entry.items || [];
            if (type.indexOf("update") === 0) {
                runTimes.push(ts);
                let inThisRun = 0;
                const month = new Date(ts * 1000);
                const monthKey = month.getFullYear() + "-" + month.getMonth();
                for (const item of items) {
                    if (item.status === "error") {
                        failed++;
                        continue;
                    }
                    updated++;
                    inThisRun++;
                    months[monthKey] = (months[monthKey] || 0) + 1;
                    const name = item.name || "";
                    if (name !== "")
                        packages[name] = (packages[name] || 0) + 1;
                }
                if (inThisRun > biggestRun) {
                    biggestRun = inThisRun;
                    biggestRunTs = ts;
                }
            } else if (type === "install") {
                installed += items.length;
            } else if (type === "uninstall") {
                removed += items.length;
            }
        }

        // The rhythm of the runs: how often, and the longest it ever went
        // quiet. Both come from the gaps, so both need at least two runs.
        runTimes.sort((a, b) => a - b);
        let averageGap = 0;
        let longestGap = 0;
        if (runTimes.length > 1) {
            for (let i = 1; i < runTimes.length; i++) {
                const gap = runTimes[i] - runTimes[i - 1];
                if (gap > longestGap)
                    longestGap = gap;
            }
            averageGap = (runTimes[runTimes.length - 1] - runTimes[0]) / (runTimes.length - 1);
        }

        let busiestKey = "";
        let busiestCount = 0;
        for (const key in months) {
            if (months[key] > busiestCount) {
                busiestCount = months[key];
                busiestKey = key;
            }
        }
        let topName = "";
        let topCount = 0;
        for (const name in packages) {
            if (packages[name] > topCount) {
                topCount = packages[name];
                topName = name;
            }
        }

        return {
            updated: updated,
            installed: installed,
            removed: removed,
            failed: failed,
            runs: runTimes.length,
            earliest: earliest,
            averageGap: averageGap,
            longestGap: longestGap,
            biggestRun: biggestRun,
            biggestRunTs: biggestRunTs,
            busiestKey: busiestKey,
            busiestCount: busiestCount,
            topName: topName,
            topCount: topCount
        };
    }

    readonly property bool worthShowing: stats.earliest > 0 && (Date.now() / 1000 - stats.earliest) > 30 * 86400 && (stats.updated + stats.installed + stats.removed) >= 20

    // "every 3.4 days" reads as a rhythm; "every 81.6 hours" does not, and
    // below a day the other way round. The decimal is dropped when it is a
    // zero and written with the locale's own separator when it is not —
    // "5.4 dagen" is not how that number is spelled in Dutch.
    function _duration(seconds) {
        if (seconds < 36 * 3600)
            return Tr.t("%1 hours").arg(Math.round(seconds / 3600));
        const days = Math.round(seconds / 8640) / 10;
        const text = days % 1 === 0 ? String(days) : Number(days).toLocaleString(Tr.locale, 'f', 1);
        return Tr.t("%1 days").arg(text);
    }

    function _monthLabel(key) {
        const parts = (key || "").split("-");
        if (parts.length !== 2)
            return "";
        return new Date(parseInt(parts[0], 10), parseInt(parts[1], 10), 1).toLocaleDateString(Tr.locale, "MMMM yyyy");
    }

    implicitHeight: worthShowing ? column.implicitHeight + Theme.spacingM * 2 : 0
    visible: worthShowing

    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Ui.chipSurface, 0.45)
    }

    ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        anchors.topMargin: Theme.spacingM
        spacing: Theme.spacingS

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DIcon {
                name: "calendar_month"
                size: 20
                color: Theme.primary
            }

            StyledText {
                text: Tr.t("The last year")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }

            Item {
                Layout.fillWidth: true
            }

            // A year of figures counted from four months of log would be a
            // lie by omission; the period it really covers is part of it
            StyledText {
                visible: card.stats.earliest > 0 && (Date.now() / 1000 - card.stats.earliest) < (card.periodDays - 7) * 86400
                text: Tr.t("as far back as the log goes — %1").arg(new Date(card.stats.earliest * 1000).toLocaleDateString(Tr.locale, Locale.ShortFormat))
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingL

            Repeater {
                model: [
                    {
                        value: card.stats.updated,
                        label: Tr.t("updated"),
                        colour: Theme.primary
                    },
                    {
                        value: card.stats.installed,
                        label: Tr.t("installed"),
                        colour: Theme.success
                    },
                    {
                        value: card.stats.removed,
                        label: Tr.t("removed"),
                        colour: Theme.surfaceVariantText
                    },
                    {
                        value: card.stats.failed,
                        label: Tr.t("failed"),
                        colour: Ui.failColor
                    }
                ]

                delegate: ColumnLayout {
                    required property var modelData

                    visible: modelData.value > 0
                    spacing: 0

                    StyledText {
                        text: String(modelData.value)
                        font.pixelSize: Theme.fontSizeLarge + 2
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

        Repeater {
            model: [
                {
                    show: card.stats.runs > 1,
                    text: Tr.t("across %1 update runs, one every %2 on average").arg(card.stats.runs).arg(card._duration(card.stats.averageGap))
                },
                {
                    show: card.stats.longestGap > 2 * 86400,
                    text: Tr.t("the longest quiet stretch was %1").arg(card._duration(card.stats.longestGap))
                },
                {
                    show: card.stats.biggestRun > 1 && card.stats.biggestRun < card.stats.updated,
                    text: Tr.t("the biggest run was %1 packages, on %2").arg(card.stats.biggestRun).arg(new Date(card.stats.biggestRunTs * 1000).toLocaleDateString(Tr.locale, Locale.ShortFormat))
                },
                {
                    show: card.stats.busiestCount > 0 && card.stats.updated > card.stats.busiestCount,
                    text: Tr.t("%1 was the busiest month, with %2 packages").arg(card._monthLabel(card.stats.busiestKey)).arg(card.stats.busiestCount)
                },
                {
                    show: card.stats.topCount > 1,
                    text: Tr.t("%1 is what you update most — %2 times").arg(card.stats.topName).arg(card.stats.topCount)
                }
            ]

            delegate: StyledText {
                required property var modelData

                Layout.fillWidth: true
                visible: modelData.show
                text: modelData.text
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }
    }
}
