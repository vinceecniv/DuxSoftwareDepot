import QtQuick.Shapes
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Install tab: live search across Fedora repos and Flathub (AppStream-based),
// with ODRS star ratings, a source choice when software is available from
// multiple sources, and a most-popular storefront shown before searching.
Item {
    id: view

    property var sectionOrder: []    // section labels, in the order enrich.py assigns them
    property var installsById: ({})  // Flathub app id -> installs last month
    property string searchText: ""
    property int sourceFilter: 0     // 0 all, 1 flathub, 2 fedora
    property string busyAction: ""   // "<ref>" while an install runs
    property string lastInstallResult: ""
    property string installProgress: ""  // live phase/percent line while installProcess runs
    property int installStep: 0          // PhaseIndicator step: 0 check, 1 download, 2 install
    property real installFraction: 0     // 0..1 overall progress estimate
    property string installIcon: ""      // catalog icon (path or URL) of the app being installed
    property var installedFlatpaks: new Set()
    property var installedRpms: new Set()
    property var logger: null

    // Fired after a successful install so other views can refresh their lists
    signal softwareMutated()

    // Fired when what was installed only exists in the next deployment, so
    // the window can raise its reboot notice (atomic systems)
    signal stagedChange()

    // The sources panel lives in the window, because it is about the whole
    // system rather than about this tab — but this is where you stand when
    // the question comes up
    signal sourcesRequested()

    // Bumped by the window when software changed elsewhere (Installed tab,
    // update run) so the Installed-chips stay current.
    property int refreshSerial: 0

    onRefreshSerialChanged: installedProcess.running = true

    // Set from the command palette, which searches what is already in memory
    // and hands anything needing the repositories to this tab
    function setQuery(text) {
        searchField.text = text;
        searchText = text;
        searchField.forceActiveFocus();
    }

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    // ── App details popup ────────────────────────────────────────────────────
    // A formula opens the same popup as everything else, filled from brew
    // rather than from AppStream — there is no catalogue entry for it, and
    // brew knows what there is to know.
    function openBrewDetails(formula) {
        detailsDialog.entry = null;
        detailsDialog.brewFacts = formula;
        detailsDialog.open({
            id: formula.name,
            name: formula.name,
            summary: formula.desc || "",
            iconPath: "",
            homepage: formula.homepage || "",
            versionLabel: formula.version || "",
            origin: "Homebrew",
            isFlatpak: false,
            sources: []
        });
        brewInfoProcess.command = [Backend.python, scriptPath.replace("enrich.py", "brew_helper.py"), "--info", formula.name];
        brewInfoProcess.running = true;
    }

    Process {
        id: brewInfoProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const info = JSON.parse(text);
                    if (info.found === true && detailsDialog.brewFacts && info.name === detailsDialog.brewFacts.name)
                        detailsDialog.brewFacts = info;
                } catch (e) {
                }
            }
        }
    }

    function openDetails(entry) {
        detailsDialog.brewFacts = null;
        detailsDialog.entry = entry;
        detailsDialog.open({
            id: entry.id,
            name: entry.name,
            summary: entry.summary || "",
            descriptionHtml: entry.descriptionHtml || "",
            screenshots: entry.screenshots || [],
            iconPath: entry.icon || "",
            homepage: entry.homepage || "",
            rating: entry.rating || null,
            sources: entry.sources
        });
    }

    // For the screenshots: an app from the front page whose details have
    // something to show — the one named if it is there, else the most
    // popular app with screenshots.
    function showcaseEntry(preferredName) {
        const all = (sections[0] || {}).items || [];
        const wanted = (preferredName || "").toLowerCase();
        return all.find(item => (item.name || "").toLowerCase() === wanted)
            || all.find(item => (item.screenshots || []).length > 0)
            || all[0] || null;
    }

    readonly property bool detailsLoading: detailsDialog.loading

    function closeDialogs() {
        detailsDialog.close();
        offerDialog.close();
    }

    // ── Which source ─────────────────────────────────────────────────────────
    function openSourcePicker(entry) {
        sourcePicker.pickerEntry = entry;
        sourcePicker.open({
            id: entry.id,
            name: entry.name,
            iconPath: entry.icon || "",
            sources: entry.sources || []
        });
    }

    // Reparented into the window's overlay layer so the dim covers everything
    property var overlayParent: null

    SourcePickerDialog {
        id: sourcePicker

        parent: view.overlayParent || view

        property var pickerEntry: null

        onInstallRequested: source => {
            if (pickerEntry)
                view.install(source, pickerEntry.name, pickerEntry.icon || "");
        }
    }

    AppDetailsDialog {
        id: detailsDialog

        parent: view.overlayParent || view

        property var entry: null

        showInstallButtons: true
        installedChipVisible: entry ? view.isInstalled(entry) : false
        installedRefs: entry ? (entry.sources || []).filter(source => view.isSourceInstalled(entry, source)).map(source => source.ref) : []
        showOpenButton: entry !== null && entry.sources.some(s => s.kind === "flatpak" && view.installedFlatpaks.has(s.ref.toLowerCase()))
        busy: entry ? entry.sources.some(s => s.ref !== "" && view.sourceKey(s) === view.busyAction) : false
        busyDetail: view.installProgress
        busyFraction: view.installFraction

        onInstallRequested: source => view.install(source, entry.name, entry.icon || "")
    }

    readonly property string scriptPath: Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", "")

    Component.onCompleted: {
        installedProcess.running = true;
        installsProcess.running = true;
        indexProcess.running = true;
        appimageIndexProcess.running = true;
        appimageListProcess.running = true;
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(resultsList);
    }

    Process {
        id: appimageIndexProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--index"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const raw = JSON.parse(text);
                    view.appimageIndex = raw.map(e => ({
                                id: e.id,
                                name: e.name,
                                summary: e.summary || "",
                                descriptionHtml: e.descriptionHtml || "",
                                screenshots: e.screenshots || [],
                                homepage: e.homepage || "",
                                icon: e.iconUrl || "",
                                updated: 0,
                                rating: null,
                                nl: e.nl,
                                ne: e.nl,
                                il: e.id,
                                pl: "",
                                sl: e.sl || "",
                                sources: [{
                                        source: "appimage",
                                        kind: "appimage",
                                        ref: e.repo || e.download,
                                        repo: e.repo || "",
                                        download: e.download || ""
                                    }]
                            }));
                } catch (e) {
                    view.appimageIndex = [];
                }
            }
        }
    }

    Process {
        id: appimageListProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--list"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const ids = new Set();
                    for (const rec of JSON.parse(text))
                        ids.add(rec.id);
                    view.installedAppimages = ids;
                } catch (e) {
                }
            }
        }
    }

    // Install an AppImage from the catalog (GitHub release) or from a
    // user-supplied URL / local file
    property string appimageBusy: ""

    function installAppimage(args, label) {
        if (appimageInstallProcess.running)
            return;
        appimageBusy = label;
        lastInstallResult = "";
        appimageInstallProcess._label = label;
        appimageInstallProcess.command = [Backend.python, scriptPath.replace("enrich.py", "appimage.py")].concat(args);
        appimageInstallProcess.running = true;
    }

    Process {
        id: appimageInstallProcess

        property string _label: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "progress" && event.total > 0)
                    view.lastInstallResult = appimageInstallProcess._label + " · " + event.percent + "%";
                else if (event.event === "error")
                    view.lastInstallResult = Tr.t("%1 failed (exit %2)").arg(appimageInstallProcess._label).arg(event.message || "?");
            }
        }

        onExited: (exitCode, exitStatus) => {
            view.appimageBusy = "";
            const failed = view.lastInstallResult.indexOf("%") === -1 && view.lastInstallResult !== "" && view.lastInstallResult.indexOf("✓") === -1;
            if (exitCode === 0 && !failed) {
                view.lastInstallResult = Tr.t("%1 installed ✓").arg(_label);
                if (view.logger)
                    view.logger.record("install", Tr.t("Installed %1").arg(_label), [{
                        name: _label,
                        id: _label,
                        repo: "appimage",
                        from: "",
                        to: "",
                        source: "AppImage",
                        status: "done"
                    }], 0, {
                        key: "Installed %1",
                        args: [_label]
                    });
                view.softwareMutated();
            } else if (view.lastInstallResult.indexOf("✓") === -1 && view.lastInstallResult.indexOf("%") !== -1) {
                view.lastInstallResult = Tr.t("%1 failed (exit %2)").arg(_label).arg(exitCode);
                if (view.logger)
                    view.logger.record("install-failed", Tr.t("Could not install %1").arg(_label), [{
                        name: _label,
                        id: _label,
                        repo: "appimage",
                        from: "",
                        to: "",
                        source: "AppImage",
                        status: "error",
                        reason: Tr.t("exit %1").arg(exitCode),
                        error: ""
                    }], 0, {
                        key: "Could not install %1",
                        args: [_label]
                    });
            }
            appimageListProcess.running = true;
            resultClearTimer.restart();
        }
    }

    // ── Installing an AppImage from a file ───────────────────────────────────
    // Both ways in end up here: the toolbar button opens the dialog empty,
    // and a .appimage double-clicked in the file manager opens it on that
    // file. The dialog does the reading and the asking; running the install
    // stays here, where the progress, the log entry and the refresh live.
    AppimageOfferDialog {
        id: offerDialog

        parent: view.overlayParent || view
        busy: view.appimageBusy !== "" || view.busyAction !== ""

        onInstallRequested: (args, label) => view.installAppimage(args, label)
        onFlatpakInstallRequested: (path, label, appid, icon) => view.installFlatpakFile(path, label, appid, icon)
    }

    function offerAppimageFile(path) {
        offerDialog.openWithFile(path);
    }

    // ── Instant search ───────────────────────────────────────────────────────
    // The merged AppStream index is loaded into memory once, so filtering
    // happens locally on every keystroke. The dnf name fallback (CLI packages
    // without AppStream data) is slower and trickles in asynchronously.
    property var searchIndex: []
    property var appimageIndex: []
    property var installedAppimages: new Set()
    property bool indexLoading: true
    readonly property bool searching: searchMode && indexLoading
    // Whether "nothing found" is a finding or just the current state of a
    // sentence still being written. The name search for CLI packages — the
    // one that finds libheif, which no AppStream entry describes — answers a
    // moment after the local index, and for a query only it can answer, that
    // moment was being filled with "No results for heif". An answer that
    // changes its mind is worse than one that takes a beat. It deliberately
    // does not gate the result list: hits the local index already has go up
    // immediately, and the rest join them.
    readonly property bool awaitingResults: searchMode && (indexLoading || moreResultsPending)
    property var dnfExtras: []
    property string dnfExtrasQuery: ""
    // True while the async dnf name search hasn't answered for the current
    // query. It gates both the "more on the way" hint under a result list and
    // the empty state above, which must not conclude anything until it is
    // false.
    readonly property bool moreResultsPending: searchMode && dnfExtrasQuery !== searchText.trim()

    // ── Copr ─────────────────────────────────────────────────────────────────
    // Nothing in Copr is part of any index this machine has: a package built
    // there stays invisible to search until its project is enabled, which is
    // the wrong way round for software nobody has found yet. Asking the hub
    // is therefore possible — but on request, not on every keystroke: it is
    // someone else's server and it takes seconds, not milliseconds.
    property var coprResults: []
    property string coprQuery: ""     // the query coprResults answer
    property string coprError: ""
    property bool coprSearching: false

    // ── Homebrew ────────────────────────────────────────────────────────────
    // Asked for the same way Copr is, and for a related reason: it is a
    // catalogue this machine keeps but the storefront does not index, so
    // searching it is a deliberate press rather than something that happens
    // per keystroke. Only offered where brew exists.
    property var brewResults: []
    property string brewQuery: ""
    property string brewError: ""
    property bool brewSearching: false
    // Bound by the window from the widget, which is the one that asks brew
    property bool hasBrew: false

    // Brew's analytics run to six figures; the row has room for two.
    function formatCount(n) {
        if (n >= 1000000)
            return (n / 1000000).toFixed(1) + "M";
        if (n >= 1000)
            return Math.round(n / 1000) + "k";
        return String(n);
    }

    function installBrew(name) {
        if (busyAction !== "" || brewInstallProcess.running)
            return;
        busyAction = name;
        installProgress = Tr.t("Installing %1…").arg(name);
        installIcon = "";
        installFraction = 0;
        brewInstallProcess._label = name;
        brewInstallProcess._failed = "";
        brewInstallProcess.command = [Backend.python, scriptPath.replace("enrich.py", "brew_helper.py"), "--install", name];
        brewInstallProcess.running = true;
    }

    Process {
        id: brewInstallProcess

        property string _label: ""
        property string _failed: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "op-error")
                    brewInstallProcess._failed = event.message || "";
            }
        }

        onExited: (exitCode, exitStatus) => {
            view.busyAction = "";
            view.installProgress = "";
            const label = brewInstallProcess._label;
            const ok = exitCode === 0 && brewInstallProcess._failed === "";
            view.lastInstallResult = ok ? Tr.t("%1 installed ✓").arg(label)
                                        : Tr.t("%1 failed (exit %2)").arg(label).arg(exitCode);
            if (view.logger) {
                const label2 = {
                    key: ok ? "Installed %1" : "Could not install %1",
                    args: [label]
                };
                view.logger.record(ok ? "install" : "install-failed", Tr.t(label2.key).arg(label), [
                    {
                        name: label,
                        id: label,
                        repo: "brew",
                        from: "",
                        to: "",
                        source: "Homebrew",
                        status: ok ? "done" : "error",
                        reason: ok ? "" : brewInstallProcess._failed,
                        error: ok ? "" : brewInstallProcess._failed
                    }
                ], 0, label2);
            }
            // The row said "Install" a moment ago; ask brew what is true now
            view.searchBrew();
            view.softwareMutated();
            resultClearTimer.restart();
        }
    }

    function searchBrew() {
        const query = searchText.trim();
        if (query.length < 2 || brewProcess.running)
            return;
        brewError = "";
        brewSearching = true;
        brewProcess._query = query;
        brewProcess.command = [Backend.python, scriptPath.replace("enrich.py", "brew_helper.py"), "--search", query];
        brewProcess.running = true;
    }

    Process {
        id: brewProcess

        property string _query: ""

        stdout: StdioCollector {
            onStreamFinished: {
                view.brewSearching = false;
                try {
                    const answer = JSON.parse(text);
                    view.brewResults = answer.results || [];
                    view.brewQuery = brewProcess._query;
                    view.brewError = "";
                } catch (e) {
                    view.brewResults = [];
                    view.brewQuery = brewProcess._query;
                    view.brewError = Tr.t("Homebrew could not be asked.");
                }
            }
        }
    }

    function searchCopr() {
        const query = searchText.trim();
        if (query.length < 2 || coprProcess.running)
            return;
        coprError = "";
        coprSearching = true;
        coprProcess._query = query;
        coprProcess.command = Backend.coprSearchCommand(query);
        coprProcess.running = true;
    }

    onSearchTextChanged: {
        dnfDebounce.restart();
        // Results belong to the query they were asked for
        if (searchText.trim() !== coprQuery) {
            coprResults = [];
            coprError = "";
        }
        if (searchText.trim() !== brewQuery) {
            brewResults = [];
            brewError = "";
        }
    }

    Timer {
        id: dnfDebounce
        interval: 450
        onTriggered: view.runDnfSearch()
    }

    function runDnfSearch() {
        const query = searchText.trim();
        if (query.length < 2) {
            dnfExtras = [];
            dnfExtrasQuery = "";
            return;
        }
        if (dnfProcess.running) {
            dnfDebounce.restart();
            return;
        }
        dnfProcess._query = query;
        dnfProcess.command = [Backend.python, scriptPath, "--search-dnf", query];
        dnfProcess.running = true;
    }

    // One array instead of a fresh concat per keystroke. The two indexes are
    // replaced twice in a session — when each finishes loading — and copying
    // four thousand entries on every letter to express that is a waste.
    readonly property var searchPool: searchIndex.concat(appimageIndex)

    // Typing only ever narrows. Every test below is containment or a stronger
    // form of it, so an entry that cannot match "fire" cannot match "firef"
    // either, and the second letter can be scanned against the few hundred
    // that survived the first rather than against the whole catalog.
    //
    // Kept in a plain object rather than in properties on purpose: this is
    // written from inside a binding, and a property write would notify the
    // binding that reads it. Assigning to the fields of a var never does.
    // `source` is the pool identity, so an index arriving mid-word throws the
    // cache away rather than filtering a stale subset.
    readonly property var _searchCache: ({
            source: null,
            needle: "",
            pool: []
        })

    function localResults(query) {
        const needle = query.toLowerCase();
        const words = needle.split(/\s+/).filter(w => w !== "");
        const scored = [];
        const cache = _searchCache;
        const narrowed = cache.source === searchPool && cache.needle.length >= 2 && needle.startsWith(cache.needle);
        const pool = narrowed ? cache.pool : searchPool;
        for (const item of pool) {
            let score = -1;
            if (words.length <= 1) {
                if (item.nl === needle || item.ne === needle || item.il === needle)
                    score = 0;
                else if (item.nl.startsWith(needle) || item.ne.startsWith(needle))
                    score = 1;
                else if (item.nl.indexOf(needle) !== -1 || item.ne.indexOf(needle) !== -1 || item.il.indexOf(needle) !== -1 || item.pl.indexOf(needle) !== -1)
                    score = 2;
                else if (item.sl.indexOf(needle) !== -1)
                    score = 3;
            } else {
                // Multi-word AND search: every word must match somewhere,
                // order-independent
                const mainHay = item.nl + " " + item.ne + " " + item.il + " " + item.pl;
                let all = true;
                let allInMain = true;
                for (const word of words) {
                    const inMain = mainHay.indexOf(word) !== -1;
                    if (!inMain && item.sl.indexOf(word) === -1) {
                        all = false;
                        break;
                    }
                    if (!inMain)
                        allInMain = false;
                }
                if (all)
                    score = allInMain ? 2 : 3;
            }
            if (score >= 0)
                scored.push({
                    item: item,
                    score: score
                });
        }
        // The whole match set, not the sixty that get shown: the next letter
        // has to be scanned against everything that could still match it
        cache.source = searchPool;
        cache.needle = needle;
        cache.pool = scored.map(entry => entry.item);
        scored.sort((a, b) => {
            if (a.score !== b.score)
                return a.score - b.score;
            const countA = a.item.rating ? a.item.rating.count : 0;
            const countB = b.item.rating ? b.item.rating.count : 0;
            if (countA !== countB)
                return countB - countA;
            return a.item.name.localeCompare(b.item.name);
        });
        return scored.slice(0, 60).map(s => Object.assign({
                score: s.score
            }, s.item));
    }

    // Labels and kinds built together, because both are conditional — Copr
    // only where dnf is, Homebrew only where brew is — and two lists that
    // shift independently are two lists that will disagree about which chip
    // means what.
    readonly property var filterChips: {
        const labels = [Tr.t("All"), "Flathub", Backend.systemRepoLabel, "AppImage"];
        const kinds = ["", "flatpak", "dnf", "appimage"];
        if (Backend.hasCopr) {
            labels.push("Copr");
            kinds.push("copr");
        }
        if (view.hasBrew) {
            labels.push("Homebrew");
            kinds.push("brew");
        }
        return {
            labels: labels,
            kinds: kinds
        };
    }
    readonly property var filterKinds: filterChips.kinds
    readonly property bool brewFilterWanted: sourceFilter === 0 || filterKinds[sourceFilter] === "brew"
    // Offering to search Copr while the Homebrew chip is selected is offering
    // an answer the filter would then hide
    readonly property bool coprFilterWanted: sourceFilter === 0 || filterKinds[sourceFilter] === "copr"

    function matchesSourceFilter(item) {
        if (sourceFilter === 0)
            return true;
        const wanted = filterKinds[sourceFilter] || "dnf";
        return item.sources.some(s => s.kind === wanted);
    }

    // Two Coprs can build a package of the same name, so what is busy is this
    // project's copy of it rather than the name
    function sourceKey(source) {
        return source.kind === "copr" ? source.project + ":" + source.ref : source.ref;
    }

    readonly property bool searchMode: searchText.trim().length >= 2

    // ── Sections ─────────────────────────────────────────────────────────────
    // The storefront is a row of teasers per category; naming one here opens it
    // and the tab shows that category alone. Searching outranks it rather than
    // clearing it: a search is a detour, and the section is still where the
    // reader was when they left.
    // A section outranks a search rather than the other way round: typing
    // while inside one narrows that section instead of abandoning it, which is
    // what "search further" means once you have chosen where to look. Leaving
    // is a chip away, and leaving is what widens the search back to everything.
    property string activeCategory: ""
    readonly property bool sectionMode: activeCategory !== ""

    function installsFor(item) {
        let best = 0;
        for (const source of item.sources) {
            if (source.kind === "flatpak") {
                const count = installsById[source.ref] || 0;
                if (count > best)
                    best = count;
            }
        }
        return best;
    }

    // Every app in the catalog, in exactly one section, most-downloaded first.
    // Whole sections rather than a sample of each: a section holds what a
    // section holds, the list shows as much of it as has been scrolled to, and
    // searching one searches all of it. Computed when an index or the download
    // figures arrive — twice in a session, not once per keystroke.
    readonly property var sections: {
        if (searchIndex.length === 0 || sectionOrder.length === 0)
            return [];
        for (const item of searchIndex)
            item._inst = installsFor(item);
        const byDownloads = (a, b) => {
            if (a._inst !== b._inst)
                return b._inst - a._inst;
            const countA = a.rating ? a.rating.count : 0;
            const countB = b.rating ? b.rating.count : 0;
            if (countA !== countB)
                return countB - countA;
            return a.name.localeCompare(b.name);
        };
        const buckets = {};
        for (const label of sectionOrder)
            buckets[label] = [];
        for (const item of searchIndex) {
            const bucket = buckets[item.section];
            if (bucket !== undefined)
                bucket.push(item);
        }
        // The chart is every app there is rather than a category, which also
        // makes it the section to open when what you want is to browse the lot
        const groups = [{
                category: "Most popular",
                label: "Most popular",
                items: searchIndex.slice().sort(byDownloads)
            }];
        for (const label of sectionOrder) {
            if (buckets[label].length === 0)
                continue;
            groups.push({
                category: label,
                label: label,
                items: buckets[label].sort(byDownloads)
            });
        }
        return groups;
    }
    readonly property var sectionNames: sections.map(group => group.category)

    function matchesQuery(item, query) {
        if (query.length < 2)
            return true;
        return item.nl.indexOf(query) !== -1 || item.ne.indexOf(query) !== -1 || item.il.indexOf(query) !== -1 || item.pl.indexOf(query) !== -1 || item.sl.indexOf(query) !== -1;
    }

    // Everything in the open section that matches, before anything is cut off
    // for the sake of the list. The heading counts this, and the search runs
    // over it — a section you have only scrolled a third of the way through is
    // still a section you searched in full.
    readonly property var sectionMatches: {
        const section = activeCategory !== "" ? sections.find(group => group.category === activeCategory) : null;
        if (!section)
            return [];
        const needle = searchText.trim().toLowerCase();
        const matches = [];
        for (const item of section.items) {
            // Browsing is for what you could install; the Installed tab
            // already answers the other question. Searching is not browsing
            // though — typing a name and being told there is no such app,
            // because you already have it, is a worse answer than the row.
            if (needle.length < 2 && isInstalled(item))
                continue;
            if (matchesSourceFilter(item) && matchesQuery(item, needle))
                matches.push(item);
        }
        return matches;
    }

    // How much of it has been asked for. Rows are cheap but not free, and a
    // section can be nine hundred apps long; the rest arrives on the way down.
    property int sectionRevealed: sectionPage
    readonly property int sectionPage: 60

    onSectionMatchesChanged: sectionRevealed = sectionPage

    function revealMoreOfSection() {
        if (sectionRevealed < sectionMatches.length)
            sectionRevealed += sectionPage;
    }

    // Category drill-down animation direction: true = going into a category, false = going back
    property bool categoryDrillIn: true

    function openSection(category) {
        categoryDrillIn = (category || "") !== "";
        activeCategory = category || "";
        sectionRevealed = sectionPage;
        resultsList.positionViewAtBeginning();
    }

    function categoryIcon(category) {
        const cat = (category || "").toLowerCase().trim();
        if (cat === "" || cat === "search results")
            return "search";
        if (cat.indexOf("popular") !== -1)
            return "trending_up";
        if (cat.indexOf("audio") !== -1 || cat.indexOf("sound") !== -1 || cat.indexOf("music") !== -1)
            return "music_note";
        if (cat.indexOf("video") !== -1 || cat.indexOf("media") !== -1 || cat.indexOf("tv") !== -1)
            return "movie";
        if (cat.indexOf("game") !== -1)
            return "sports_esports";
        if (cat.indexOf("graphic") !== -1 || cat.indexOf("photo") !== -1 || cat.indexOf("image") !== -1 || cat.indexOf("art") !== -1)
            return "brush";
        if (cat.indexOf("dev") !== -1 || cat.indexOf("code") !== -1 || cat.indexOf("programming") !== -1)
            return "code";
        if (cat.indexOf("productiv") !== -1 || cat.indexOf("office") !== -1 || cat.indexOf("document") !== -1)
            return "business_center";
        if (cat.indexOf("util") !== -1 || cat.indexOf("tool") !== -1)
            return "build";
        if (cat.indexOf("system") !== -1 || cat.indexOf("hardware") !== -1 || cat.indexOf("setting") !== -1)
            return "settings_suggest";
        if (cat.indexOf("add-on") !== -1 || cat.indexOf("addon") !== -1 || cat.indexOf("plugin") !== -1 || cat.indexOf("extension") !== -1)
            return "extension";
        if (cat.indexOf("network") !== -1 || cat.indexOf("internet") !== -1 || cat.indexOf("browser") !== -1 || cat.indexOf("web") !== -1)
            return "hub";
        if (cat.indexOf("science") !== -1 || cat.indexOf("educat") !== -1)
            return "school";
        if (cat.indexOf("communicat") !== -1 || cat.indexOf("chat") !== -1)
            return "chat";
        if (cat.indexOf("health") !== -1 || cat.indexOf("fit") !== -1)
            return "fitness_center";
        if (cat.indexOf("copr") !== -1)
            return "deployed_code";
        if (cat.indexOf("brew") !== -1 || cat.indexOf("homebrew") !== -1)
            return "local_drink";
        return "category";
    }
    // What the list has to show, which decides whether the list is shown at
    // all. Copr answers arrive as ordinary rows and were counted from the
    // start; Homebrew's are their own kind of row and were not, so a search
    // that only brew could answer said "14 found in Homebrew, listed below"
    // over an empty screen — the list holding them was hidden for being
    // empty.
    readonly property int resultCount: {
        if (searchMode) {
            let count = 0;
            for (const row of listModel) {
                if (row.type === "category_card")
                    count += (row.items || []).length;
                else if (row.type === "app" || row.type === "brew")
                    count++;
            }
            return count;
        }
        if (sectionMode)
            return sectionMatches.length;
        // The storefront's apps are rows of their own under each heading
        let total = 0;
        for (const row of listModel)
            total += row.type === "app" ? 1 : (row.items || []).length;
        return total;
    }

    // Sort order for search results
    property string sortMode: "Relevance"
    readonly property var sortOptions: ["Relevance", "Name", "Rating", "Popularity", "Recently updated"]

    function sortResults(items) {
        const sorted = items.slice();
        switch (sortMode) {
        case "Name":
            sorted.sort((a, b) => a.name.localeCompare(b.name));
            break;
        case "Rating":
            sorted.sort((a, b) => {
                const ratingA = a.rating ? a.rating.stars : -1;
                const ratingB = b.rating ? b.rating.stars : -1;
                if (ratingB !== ratingA)
                    return ratingB - ratingA;
                return (b.rating ? b.rating.count : 0) - (a.rating ? a.rating.count : 0);
            });
            break;
        case "Popularity":
            sorted.sort((a, b) => (b.rating ? b.rating.count : 0) - (a.rating ? a.rating.count : 0));
            break;
        case "Recently updated":
            sorted.sort((a, b) => (b.updated || 0) - (a.updated || 0));
            break;
        default:
            break;
        }
        return sorted;
    }

    // Model representing sections as structured cards in storefront mode,
    // or flat list in section / search mode.
    readonly property var listModel: {
        const rows = [];
        // Single section drilldown mode (Extended Category Container)
        if (activeCategory !== "" && sections.some(group => group.category === activeCategory)) {
            // One row per app, not one card holding all of them. A card is
            // a single delegate, so a Repeater inside it builds every row it
            // is given and the view has nothing left to virtualise — on a
            // section that runs to nine hundred apps that is the whole
            // section alive at once. Flat, the view keeps a dozen.
            const shownItems = sectionMatches.slice(0, sectionRevealed);
            for (let i = 0; i < shownItems.length; i++)
                rows.push({
                    type: "app",
                    data: shownItems[i],
                    rowIndex: i,
                    totalCount: shownItems.length
                });
            return rows;
        }
        // Search results mode
        if (searchMode) {
            const query = searchText.trim();
            let items = localResults(query);
            if (dnfExtrasQuery === query && dnfExtras.length > 0) {
                const covered = new Set();
                for (const item of items) {
                    for (const s of item.sources) {
                        if (s.kind === "dnf")
                            covered.add(s.ref);
                    }
                }
                for (const extra of dnfExtras) {
                    if (!covered.has(extra.sources[0].ref))
                        items.push(extra);
                }
            }
            if (sortMode === "Relevance")
                items.sort((a, b) => (a.score !== undefined ? a.score : 9) - (b.score !== undefined ? b.score : 9));
            else
                items = sortResults(items);
            
            const searchItems = [];
            for (const item of items) {
                if (matchesSourceFilter(item))
                    searchItems.push(item);
            }
            for (let i = 0; i < searchItems.length; i++)
                rows.push({
                    type: "app",
                    data: searchItems[i],
                    rowIndex: i,
                    totalCount: searchItems.length
                });
            if (Backend.hasCopr && view.coprFilterWanted)
                rows.push({
                    type: "coprPrompt"
                });
            if (view.hasBrew && view.brewFilterWanted)
                rows.push({
                    type: "brewPrompt"
                });
            if (brewQuery === query && brewResults.length > 0 && view.brewFilterWanted) {
                rows.push({
                    type: "category_card",
                    category: "brew",
                    label: "Homebrew",
                    total: brewResults.length,
                    items: brewResults,
                    isBrew: true
                });
            }
            if (coprQuery === query && coprResults.length > 0) {
                const coprRows = coprResults.filter(item => matchesSourceFilter(item));
                if (coprRows.length > 0) {
                    rows.push({
                        type: "category_card",
                        category: "copr",
                        label: Tr.t("Copr Packages"),
                        total: coprRows.length,
                        items: coprRows,
                        isCopr: true
                    });
                }
            }
            return rows;
        }

        // Storefront mode: Top categories in cards
        for (const cat of sectionOrder) {
            const group = sections.find(g => g.category === cat);
            if (!group)
                continue;
            const items = group.items.filter(item => matchesSourceFilter(item));
            if (items.length > 0) {
                // The heading is a row of its own and so is each app under
                // it, as in Installed: a card holding its five rows was one
                // delegate, built whole in the frame it scrolled in — a
                // stutter per category.
                rows.push({
                    type: "category_card",
                    category: group.category,
                    label: group.label,
                    total: items.length,
                    items: [],
                    headingOnly: true,
                    first: rows.length === 0
                });
                const shown = items.slice(0, 5);
                for (let i = 0; i < shown.length; i++)
                    rows.push({
                        type: "app",
                        data: shown[i],
                        rowIndex: i,
                        totalCount: shown.length
                    });
            }
        }
        return rows;
    }

    // Per source rather than per app: an app carried by both Fedora and
    // Flathub is installed from one of them, and "installed" without saying
    // which is the answer to a question nobody asked
    function isSourceInstalled(item, source) {
        if (source.kind === "flatpak")
            return installedFlatpaks.has(source.ref.toLowerCase());
        if (source.kind === "dnf")
            return installedRpms.has(source.ref);
        if (source.kind === "copr")
            return source.installed === true;
        if (source.kind === "appimage")
            return installedAppimages.has(item.id);
        return false;
    }

    function isInstalled(item) {
        for (const source of item.sources) {
            if (source.kind === "flatpak" && installedFlatpaks.has(source.ref.toLowerCase()))
                return true;
            if (source.kind === "dnf" && installedRpms.has(source.ref))
                return true;
            // A Copr row is installed only when the package on the machine
            // came out of that Copr: five of them can build the same name,
            // and the name alone would mark all five
            if (source.kind === "copr" && source.installed === true)
                return true;
            if (source.kind === "appimage" && installedAppimages.has(item.id))
                return true;
        }
        return false;
    }

    // A .flatpak bundle or .flatpakref picked or opened as a file: the same
    // install as one from the catalog, with the file in place of a remote
    function installFlatpakFile(path, label, appid, icon) {
        if (busyAction !== "" || installProcess.running)
            return;
        _beginInstall("file:" + path, label, appid, "Flatpak", icon);
        installProgress = Tr.t("Starting…");
        installProcess.command = [Backend.python, scriptPath.replace("enrich.py", "flatpak_helper.py"), "install-file", path];
        installProcess.running = true;
    }

    function _beginInstall(key, label, id, sourceLabel, icon) {
        busyAction = key;
        installIcon = icon || "";
        lastInstallResult = "";
        installProcess._label = label;
        // The ref is what the log needs to lead back to this app later
        installProcess._id = id || "";
        installProcess._source = sourceLabel;
        installStep = 0;
        installFraction = 0.02;
        _fpOpCount = 0;
        _fpOpsDone = 0;
        _helperError = "";
        _staged = false;
    }

    function install(source, itemName, itemIcon) {
        if (source.kind === "appimage") {
            if (source.repo)
                installAppimage(["--install-github", source.repo, itemName], itemName);
            else if (source.download)
                Qt.openUrlExternally(source.download);
            return;
        }
        _beginInstall(sourceKey(source), itemName, source.ref, source.kind === "flatpak" ? "Flatpak" : "System", itemIcon);
        if (source.kind === "flatpak") {
            // The flatpak CLI is silent when piped; the libflatpak helper
            // emits NDJSON progress events instead (same one updates use).
            installProgress = Tr.t("Starting…");
            installProcess.command = [Backend.python, scriptPath.replace("enrich.py", "flatpak_helper.py"), "install", source.source, source.ref];
        } else {
            // rpm installs run through the backend helper: real per-package
            // byte progress as NDJSON events instead of scraping dnf output.
            // A package found in Copr brings its repository with it, added by
            // the same privileged run so it costs one password, not two.
            installProgress = Tr.t("Waiting for authorization…");
            installProcess.command = (source.kind === "copr" && !source.enabled) ? Backend.coprInstallCommand(source.project, [source.ref]) : Backend.helperCommand("install", [source.ref]);
        }
        installProcess.running = true;
    }

    Process {
        id: installedProcess
        command: ["sh", "-c", "LC_ALL=C flatpak list --app --columns=application 2>/dev/null; echo '---RPM---'; " + Backend.installedNamesShellFragment]

        stdout: StdioCollector {
            onStreamFinished: {
                const flatpaks = new Set();
                const rpms = new Set();
                let inRpm = false;
                for (const line of text.trim().split("\n")) {
                    const value = line.trim();
                    if (value === "---RPM---") {
                        inRpm = true;
                        continue;
                    }
                    if (!value)
                        continue;
                    if (inRpm)
                        rpms.add(value);
                    else
                        flatpaks.add(value.toLowerCase());
                }
                view.installedFlatpaks = flatpaks;
                view.installedRpms = rpms;
            }
        }
    }

    // Download figures, refreshed here and nowhere else. The index reads them
    // from cache and never waits for a server on another continent; this asks
    // that server, once a day, alongside the index rather than in front of it.
    // What comes back is used directly, so the first run on a machine is
    // ordered correctly a second later instead of at the next start.
    Process {
        id: installsProcess
        command: [Backend.python, view.scriptPath, "--flathub-installs"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.installsById = JSON.parse(text) || ({});
                } catch (e) {
                    view.installsById = ({});
                }
            }
        }
    }

    Process {
        id: indexProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const payload = JSON.parse(text);
                    view.sectionOrder = payload.sections || [];
                    view.searchIndex = payload.items || [];
                } catch (e) {
                    view.sectionOrder = [];
                    view.searchIndex = [];
                }
                view.indexLoading = false;
            }
        }

        command: [Backend.python, view.scriptPath, "--qml-index"]

        onExited: (exitCode, exitStatus) => {
            view.indexLoading = false;
        }
    }

    Process {
        id: dnfProcess

        property string _query: ""

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.dnfExtras = JSON.parse(text);
                } catch (e) {
                    // Nothing usable came back. Recording the query anyway is
                    // the point: "this query has been answered, with nothing"
                    // is an answer, and without it the empty state below waits
                    // for a reply that is never coming.
                    view.dnfExtras = [];
                }
                view.dnfExtrasQuery = dnfProcess._query;
            }
        }
    }

    Process {
        id: coprProcess

        property string _query: ""

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const answer = JSON.parse(text);
                    view.coprResults = answer.items || [];
                    view.coprError = answer.error || "";
                } catch (e) {
                    view.coprResults = [];
                    view.coprError = Tr.t("Copr could not be reached.");
                }
                view.coprQuery = coprProcess._query;
            }
        }

        onExited: (exitCode, exitStatus) => {
            view.coprSearching = false;
            if (exitCode !== 0 && view.coprQuery !== coprProcess._query) {
                view.coprError = Tr.t("Copr could not be reached.");
                view.coprQuery = coprProcess._query;
            }
        }
    }

    // Turn a raw dnf5/flatpak output line into progress state: a short message,
    // a PhaseIndicator step and an overall 0..1 fraction (check 0–0.35,
    // download 0.35–0.65, install 0.65–1). dnf5 piped output: "Updating and
    // loading repositories:", "Repositories loaded.", "Total size of inbound
    // packages is 39 KiB. …", then
    // "[x/y] <package or transaction step> … NN% | speed | size | time".
    // Flatpak-helper transaction bookkeeping (ops = app + runtimes/extensions)
    property int _fpOpCount: 0
    property int _fpOpsDone: 0

    function _formatBytes(bytes) {
        if (!bytes || bytes <= 0)
            return "";
        if (bytes >= 1e9)
            return (bytes / 1e9).toFixed(1) + " GB";
        if (bytes >= 1e6)
            return Math.round(bytes / 1e6) + " MB";
        return Math.max(1, Math.round(bytes / 1e3)) + " kB";
    }

    // NDJSON event from flatpak_helper.py or rpm_helper.py. Flatpak events
    // carry no phase (download-dominated); the rpm helper tags each event
    // with download/install/remove and index/total for the rpm stage.
    property int _rpmIdx: 0
    property int _rpmTot: 0
    property real _planBytes: 0
    property real _lastOverall: 0

    function _installEvent(event) {
        const count = Math.max(1, _fpOpCount);
        const phase = event.phase || "";
        switch (event.event) {
        case "status":
            installStep = 0;
            installFraction = 0.1;
            installProgress = Tr.t("Loading repositories…");
            break;
        case "plan":
            _fpOpCount = (event.ops || []).length;
            _fpOpsDone = 0;
            _rpmIdx = 0;
            _rpmTot = 0;
            _planBytes = event.totalDownloadBytes || 0;
            _lastOverall = 0;
            installStep = 1;
            installFraction = 0.05;
            const total = _formatBytes(event.totalDownloadBytes);
            installProgress = total !== "" ? Tr.t("Downloading (%1)…").arg(total) : Tr.t("Downloading");
            break;
        case "op-start":
            if (phase === "install" || phase === "remove") {
                _rpmIdx = event.index || (_rpmIdx + 1);
                _rpmTot = event.total || _rpmTot;
                installStep = 2;
                installProgress = (phase === "remove" ? Tr.t("Removing") : Tr.t("Installing")) + " " + _rpmIdx + "/" + Math.max(1, _rpmTot);
            } else {
                installStep = 1;
                installProgress = Tr.t("Downloading") + " " + Math.min(_fpOpsDone + 1, count) + "/" + count;
            }
            break;
        case "progress":
            const part = Math.min(100, event.percent || 0) / 100;
            if (phase === "install" || phase === "remove") {
                const tot = Math.max(1, _rpmTot);
                const overall = Math.min(1, (Math.max(0, _rpmIdx - 1) + part) / tot);
                installStep = 2;
                installFraction = 0.65 + 0.3 * overall;
                installProgress = (phase === "remove" ? Tr.t("Removing") : Tr.t("Installing")) + " " + _rpmIdx + "/" + tot + " · " + Math.round(overall * 100) + "%";
            } else {
                // rpm has a real install stage after this; flatpak's download
                // dominates its whole transaction
                const span = installProcess._source === "System" ? 0.55 : 0.9;
                // Downloads run in parallel and their events interleave —
                // aggregate bytes (rpm helper) give a steady overall; the
                // per-event fallback (flatpak) is clamped monotonic.
                let overall;
                if (event.totalTransferred !== undefined && _planBytes > 0)
                    overall = Math.min(1, event.totalTransferred / _planBytes);
                else
                    overall = Math.min(1, (_fpOpsDone + part) / count);
                overall = Math.max(_lastOverall, overall);
                _lastOverall = overall;
                installStep = 1;
                installFraction = 0.05 + span * overall;
                // Transaction-wide percentage, not the current component's
                installProgress = Tr.t("Downloading") + " " + Math.min(_fpOpsDone + 1, count) + "/" + count + " · " + Math.round(overall * 100) + "%";
            }
            break;
        case "op-done":
            if (phase === "install" || phase === "remove")
                break;
            _fpOpsDone = Math.min(_fpOpsDone + 1, count);
            installFraction = 0.05 + (installProcess._source === "System" ? 0.55 : 0.9) * (_fpOpsDone / count);
            if (_fpOpsDone >= count) {
                installStep = 2;
                installProgress = Tr.t("Installing…");
            }
            break;
        case "error":
            _helperError = event.message || "";
            break;
        case "done":
            // rpm-ostree writes the next boot rather than this one, and says
            // so. Claiming the package is ready would be a claim about a
            // system that does not have it yet.
            _staged = event.staged === true;
            break;
        }
    }

    // Last error message from a helper, shown with the failure result
    property string _helperError: ""
    // The helper wrote a deployment that takes effect at the next boot
    property bool _staged: false

    function _installLine(raw) {
        const line = raw.trim();
        if (line === "")
            return;
        if (line[0] === "{") {
            let event = null;
            try {
                event = JSON.parse(line);
            } catch (e) {
                return;
            }
            _installEvent(event);
            return;
        }
        if (line.indexOf("Updating and loading repositories") === 0) {
            installStep = 0;
            installFraction = 0.1;
            installProgress = Tr.t("Loading repositories…");
            return;
        }
        if (line.indexOf("Repositories loaded") === 0) {
            installStep = 0;
            installFraction = 0.25;
            installProgress = Tr.t("Resolving dependencies…");
            return;
        }
        const inbound = /Total size of inbound packages is ([0-9.,]+\s*\S+)/.exec(line);
        if (inbound) {
            installStep = 1;
            installFraction = 0.35;
            installProgress = Tr.t("Downloading (%1)…").arg(inbound[1]);
            return;
        }
        if (line.indexOf("Running transaction") === 0) {
            installStep = 2;
            installFraction = 0.65;
            installProgress = Tr.t("Installing…");
            return;
        }
        const step = /^\[\s*(\d+)\s*\/\s*(\d+)\s*\]\s*(.*)/.exec(line);
        if (step) {
            const x = parseInt(step[1], 10);
            const y = Math.max(1, parseInt(step[2], 10));
            const rest = step[3] || "";
            const transaction = /^(Verify|Prepare|Installing|Upgrading|Reinstalling|Downgrading|Running|Cleanup|Removing)/.test(rest);
            const pct = /(\d{1,3})%/.exec(rest);
            const part = Math.min(1, (x - 1 + (pct ? Math.min(100, parseInt(pct[1], 10)) / 100 : 0)) / y);
            installStep = transaction ? 2 : 1;
            installFraction = transaction ? 0.65 + 0.35 * part : 0.35 + 0.3 * part;
            // Stage-wide percentage — the per-item percent reads oddly ("16/24 · 100%")
            installProgress = (transaction ? Tr.t("Installing") : Tr.t("Downloading")) + " " + x + "/" + y + " · " + Math.round(part * 100) + "%";
            return;
        }
        // Flatpak's piped output has no bracket steps; keep whatever percent shows up
        const pct = /(\d{1,3})%/.exec(line);
        if (pct) {
            const part = Math.min(100, parseInt(pct[1], 10)) / 100;
            installStep = 1;
            installFraction = 0.3 + 0.6 * part;
            installProgress = Tr.t("Downloading") + " · " + pct[1] + "%";
        } else if (line.indexOf("Installing") === 0) {
            installStep = 2;
            installFraction = Math.max(installFraction, 0.7);
            installProgress = Tr.t("Installing…");
        }
    }

    Process {
        id: installProcess

        property string _label: ""
        property string _id: ""
        property string _source: ""

        stdout: SplitParser {
            onRead: line => view._installLine(line)
        }

        stderr: SplitParser {
            onRead: line => view._installLine(line)
        }

        onExited: (exitCode, exitStatus) => {
            view.busyAction = "";
            view.installProgress = "";
            view.installStep = 0;
            view.installFraction = 0;
            view.installIcon = "";
            view.lastInstallResult = exitCode === 0 ? (Tr.t("%1 installed ✓").arg(installProcess._label) + (view._staged ? " · " + Tr.t("takes effect after reboot") : "")) : (Tr.t("%1 failed (exit %2)").arg(installProcess._label).arg(exitCode) + (view._helperError !== "" ? " · " + view._helperError : ""));
            if (exitCode !== 0 && view.logger) {
                // A failed run says so on its card; a failed install said so
                // in a line that is gone the moment the view moves on. The
                // update side has kept its failures with their reasons since
                // the beginning — this is the same bargain for installs.
                const reason = view._helperError !== "" ? view._helperError : Tr.t("exit %1").arg(exitCode);
                view.logger.record("install-failed", Tr.t("Could not install %1").arg(installProcess._label), [{
                    name: installProcess._label,
                    id: installProcess._id || installProcess._label,
                    repo: installProcess._source === "Flatpak" ? "flatpak" : "system",
                    from: "",
                    to: "",
                    source: installProcess._source,
                    status: "error",
                    reason: reason,
                    error: view._helperError
                }], 0, {
                    key: "Could not install %1",
                    args: [installProcess._label]
                });
            }
            if (exitCode === 0) {
                if (view.logger) {
                    view.logger.record("install", Tr.t("Installed %1").arg(installProcess._label), [{
                        name: installProcess._label,
                        id: installProcess._id || installProcess._label,
                        repo: installProcess._source === "Flatpak" ? "flatpak" : "system",
                        from: "",
                        to: "",
                        source: installProcess._source,
                        status: "done"
                    }], 0, {
                        key: "Installed %1",
                        args: [installProcess._label]
                    });
                }
                view.softwareMutated();
                if (view._staged)
                    view.stagedChange();
                // Which Copr a package came from, and which Coprs are
                // configured, both just changed. The answer is cached, so
                // asking again costs nothing.
                if (view.coprQuery !== "" && view.coprQuery === view.searchText.trim())
                    view.searchCopr();
            }
            installedProcess.running = true;
            resultClearTimer.restart();
        }
    }

    Timer {
        id: resultClearTimer
        interval: 8000
        onTriggered: view.lastInstallResult = ""
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            SearchField {
                id: searchField
                Layout.fillWidth: true
                // The field says where it is pointing: inside a section it
                // searches that section, and typing without being told so
                // would look like a search that had lost most of the catalog
                placeholderText: view.sectionMode ? Tr.t("Search in %1…").arg(Tr.t(view.activeCategory)) : Tr.t("Search new software (%1 repos + Flathub)…").arg(Backend.systemRepoLabel)
                FieldPlaceholder {
                    text: view.sectionMode ? Tr.t("Search in %1…").arg(Tr.t(view.activeCategory)) : Tr.t("Search new software (%1 repos + Flathub)…").arg(Backend.systemRepoLabel)
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

                // The Keys handler above only sees Esc while the field has
                // focus; catch it window-wide as long as the popup doesn't
                // need it.
                Shortcut {
                    sequence: "Escape"
                    enabled: view.visible && searchField.text !== "" && !detailsDialog.visible
                    onActivated: searchField.clear()
                }
            }

            DankActionButton {
                buttonSize: 34
                iconName: "database"
                iconSize: 18
                iconColor: Theme.surfaceText
                tooltipText: Tr.t("Software sources")
                onClicked: view.sourcesRequested()
            }

            DankActionButton {
                buttonSize: 34
                iconName: "note_add"
                iconSize: 18
                iconColor: offerDialog.showing ? Theme.primary : Theme.surfaceText
                tooltipText: Tr.t("Install AppImage from file or URL")
                onClicked: offerDialog.open()
            }

            // The fifth source of software, and the one this window does not
            // serve itself: browsing and installing plugins is DMS's own
            // screen, so the button opens that rather than pretending to be
            // a second registry client.
            DankActionButton {
                buttonSize: 34
                iconName: "extension"
                iconSize: 18
                iconColor: Theme.surfaceText
                tooltipText: Tr.t("Install a DMS plugin")
                onClicked: PopoutService.openSettingsWithTab("plugins")
            }
        }

        // Second toolbar row: back button + source filter on the left, sorting
        // on the right
        Item {
            Layout.fillWidth: true
            implicitHeight: 34

            Rectangle {
                id: allSectionsBtn
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: view.sectionMode
                width: allSecRow.implicitWidth + 24
                height: 32
                property bool isHovered: allSecMa.containsMouse
                radius: allSecMa.pressed ? (height / 2) : 8
                Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                color: Ui.buttonFill("tonal", isHovered)
                Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                scale: allSecMa.pressed ? 0.94 : 1.0
                Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                DankRipple {
                    id: allSecRip
                    anchors.fill: parent
                    cornerRadius: parent.radius
                    rippleColor: Ui.buttonInk("tonal")
                }

                RowLayout {
                    id: allSecRow
                    anchors.centerIn: parent
                    spacing: 6

                    DankIcon {
                        name: "arrow_back"
                        size: 16
                        color: Ui.buttonInk("tonal")
                    }

                    StyledText {
                        text: Tr.t("All sections")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Ui.buttonInk("tonal")
                    }
                }

                MouseArea {
                    id: allSecMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: (m) => allSecRip.trigger(m.x, m.y)
                    onClicked: view.openSection("")
                }
            }

            DankButtonGroup {
                anchors.left: allSectionsBtn.visible ? allSectionsBtn.right : parent.left
                anchors.leftMargin: allSectionsBtn.visible ? Theme.spacingM : 0
                anchors.verticalCenter: parent.verticalCenter
                model: view.filterChips.labels
                currentIndex: view.sourceFilter
                onSelectionChanged: (index, selected) => {
                    if (selected)
                        view.sourceFilter = index;
                }
            }

            DankDropdown {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: view.searchMode && !view.sectionMode
                dropdownWidth: 170
                alignPopupRight: true
                options: view.sortOptions.map(o => Tr.t(o))
                currentValue: Tr.t(view.sortMode)
                onValueChanged: value => {
                    for (const option of view.sortOptions) {
                        if (Tr.t(option) === value) {
                            view.sortMode = option;
                            return;
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            // In a section the heading above already carries the count
            visible: view.searchMode && !view.sectionMode && !view.indexLoading
            spacing: Theme.spacingS

            StyledText {
                text: (view.resultCount === 1 ? Tr.t("%1 result") : Tr.t("%1 results")).arg(view.resultCount)
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }

            // More results may still arrive from the dnf name fallback
            DankSpinner {
                visible: view.moreResultsPending
                size: 14
            }

            StyledText {
                Layout.fillWidth: true
                visible: ["Rating", "Popularity", "Recently updated"].indexOf(view.sortMode) !== -1
                text: Tr.t("Sorting uses app-catalog data — plain rpm packages without it are listed last.")
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
            }
        }

        // Live install progress: same visual language as the Updates run
        // panel — phase stepper, animated wave bar and a detail row.
        Rectangle {
            Layout.fillWidth: true
            visible: view.busyAction !== ""
            implicitHeight: installProgressColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Ui.cardSurface

            ColumnLayout {
                id: installProgressColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                M3WaveProgress {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 18
                    value: view.installFraction
                    isPlaying: visible
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS

                    Item {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        visible: view.installIcon !== ""

                        Image {
                            id: installProgressLogo
                            anchors.fill: parent
                            source: view.installIcon !== "" ? (view.installIcon.indexOf("http") === 0 ? view.installIcon : "file://" + view.installIcon) : ""
                            sourceSize.width: 44
                            sourceSize.height: 44
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            visible: status === Image.Ready
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            visible: installProgressLogo.status !== Image.Ready
                            name: "apps"
                            size: 16
                            // A package with no icon of its own falls back to this glyph, and a
                            // list of them is most of what an installed-software list is. Left
                            // grey it made the setting look half-applied — the apps with
                            // artwork turned, the ones without stayed as they were.
                            color: Ui.tintAppIcons ? Theme.primary : Theme.surfaceVariantText
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: installProcess._label
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: view.installProgress
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: view.busyAction === "" && view.lastInstallResult !== ""
            text: view.lastInstallResult
            font.pixelSize: Theme.fontSizeSmall
            color: view.lastInstallResult.indexOf("✓") !== -1 ? Theme.success : Theme.error
        }

        Item {
            id: listOuterContainer
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.resultCount > 0 && !view.searching
            clip: true

            Connections {
                target: view
                function onActiveCategoryChanged() {
                    slideAnim.stop();
                    listWrapper.targetX = view.categoryDrillIn ? 50 : -50;
                    listWrapper.opacity = 0.0;
                    slideAnim.start();
                }
            }

            ParallelAnimation {
                id: slideAnim
                NumberAnimation {
                    target: listWrapper
                    property: "targetX"
                    to: 0
                    duration: Theme.longDuration
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: listWrapper
                    property: "opacity"
                    to: 1.0
                    duration: Theme.longDuration
                    easing.type: Easing.OutCubic
                }
            }

            Item {
                id: listWrapper
                property real targetX: 0
                x: targetX
                y: 0
                width: parent.width
                height: parent.height

                DankListView {
                    id: resultsList
                    anchors.fill: parent
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    // Rows 2px apart, as in every other list (#29). The space
                    // between categories is the cards' own, below.
                    spacing: 2
                    model: view.listModel

                    Component.onCompleted: {
                        Ui.softenScrollbar(resultsList);
                        Ui.takeOverWheel(resultsList);
                        Ui.registerBench("install", resultsList);
                    }

                    WheelHandler {
                        id: listSmoothWheel
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            if (Ui.wheelToShell(resultsList, event)) {
                                listScrollAnim.stop();
                                return;
                            }
                            if (resultsList.contentHeight <= resultsList.height) return;
                            const delta = event.angleDelta.y;
                            if (delta === 0) return;
                            const lines = Math.round(Math.abs(delta) / 120) || 1;
                            const scrollDelta = (delta > 0 ? -lines : lines) * 120;
                            const currentTarget = listScrollAnim.running ? listScrollAnim.to : resultsList.contentY;
                            const maxScroll = Math.max(0, resultsList.contentHeight - resultsList.height + resultsList.originY);
                            const newTarget = Math.max(resultsList.originY, Math.min(maxScroll, currentTarget + scrollDelta));
                            listScrollAnim.stop();
                            listScrollAnim.from = resultsList.contentY;
                            listScrollAnim.to = newTarget;
                            listScrollAnim.start();
                            Ui.showScrollbar(resultsList);
                            event.accepted = true;
                        }
                    }

                    NumberAnimation {
                        id: listScrollAnim
                        target: resultsList
                        property: "contentY"
                        duration: Theme.longDuration
                        easing.type: Easing.OutCubic
                    }

            add: Transition {
                NumberAnimation { property: "y"; from: 24; duration: Theme.longDuration; easing.type: Easing.OutCubic }
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.longDuration; easing.type: Easing.OutCubic }
            }
            remove: Transition {
                NumberAnimation { property: "opacity"; to: 0; duration: Theme.mediumDuration }
            }
            displaced: Transition {
                NumberAnimation { properties: "y"; duration: Theme.longDuration; easing.type: Easing.OutCubic }
            }
            move: Transition {
                NumberAnimation { properties: "y"; duration: Theme.longDuration; easing.type: Easing.OutCubic }
            }
            moveDisplaced: Transition {
                NumberAnimation { properties: "y"; duration: Theme.longDuration; easing.type: Easing.OutCubic }
            }

            onContentYChanged: {
                if (view.sectionMode && contentHeight > 0 && (contentHeight - (contentY + height)) < 400 && view.sectionRevealed < 300) {
                    view.revealMoreOfSection();
                }
            }

            // Sticky Header pinning active category
            StickyHeader {
                id: installSticky

                view: resultsList
                rows: view.listModel
                headingOf: row => (row && (row.type === "category_card" || row.type === "header")) ? row : ""
                barHeight: 48

                content: Component {
                    StyledRect {
                        anchors.fill: parent
                        // No fill: the bar is the list's own heading, pinned.
                        // StickyHeader puts the window surface behind it.
                        color: "transparent"
                        border.width: 0

                        property var rowData: installSticky.heading || ({})
                        readonly property bool opens: (rowData.category || "") !== ""

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 0
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            DankIcon {
                                name: view.categoryIcon(rowData.category || rowData.label || "")
                                size: 20
                                color: Theme.primary
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: Tr.t(rowData.label || "")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.primary
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Rectangle {
                                visible: opens && (rowData.total || 0) > 0
                                implicitWidth: stickyCatCount.implicitWidth + 14
                                implicitHeight: 20
                                radius: 10
                                color: Theme.withAlpha(Theme.primary, 0.15)
                                Layout.alignment: Qt.AlignVCenter

                                StyledText {
                                    id: stickyCatCount
                                    anchors.centerIn: parent
                                    text: String(rowData.total || "")
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    font.weight: Font.Medium
                                    color: Theme.primary
                                }
                            }

                            DankIcon {
                                visible: opens
                                name: "chevron_right"
                                size: 16
                                color: Theme.primary
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Item { Layout.fillWidth: true }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: opens
                            cursorShape: opens ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: view.openSection(rowData.category)
                        }
                    }
                }
            }

            delegate: Loader {
                id: installDelegateLoader
                required property var modelData
                property var rowData: modelData

                width: resultsList.width
                sourceComponent: {
                    if (modelData.type === "category_card")
                        return categoryCardComponent;
                    if (modelData.type === "header")
                        return categoryHeaderComponent;
                    if (modelData.type === "coprPrompt")
                        return coprPromptComponent;
                    if (modelData.type === "brewPrompt")
                        return brewPromptComponent;
                    if (modelData.type === "brew")
                        return brewRowComponent;
                    return appRowComponent;
                }

                Binding {
                    target: installDelegateLoader.item
                    property: "rowData"
                    value: installDelegateLoader.modelData
                }

                // A flat app row has to know where it sits to round its
                // corners: the card used to tell it from the Repeater's
                // index, and there is no card any more.
                Binding {
                    target: installDelegateLoader.item
                    property: "rowIndex"
                    value: installDelegateLoader.modelData.rowIndex || 0
                    when: installDelegateLoader.modelData.rowIndex !== undefined
                }

                Binding {
                    target: installDelegateLoader.item
                    property: "totalCount"
                    value: installDelegateLoader.modelData.totalCount || 1
                    when: installDelegateLoader.modelData.totalCount !== undefined
                }
            }
        }
        } // end listWrapper
        } // end Item { Layout.fillWidth } wrapper

        // Component for a complete Storefront Category Card Container
        Component {
            id: categoryCardComponent

            StyledRect {
                id: cardContainer
                property var rowData: ({})

                width: resultsList.width
                // Space above and below, plus what the list's spacing gave
                // between categories before it became the rows' 2px
                // A heading alone keeps the old card's spacing: the gap the
                // card left below its last row now sits above the next heading
                readonly property bool headingOnly: rowData.headingOnly === true
                readonly property real topGap: headingOnly && rowData.first !== true ? Theme.spacingM * 3 - 2 : Theme.spacingM
                implicitHeight: headingOnly ? cardCol.implicitHeight + topGap : cardCol.implicitHeight + Theme.spacingM * 3 - 2
                radius: Theme.cornerRadius
                // No fill of its own: the rows inside are already containers,
                // and a tinted box around a stack of tinted boxes is a third
                // tonal level that says nothing the heading does not. The
                // heading carries the grouping, the spacing separates it.
                color: "transparent"
                border.width: 0
                clip: true

                ColumnLayout {
                    id: cardCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    // Space above and below, none at the sides: the heading
                    // and rows line up with the list's edge, as in Installed
                    anchors.topMargin: cardContainer.topGap
                    // Rows 2px apart, as in every other list (#29); the
                    // heading keeps its distance through its own margin
                    spacing: 2

                    // Category Title & Action Header
                    Item {
                        Layout.fillWidth: true
                        Layout.bottomMargin: Theme.spacingS - 2
                        implicitHeight: 32

                        RowLayout {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankIcon {
                                name: view.categoryIcon(cardContainer.rowData.category || cardContainer.rowData.label || "")
                                size: 20
                                color: Theme.primary
                                Layout.alignment: Qt.AlignVCenter
                            }

                            StyledText {
                                text: Tr.t(cardContainer.rowData.label || cardContainer.rowData.category || "")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Rectangle {
                                visible: (cardContainer.rowData.total || 0) > 0
                                implicitWidth: storeCountText.implicitWidth + 14
                                implicitHeight: 20
                                radius: 10
                                color: Theme.withAlpha(Theme.primary, 0.15)
                                Layout.alignment: Qt.AlignVCenter

                                StyledText {
                                    id: storeCountText
                                    anchors.centerIn: parent
                                    text: String(cardContainer.rowData.total || "")
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    font.weight: Font.Medium
                                    color: Theme.primary
                                }
                            }
                        }

                        // View All Custom Action Button (Storefront mode)
                        Rectangle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: (cardContainer.rowData.category || "") !== ""
                            width: viewAllRow.implicitWidth + 22
                            height: 28
                            property bool isHovered: viewAllMa.containsMouse
                            radius: viewAllMa.pressed ? (height / 2) : 8
                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            color: Ui.buttonFill("tonal", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                            scale: viewAllMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DankRipple {
                                id: viewAllRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk("tonal")
                            }

                            RowLayout {
                                id: viewAllRow
                                anchors.centerIn: parent
                                spacing: 4

                                StyledText {
                                    text: Tr.t("View all")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.weight: Font.Medium
                                    color: Ui.buttonInk("tonal")
                                }

                                DankIcon {
                                    name: "chevron_right"
                                    size: 14
                                    color: Ui.buttonInk("tonal")
                                }
                            }

                            MouseArea {
                                id: viewAllMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: (m) => viewAllRip.trigger(m.x, m.y)
                                onClicked: view.openSection(cardContainer.rowData.category)
                            }
                        }


                    }

                    // Category items list repeater
                    Repeater {
                        id: catItemRepeater
                        model: cardContainer.rowData.items || []

                        delegate: Loader {
                            id: catItemLoader
                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            sourceComponent: appRowComponent
                            onLoaded: {
                                item.rowData = { type: "app", data: catItemLoader.modelData };
                                item.rowIndex = catItemLoader.index;
                                item.totalCount = Qt.binding(() => (cardContainer.rowData.items || []).length);
                            }
                        }
                    }
                }
            }
        }

        // ── Copr, on request ─────────────────────────────────────────────────
        // Used twice: as the last row of a result list, and in the empty state
        // where there is no list to be the last row of. Nothing about it reads
        // its own position, so both are the same component.
        Component {
            id: coprPromptComponent

            Rectangle {
                property var rowData: ({})

                implicitHeight: coprRow.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Ui.chipSurface, 0.45)

                RowLayout {
                    id: coprRow

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "person"
                        size: 16
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            if (view.coprSearching)
                                return Tr.t("Searching Copr…");
                            if (view.coprError !== "")
                                return Tr.t("Copr could not be reached.");
                            if (view.coprQuery === view.searchText.trim())
                                return view.coprResults.length > 0 ? Tr.t("%1 found in Copr, listed below").arg(view.coprResults.length) : Tr.t("Nothing in Copr for \"%1\"").arg(view.coprQuery);
                            return Tr.t("Not here? Copr has builds by individuals, for software Fedora does not ship.");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: view.coprError !== "" ? Theme.error : Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    DankSpinner {
                        visible: view.coprSearching
                        size: 16
                    }

                    // Wrapper Item: DankButton sizes itself through `width`, which a layout does not read
                    //
                    // The condition lives here rather than on the button: a
                    // wrapper that reads its child's `visible` is asking a
                    // question it has already answered, since `visible` reads
                    // back as false whenever a parent's is. That is what kept
                    // this button off the screen from 0.8.0 on.
                    Item {
                        Layout.preferredWidth: coprSearchButton.width
                        Layout.preferredHeight: coprSearchButton.height
                        visible: !view.coprSearching && view.coprQuery !== view.searchText.trim()

                        Rectangle {
                            id: coprSearchButton
                            width: coprSearchRow.implicitWidth + 24
                            height: 28
                            property bool isHovered: coprSearchMa.containsMouse
                            radius: coprSearchMa.pressed ? (height / 2) : 8
                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            color: Ui.buttonFill("tonal", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                            scale: coprSearchMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DankRipple {
                                id: coprSearchRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk("tonal")
                            }

                            RowLayout {
                                id: coprSearchRow
                                anchors.centerIn: parent
                                spacing: 4

                                DankIcon {
                                    name: "search"
                                    size: 14
                                    color: Ui.buttonInk("tonal")
                                }

                                StyledText {
                                    text: Tr.t("Search Copr")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.weight: Font.Medium
                                    color: Ui.buttonInk("tonal")
                                }
                            }

                            MouseArea {
                                id: coprSearchMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: (m) => coprSearchRip.trigger(m.x, m.y)
                                onClicked: view.searchCopr()
                            }
                        }
                    }
                }
            }
        }

        // A formula in a result list: what it is, what it costs you to know
        // (nothing — the numbers come from brew's own analytics), and whether
        // it can run here at all. Homebrew grew up on macOS and its core still
        // carries formulae that cannot: those are shown greyed with the reason
        // rather than hidden, because "this exists, but not for you" is an
        // answer and silently dropping it is not.
        Component {
            id: brewRowComponent

            Rectangle {
                id: brewRowRoot

                property var rowData: ({})

                readonly property var formula: rowData.data || ({})
                readonly property bool usable: formula.linux !== false

                implicitHeight: brewInfoColumn.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Ui.chipSurface, 0.45)
                opacity: usable ? 1 : 0.55

                RowLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "local_drink"
                        size: 18
                        color: Theme.surfaceVariantText
                    }

                    ColumnLayout {
                        id: brewInfoColumn

                        Layout.fillWidth: true
                        spacing: 1

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingS

                            StyledText {
                                text: brewRowRoot.formula.name || ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                visible: (brewRowRoot.formula.version || "") !== ""
                                text: brewRowRoot.formula.version || ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                visible: (brewRowRoot.formula.installs30d || 0) > 0
                                text: "· " + Tr.t("%1 installs last month").arg(view.formatCount(brewRowRoot.formula.installs30d))
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            Item {
                                Layout.fillWidth: true
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: brewRowRoot.usable ? (brewRowRoot.formula.desc || "")
                                                     : Tr.t("Homebrew has no build of this for Linux")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.PointingHandCursor
                        z: -1
                        onClicked: view.openBrewDetails(brewRowRoot.formula)
                    }

                    Rectangle {
                        id: brewInstallButton
                        visible: brewRowRoot.usable && brewRowRoot.formula.installed !== true
                        width: brewInstRow.implicitWidth + 20
                        height: 26
                        enabled: view.busyAction === ""
                        property bool isHovered: brewInstMa.containsMouse
                        radius: brewInstMa.pressed ? (height / 2) : 8
                        Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                        color: Ui.buttonFill("accent", isHovered)
                        Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                        scale: brewInstMa.pressed ? 0.94 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                        DankRipple {
                            id: brewInstRip
                            anchors.fill: parent
                            cornerRadius: parent.radius
                            rippleColor: Ui.buttonInk("accent")
                        }

                        RowLayout {
                            id: brewInstRow
                            anchors.centerIn: parent
                            spacing: 4

                            DankIcon {
                                name: "download"
                                size: 13
                                color: Ui.buttonInk("accent")
                            }

                            StyledText {
                                text: Tr.t("Install")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: Ui.buttonInk("accent")
                            }
                        }

                        MouseArea {
                            id: brewInstMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (m) => brewInstRip.trigger(m.x, m.y)
                            onClicked: view.installBrew(brewRowRoot.formula.name)
                        }
                    }

                    StyledText {
                        visible: brewRowRoot.formula.installed === true
                        text: Tr.t("Installed")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.success
                    }
                }
            }
        }

        // ── Homebrew, on request ─────────────────────────────────────────────
        // The same shape as the Copr row above it, because it is the same
        // offer: a catalogue this window does not index, searched when asked.
        Component {
            id: brewPromptComponent

            Rectangle {
                property var rowData: ({})

                implicitHeight: brewRow.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Ui.chipSurface, 0.45)

                RowLayout {
                    id: brewRow

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "local_drink"
                        size: 16
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            if (view.brewSearching)
                                return Tr.t("Searching Homebrew…");
                            if (view.brewError !== "")
                                return Tr.t("Homebrew could not be asked.");
                            if (view.brewQuery === view.searchText.trim())
                                return view.brewResults.length > 0 ? Tr.t("%1 found in Homebrew, listed below").arg(view.brewResults.length) : Tr.t("Nothing in Homebrew for \"%1\"").arg(view.brewQuery);
                            return Tr.t("Homebrew has command-line software the distribution does not carry.");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: view.brewError !== "" ? Theme.error : Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    DankSpinner {
                        visible: view.brewSearching
                        size: 16
                    }

                    Item {
                        Layout.preferredWidth: brewSearchButton.width
                        Layout.preferredHeight: brewSearchButton.height
                        visible: !view.brewSearching && view.brewQuery !== view.searchText.trim()

                        Rectangle {
                            id: brewSearchButton
                            width: brewSearchRow.implicitWidth + 24
                            height: 28
                            property bool isHovered: brewSearchMa.containsMouse
                            radius: brewSearchMa.pressed ? (height / 2) : 8
                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }
                            color: Ui.buttonFill("tonal", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                            scale: brewSearchMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DankRipple {
                                id: brewSearchRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk("tonal")
                            }

                            RowLayout {
                                id: brewSearchRow
                                anchors.centerIn: parent
                                spacing: 4

                                DankIcon {
                                    name: "search"
                                    size: 14
                                    color: Ui.buttonInk("tonal")
                                }

                                StyledText {
                                    text: Tr.t("Search Homebrew")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.weight: Font.Medium
                                    color: Ui.buttonInk("tonal")
                                }
                            }

                            MouseArea {
                                id: brewSearchMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: (m) => brewSearchRip.trigger(m.x, m.y)
                                onClicked: view.searchBrew()
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: categoryHeaderComponent

            Item {
                id: headerRoot

                property var rowData: ({})
                readonly property bool opens: (rowData.category || "") !== ""

                implicitHeight: headerLabel.implicitHeight + Theme.spacingM

                Row {
                    id: headerContent

                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    spacing: Theme.spacingS

                    DankIcon {
                        name: view.categoryIcon(headerRoot.rowData.category || headerRoot.rowData.label || "")
                        size: 18
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        id: headerLabel
                        text: Tr.t(headerRoot.rowData.label || "")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        font.underline: headerRoot.opens && headerArea.containsMouse
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        visible: headerRoot.opens && (headerRoot.rowData.total || 0) > 0
                        text: headerRoot.rowData.total || ""
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.withAlpha(Theme.primary, 0.7)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankIcon {
                        visible: headerRoot.opens
                        name: "chevron_right"
                        size: 14
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: headerArea

                    anchors.left: headerContent.left
                    anchors.right: headerContent.right
                    anchors.top: headerContent.top
                    anchors.bottom: headerContent.bottom
                    anchors.margins: -Theme.spacingXS
                    enabled: headerRoot.opens
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.openSection(headerRoot.rowData.category)
                }
            }
        }

        Component {
            id: appRowComponent

            Item {
                id: resultRow
                property var rowData: ({})
                property int rowIndex: 0
                property int totalCount: 1

                readonly property var app: rowData.data || ({})
                readonly property bool installed: app.sources ? view.isInstalled(app) : false
                readonly property bool busy: app.sources ? app.sources.some(s => s.ref !== "" && (view.sourceKey(s) === view.busyAction || (view.appimageBusy !== "" && s.kind === "appimage" && view.appimageBusy === app.name))) : false
                readonly property bool isFirst: rowIndex === 0
                readonly property bool isLast: rowIndex === totalCount - 1

                implicitHeight: resultContent.implicitHeight + (Theme.spacingS + 2) * 2
                height: implicitHeight

                Shape {
                    id: resultBg
                    anchors.fill: parent
                    // Inset by half the stroke so the 1px outline lands on
                    // whole pixels inside the row: centred on the row's edge,
                    // the list's clip took its outer half and the left side
                    // all but vanished.
                    anchors.margins: 0.5

                    property real innerRadius: 6
                    property real outerRadius: 12
                    // Hover is a state layer and nothing more; the shape answers a press, and
                    // stays changed while the row is selected (M3 Expressive, as DMS does it, #22)
                    property bool hovered: resultMa.containsMouse
                    property bool selected: false
                    property bool morphed: resultMa.pressed || selected

                    property real tlr: morphed ? Math.min(height / 2, 28) : (resultRow.isFirst ? outerRadius : innerRadius)
                    property real trr: morphed ? Math.min(height / 2, 28) : (resultRow.isFirst ? outerRadius : innerRadius)
                    property real blr: morphed ? Math.min(height / 2, 28) : (resultRow.isLast ? outerRadius : innerRadius)
                    property real brr: morphed ? Math.min(height / 2, 28) : (resultRow.isLast ? outerRadius : innerRadius)

                    property real tlrAnim: tlr; Behavior on tlrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    property real trrAnim: trr; Behavior on trrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    property real blrAnim: blr; Behavior on blrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    property real brrAnim: brr; Behavior on brrAnim { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                    property color paintColor: Ui.rowFill(hovered, selected)

                    ShapePath {
                        fillColor: resultBg.paintColor
                        strokeColor: "transparent"
                        strokeWidth: -1

                        startX: resultBg.tlrAnim; startY: 0
                        PathLine { x: resultBg.width - resultBg.trrAnim; y: 0 }
                        PathArc { x: resultBg.width; y: resultBg.trrAnim; radiusX: resultBg.trrAnim; radiusY: resultBg.trrAnim; direction: PathArc.Clockwise }
                        PathLine { x: resultBg.width; y: resultBg.height - resultBg.brrAnim }
                        PathArc { x: resultBg.width - resultBg.brrAnim; y: resultBg.height; radiusX: resultBg.brrAnim; radiusY: resultBg.brrAnim; direction: PathArc.Clockwise }
                        PathLine { x: resultBg.blrAnim; y: resultBg.height }
                        PathArc { x: 0; y: resultBg.height - resultBg.blrAnim; radiusX: resultBg.blrAnim; radiusY: resultBg.blrAnim; direction: PathArc.Clockwise }
                        PathLine { x: 0; y: resultBg.tlrAnim }
                        PathArc { x: resultBg.tlrAnim; y: 0; radiusX: resultBg.tlrAnim; radiusY: resultBg.tlrAnim; direction: PathArc.Clockwise }
                    }
                }

                DankRipple {
                    id: resultRip
                    anchors.fill: parent
                    cornerRadius: resultBg.tlrAnim
                    rippleColor: Theme.primary
                }

                MouseArea {
                    id: resultMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onPressed: (m) => resultRip.trigger(m.x, m.y)
                    onClicked: view.openDetails(resultRow.app)
                }

                RowLayout {
                    id: resultContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingM

                    // The icon slot of every list: 32px, and a tile behind it
                    // only when there is no icon to show
                    Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        radius: 6
                        color: resultLogo.status === Image.Ready ? "transparent" : Theme.withAlpha(Ui.chipSurface, 0.6)

                        Image {
                            id: resultLogo
                            anchors.fill: parent
                            source: resultRow.app.icon ? (resultRow.app.icon.indexOf("http") === 0 ? resultRow.app.icon : "file://" + resultRow.app.icon) : ""
                            // Rendered at the size it is shown: left to its own, an SVG
                            // logo is drawn at hundreds of pixels and shrunk unfiltered
                            sourceSize.width: width
                            sourceSize.height: height
                            layer.enabled: Ui.tintAppIcons
                            layer.effect: TintedIconEffect {}
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            visible: resultLogo.status !== Image.Ready
                            name: "apps"
                            size: 18
                            color: Theme.surfaceVariantText
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingS

                            StyledText {
                                text: resultRow.app.name || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                Layout.maximumWidth: 320
                            }

                            // ODRS star rating
                            RowLayout {
                                visible: !!resultRow.app.rating
                                spacing: 1

                                Repeater {
                                    model: 5

                                    delegate: DankIcon {
                                        required property int index

                                        name: {
                                            const stars = resultRow.app.rating ? resultRow.app.rating.stars : 0;
                                            if (index + 0.75 <= stars)
                                                return "star";
                                            if (index + 0.25 <= stars)
                                                return "star_half";
                                            return "star";
                                        }
                                        filled: resultRow.app.rating && (index + 0.25 <= resultRow.app.rating.stars)
                                        size: 13
                                        color: resultRow.app.rating && (index + 0.25 <= resultRow.app.rating.stars) ? Theme.primary : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
                                    }
                                }

                                StyledText {
                                    text: resultRow.app.rating ? (resultRow.app.rating.stars + " (" + resultRow.app.rating.count + ")") : ""
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: Theme.surfaceVariantText
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: text !== ""
                            // Which Copr a package comes out of is the first
                            // thing to know about it, so it leads the line
                            text: {
                                const summary = resultRow.app.summary || "";
                                const copr = (resultRow.app.sources || []).find(s => s.kind === "copr");
                                if (!copr)
                                    return summary;
                                return summary !== "" ? copr.project + " · " + summary : copr.project;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }

                    DankSpinner {
                        visible: resultRow.busy
                        size: 22
                    }

                    Rectangle {
                        visible: resultRow.installed
                        Layout.preferredWidth: installedChip.implicitWidth + 14
                        Layout.preferredHeight: 20
                        radius: 10
                        color: Theme.withAlpha(Theme.success, 0.15)

                        StyledText {
                            id: installedChip
                            anchors.centerIn: parent
                            text: Tr.t("Installed")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.success
                        }
                    }

                    // One install button per available source — the source
                    // choice when software ships from multiple sources
                    Repeater {
                        // One button when there is one thing it can mean, and
                        // one button when there are several — in that case it
                        // opens the picker instead of guessing. A row of two
                        // buttons is not two actions, it is the same action
                        // with a difference nobody wrote down; the picker is
                        // where that difference is written down.
                        model: {
                            if (resultRow.installed)
                                return [];
                            const sources = resultRow.app.sources || [];
                            return sources.length > 1 ? [null] : sources;
                        }

                        delegate: Rectangle {
                            id: instActionBtn
                            required property var modelData

                            readonly property bool picks: modelData === null
                            property bool isHovered: instActionMa.containsMouse

                            Layout.preferredWidth: instActionRow.implicitWidth + 22
                            Layout.preferredHeight: 28
                            radius: instActionMa.pressed ? (height / 2) : 8
                            Behavior on radius { NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutExpo } }

                            readonly property bool isPrimary: picks || modelData.kind === "flatpak"
                            color: Ui.buttonFill(instActionBtn.isPrimary ? "accent" : "tonal", isHovered)
                            Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }

                            scale: instActionMa.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                            DankRipple {
                                id: instActionRip
                                anchors.fill: parent
                                cornerRadius: parent.radius
                                rippleColor: Ui.buttonInk(instActionBtn.isPrimary ? "accent" : "tonal")
                            }

                            RowLayout {
                                id: instActionRow
                                anchors.centerIn: parent
                                spacing: 4

                                DankIcon {
                                    name: instActionBtn.picks ? "download" : (modelData.kind === "appimage" && !modelData.repo ? "open_in_new" : "download")
                                    size: 13
                                    color: Ui.buttonInk(instActionBtn.isPrimary ? "accent" : "tonal")
                                }

                                StyledText {
                                    text: instActionBtn.picks ? Tr.t("Install") : (modelData.kind === "flatpak" ? "Flathub" : (modelData.kind === "appimage" ? "AppImage" : (modelData.kind === "copr" ? "Copr" : Backend.systemRepoLabel)))
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.weight: Font.Medium
                                    color: Ui.buttonInk(instActionBtn.isPrimary ? "accent" : "tonal")
                                }
                            }

                            MouseArea {
                                id: instActionMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !resultRow.busy && view.busyAction === "" && view.appimageBusy === ""
                                onPressed: (m) => instActionRip.trigger(m.x, m.y)
                                onClicked: {
                                    if (instActionBtn.picks)
                                        view.openSourcePicker(resultRow.app);
                                    else
                                        view.install(modelData, resultRow.app.name, resultRow.app.icon || "");
                                }
                            }
                        }
                    }
                }
            }
        }

        // States: idle hint / searching / no results
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.resultCount === 0 || view.searching

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DankSpinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: view.awaitingResults
                    size: 36
                }

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !view.awaitingResults
                    name: view.searchText.trim().length >= 2 ? "search_off" : "storefront"
                    size: 48
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: {
                        if (view.awaitingResults)
                            return Tr.t("Searching…");
                        if (view.searchMode)
                            return Tr.t("No results for \"%1\"").arg(view.searchText.trim());
                        return Tr.t("Type to search %1 repos and Flathub").arg(Backend.systemRepoLabel);
                    }
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !view.awaitingResults && view.searchText.trim().length < 2
                    text: Tr.t("Ratings by the Open Desktop Ratings Service")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.7)
                }

                // Nothing found is the case the offer was written for, and
                // it is the one case with no result list to sit at the end of
                Loader {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(520, view.width - Theme.spacingXL * 2)
                    // Offering to look elsewhere before this machine has
                    // finished answering is advice given too early
                    active: view.searchMode && !view.awaitingResults && Backend.hasCopr && view.coprFilterWanted
                    visible: active
                    sourceComponent: coprPromptComponent
                }

                // The same offer for brew, in the same place and for the same
                // reason. Nothing found is exactly when a second catalogue is
                // worth mentioning — and with the Homebrew chip selected it is
                // the only thing that could still answer.
                Loader {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(520, view.width - Theme.spacingXL * 2)
                    active: view.searchMode && !view.awaitingResults && view.hasBrew && view.brewFilterWanted
                    visible: active
                    sourceComponent: brewPromptComponent
                }
            }
        }
    }

}
