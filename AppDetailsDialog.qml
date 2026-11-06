import QtQuick.Effects
import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets

// Shared app-details popup used by the Updates, Installed and Install tabs.
// Shows everything that is known about an app: description, screenshots,
// sizes, release notes / changelog, ODRS review texts — plus the actions the
// hosting tab provides (install, update, hold, restore, uninstall).
//
// The host calls open(appData) with:
//   {id, name, summary, iconPath, homepage, rating, held, holdReason,
//    versionLabel, origin, isFlatpak, sources: [{source, kind, ref}]}
// and binds the extra-content/action properties below. Description,
// screenshots, sizes, reviews and rating are fetched here via
// `enrich.py --appinfo` (cached daily).
Item {
    id: dialog

    property var app: null
    property bool animActive: false
    readonly property bool showing: animActive || (app !== null)
    readonly property var appData: app || ({})
    property var info: ({})
    property bool loading: false
    readonly property string effectiveDescription: (info.descriptionHtml || "") !== "" ? info.descriptionHtml : ((appData.descriptionHtml || "") !== "" ? appData.descriptionHtml : (info.description || appData.description || appData.summary || ""))

    // Extra content supplied by the host
    property var releases: []            // [{version, date, notesHtml, newer}]
    property string releasesTitle: Tr.t("Release notes")
    property string changelog: ""        // rpm changelog text
    property bool changelogLoading: false
    // Upstream notes for a package built from git, where the distro has none
    // to give: either the release being installed, or the commits between two
    // snapshots of the branch. See MetadataStore.fetchGitNotes().
    property var gitReleases: []         // [{version, date, notesHtml}]
    property bool gitNotesLoading: false
    property string gitNotesKind: ""     // "release" | "changelog" | "commits" | "untouched" | ""
    property string gitNotesUrl: ""      // release or compare page upstream
    property int gitNotesMore: 0         // commits or blocks left unshown
    property int gitNotesCommits: 0
    // {type, severity, ids} from updateinfo. The CVE numbers were being
    // fetched with the rest and thrown away; this is the one place with room
    // to print them, and the one place someone would look them up from.
    // A DMS plugin is not a package: it has no repository, no download size,
    // nobody has reviewed it on ODRS and `dnf` has never heard of it. What it
    // does have is a manifest, which is what this shows instead — author,
    // category, where it came from, and the permissions it declares.
    // {author, category, source, directory, permissions: [...]}
    property var pluginFacts: null
    readonly property bool isPlugin: pluginFacts !== null

    // A Homebrew formula is not a package either: no repository to name, no
    // AppStream entry, no reviews. What it has is what brew knows —
    // {name, desc, homepage, license, version, installs30d, linux,
    //  dependencies, deprecated}
    property var brewFacts: null
    readonly property bool isBrew: brewFacts !== null

    property var advisory: null
    property var previousVersions: []    // [{label, payload}]
    property bool versionsLoading: false
    property bool noOlderVersions: false

    // Actions
    property bool busy: false
    property string busyDetail: ""   // live progress line shown next to the spinner
    property real busyFraction: 0    // 0..1 estimate; > 0 swaps the spinner for a progress bar
    property bool installedChipVisible: false
    property bool showInstallButtons: false
    property bool showUpdateButton: false
    property bool showHoldToggle: false
    property bool showUninstall: false
    // Packages the resolver says would go with this one. Empty until the
    // unprivileged plan comes back, and empty for anything that takes
    // nothing with it.
    property var alsoRemoves: []
    // {userInstalled, requiredBy, requiredByCount} — why this package is here
    property var provenance: null

    signal installRequested(var source)
    signal updateRequested()
    signal holdToggleRequested()
    signal uninstallRequested()
    signal restoreRequested(var payload)
    signal opened()

    // AppImage update source: a GitHub project whose releases feed updates.
    // The host binds the current repo and performs the save.
    property bool showUpdateSource: false
    property string updateSourceRepo: ""       // "owner/repo" or ""
    property string updateSourceStatus: ""     // "" | saving | done | error:<msg>
    signal updateSourceSaveRequested(string link)

    // The name a source goes by, not the id it is keyed on: the sizes line
    // read "fedora: 12 MB download" in every language, next to a translated
    // sentence. The install button below has always used the kind for this.
    function sourceLabel(entry) {
        if (entry.kind === "flatpak")
            return "Flathub";
        if (entry.kind === "appimage")
            return "AppImage";
        if (entry.kind === "dnf")
            return Backend.systemRepoLabel;
        const source = entry.source || "";
        return source.charAt(0).toUpperCase() + source.slice(1);
    }

    // Which source to take — the judgement lives in OriginComparison, which
    // the picker uses too, so the two cannot come to different conclusions
    readonly property var origins: dialog.info.origins || []

    // Which of them is already here. Decided by whoever opened this popup:
    // only the tab knows what is on the machine, and it knows it per source
    property var installedRefs: []

    readonly property string updateSourceUrl: updateSourceRepo !== "" ? "https://github.com/" + updateSourceRepo : ""

    property string _confirmUninstall: ""

    readonly property string scriptPath: Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", "")

    Timer {
        id: closeTimer
        interval: 220
        repeat: false
        onTriggered: {
            dialog.app = null;
            dialog.info = {};
            dialog._confirmUninstall = "";
            dialog.lightboxIndex = -1;
            dialog.reviewsShown = 10;
            dialog.descExpanded = false;
        }
    }

    function open(appData) {
        closeTimer.stop();
        app = appData;
        animActive = true;
        info = {};
        _confirmUninstall = "";
        reviewsShown = 10;
        descExpanded = false;
        reviewFormOpen = false;
        reviewStatus = "";
        reviewStars = 5;
        permsExpanded = false;
        updateSourceStatus = "";
        if ((appData.sources || []).some(s => s.kind === "flatpak" || s.kind === "dnf")) {
            loading = true;
            infoProcess.command = [Backend.python, scriptPath, "--appinfo", JSON.stringify({
                id: appData.id,
                sources: appData.sources || []
            })];
            infoProcess.running = true;
        } else {
            loading = false;
        }
        opened();
    }

    function close() {
        if (!showing) return;
        animActive = false;
        lightboxIndex = -1;
        closeTimer.restart();
    }

    // Reviews are revealed incrementally while scrolling toward the bottom
    property int reviewsShown: 10
    // Expansion toggles for details dialog
    property bool descExpanded: false

    // Launch button (installed flatpaks / AppImages). openCommand overrides
    // the default `flatpak run <id>`.
    property bool showOpenButton: false
    property var openCommand: []

    // ── Write-a-review state ────────────────────────────────────────────────
    property bool reviewFormOpen: false
    property int reviewStars: 5
    property string reviewStatus: ""   // "" | sending | done | error:<msg>

    // Reviews live on ODRS, keyed by the AppStream/package id. AppImages only
    // have a plugin-local id (no shared identity anyone else could look up),
    // so reading and writing reviews is disabled for them.
    readonly property bool reviewable: (appData.sources || []).some(s => s.kind === "flatpak" || s.kind === "dnf")

    // Prefill the reviewer name from the remembered value, falling back to
    // the login name (which the backend would otherwise use anyway)
    onReviewFormOpenChanged: {
        if (reviewFormOpen && reviewNameField.text.trim() === "")
            reviewNameField.text = PluginService.loadPluginData("dankSoftwareDepot", "reviewerName", Quickshell.env("USER") || "");
    }

    function submitReview(summaryText, bodyText, displayName) {
        reviewStatus = "sending";
        if (displayName !== "")
            PluginService.savePluginData("dankSoftwareDepot", "reviewerName", displayName);
        reviewProcess.command = [Backend.python, scriptPath, "--submit-review", JSON.stringify({
            app_id: appData.id,
            rating: reviewStars,
            summary: summaryText,
            description: bodyText,
            user_display: displayName,
            version: appData.versionLabel || "unknown"
        })];
        reviewProcess.running = true;
    }

    Process {
        id: reviewProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let ok = false;
                let error = "";
                try {
                    const result = JSON.parse(text);
                    ok = result.ok === true;
                    error = result.error || "";
                } catch (e) {
                    error = "parse";
                }
                dialog.reviewStatus = ok ? "done" : ("error:" + error);
                if (ok)
                    dialog.reviewFormOpen = false;
            }
        }
    }

    // Sandbox permission token → readable label
    function permLabel(token) {
        switch (token) {
        case "network":
            return Tr.t("Network");
        case "ipc":
            return "IPC";
        case "x11":
        case "fallback-x11":
            return "X11";
        case "wayland":
            return "Wayland";
        case "pulseaudio":
            return Tr.t("Audio");
        case "pcsc":
            return "PC/SC";
        case "cups":
            return Tr.t("Printing");
        case "ssh-auth":
            return "SSH";
        case "session-bus":
        case "dbus-talk":
            return Tr.t("D-Bus services");
        case "system-dbus":
            return Tr.t("System D-Bus");
        case "devices:all":
            return Tr.t("All devices");
        case "devices":
            return Tr.t("Device access");
        }
        if (token.indexOf("fs:") === 0) {
            const fs = token.substring(3);
            if (fs === "host" || fs === "host:ro")
                return Tr.t("Full file access");
            if (fs.indexOf("home") === 0)
                return Tr.t("Home folder");
            if (fs.indexOf("xdg-download") === 0)
                return Tr.t("Downloads folder");
            if (fs.indexOf("xdg-documents") === 0)
                return Tr.t("Documents folder");
            if (fs.indexOf("xdg-pictures") === 0)
                return Tr.t("Pictures folder");
            if (fs.indexOf("xdg-music") === 0)
                return Tr.t("Music folder");
            if (fs.indexOf("xdg-videos") === 0)
                return Tr.t("Videos folder");
            return fs;
        }
        return token;
    }

    // Risky permissions first, filesystem paths last; the list is collapsed
    // to one row's worth of chips until expanded
    readonly property var permissionTokens: {
        if (dialog.isPlugin)
            return (pluginFacts.permissions || []).slice();
        const tokens = ((info.flathub && info.flathub.permissions) ? info.flathub.permissions : []).filter(tok => tok !== "ipc");
        const rank = tok => {
            if (tok === "devices:all" || tok === "fs:host" || tok === "fs:host:ro")
                return 0;
            if (tok === "network")
                return 1;
            if (tok.indexOf("fs:") === 0)
                return 4;
            if (tok === "dbus-talk" || tok === "system-dbus")
                return 3;
            return 2;
        };
        return tokens.slice().sort((a, b) => rank(a) - rank(b));
    }
    property bool permsExpanded: false
    readonly property int permsCollapsedCount: 4

    // ── Screenshot lightbox state ────────────────────────────────────────────
    property int lightboxIndex: -1
    readonly property bool lightboxOpen: lightboxIndex >= 0
    readonly property var screenshotUrls: (info.screenshots && info.screenshots.length > 0) ? info.screenshots : (appData.screenshots || [])

    function screenshotSource(value) {
        return value.startsWith("/") ? "file://" + value : value;
    }

    function lightboxStep(delta) {
        if (screenshotUrls.length === 0)
            return;
        lightboxIndex = (lightboxIndex + delta + screenshotUrls.length) % screenshotUrls.length;
    }

    readonly property var effectiveRating: appData.rating || info.rating || null

    // SPDX expressions can be endless AND/OR chains — show the first license
    // with a counter for the rest
    function shortLicense(license) {
        const parts = (license || "").split(/\s+(?:AND|OR)\s+/i).filter(p => p !== "");
        if (parts.length <= 1)
            return license || "";
        return parts[0].replace(/^\(+|\)+$/g, "") + " +" + (parts.length - 1);
    }

    function formatCount(n) {
        if (n >= 1000000)
            return (n / 1000000).toFixed(1) + "M";
        if (n >= 10000)
            return Math.round(n / 1000) + "k";
        if (n >= 1000)
            return (n / 1000).toFixed(1) + "k";
        return String(n);
    }

    Process {
        id: infoProcess

        // NDJSON: the local part ({"partial": true}) arrives first so the
        // description shows immediately; the network extras (screenshots,
        // sizes, reviews) merge in when the second line lands.
        stdout: SplitParser {
            onRead: line => {
                let data = null;
                try {
                    data = JSON.parse(line);
                } catch (e) {
                    return;
                }
                delete data.partial;
                dialog.info = Object.assign({}, dialog.info, data);
                dialog.loading = false;
            }
        }

        onExited: (exitCode, exitStatus) => {
            dialog.loading = false;
        }
    }

    Timer {
        id: confirmTimer
        interval: 5000
        onTriggered: dialog._confirmUninstall = ""
    }

    anchors.fill: parent
    visible: showing
    z: 100

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
            // Consume wheel events so content behind the popup never scrolls
            onWheel: wheel => wheel.accepted = true
        }
    }

    onShowingChanged: {
        if (showing)
            dialogFocus.forceActiveFocus();
    }

    Item {
        id: dialogFocus

        Keys.onEscapePressed: {
            if (dialog.lightboxOpen)
                dialog.lightboxIndex = -1;
            else
                dialog.close();
        }
        Keys.onLeftPressed: {
            if (dialog.lightboxOpen)
                dialog.lightboxStep(-1);
        }
        Keys.onRightPressed: {
            if (dialog.lightboxOpen)
                dialog.lightboxStep(1);
        }
    }

    // ── Screenshot lightbox (above the card) ────────────────────────────────
    Rectangle {
        anchors.fill: parent
        visible: dialog.lightboxOpen
        color: Qt.rgba(0, 0, 0, 0.85)
        z: 10

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.lightboxIndex = -1
            onWheel: wheel => wheel.accepted = true
        }

        Image {
            id: lightboxImage
            anchors.centerIn: parent
            width: parent.width - 110
            height: parent.height - 90
            source: dialog.lightboxOpen ? dialog.screenshotSource(dialog.screenshotUrls[dialog.lightboxIndex]) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            scale: dialog.lightboxOpen ? 1.0 : 0.92
            opacity: dialog.lightboxOpen ? 1.0 : 0.0
            Behavior on scale { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }

            MouseArea {
                anchors.fill: parent
            }
        }

        DSpinner {
            anchors.centerIn: parent
            visible: lightboxImage.status === Image.Loading
            size: 40
        }

        DActionButton {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Theme.spacingM
            buttonSize: 36
            iconName: "close"
            iconSize: 20
            iconColor: "white"
            onClicked: dialog.lightboxIndex = -1
        }

        DActionButton {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingS
            visible: dialog.screenshotUrls.length > 1
            buttonSize: 40
            iconName: "chevron_left"
            iconSize: 26
            iconColor: "white"
            onClicked: dialog.lightboxStep(-1)
        }

        DActionButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.spacingS
            visible: dialog.screenshotUrls.length > 1
            buttonSize: 40
            iconName: "chevron_right"
            iconSize: 26
            iconColor: "white"
            onClicked: dialog.lightboxStep(1)
        }

        StyledText {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: Theme.spacingM
            visible: dialog.screenshotUrls.length > 1
            text: (dialog.lightboxIndex + 1) + " / " + dialog.screenshotUrls.length
            font.pixelSize: Theme.fontSizeSmall
            color: "white"
        }
    }

    StyledRect {
        id: card
        anchors.centerIn: parent
        width: Math.min(720, dialog.width - Theme.spacingL * 2)
        height: Math.min(dialog.height - Theme.spacingL * 2, 660)
        radius: Theme.cornerRadius + 4
        color: Ui.cardSurface
        border.width: 0
        scale: dialog.animActive ? 1.0 : 0.92
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on scale { NumberAnimation { duration: dialog.animActive ? 320 : 200; easing.type: dialog.animActive ? Easing.OutBack : Easing.InQuad } }
        Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutQuad } }

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            // ── Header Container Card ──────────────────────────────────────
            StyledRect {
                Layout.fillWidth: true
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                border.width: 0
                implicitHeight: headerContentCol.implicitHeight + Theme.spacingM * 2

                ColumnLayout {
                    id: headerContentCol
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: 0

                                RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Rectangle {
                    Layout.preferredWidth: 48
                    Layout.preferredHeight: 48
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.08)
                    border.width: 0

                    Image {
                        id: dialogLogo
                        anchors.fill: parent
                        anchors.margins: 4
                        source: dialog.appData.iconPath ? (dialog.appData.iconPath.indexOf("http") === 0 ? dialog.appData.iconPath : "file://" + dialog.appData.iconPath) : ""
                        // Rendered at the size it is shown: left to its own, an SVG
                        // logo is drawn at hundreds of pixels and shrunk unfiltered
                        sourceSize.width: width
                        sourceSize.height: height
                        fillMode: Image.PreserveAspectFit
                        // Themed icons, tuned in TintedIconEffect
                        layer.enabled: Ui.tintAppIcons
                        layer.effect: TintedIconEffect {}
                    }

                    DIcon {
                        anchors.centerIn: parent
                        visible: dialogLogo.status !== Image.Ready
                        name: dialog.isPlugin
                            ? ((dialog.pluginFacts.icon || "") !== "" ? dialog.pluginFacts.icon : "extension")
                            : (dialog.appData.isFlatpak === false ? "memory" : "apps")
                        size: 28
                        color: Ui.tintAppIcons ? Theme.primary : Theme.surfaceVariantText
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        // The package name is the string most worth copying in
                        // this window — into a search box, a bug report, a
                        // command. It wraps rather than elides now, because
                        // the element that can be selected has no ellipsis and
                        // a name cut short with no mark saying so is worse
                        // than a name on two lines.
                        SelectableText {
                            text: dialog.appData.name || ""
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                            Layout.maximumWidth: 360
                        }

                        // Flathub-verified developer
                        DIcon {
                            visible: dialog.info.flathub !== undefined && dialog.info.flathub !== null && dialog.info.flathub.verified === true
                            name: "verified"
                            filled: true
                            size: 16
                            color: Theme.primary
                        }

                        Rectangle {
                            visible: (dialog.appData.origin || "") !== ""
                            Layout.preferredWidth: originChip.implicitWidth + 14
                            Layout.preferredHeight: 18
                            radius: 9
                            color: dialog.appData.isFlatpak !== false ? Theme.withAlpha(Theme.tertiary, 0.15) : Theme.withAlpha(Theme.secondary, 0.15)

                            StyledText {
                                id: originChip
                                anchors.centerIn: parent
                                text: dialog.appData.origin || ""
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: dialog.appData.isFlatpak !== false ? Theme.tertiary : Theme.secondary
                            }
                        }

                        Rectangle {
                            visible: dialog.appData.held === true
                            Layout.preferredWidth: heldChip.implicitWidth + 12
                            Layout.preferredHeight: 16
                            radius: 8
                            color: Theme.withAlpha(Theme.warning, 0.18)

                            StyledText {
                                id: heldChip
                                anchors.centerIn: parent
                                text: Tr.t("Held")
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.warning
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }

                    // Version · developer, then the license behind its own
                    // icon. A licence field is free text, not a vocabulary:
                    // next to the SPDX ids sit full names ("GNU General Public
                    // License v3.0") and whole sentences from third-party
                    // vendors ("Multiple, see https://www.vivaldi.com/"). As
                    // the third item in a dot-separated line those read like a
                    // continuation of the sentence before them; behind a mark
                    // that says "licence", any of them reads as one.
                    RowLayout {
                        id: identityRow

                        // Computed here rather than read back off the children:
                        // an item's `visible` is false whenever its parent's
                        // is, so a row asking its children whether to be shown
                        // answers itself and latches shut.
                        readonly property string identityLine: {
                            const parts = [];
                            if (dialog.appData.versionLabel)
                                parts.push(dialog.appData.versionLabel);
                            if (dialog.info.developer)
                                parts.push(dialog.info.developer);
                            return parts.join(" · ");
                        }
                        // A formula's licence comes from brew rather than
                        // from AppStream, which has never heard of one. Same
                        // row, same glyph: where it was found is not
                        // something the reader has to care about.
                        readonly property string licenseLine: dialog.info.license ? dialog.shortLicense(dialog.info.license) : ((dialog.brewFacts && dialog.brewFacts.license) ? dialog.shortLicense(dialog.brewFacts.license) : "")

                        Layout.fillWidth: true
                        spacing: Theme.spacingXS
                        visible: identityLine !== "" || licenseLine !== ""

                        // Version step and developer: the other half of what
                        // gets pasted somewhere. Both halves of this row share
                        // the width and wrap, since neither can elide any more
                        // — which is also why the developer stays in the same
                        // text as the version rather than getting a mark of
                        // its own. A third free-standing segment would need a
                        // third share of the width, and the row would pull
                        // itself apart into evenly spaced columns.
                        DIcon {
                            visible: identityRow.identityLine !== ""
                            name: "tag"
                            size: 13
                            color: Theme.surfaceVariantText
                        }

                        // Not this one: whoever takes the leftover width pushes
                        // everything after it along, and the licence was ending
                        // up adrift in the middle of the row. It can still
                        // shrink and wrap when the row is genuinely too narrow.
                        SelectableText {
                            id: identityText

                            Layout.minimumWidth: 0
                            visible: identityRow.identityLine !== ""
                            text: identityRow.identityLine
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        DIcon {
                            id: licenseIcon

                            visible: identityRow.licenseLine !== ""
                            name: "license"
                            size: 13
                            color: Theme.surfaceVariantText
                        }

                        // The licence is the one item here with no upper bound
                        // on its length — Fedora hands out whole sentences as
                        // LicenseRef ids, and one of those is a single
                        // unbreakable word. So it takes the leftover width
                        // rather than asking for its own: a word that cannot
                        // fit breaks mid-word instead of being painted past
                        // the edge of the card, and the row stops claiming a
                        // width the header cannot give it. That last part is
                        // what was pushing the dialog's close button off the
                        // right-hand side — it sits after this column in the
                        // header row, and a column asking for 900px leaves
                        // nothing behind it.
                        SelectableText {
                            id: licenseText

                            Layout.minimumWidth: 0
                            Layout.fillWidth: true
                            visible: identityRow.licenseLine !== ""
                            text: identityRow.licenseLine
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        }

                        // Somebody has to want the leftover width, or the
                        // layout hands each item an equal share of it. With a
                        // licence on show that somebody is the licence itself;
                        // a package with no licence would otherwise put the gap
                        // back, in a row that no longer has anything on its
                        // right to blame.
                        Item {
                            Layout.fillWidth: identityRow.licenseLine === ""
                        }
                    }

                    RowLayout {
                        visible: !!dialog.effectiveRating
                        spacing: 1

                        Repeater {
                            model: 5

                            delegate: DIcon {
                                required property int index

                                readonly property bool lit: dialog.effectiveRating && (index + 0.25 <= dialog.effectiveRating.stars)

                                name: "star"
                                filled: lit
                                size: 13
                                color: lit ? Theme.primary : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
                            }
                        }

                        StyledText {
                            text: dialog.effectiveRating ? Tr.t("%1 (%2 ratings)").arg(dialog.effectiveRating.stars).arg(dialog.effectiveRating.count) : ""
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    radius: closeBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                    Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                    color: closeBtnMa.containsMouse ? Theme.withAlpha(Theme.error, 0.12) : Ui.buttonFill("icon", false)
                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                    DIcon {
                        anchors.centerIn: parent
                        name: "close"
                        size: 16
                        color: closeBtnMa.containsMouse ? Ui.failColor : Ui.buttonInk("icon")
                    }

                    MouseArea {
                        id: closeBtnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: dialog.close()
                    }
                }
            }
                }
            }

            // ── Scrollable body (DFlickable: same wheel feel as the lists)
            DFlickable {
                id: body
                Component.onCompleted: {
                    Ui.softenScrollbar(body);
                    Ui.takeOverWheel(body);
                }
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: bodyColumn.height

                WheelHandler {
                    id: smoothWheel
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (event) => {
                        if (Ui.wheelToShell(body, event)) {
                            bodyScrollAnim.stop();
                            return;
                        }
                        if (body.contentHeight <= body.height) return;
                        const delta = event.angleDelta.y;
                        if (delta === 0) return;
                        const lines = Math.round(Math.abs(delta) / 120) || 1;
                        const scrollDelta = (delta > 0 ? -lines : lines) * 120;
                        const currentTarget = bodyScrollAnim.running ? bodyScrollAnim.to : body.contentY;
                        const maxScroll = Math.max(0, body.contentHeight - body.height);
                        const newTarget = Math.max(0, Math.min(maxScroll, currentTarget + scrollDelta));
                        bodyScrollAnim.stop();
                        bodyScrollAnim.from = body.contentY;
                        bodyScrollAnim.to = newTarget;
                        bodyScrollAnim.start();
                        Ui.showScrollbar(body);
                        event.accepted = true;
                    }
                }

                NumberAnimation {
                    id: bodyScrollAnim
                    target: body
                    property: "contentY"
                    duration: Theme.longDuration
                    easing.type: Easing.OutCubic
                }



                Column {
                    id: bodyColumn
                    width: body.width
                    spacing: Theme.spacingM

                    Item {
                        width: parent.width
                        height: 80
                        visible: dialog.loading

                        DSpinner {
                            anchors.centerIn: parent
                            size: 32
                        }
                    }

                    // Screenshots Container Card
                    StyledRect {
                        id: screenshotsCard
                        width: parent.width
                        implicitHeight: screenshotsInner.implicitHeight + Theme.spacingM * 2
                        visible: (dialog.info.screenshots || []).length > 0
                        radius: Theme.cornerRadius
                        // The thumbnails inside are the containers
                        color: "transparent"
                        border.width: 0

                        ColumnLayout {
                            id: screenshotsInner
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "photo_library"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Screenshots (%1)").arg((dialog.screenshotUrls || []).length)
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 170

                                NumberAnimation {
                                    id: shotScrollAnim
                                    target: shotsFlickable
                                    property: "contentX"
                                    duration: Theme.longDuration
                                    easing.type: Easing.OutCubic
                                }

                                Flickable {
                                    id: shotsFlickable
                                    anchors.fill: parent
                                    contentWidth: shotsRow.width
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds

                                    Row {
                                        id: shotsRow
                                        spacing: Theme.spacingS
                                        height: parent.height

                                        Repeater {
                                            model: dialog.screenshotUrls

                                            delegate: Item {
                                                id: shotDelegate
                                                required property var modelData
                                                required property int index

                                                width: 280
                                                height: parent.height

                                                readonly property bool isFirst: index === 0
                                                readonly property bool isLast: index === ((dialog.screenshotUrls || []).length - 1)
                                                readonly property real innerRadius: 6
                                                readonly property real outerRadius: 14

                                                property bool hovered: shotMa.containsMouse
                                                // The shape answers a press, not the pointer passing over (#22)
                                                property bool morphed: shotMa.pressed

                                                property real tlr: morphed ? (height / 2) : (isFirst ? outerRadius : innerRadius)
                                                property real trr: morphed ? (height / 2) : (isLast ? outerRadius : innerRadius)
                                                property real blr: morphed ? (height / 2) : (isFirst ? outerRadius : innerRadius)
                                                property real brr: morphed ? (height / 2) : (isLast ? outerRadius : innerRadius)

                                                property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                                property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                                property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                                                property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                                                // Mask for dynamic rounded corners directly on the image
                                                Shape {
                                                    id: shotMask
                                                    anchors.fill: parent
                                                    visible: false
                                                    layer.enabled: true

                                                    ShapePath {
                                                        fillColor: "black"
                                                        strokeColor: "transparent"

                                                        startX: shotDelegate.tlrAnim; startY: 0
                                                        PathLine { x: shotDelegate.width - shotDelegate.trrAnim; y: 0 }
                                                        PathArc { x: shotDelegate.width; y: shotDelegate.trrAnim; radiusX: shotDelegate.trrAnim; radiusY: shotDelegate.trrAnim; direction: PathArc.Clockwise }
                                                        PathLine { x: shotDelegate.width; y: shotDelegate.height - shotDelegate.brrAnim }
                                                        PathArc { x: shotDelegate.width - shotDelegate.brrAnim; y: shotDelegate.height; radiusX: shotDelegate.brrAnim; radiusY: shotDelegate.brrAnim; direction: PathArc.Clockwise }
                                                        PathLine { x: shotDelegate.blrAnim; y: shotDelegate.height }
                                                        PathArc { x: 0; y: shotDelegate.height - shotDelegate.blrAnim; radiusX: shotDelegate.blrAnim; radiusY: shotDelegate.blrAnim; direction: PathArc.Clockwise }
                                                        PathLine { x: 0; y: shotDelegate.tlrAnim }
                                                        PathArc { x: shotDelegate.tlrAnim; y: 0; radiusX: shotDelegate.tlrAnim; radiusY: shotDelegate.tlrAnim; direction: PathArc.Clockwise }
                                                    }
                                                }

                                                Item {
                                                    id: thumbCont
                                                    anchors.fill: parent

                                                    Item {
                                                        id: thumbSrc
                                                        anchors.fill: parent
                                                        visible: false

                                                        Rectangle {
                                                            anchors.fill: parent
                                                            color: Ui.cardSurface
                                                        }

                                                        Image {
                                                            anchors.fill: parent
                                                            source: dialog.screenshotSource(shotDelegate.modelData)
                                                            fillMode: Image.PreserveAspectCrop
                                                            asynchronous: true
                                                            mipmap: true
                                                        }
                                                    }

                                                    MultiEffect {
                                                        anchors.fill: parent
                                                        source: thumbSrc
                                                        maskEnabled: true
                                                        maskSource: shotMask
                                                    }
                                                }

                                                // Dynamic Corner Outline Border (matches QuickTote pattern)
                                                Shape {
                                                    id: shotBorder
                                                    anchors.fill: parent
                                                    layer.enabled: true
                                                    layer.samples: 4
                                                    property color borderColor: Theme.withAlpha(Theme.outline, 0.25)
                                                    Behavior on borderColor { ColorAnimation { duration: Theme.mediumDuration } }

                                                    ShapePath {
                                                        fillColor: "transparent"
                                                        strokeColor: shotBorder.borderColor
                                                        strokeWidth: 1.5

                                                        startX: shotDelegate.tlrAnim; startY: 0
                                                        PathLine { x: shotDelegate.width - shotDelegate.trrAnim; y: 0 }
                                                        PathArc { x: shotDelegate.width; y: shotDelegate.trrAnim; radiusX: shotDelegate.trrAnim; radiusY: shotDelegate.trrAnim; direction: PathArc.Clockwise }
                                                        PathLine { x: shotDelegate.width; y: shotDelegate.height - shotDelegate.brrAnim }
                                                        PathArc { x: shotDelegate.width - shotDelegate.brrAnim; y: shotDelegate.height; radiusX: shotDelegate.brrAnim; radiusY: shotDelegate.brrAnim; direction: PathArc.Clockwise }
                                                        PathLine { x: shotDelegate.blrAnim; y: shotDelegate.height }
                                                        PathArc { x: 0; y: shotDelegate.height - shotDelegate.blrAnim; radiusX: shotDelegate.blrAnim; radiusY: shotDelegate.blrAnim; direction: PathArc.Clockwise }
                                                        PathLine { x: 0; y: shotDelegate.tlrAnim }
                                                        PathArc { x: shotDelegate.tlrAnim; y: 0; radiusX: shotDelegate.tlrAnim; radiusY: shotDelegate.tlrAnim; direction: PathArc.Clockwise }
                                                    }
                                                }

                                                MouseArea {
                                                    id: shotMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: dialog.lightboxIndex = shotDelegate.index
                                                }
                                            }
                                        }
                                    }
                                }

                                // Left navigation arrow
                                Rectangle {
                                    id: leftShotBtn
                                    width: 34
                                    height: 34
                                    radius: width / 2
                                    anchors.left: parent.left
                                    anchors.leftMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    z: 10
                                    visible: shotsFlickable.contentWidth > shotsFlickable.width && shotsFlickable.contentX > 5
                                    opacity: visible ? (leftShotMa.containsMouse ? 1.0 : 0.85) : 0.0
                                    color: Theme.withAlpha(Ui.chipSurfaceNested, 0.95)

                                    Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }
                                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutCubic } }
                                    scale: leftShotMa.pressed ? 0.92 : 1.0

                                    DIcon {
                                        anchors.centerIn: parent
                                        name: "chevron_left"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    MouseArea {
                                        id: leftShotMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            shotScrollAnim.stop();
                                            shotScrollAnim.from = shotsFlickable.contentX;
                                            shotScrollAnim.to = Math.max(0, shotsFlickable.contentX - 288);
                                            shotScrollAnim.start();
                                        }
                                    }
                                }

                                // Right navigation arrow
                                Rectangle {
                                    id: rightShotBtn
                                    width: 34
                                    height: 34
                                    radius: width / 2
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    z: 10
                                    visible: shotsFlickable.contentWidth > shotsFlickable.width && (shotsFlickable.contentX < shotsFlickable.contentWidth - shotsFlickable.width - 5)
                                    opacity: visible ? (rightShotMa.containsMouse ? 1.0 : 0.85) : 0.0
                                    color: Theme.withAlpha(Ui.chipSurfaceNested, 0.95)

                                    Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }
                                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutCubic } }
                                    scale: rightShotMa.pressed ? 0.92 : 1.0

                                    DIcon {
                                        anchors.centerIn: parent
                                        name: "chevron_right"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    MouseArea {
                                        id: rightShotMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            shotScrollAnim.stop();
                                            shotScrollAnim.from = shotsFlickable.contentX;
                                            shotScrollAnim.to = Math.min(Math.max(0, shotsFlickable.contentWidth - shotsFlickable.width), shotsFlickable.contentX + 288);
                                            shotScrollAnim.start();
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Description: appstream enrichment first, then the catalog-provided
                    // sanitized HTML (e.g. AppImage feed), then the plain summary
                    readonly property string effectiveDescription: (dialog.info.descriptionHtml || "") !== "" ? dialog.info.descriptionHtml : (dialog.appData.descriptionHtml || "")

                    // ── Description Container Card ───────────────────────────
                    StyledRect {
                        width: parent.width
                        implicitHeight: descCardCol.implicitHeight + Theme.spacingM * 2
                        visible: bodyColumn.effectiveDescription !== "" || (!dialog.loading && (dialog.appData.summary || "") !== "") || (dialog.appData.holdReason || "") !== ""
                        radius: Theme.cornerRadius
                        // A section heading with a rule of space under
                        // it groups this as well as a tinted box did,
                        // without a second tonal level over the dialog
                        // surface. Cards that are the leaf — a single
                        // origin, a row you can press — keep theirs.
                        color: "transparent"
                        border.width: 0

                        ColumnLayout {
                            id: descCardCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            // Section header
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "description"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Description")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            // Animated expandable description container
                            Item {
                                id: descTextWrapper
                                Layout.fillWidth: true
                                clip: true

                                readonly property real collapsedMaxH: 96
                                readonly property bool needsTruncation: rawDescText.implicitHeight > collapsedMaxH
                                readonly property real targetH: (!needsTruncation || dialog.descExpanded) ? rawDescText.implicitHeight : collapsedMaxH

                                implicitHeight: animatedH
                                property real animatedH: targetH
                                Behavior on animatedH {
                                    NumberAnimation {
                                        duration: Theme.longDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }
                                height: animatedH

                                SelectableText {
                                    id: rawDescText
                                    width: descTextWrapper.width
                                    visible: bodyColumn.effectiveDescription !== ""
                                    text: bodyColumn.effectiveDescription
                                    textFormat: Text.RichText
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                }

                                // Fade out gradient at bottom when collapsed
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 36
                                    visible: descTextWrapper.needsTruncation && !dialog.descExpanded
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 1.0; color: Ui.chipSurface }
                                    }
                                }
                            }

                            // Read more / Show less toggle button (Centered)
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 28
                                visible: descTextWrapper.needsTruncation

                                Rectangle {
                                    anchors.centerIn: parent
                                    implicitWidth: readMoreRow.implicitWidth + 24
                                    implicitHeight: 28
                                    radius: height / 2
                                    color: Ui.buttonFill("text", readMoreMa.containsMouse)
                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                    RowLayout {
                                        id: readMoreRow
                                        anchors.centerIn: parent
                                        spacing: 6

                                        StyledText {
                                            text: dialog.descExpanded ? Tr.t("Show less") : Tr.t("Read more")
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.primary
                                        }

                                        DIcon {
                                            name: dialog.descExpanded ? "expand_less" : "expand_more"
                                            size: 14
                                            color: Theme.primary
                                        }
                                    }

                                    MouseArea {
                                        id: readMoreMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: dialog.descExpanded = !dialog.descExpanded
                                    }
                                }
                            }
                        }
                    }

                    // ── What brew knows about a formula ─────────────────────
                    Column {
                        width: parent.width
                        spacing: 4
                        visible: dialog.isBrew

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS
                            visible: (dialog.brewFacts && dialog.brewFacts.installs30d > 0) || false

                            DIcon {
                                name: "trending_up"
                                size: 14
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: Tr.t("%1 installs last month").arg(dialog.brewFacts ? dialog.formatCount(dialog.brewFacts.installs30d) : "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS
                            visible: dialog.isBrew && dialog.brewFacts.linux === false

                            DIcon {
                                name: "warning"
                                size: 14
                                color: Theme.warning
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: Tr.t("Homebrew has no build of this for Linux")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.warning
                                wrapMode: Text.WordWrap
                            }
                        }

                        StyledText {
                            width: parent.width
                            visible: dialog.isBrew && (dialog.brewFacts.dependencies || []).length > 0
                            text: Tr.t("Depends on: %1").arg((dialog.brewFacts ? (dialog.brewFacts.dependencies || []) : []).join(", "))
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ── What a plugin is, in the terms a plugin has ─────────
                    Column {
                        width: parent.width
                        spacing: 4
                        visible: dialog.isPlugin

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS

                            DIcon {
                                name: "extension"
                                size: 14
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: {
                                    const facts = dialog.pluginFacts || {};
                                    const parts = [];
                                    if (facts.author)
                                        parts.push(Tr.t("by %1").arg(facts.author));
                                    if (facts.category)
                                        parts.push(facts.category);
                                    parts.push(facts.source === "system" ? Tr.t("installed for all users") : Tr.t("installed for you"));
                                    return parts.join(" · ");
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }
                        }

                        SelectableText {
                            width: parent.width
                            visible: text !== ""
                            text: (dialog.pluginFacts && dialog.pluginFacts.directory) ? dialog.pluginFacts.directory : ""
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.family: Theme.monoFontFamily
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        }
                    }

                    // ── Where it comes from Container Card ──────────────
                    StyledRect {
                        width: parent.width
                        implicitHeight: originsCardCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.origins.length > 0
                        radius: Theme.cornerRadius
                        // A section heading with a rule of space under
                        // it groups this as well as a tinted box did,
                        // without a second tonal level over the dialog
                        // surface. Cards that are the leaf — a single
                        // origin, a row you can press — keep theirs.
                        color: "transparent"
                        border.width: 0

                        ColumnLayout {
                            id: originsCardCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            // Section header
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "deployed_code"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Where it comes from")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            OriginComparison {
                                Layout.fillWidth: true
                                origins: dialog.origins
                                installedRefs: dialog.installedRefs
                            }
                        }
                    }

                    // AppImage update source (GitHub releases)
                    StyledText {
                        visible: dialog.showUpdateSource
                        text: Tr.t("Update source")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: dialog.showUpdateSource

                        StyledText {
                            width: parent.width
                            text: Tr.t("Link a GitHub project to get updates from its releases.")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS

                            DTextField {
                                id: repoField
                                Layout.fillWidth: true
                                placeholderText: "https://github.com/owner/project"
                                FieldPlaceholder {
                                    text: "https://github.com/owner/project"
                                }

                                Connections {
                                    target: dialog

                                    function onOpened() {
                                        repoField.text = dialog.updateSourceUrl;
                                    }
                                }
                            }

                            DSpinner {
                                visible: dialog.updateSourceStatus === "saving"
                                size: 18
                            }

                            Item {
                                Layout.preferredWidth: updateSourceSaveButton.width
                                Layout.preferredHeight: updateSourceSaveButton.height

                                DButton {
                                    id: updateSourceSaveButton
                                    buttonHeight: 28
                                    horizontalPadding: Theme.spacingM
                                    iconName: "save"
                                    iconSize: 13
                                    text: Tr.t("Save")
                                    backgroundColor: Theme.buttonBg
                                    textColor: Theme.buttonText
                                    enabled: dialog.updateSourceStatus !== "saving" && repoField.text.trim() !== dialog.updateSourceUrl
                                    onClicked: dialog.updateSourceSaveRequested(repoField.text.trim())
                                }
                            }
                        }

                        StyledText {
                            width: parent.width
                            visible: dialog.updateSourceStatus === "done"
                            text: Tr.t("Update source saved.")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.success
                        }

                        StyledText {
                            width: parent.width
                            visible: dialog.updateSourceStatus.indexOf("error:") === 0
                            text: Tr.t("Could not set update source: %1").arg(dialog.updateSourceStatus.substring(6))
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.error
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ── Sandbox Permissions Container Card ──────────────
                    StyledRect {
                        width: parent.width
                        implicitHeight: permsCardCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.permissionTokens.length > 0
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)

                        ColumnLayout {
                            id: permsCardCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            // Section header
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "security"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Permissions")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    Layout.fillWidth: true
                                }

                                // Quick high-risk badge
                                Rectangle {
                                    visible: dialog.permissionTokens.some(t => t === "devices:all" || t === "fs:host" || t === "fs:host:ro")
                                    implicitWidth: riskLabel.implicitWidth + 10
                                    implicitHeight: 18
                                    radius: 9
                                    color: Theme.withAlpha(Theme.warning, 0.18)

                                    StyledText {
                                        id: riskLabel
                                        anchors.centerIn: parent
                                        text: Tr.t("High access")
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        font.weight: Font.Medium
                                        color: Theme.warning
                                    }
                                }
                            }

                            // Chips with animated expand / collapse
                            Item {
                                id: permsAnimWrapper
                                Layout.fillWidth: true
                                clip: true

                                readonly property real targetH: dialog.permsExpanded ? permsFlow.implicitHeight : Math.min(permsFlow.implicitHeight, 30)
                                implicitHeight: animatedPermsH
                                property real animatedPermsH: targetH
                                Behavior on animatedPermsH {
                                    NumberAnimation {
                                        duration: Theme.longDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }
                                height: animatedPermsH

                                Flow {
                                    id: permsFlow
                                    width: permsAnimWrapper.width
                                    spacing: Theme.spacingXS

                                    Repeater {
                                        model: dialog.permissionTokens

                                        delegate: Rectangle {
                                            required property var modelData

                                            width: permChipRow.implicitWidth + 14
                                            height: 24
                                            radius: 12
                                            color: (modelData === "devices:all" || modelData === "fs:host" || modelData === "fs:host:ro")
                                                ? Theme.withAlpha(Theme.warning, 0.15)
                                                : Theme.withAlpha(Ui.chipSurfaceNested, 0.8)

                                            RowLayout {
                                                id: permChipRow
                                                anchors.centerIn: parent
                                                spacing: 4

                                                DIcon {
                                                    name: modelData === "network" ? "public" : (modelData.indexOf("fs:") === 0 ? "folder" : (modelData.indexOf("devices") === 0 ? "usb" : "shield"))
                                                    size: 12
                                                    color: (modelData === "devices:all" || modelData === "fs:host" || modelData === "fs:host:ro")
                                                        ? Theme.warning
                                                        : Theme.primary
                                                }

                                                StyledText {
                                                    text: dialog.permLabel(modelData)
                                                    font.pixelSize: Theme.fontSizeSmall - 2
                                                    color: Theme.surfaceText
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Expand / collapse toggle row (Centered)
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 28
                                visible: dialog.permissionTokens.length > dialog.permsCollapsedCount

                                Rectangle {
                                    anchors.centerIn: parent
                                    implicitWidth: permToggleRow.implicitWidth + 24
                                    implicitHeight: 28
                                    radius: height / 2
                                    color: Ui.buttonFill("text", permToggleMa.containsMouse)
                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                    RowLayout {
                                        id: permToggleRow
                                        anchors.centerIn: parent
                                        spacing: 6

                                        DIcon {
                                            name: dialog.permsExpanded ? "expand_less" : "expand_more"
                                            size: 14
                                            color: Theme.primary
                                        }

                                        StyledText {
                                            text: dialog.permsExpanded ? Tr.t("Show fewer permissions") : Tr.t("Show all permissions (%1)").arg(dialog.permissionTokens.length)
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.weight: Font.Medium
                                            color: Theme.primary
                                        }
                                    }

                                    MouseArea {
                                        id: permToggleMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: dialog.permsExpanded = !dialog.permsExpanded
                                    }
                                }
                            }
                        }
                    }

                    // Flathub install statistics
                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: !!dialog.info.installStats

                        DIcon {
                            name: "trending_up"
                            size: 14
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                const stats = dialog.info.installStats || {};
                                const parts = [];
                                if (stats.month !== undefined)
                                    parts.push(Tr.t("%1 installs last month").arg(dialog.formatCount(stats.month)));
                                else if (stats.week !== undefined)
                                    parts.push(Tr.t("%1 installs last week").arg(dialog.formatCount(stats.week)));
                                if (stats.total !== undefined)
                                    parts.push(Tr.t("%1 total").arg(dialog.formatCount(stats.total)));
                                return "Flathub: " + parts.join(" · ");
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    // What this update is rated, and what it closes
                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: dialog.advisory !== null && (dialog.advisory.type || "") === "security"

                        DIcon {
                            Layout.alignment: Qt.AlignTop
                            name: "shield"
                            size: 16
                            color: Ui.failColor
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (!dialog.advisory)
                                    return "";
                                const severity = (dialog.advisory.severity || "").toLowerCase();
                                const names = ({
                                        critical: Tr.t("Critical"),
                                        important: Tr.t("Important"),
                                        moderate: Tr.t("Moderate"),
                                        low: Tr.t("Low")
                                    });
                                const label = names[severity] || Tr.t("Security");
                                const ids = dialog.advisory.ids || [];
                                return ids.length > 0 ? Tr.t("Security fix, rated %1 — %2").arg(label.toLowerCase()).arg(ids.join(", ")) : Tr.t("Security fix, rated %1").arg(label.toLowerCase());
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        }
                    }

                    // Release notes Container Card
                    StyledRect {
                        width: parent.width
                        height: relCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.releases.length > 0
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)

                        ColumnLayout {
                            id: relCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "new_releases"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: dialog.releasesTitle
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            Repeater {
                                model: dialog.releases

                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 4

                                    RowLayout {
                                        spacing: Theme.spacingS

                                        Rectangle {
                                            Layout.preferredWidth: versionChip.implicitWidth + 14
                                            Layout.preferredHeight: 18
                                            radius: 9
                                            color: Theme.withAlpha(Theme.primary, 0.12)

                                            StyledText {
                                                id: versionChip
                                                anchors.centerIn: parent
                                                text: modelData.version || ""
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                color: Theme.primary
                                            }
                                        }

                                        StyledText {
                                            visible: (modelData.date || 0) > 0
                                            text: modelData.date > 0 ? new Date(modelData.date * 1000).toLocaleDateString(Tr.locale, Locale.ShortFormat) : ""
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    SelectableText {
                                        Layout.fillWidth: true
                                        text: modelData.notesHtml || ("<i>" + Tr.t("No release notes published.") + "</i>")
                                        textFormat: Text.RichText
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }
                        }
                    }

                    // Upstream git notes Container Card
                    StyledRect {
                        width: parent.width
                        height: gitNotesCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.gitNotesLoading || dialog.gitReleases.length > 0 || dialog.gitNotesKind === "untouched"
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)

                        ColumnLayout {
                            id: gitNotesCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "commit"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: dialog.gitNotesKind === "commits" ? Tr.t("Commits since your build") : Tr.t("What's new upstream")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            // A plugin sharing its repository with others is
                            // reported as updated whenever any of them changes
                            StyledText {
                                Layout.fillWidth: true
                                visible: dialog.gitNotesKind === "untouched"
                                text: Tr.t("Nothing in this update changes this plugin. It shares its repository with other plugins, and one of those changed.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                Layout.fillWidth: true
                                visible: dialog.gitNotesLoading
                                text: Tr.t("Asking upstream…")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            Repeater {
                                model: dialog.gitReleases

                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: 4

                                    RowLayout {
                                        spacing: Theme.spacingS

                                        Rectangle {
                                            Layout.preferredWidth: gitVersionChip.implicitWidth + 14
                                            Layout.preferredHeight: 18
                                            radius: 9
                                            color: Theme.withAlpha(Theme.primary, 0.12)

                                            StyledText {
                                                id: gitVersionChip
                                                anchors.centerIn: parent
                                                text: modelData.version || ""
                                                font.pixelSize: Theme.fontSizeSmall - 2
                                                font.family: dialog.gitNotesKind === "commits" ? (Theme.monoFontFamily || "monospace") : Theme.fontFamily
                                                color: Theme.primary
                                            }
                                        }

                                        StyledText {
                                            visible: dialog.gitNotesKind === "commits" && dialog.gitNotesCommits > 0
                                            text: Tr.t("%1 commits").arg(dialog.gitNotesCommits)
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            visible: (modelData.date || 0) > 0
                                            text: modelData.date > 0 ? new Date(modelData.date * 1000).toLocaleDateString(Tr.locale, Locale.ShortFormat) : ""
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    SelectableText {
                                        Layout.fillWidth: true
                                        text: modelData.notesHtml || ("<i>" + Tr.t("No release notes published.") + "</i>")
                                        textFormat: Text.RichText
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingXS
                                visible: dialog.gitNotesUrl !== "" && dialog.gitReleases.length > 0

                                DIcon {
                                    name: "open_in_new"
                                    size: 13
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: dialog.gitNotesMore > 0 && dialog.gitNotesKind === "commits" ? Tr.t("%1 more commits upstream").arg(dialog.gitNotesMore) : (dialog.gitNotesMore > 0 ? Tr.t("Read the rest upstream") : Tr.t("Open upstream"))
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.primary
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                HoverHandler {
                                    cursorShape: Qt.PointingHandCursor
                                }

                                TapHandler {
                                    onTapped: Qt.openUrlExternally(dialog.gitNotesUrl)
                                }
                            }
                        }
                    }

                    // rpm changelog Container Card
                    StyledRect {
                        width: parent.width
                        height: clCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.changelogLoading || dialog.changelog !== ""
                        radius: Theme.cornerRadius
                        // A section heading with a rule of space under
                        // it groups this as well as a tinted box did,
                        // without a second tonal level over the dialog
                        // surface. Cards that are the leaf — a single
                        // origin, a row you can press — keep theirs.
                        color: "transparent"
                        border.width: 0

                        ColumnLayout {
                            id: clCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "history_edu"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Changelog")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            SelectableText {
                                Layout.fillWidth: true
                                text: dialog.changelogLoading ? Tr.t("Loading changelog…") : dialog.changelog
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.family: Theme.monoFontFamily || "monospace"
                                color: Theme.surfaceText
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                textFormat: Text.PlainText
                            }
                        }
                    }

                    // Previous versions Container Card
                    StyledRect {
                        width: parent.width
                        height: prevVerCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.versionsLoading || dialog.previousVersions.length > 0 || dialog.noOlderVersions
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Ui.chipSurface, 0.45)
                        border.width: 0

                        ColumnLayout {
                            id: prevVerCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "history"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Previous versions")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            StyledText {
                                Layout.fillWidth: true
                                visible: dialog.versionsLoading
                                text: Tr.t("Checking available versions…")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                Layout.fillWidth: true
                                visible: !dialog.versionsLoading && dialog.noOlderVersions && dialog.previousVersions.length === 0
                                text: Tr.t("No older version available.")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS
                                visible: dialog.previousVersions.length > 0

                                Repeater {
                                    model: dialog.previousVersions

                                    delegate: DButton {
                                        required property var modelData

                                        buttonHeight: 28
                                        horizontalPadding: Theme.spacingM
                                        iconName: "history"
                                        iconSize: 13
                                        text: Tr.t("Restore %1").arg(modelData.label)
                                        backgroundColor: Ui.buttonFill("tonal", false)
                                        textColor: Ui.buttonInk("tonal")
                                        enabled: !dialog.busy
                                        onClicked: dialog.restoreRequested(modelData.payload)
                                    }
                                }
                            }
                        }
                    }

                    // Reviews Main Container Card
                    StyledRect {
                        id: mainReviewsRect
                        width: parent.width
                        implicitHeight: mainReviewsCol.implicitHeight + Theme.spacingM * 2
                        visible: dialog.reviewable && ((dialog.info.reviews || []).length > 0 || dialog.installedChipVisible || dialog.showOpenButton)
                        radius: Theme.cornerRadius
                        // The reviews inside are the containers
                        color: "transparent"
                        border.width: 0

                        ColumnLayout {
                            id: mainReviewsCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DIcon {
                                    name: "star"
                                    size: 16
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Reviews & Ratings")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                StyledText {
                                    visible: dialog.reviewStatus === "done"
                                    text: Tr.t("Thanks — your review was submitted.")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.success
                                }

                                Rectangle {
                                    visible: !dialog.reviewFormOpen && dialog.reviewStatus !== "done"
                                    Layout.preferredWidth: writeRevContent.implicitWidth + 24
                                    Layout.preferredHeight: 28
                                    radius: 14
                                    color: Ui.buttonFill("tonal", writeRevMa.containsMouse)
                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                    RowLayout {
                                        id: writeRevContent
                                        anchors.centerIn: parent
                                        spacing: 6

                                        DIcon {
                                            name: "rate_review"
                                            size: 14
                                            color: Ui.buttonInk("tonal")
                                        }

                                        StyledText {
                                            text: Tr.t("Write a review")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.weight: Font.Medium
                                            color: Ui.buttonInk("tonal")
                                        }
                                    }

                                    MouseArea {
                                        id: writeRevMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: dialog.reviewFormOpen = true
                                    }
                                }
                            }

                            // Inline review form (Animated expand & collapse)
                            Item {
                                Layout.fillWidth: true
                                clip: true
                                visible: Layout.preferredHeight > 0 || opacity > 0.001
                                Layout.preferredHeight: dialog.reviewFormOpen ? (reviewFormRect.implicitHeight + 4) : 0
                                Behavior on Layout.preferredHeight { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                                opacity: dialog.reviewFormOpen ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

                                Rectangle {
                                    id: reviewFormRect
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    implicitHeight: reviewForm.implicitHeight + Theme.spacingM * 2
                                    radius: Theme.cornerRadius
                                    color: Theme.withAlpha(Ui.chipSurfaceNested, 0.6)

                                    ColumnLayout {
                                        id: reviewForm
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingS

                                        Row {
                                            id: reviewStarsRow
                                            spacing: 2

                                            property int hoverStars: 0

                                            Repeater {
                                                model: 5

                                                delegate: DIcon {
                                                    required property int index

                                                    name: "star"
                                                    filled: (reviewStarsRow.hoverStars > 0 ? index < reviewStarsRow.hoverStars : index < dialog.reviewStars)
                                                    size: 20
                                                    color: (reviewStarsRow.hoverStars > 0 ? index < reviewStarsRow.hoverStars : index < dialog.reviewStars)
                                                        ? Theme.primary
                                                        : Theme.withAlpha(Theme.surfaceVariantText, 0.3)

                                                    MouseArea {
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onEntered: reviewStarsRow.hoverStars = index + 1
                                                        onExited: reviewStarsRow.hoverStars = 0
                                                        onClicked: dialog.reviewStars = index + 1
                                                    }
                                                }
                                            }
                                        }

                                        DTextField {
                                            id: reviewSummaryField
                                            Layout.fillWidth: true
                                            placeholderText: Tr.t("One-line summary")
                                            font.pixelSize: Theme.fontSizeSmall
                                        }

                                        DTextField {
                                            id: reviewBodyField
                                            Layout.fillWidth: true
                                            placeholderText: Tr.t("What did you think? (optional)")
                                            font.pixelSize: Theme.fontSizeSmall
                                        }

                                        DTextField {
                                            id: reviewAuthorField
                                            Layout.fillWidth: true
                                            placeholderText: Tr.t("Your name (optional)")
                                            font.pixelSize: Theme.fontSizeSmall
                                        }

                                        StyledText {
                                            visible: dialog.reviewStatus !== "" && dialog.reviewStatus !== "done"
                                            text: dialog.reviewStatus === "submitting" ? Tr.t("Submitting…") : Tr.t("Could not submit review. Please try again.")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: dialog.reviewStatus === "error" ? Theme.error : Theme.surfaceVariantText
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingS

                                            Item { Layout.fillWidth: true }

                                            DButton {
                                                buttonHeight: 28
                                                horizontalPadding: Theme.spacingM
                                                iconName: "close"
                                                iconSize: 14
                                                text: Tr.t("Cancel")
                                                backgroundColor: Ui.buttonFill("tonal", false)
                                                textColor: Ui.buttonInk("tonal")
                                                onClicked: dialog.reviewFormOpen = false
                                            }

                                            DButton {
                                                buttonHeight: 28
                                                horizontalPadding: Theme.spacingM
                                                iconName: "send"
                                                iconSize: 14
                                                text: Tr.t("Submit")
                                                backgroundColor: Theme.buttonBg
                                                textColor: Theme.buttonText
                                                enabled: (reviewSummaryField.text || "").trim() !== "" && dialog.reviewStatus !== "submitting"
                                                onClicked: dialog.submitReview(reviewSummaryField.text, reviewBodyField.text, reviewAuthorField.text)
                                            }
                                        }
                                    }
                                }
                            }

                            // Animated Reviews List Wrapper
                            Item {
                                id: revListWrapper
                                Layout.fillWidth: true
                                clip: true
                                implicitHeight: animatedRevH
                                property real animatedRevH: revListCol.implicitHeight
                                Behavior on animatedRevH {
                                    NumberAnimation {
                                        duration: Theme.longDuration
                                        easing.type: Easing.OutExpo
                                    }
                                }
                                height: animatedRevH

                                ColumnLayout {
                                    id: revListCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    spacing: Theme.spacingS

                                    Repeater {
                                        model: (dialog.info.reviews || []).slice(0, dialog.reviewsShown)

                                        delegate: Rectangle {
                                            id: revCard
                                            Layout.fillWidth: true
                                            implicitHeight: revCardInner.implicitHeight + Theme.spacingM * 2
                                            radius: Theme.cornerRadius
                                            color: Theme.withAlpha(Ui.chipSurfaceNested, 0.4)
                                            border.width: 0

                                            opacity: 1.0
                                            Component.onCompleted: {
                                                if (index >= 10) {
                                                    revCard.opacity = 0.0;
                                                    fadeRevTimer.start();
                                                }
                                            }
                                            Timer {
                                                id: fadeRevTimer
                                                interval: Math.min((index - 10) * 35, 200)
                                                onTriggered: revCard.opacity = 1.0
                                            }
                                            Behavior on opacity { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad } }

                                            ColumnLayout {
                                                id: revCardInner
                                                anchors.fill: parent
                                                anchors.margins: Theme.spacingM
                                                spacing: 4

                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: Theme.spacingS

                                                    Row {
                                                        spacing: 1

                                                        Repeater {
                                                            model: 5

                                                            delegate: DIcon {
                                                                required property int index

                                                                name: "star"
                                                                filled: index < modelData.stars
                                                                size: 12
                                                                color: index < modelData.stars ? Theme.primary : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                                                            }
                                                        }
                                                    }

                                                    StyledText {
                                                        Layout.fillWidth: true
                                                        text: modelData.user + (modelData.date > 0 ? (" · " + Qt.formatDate(new Date(modelData.date * 1000), "MMM yyyy")) : "")
                                                        font.pixelSize: Theme.fontSizeSmall - 1
                                                        color: Theme.surfaceVariantText
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                StyledText {
                                                    Layout.fillWidth: true
                                                    visible: (modelData.summary || "") !== ""
                                                    text: modelData.summary
                                                    textFormat: Text.PlainText
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.DemiBold
                                                    color: Theme.surfaceText
                                                    wrapMode: Text.WordWrap
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    Layout.topMargin: 2
                                                    visible: (modelData.text || "") !== ""
                                                    text: modelData.text || ""
                                                    textFormat: Text.PlainText
                                                    font.family: Theme.fontFamily
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    wrapMode: Text.WordWrap
                                                    maximumLineCount: 4
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Centered expand / collapse toggle buttons
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 32
                                visible: (dialog.info.reviews || []).length > 10

                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingS

                                    // Show 10 more
                                    Rectangle {
                                        visible: dialog.reviewsShown < (dialog.info.reviews || []).length
                                        implicitWidth: rev10MoreRow.implicitWidth + 24
                                        implicitHeight: 28
                                        radius: height / 2
                                        color: Ui.buttonFill("text", rev10MoreMa.containsMouse)
                                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                        RowLayout {
                                            id: rev10MoreRow
                                            anchors.centerIn: parent
                                            spacing: 6

                                            DIcon {
                                                name: "expand_more"
                                                size: 14
                                                color: Theme.primary
                                            }

                                            StyledText {
                                                text: Tr.t("Show 10 more (%1 remaining)").arg(Math.max(0, (dialog.info.reviews || []).length - dialog.reviewsShown))
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                font.weight: Font.Medium
                                                color: Theme.primary
                                            }
                                        }

                                        MouseArea {
                                            id: rev10MoreMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: dialog.reviewsShown += 10
                                        }
                                    }

                                    // Show all
                                    Rectangle {
                                        visible: dialog.reviewsShown < (dialog.info.reviews || []).length && ((dialog.info.reviews || []).length - dialog.reviewsShown > 10)
                                        implicitWidth: revAllRow.implicitWidth + 24
                                        implicitHeight: 28
                                        radius: height / 2
                                        color: Ui.buttonFill("text", revAllMa.containsMouse)
                                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                        RowLayout {
                                            id: revAllRow
                                            anchors.centerIn: parent
                                            spacing: 6

                                            DIcon {
                                                name: "unfold_more"
                                                size: 14
                                                color: Theme.primary
                                            }

                                            StyledText {
                                                text: Tr.t("Show all (%1)").arg((dialog.info.reviews || []).length)
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                font.weight: Font.Medium
                                                color: Theme.primary
                                            }
                                        }

                                        MouseArea {
                                            id: revAllMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: dialog.reviewsShown = (dialog.info.reviews || []).length
                                        }
                                    }

                                    // Show fewer
                                    Rectangle {
                                        visible: dialog.reviewsShown > 10
                                        implicitWidth: revLessRow.implicitWidth + 24
                                        implicitHeight: 28
                                        radius: height / 2
                                        color: Ui.buttonFill("text", revLessMa.containsMouse)
                                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                        RowLayout {
                                            id: revLessRow
                                            anchors.centerIn: parent
                                            spacing: 6

                                            DIcon {
                                                name: "expand_less"
                                                size: 14
                                                color: Theme.primary
                                            }

                                            StyledText {
                                                text: Tr.t("Show fewer")
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                font.weight: Font.Medium
                                                color: Theme.primary
                                            }
                                        }

                                        MouseArea {
                                            id: revLessMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                dialog.reviewsShown = 10;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Footer actions Container ────────────────────────────────────
            StyledRect {
                Layout.fillWidth: true
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                implicitHeight: footerLayout.implicitHeight + Theme.spacingM * 2

                RowLayout {
                    id: footerLayout
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    anchors.topMargin: Theme.spacingS
                    anchors.bottomMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    // Left actions: website and hold, two standard icon buttons
                    // (no container until hovered), not a connected pair
                    Row {
                        spacing: Theme.spacingXS
                        visible: !dialog.busy

                        // An icon alone does not say what a globe or a lock
                        // does here; the tooltips the #21 overhaul dropped
                        DTooltipV2 {
                            id: footerTooltip
                        }

                        // Website Button Container
                        Rectangle {
                            id: webBtnRoot
                            visible: (dialog.appData.homepage || "") !== ""
                            width: 32
                            height: 32
                            property bool isHovered: webBtnMa.containsMouse

                            radius: webBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                            Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                            color: Ui.buttonFill("icon", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            scale: webBtnMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DRipple {
                                id: webRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk("icon")
                            }

                            DIcon {
                                anchors.centerIn: parent
                                name: "language"
                                size: 16
                                color: Ui.buttonInk("icon")
                            }

                            MouseArea {
                                id: webBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: (m) => webRip.trigger(m.x, m.y)
                                onClicked: Qt.openUrlExternally(dialog.appData.homepage)
                                onEntered: footerTooltip.show(Tr.t("Open website — %1").arg((dialog.appData.homepage || "").replace(/^[a-z]+:\/\//i, "").split("/")[0]), webBtnRoot, 0, 4, "top")
                                onExited: footerTooltip.hide()
                            }
                        }

                        // Hold Toggle Button Container
                        Rectangle {
                            id: holdBtnRoot
                            visible: dialog.showHoldToggle
                            width: 32
                            height: 32
                            property bool isHovered: holdBtnMa.containsMouse

                            radius: holdBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                            Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                            // Held is a switched-on state, shown as a warning
                            // tint rather than the neutral selected fill: an
                            // app that no longer updates is worth noticing.
                            color: dialog.appData.held === true ? Theme.withAlpha(Theme.warning, isHovered ? 0.22 : 0.15) : Ui.buttonFill("icon", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            scale: holdBtnMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DRipple {
                                id: holdRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: dialog.appData.held === true ? Theme.warning : Ui.buttonInk("icon")
                            }

                            DIcon {
                                anchors.centerIn: parent
                                name: dialog.appData.held === true ? "lock_open" : "lock"
                                size: 15
                                color: dialog.appData.held === true ? Theme.warning : Ui.buttonInk("icon")
                                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                            }

                            MouseArea {
                                id: holdBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !dialog.busy
                                onPressed: (m) => holdRip.trigger(m.x, m.y)
                                onClicked: {
                                    footerTooltip.hide();
                                    dialog.holdToggleRequested();
                                }
                                onEntered: footerTooltip.show(dialog.appData.held === true ? Tr.t("Stop holding (updates allowed again)") : Tr.t("Hold (skip in updates)"), holdBtnRoot, 0, 4, "top")
                                onExited: footerTooltip.hide()
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Middle/Right busy or action items
                    Rectangle {
                        id: pluginBtnRoot
                        visible: dialog.isPlugin
                        Layout.preferredWidth: pluginBtnRow.implicitWidth + 24
                        Layout.preferredHeight: 32
                        property bool isHovered: pluginBtnMa.containsMouse
                        readonly property string kind: (dialog.showOpenButton || dialog.showUpdateButton || dialog.showUninstall) ? "tonal" : "filled"

                        radius: pluginBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        color: Ui.buttonFill(kind, isHovered)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: pluginBtnMa.pressed ? 0.94 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DRipple {
                            id: pluginRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.buttonInk(pluginBtnRoot.kind)
                        }

                        RowLayout {
                            id: pluginBtnRow
                            anchors.centerIn: parent
                            spacing: 6

                            DIcon {
                                name: "open_in_new"
                                size: 14
                                color: Ui.buttonInk(pluginBtnRoot.kind)
                            }

                            StyledText {
                                text: Tr.t("Manage plugins")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Ui.buttonInk(pluginBtnRoot.kind)
                            }
                        }

                        MouseArea {
                            id: pluginBtnMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => pluginRip.trigger(m.x, m.y)
                            onClicked: {
                                dialog.close();
                                PopoutService.openSettingsWithTab("plugins");
                            }
                        }
                    }

                    // Open Button (Custom Action Button)
                    Rectangle {
                        id: openBtnRoot
                        visible: dialog.showOpenButton
                        Layout.preferredWidth: openBtnRow.implicitWidth + 24
                        Layout.preferredHeight: 32
                        property bool isHovered: openBtnMa.containsMouse
                        // The main action is updating when there is one; else opening.
                        readonly property string kind: dialog.showUpdateButton ? "tonal" : "filled"

                        radius: openBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                        Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                        color: Ui.buttonFill(kind, isHovered)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                        scale: openBtnMa.pressed ? 0.94 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DRipple {
                            id: openRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.buttonInk(openBtnRoot.kind)
                        }

                        RowLayout {
                            id: openBtnRow
                            anchors.centerIn: parent
                            spacing: 6

                            DIcon {
                                name: "launch"
                                size: 14
                                color: Ui.buttonInk(openBtnRoot.kind)
                            }

                            StyledText {
                                text: Tr.t("Open")
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Ui.buttonInk(openBtnRoot.kind)
                            }
                        }

                        MouseArea {
                            id: openBtnMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => openRip.trigger(m.x, m.y)
                            onClicked: {
                                Quickshell.execDetached(dialog.openCommand.length > 0 ? dialog.openCommand : ["flatpak", "run", dialog.appData.id]);
                                dialog.close();
                            }
                        }
                    }

                    StyledText {
                        visible: dialog.busy && dialog.busyDetail !== ""
                        text: dialog.busyDetail
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                        elide: Text.ElideLeft
                        Layout.maximumWidth: 260
                    }

                    M3WaveProgress {
                        visible: dialog.busy && dialog.busyFraction > 0
                        Layout.preferredWidth: 110
                        Layout.preferredHeight: 18
                        value: dialog.busyFraction
                        isPlaying: visible
                    }

                    DSpinner {
                        visible: dialog.busy && dialog.busyFraction <= 0
                        size: 22
                    }

                    Rectangle {
                        visible: dialog.installedChipVisible
                        Layout.preferredWidth: installedChipText.implicitWidth + 18
                        Layout.preferredHeight: 26
                        radius: 13
                        color: Theme.withAlpha(Theme.success, 0.15)

                        StyledText {
                            id: installedChipText
                            anchors.centerIn: parent
                            text: Tr.t("Installed")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.Medium
                            color: Theme.success
                        }
                    }

                    // Uninstall, Update, Install: separate buttons, one of them filled
                    Row {
                        spacing: Theme.spacingS
                        visible: !dialog.busy

                        // Uninstall Button (Custom Danger Button)
                        Rectangle {
                            id: uninstBtnRoot
                            visible: dialog.showUninstall
                            width: uninstBtnRow.implicitWidth + 24
                            height: 32
                            property bool isHovered: uninstBtnMa.containsMouse
                            readonly property bool confirming: dialog._confirmUninstall === (dialog.appData.id || "")
                            readonly property string kind: confirming ? "danger" : "dangerTonal"

                            radius: uninstBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                            Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                            color: Ui.buttonFill(kind, isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            scale: uninstBtnMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DRipple {
                                id: uninstRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk(uninstBtnRoot.kind)
                            }

                            RowLayout {
                                id: uninstBtnRow
                                anchors.centerIn: parent
                                spacing: 6

                                DIcon {
                                    name: uninstBtnRoot.confirming ? "delete_forever" : "delete"
                                    size: 14
                                    color: Ui.buttonInk(uninstBtnRoot.kind)
                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                                }

                                StyledText {
                                    text: uninstBtnRoot.confirming ? Tr.t("Confirm uninstall") : Tr.t("Uninstall")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Ui.buttonInk(uninstBtnRoot.kind)
                                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                                }
                            }

                            MouseArea {
                                id: uninstBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !dialog.busy
                                onPressed: (m) => uninstRip.trigger(m.x, m.y)
                                onClicked: {
                                    if (dialog._confirmUninstall === (dialog.appData.id || "")) {
                                        dialog._confirmUninstall = "";
                                        dialog.uninstallRequested();
                                    } else {
                                        dialog._confirmUninstall = dialog.appData.id || "";
                                        confirmTimer.restart();
                                    }
                                }
                            }
                        }

                        // Update Button (Custom Action Button)
                        Rectangle {
                            id: updateBtnRoot
                            visible: dialog.showUpdateButton
                            width: updateBtnRow.implicitWidth + 24
                            height: 32
                            property bool isHovered: updateBtnMa.containsMouse

                            radius: updateBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                            Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                            color: Ui.buttonFill("filled", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            scale: updateBtnMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DRipple {
                                id: updateRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk("filled")
                            }

                            RowLayout {
                                id: updateBtnRow
                                anchors.centerIn: parent
                                spacing: 6

                                DIcon {
                                    name: "download"
                                    size: 14
                                    color: Ui.buttonInk("filled")
                                }

                                StyledText {
                                    text: Tr.t("Update")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Ui.buttonInk("filled")
                                }
                            }

                            MouseArea {
                                id: updateBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !dialog.busy
                                onPressed: (m) => updateRip.trigger(m.x, m.y)
                                onClicked: dialog.updateRequested()
                            }
                        }

                        // Install buttons, one per source: Flathub (else the first
                        // source) is the filled one, the others tonal
                        Repeater {
                            model: (dialog.showInstallButtons && !dialog.installedChipVisible) ? (dialog.appData.sources || []) : []

                            delegate: Rectangle {
                                id: instBtnRoot
                                required property var modelData
                                required property int index

                                property bool isHovered: instBtnMa.containsMouse
                                readonly property bool isRecommended: index === Math.max(0, (dialog.appData.sources || []).findIndex(src => src.kind === "flatpak"))
                                readonly property string kind: isRecommended ? "filled" : "tonal"

                                width: instBtnRow.implicitWidth + 24
                                height: 32

                                radius: instBtnMa.pressed ? (height / 2) : Theme.cornerRadius
                                Behavior on radius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                                color: Ui.buttonFill(kind, isHovered)
                                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                                scale: instBtnMa.pressed ? 0.94 : 1.0
                                Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                                DRipple {
                                    id: instBtnRip
                                    anchors.fill: parent
                                    cornerRadius: parent.radius
                                    rippleColor: Ui.buttonInk(instBtnRoot.kind)
                                }

                                RowLayout {
                                    id: instBtnRow
                                    anchors.centerIn: parent
                                    spacing: 6

                                    DIcon {
                                        name: "download"
                                        size: 14
                                        color: Ui.buttonInk(instBtnRoot.kind)
                                    }

                                    StyledText {
                                        text: modelData.kind === "flatpak" ? Tr.t("Install from Flathub") : (modelData.kind === "appimage" ? Tr.t("Install AppImage") : Tr.t("Install from %1").arg(modelData.kind === "copr" ? modelData.project : Backend.systemRepoLabel))
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Ui.buttonInk(instBtnRoot.kind)
                                    }
                                }

                                MouseArea {
                                    id: instBtnMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: !dialog.busy
                                    onPressed: (m) => instBtnRip.trigger(m.x, m.y)
                                    onClicked: dialog.installRequested(modelData)
                                }
                            }
                        }
                    }
                }
            }

            // ── Why this is here (Containerized) ────────────────────────────
            StyledRect {
                Layout.fillWidth: true
                visible: dialog.provenance !== null && !dialog.busy
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                implicitHeight: provInfoCol.implicitHeight + Theme.spacingS * 2

                RowLayout {
                    id: provInfoCol
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    DIcon {
                        name: "alt_route"
                        size: 15
                        color: Theme.surfaceVariantText
                    }

                    Text {
                        Layout.fillWidth: true
                        text: {
                            const prov = dialog.provenance;
                            if (!prov)
                                return "";
                            const origin = prov.userInstalled ? Tr.t("You installed this") : Tr.t("Came in as a dependency");
                            const count = prov.requiredByCount || 0;
                            if (count === 0)
                                return origin + " · " + Tr.t("nothing else needs it");
                            const names = (prov.requiredBy || []).slice(0, 3).join(", ");
                            return origin + " · " + (count === 1 ? Tr.t("needed by %1").arg(names) : Tr.t("needed by %1 packages, among them %2").arg(count).arg(names));
                        }
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }
            }

            // ── What else goes (Containerized) ──────────────────────────────
            StyledRect {
                Layout.fillWidth: true
                visible: dialog.showUninstall && dialog.alsoRemoves.length > 0 && !dialog.busy
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.warning, 0.12)
                implicitHeight: alsoRemovesCol.implicitHeight + Theme.spacingS * 2

                RowLayout {
                    id: alsoRemovesCol
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    DIcon {
                        name: "warning"
                        size: 16
                        color: Theme.warning
                    }

                    Text {
                        Layout.fillWidth: true
                        text: {
                            const names = dialog.alsoRemoves;
                            const listed = names.slice(0, 4).join(", ");
                            const rest = names.length - 4;
                            const tail = rest > 0 ? listed + Tr.t(" and %1 more").arg(rest) : listed;
                            return (names.length === 1 ? Tr.t("Uninstalling also removes %1") : Tr.t("Uninstalling also removes %1 packages: %2").arg(names.length)).arg(tail);
                        }
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.warning
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
