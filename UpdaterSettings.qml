import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "dankSoftwareDepot"

    ToggleSetting { id: s_hide; settingKey: "hideWhenUpToDate"; label: Tr.t("Hide when up to date"); defaultValue: false; visible: false; height: 0 }
    ToggleSetting { id: s_runtimes; settingKey: "showRuntimes"; label: Tr.t("Show runtimes and extensions"); defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_firmware; settingKey: "includeFirmware"; label: Tr.t("Include firmware updates"); defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_confirm; settingKey: "confirmBeforeUpdate"; label: Tr.t("Confirm before updating"); defaultValue: false; visible: false; height: 0 }
    ToggleSetting { id: s_tint; settingKey: "tintAppIcons"; label: Tr.t("Tint app icons with the theme colour"); defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_pill; settingKey: "pillOpensWindow"; label: Tr.t("Bar click opens window"); defaultValue: false; visible: false; height: 0 }
    SelectionSetting { id: s_auto; settingKey: "autoUpdateMode"; label: Tr.t("Automatic updates"); defaultValue: "notify"; visible: false; height: 0; options: [{label:"", value:""}] }

    // ── On the main bar ────────────────────────────────────
    // First on the page because it is the first thing a new user needs:
    // enabling a plugin does not put its widget anywhere, and the way to do
    // that by hand is a different settings page. One choice — left, centre
    // or right of the main bar — places it there, or moves it if it already
    // is on that bar. DMS's own setters, so its bar editor stays in step.
    StyledRect {
        id: barPlacement
        width: parent.width
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Ui.chipSurface, 0.45)
        implicitHeight: placeCol.implicitHeight + Theme.spacingM * 2

        readonly property var sideKeys: ["leftWidgets", "centerWidgets", "rightWidgets"]

        function entryId(widget) {
            return typeof widget === "string" ? widget : ((widget && widget.id) || "");
        }

        readonly property var mainBar: {
            void SettingsData.barConfigs;
            return SettingsData.getPrimaryBarConfig();
        }

        // Where the widget sits on the main bar, or -1
        readonly property int sideIndex: {
            if (!mainBar)
                return -1;
            for (let i = 0; i < sideKeys.length; i++) {
                if ((mainBar[sideKeys[i]] || []).some(w => entryId(w) === root.pluginId))
                    return i;
            }
            return -1;
        }

        function place(side) {
            if (!mainBar || side === sideIndex)
                return;
            const lists = sideKeys.map(key => (mainBar[key] || []).filter(w => entryId(w) !== root.pluginId));
            const entry = {
                "id": root.pluginId,
                "enabled": true
            };
            // On the right, next to the other status widgets rather than past
            // the control centre button that usually closes the bar
            const target = lists[side];
            const cc = side === 2 ? target.findIndex(w => entryId(w) === "controlCenterButton") : -1;
            if (cc >= 0)
                target.splice(cc, 0, entry);
            else
                target.push(entry);
            SettingsData.setDankBarLeftWidgets(lists[0]);
            SettingsData.setDankBarCenterWidgets(lists[1]);
            SettingsData.setDankBarRightWidgets(lists[2]);
        }

        ColumnLayout {
            id: placeCol
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                DIcon {
                    name: "toolbar"
                    size: 20
                    color: Theme.primary
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        text: Tr.t("On the main bar")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: !barPlacement.mainBar ? Tr.t("There is no main bar to place the widget on.") : (barPlacement.sideIndex < 0 ? Tr.t("Not on the bar yet. Choose where it goes.") : Tr.t("Choose another side to move it."))
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }
            }

            DButtonGroup {
                visible: !!barPlacement.mainBar
                model: [Tr.t("Left"), Tr.t("Center"), Tr.t("Right")]
                currentIndex: barPlacement.sideIndex
                onSelectionChanged: (index, selected) => {
                    if (selected)
                        barPlacement.place(index);
                }
            }
        }
    }

    // ── About & Plugin Info Card ───────────────────────────
    StyledRect {
        width: parent.width
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Ui.chipSurface, 0.45)
        border.width: 0
        implicitHeight: aboutCol.implicitHeight + Theme.spacingM * 2

        ColumnLayout {
            id: aboutCol
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.10)
                    border.width: 0

                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
                        // The app's own icon, as the window and the bar use it;
                        // the path #21 put here never existed
                        source: Qt.resolvedUrl("assets/icons/dux-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg")
                        sourceSize.width: 80
                        sourceSize.height: 80
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        text: "Dux Software Depot"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: Tr.t("Visual updater and software hub for DMS")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: Tr.t("Visual updater built on the DMS system update service. Check interval and ignored packages are managed in Settings → System Updater.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Rectangle {
                id: openAppBtn
                Layout.preferredHeight: 34
                Layout.preferredWidth: openRow.implicitWidth + 24
                property bool isHovered: openMa.containsMouse

                radius: openMa.pressed ? (height / 2) : Theme.cornerRadius
                Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                // The page's only action: filled (Ui.buttonFill)
                color: Ui.buttonFill("filled", isHovered)
                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                scale: openMa.pressed ? 0.94 : 1.0
                Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                DRipple {
                    id: openRip
                    anchors.fill: parent
                    cornerRadius: parent.radius
                    rippleColor: Ui.buttonInk("filled")
                }

                RowLayout {
                    id: openRow
                    anchors.centerIn: parent
                    spacing: 6

                    DIcon {
                        name: "open_in_new"
                        size: 16
                        color: Ui.buttonInk("filled")
                    }

                    StyledText {
                        text: Tr.t("Open Dux Software Depot")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Ui.buttonInk("filled")
                    }
                }

                MouseArea {
                    id: openMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: (m) => openRip.trigger(m.x, m.y)
                    onClicked: Quickshell.execDetached(["sh", Qt.resolvedUrl("scripts/open.sh").toString().replace("file://", "")])
                }
            }
        }
    }

    Column {
                                id: prefColumn
                                width: parent.width
                                spacing: 2
    
                                // 1. Hide when up to date (First)
                                Rectangle {
                                    width: parent.width
                                    height: row1.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: true
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row1
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "visibility_off"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Hide when up to date")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Hide the bar pill while there are no pending updates.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t1
                                            hideText: true
                                            checked: s_hide.value === true
                                            onToggled: checked => s_hide.value = checked
                                        }
                                    }
                                }
    
                                // 2. Show runtimes and extensions (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row2.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row2
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "extension"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Show runtimes and extensions")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("List Flatpak runtimes, locales and codec extensions. They are always included in Update All.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t2
                                            hideText: true
                                            checked: s_runtimes.value === true
                                            onToggled: checked => s_runtimes.value = checked
                                        }
                                    }
                                }
    
                                // 3. Include firmware updates (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row3.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row3
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "memory"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Include firmware updates")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Check for device firmware updates via fwupd (LVFS) and include them in Update All.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t3
                                            hideText: true
                                            checked: s_firmware.value === true
                                            onToggled: checked => s_firmware.value = checked
                                        }
                                    }
                                }
    
                                // 4. Confirm before updating (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row4.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row4
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "check_circle"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Confirm before updating")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Require a second click on Update All before the run starts.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t4
                                            hideText: true
                                            checked: s_confirm.value === true
                                            onToggled: checked => s_confirm.value = checked
                                        }
                                    }
                                }
    
                                // 5. Authorise with sudo (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row5.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row5
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "admin_panel_settings"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Authorise with sudo")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Run privileged commands through sudo instead of asking polkit, for systems where sudo has been configured to need no password. Falls back to the usual prompt whenever sudo would ask for one.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t5
                                            hideText: true
                                            checked: Backend.useSudo
                                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "useSudo", checked)
                                        }
                                    }
                                }
    
                                // 6. Tint app icons with the theme colour (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row6.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row6
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "palette"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Tint app icons with the theme colour")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Draw app icons in greyscale and colour them with the active DMS accent, instead of showing each app's own colours.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t6
                                            hideText: true
                                            checked: s_tint.value === true
                                            onToggled: checked => s_tint.value = checked
                                        }
                                    }
                                }
    
                                // 7. Show in app launcher (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row7.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row7
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "apps"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Show in app launcher")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Place a desktop entry so this window can be opened from the application launcher, like a standalone app.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t7
                                            hideText: true
                                            checked: Backend.launcherEntryPresent
                                            enabled: Backend.launcherEntryChecked && !Backend.launcherEntryBusy
                                            onToggled: checked => {
                                                if (checked)
                                                    Backend.installLauncherEntry();
                                                else
                                                    Backend.removeLauncherEntry();
                                                PluginService.savePluginData("dankSoftwareDepot", "launcherPromptDone", true);
                                            }
                                        }
                                    }
                                }
    
                                // 8. Open .appimage files with this app (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row8.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row8
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "insert_drive_file"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Open .appimage files with this app")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Double-clicking an AppImage opens this window, which offers to install it — or to replace the copy you already have. Adds the launcher entry if it is not there yet.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t8
                                            hideText: true
                                            checked: Backend.appimageHandlerDefault
                                            enabled: Backend.appimageHandlerChecked && !Backend.appimageHandlerBusy && !Backend.launcherEntryBusy
                                            onToggled: checked => {
                                                if (checked)
                                                    Backend.setAppimageHandler();
                                                else
                                                    Backend.clearAppimageHandler();
                                            }
                                        }
                                    }
                                }
    
                                // 9. Bar click opens window (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row9.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    RowLayout {
                                        id: row9
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DIcon {
                                            name: "open_in_browser"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Bar click opens window")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Open this window instead of the compact popout when clicking the bar pill. Right-click always opens the window.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DToggle {
                                            id: t9
                                            hideText: true
                                            checked: s_pill.value === true
                                            onToggled: checked => s_pill.value = checked
                                        }
                                    }
                                }
    
                                // 10. Automatic updates (Last - Stacked layout)
                                Rectangle {
                                    width: parent.width
                                    height: autoCol.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: true
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Ui.chipSurface, 0.45)
                                    border.width: 0
    
                                    ColumnLayout {
                                        id: autoCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingS
    
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingM
    
                                            DIcon {
                                                name: "sync"
                                                size: 20
                                                color: Theme.primary
                                            }
    
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2
    
                                                StyledText {
                                                    text: Tr.t("Automatic updates")
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.Medium
                                                    color: Theme.surfaceText
                                                }
    
                                                StyledText {
                                                    Layout.fillWidth: true
                                                    text: Tr.t("Notify when updates are found, and optionally install Flatpak updates automatically. System packages always ask first.")
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    wrapMode: Text.WordWrap
                                                }
                                            }
                                        }
    
                                        DDropdown {
                                            id: t10
                                            readonly property var autoMap: ({
                                                    "Off": "off",
                                                    "Notify only": "notify",
                                                    "Auto-install Flatpaks": "auto"
                                                })
    
                                            Layout.fillWidth: true
                                            compactMode: true
                                            dropdownWidth: parent.width
                                            options: Object.keys(autoMap).map(k => Tr.t(k))
                                            currentValue: {
                                                const mode = s_auto.value;
                                                for (const label in autoMap) {
                                                    if (autoMap[label] === mode)
                                                        return Tr.t(label);
                                                }
                                                return Tr.t("Off");
                                            }
                                            onValueChanged: value => {
                                                for (const label in autoMap) {
                                                    if (Tr.t(label) === value) {
                                                        s_auto.value = autoMap[label];
                                                        return;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
            }

