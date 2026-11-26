import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets

// The run dashboard: an update run as an instrument panel, live while it
// runs and kept afterwards (scripts/edition.py).
//
// Everything on it comes from code over data: the engine's own account of
// the run (timeline, throughput, phases), the advisories, DMS's launcher
// history, what the machine says after the run, and the notes the projects
// and packagers wrote, shown as they wrote them. Sentences are templates in
// the user's language over facts; nothing is generated.
//
// Used by UpdaterWindow only. The widget does not instantiate it, so an
// update in place that adds it does not break the widget (DEVELOPMENT.md).
Item {
    id: dash

    property var engine: null
    property var widgetRoot: null
    // The window: the overview's facts (restSystemRows and the rest), the
    // reclaim card, and the formatting it already does
    property var host: null
    property var store: null
    // Called with a package name to show it in the Installed tab
    property var showInstalled: null
    signal closeRequested
    signal listRequested

    // ── Data ─────────────────────────────────────────────────────────────────
    readonly property bool live: engine !== null && (engine.running || engine.phase === "verifying")
    // Before a run: the updates that are ready, read the same way. A run
    // that has just finished stays on screen until it is closed, and the
    // last run is a press away.
    // A run opened from the log: shown as it was, whatever waits now, until
    // "Back to now"
    property bool reviewing: false
    signal backToNow
    readonly property int pendingCount: widgetRoot && widgetRoot.effectiveCount !== undefined ? widgetRoot.effectiveCount : 0
    // At rest: nothing to install and no run on screen. The last run is
    // shown with what the overview used to say about the system.
    // Just after a run, until its own edition is built: the run as it went,
    // not the edition of the run before it
    readonly property bool settling: {
        if (live || reviewing || !widgetRoot || !engine || widgetRoot.runStartUnix <= 0 || !widgetRoot.previewEdition)
            return false;
        const ed = widgetRoot.latestEdition;
        if (ed && ed.ts >= widgetRoot.runStartUnix - 10)
            return false;
        return engine.phase !== "idle" || pendingCount === 0;
    }
    readonly property bool resting: !live && !reviewing && !settling && engine !== null && engine.phase === "idle" && pendingCount === 0
    readonly property bool checking: SystemUpdateService.isChecking === true
    // A check while nothing runs: the ring shows how far it is, as it does
    // for a run
    // Not over a run that has just finished: its outcome is what the band
    // is for then, and the check after a run is routine
    readonly property bool checkShown: checking && !live && engine !== null && engine.phase === "idle"
    // The ring is also a button: before a run it starts one, at rest it
    // starts a check — what the overview's logo did
    readonly property string ringAction: live || checking || reviewing ? "" : (pending ? "update" : (resting ? "check" : ""))
    readonly property bool pending: !live && !reviewing && engine !== null && engine.phase === "idle" && pendingCount > 0 && widgetRoot !== null && !!widgetRoot.pendingEdition
    // The edition on screen: the one the widget built at the end of a run;
    // while a run goes, the preview built at its start; before one, the
    // reading of what is pending
    readonly property var edition: {
        if (!widgetRoot)
            return null;
        if (live)
            return widgetRoot.previewEdition || null;
        if (reviewing)
            return widgetRoot.latestEdition || null;
        if (settling)
            return widgetRoot.previewEdition;
        if (pending)
            return widgetRoot.pendingEdition || null;
        return widgetRoot.latestEdition || null;
    }
    // The edition's stories, with the user's favourites marked and lifted:
    // a favourite counts as much as an app opened every day
    readonly property var favorites: widgetRoot && widgetRoot.favorites ? widgetRoot.favorites : []
    readonly property var stories: {
        const list = edition && edition.stories ? edition.stories : [];
        const favs = favorites;
        if (!favs.length && !list.length)
            return list;
        const out = list.map(st => {
            if (favs.indexOf(st.id) === -1)
                return st;
            return Object.assign({}, st, {
                fav: true
            });
        });
        // One order for every state of the same run: security first (by
        // severity, then by CVEs), then what touches this system (a running
        // service, the kernel, the desktop), then what you use; a favourite
        // goes first within its group; the edition's rank settles the rest
        const tier = st => {
            const f = st.facts || ({});
            if (cvesOf(st) >= 0)
                return 3;
            if ((f.services || []).length > 0 || f.role === "kernel" || f.role === "desktop")
                return 2;
            return (f.uses || 0) > 0 ? 1 : 0;
        };
        const sev = st => ({ critical: 4, important: 3, high: 3, moderate: 2, medium: 2, low: 1 })[(((st.facts || {}).advisory) || {}).severity] || 0;
        return out.sort((a, b) => tier(b) - tier(a) || (b.fav ? 1 : 0) - (a.fav ? 1 : 0) || sev(b) - sev(a) || Math.max(0, cvesOf(b)) - Math.max(0, cvesOf(a)) || (b.rank || 0) - (a.rank || 0));
    }
    // A story's picture: its own icon, the shell's logo for the shell, or
    // a symbol for its kind when it has none (niri ships no icon)
    function iconFor(st) {
        if (!st)
            return "";
        const icon = st.icon || "";
        if (icon)
            return icon.indexOf("/") === 0 ? "file://" + icon : Quickshell.iconPath(icon, true);
        // The shell, Dux's own projects, and the projects whose icons the
        // plugin carries
        const m = /^system\/(.+)$/.exec(st.id || "");
        const own = m && widgetRoot && typeof widgetRoot.projectIcon === "function" ? widgetRoot.projectIcon(m[1]) : "";
        return own ? "file://" + own : "";
    }
    function tintable(st) {
        const m = /^system\/(.+)$/.exec((st && st.id) || "");
        return !m || !widgetRoot || typeof widgetRoot.iconTintable !== "function" || widgetRoot.iconTintable(m[1]);
    }
    function symbolFor(st) {
        const f = (st && st.facts) || ({});
        if (f.role === "kernel")
            return "memory";
        if (f.role === "desktop")
            return "space_dashboard";
        return Ui.sourceIcon(f.kind === "system" ? "" : f.kind);
    }
    // Shown in "In short" already: the list below keeps them folded
    readonly property var shortSubs: stories.slice(1, 3).filter(x => x.rank >= 10 || cvesOf(x) >= 0)
    readonly property var inShort: stories.slice(0, 1).map(x => x.id).concat(shortSubs.map(x => x.id))
    // "What is new" only when it adds something: every project once more
    // under the few "In short" lifts out, not the same ones twice
    readonly property bool feedShown: stories.length > inShort.length

    // The link under a story's lines, to the ones left out. With nothing
    // shown above it, it offers them, rather than "and 1 routine commit"
    // under a sentence that already counts that very commit
    function moreText(st, picked) {
        if (picked.lines.length === 0) {
            if (st && st.notesFrom === "commits")
                return picked.rest === 1 ? Tr.t("Show the commit") : Tr.t("Show the %1 commits").arg(picked.rest);
            return Tr.t("Show the notes (%1)").arg(picked.rest);
        }
        if (picked.routine === picked.rest)
            return picked.rest === 1 ? Tr.t("and 1 routine commit") : Tr.t("and %1 routine commits").arg(picked.rest);
        return picked.routine > 0 ? Tr.t("and %1 more, %2 of them routine").arg(picked.rest).arg(picked.routine) : Tr.t("and %1 more").arg(picked.rest);
    }
    function storyById(id) {
        return stories.find(st => st.id === id) || null;
    }
    // The lists by id, changed only when the projects in them change: the
    // notes arriving later then fill the cards on screen instead of
    // building them anew
    property var feedIds: []
    property var subIds: []
    function _syncIds() {
        const f = feedStories.map(st => st.id);
        if (f.join("\n") !== feedIds.join("\n"))
            feedIds = f;
        const sub = shortSubs.map(st => st.id);
        if (sub.join("\n") !== subIds.join("\n"))
            subIds = sub;
    }
    onFeedStoriesChanged: _syncIds()
    onShortSubsChanged: _syncIds()

    // The notes are still on their way
    readonly property bool notesLoading: (pending || live) && widgetRoot !== null && widgetRoot.editionNotesLoading === true

    // ── Entrances ──
    // Each card fades in and rises a little, later the further down and to
    // the right it sits, so the page reads top to bottom when it opens, when
    // the state changes and when other projects come in; not when only the
    // notes arrive
    readonly property bool motion: Ui.busyMotion
    property int wave: 0
    property double waveAt: 0
    readonly property string phaseKey: live ? "live" : (pending ? "pending" : (resting ? "rest" : "last"))
    readonly property string storyKey: stories.map(st => st.id + "@" + st.to).join(",")
    onPhaseKeyChanged: waveTimer.restart()
    onStoryKeyChanged: waveTimer.restart()
    Timer {
        id: waveTimer
        interval: 40
        onTriggered: dash.startWave()
    }
    function startWave() {
        waveAt = Date.now();
        wave++;
    }
    // A new card created just after a wave joins it
    function inWave() {
        return Date.now() - waveAt < 900;
    }
    function revealDelay(item) {
        const p = item.mapToItem(dash, 0, 0);
        return Math.round(Math.max(0, Math.min(560, p.y * 0.28 + p.x * 0.05)));
    }
    function reveal(item, anim) {
        anim.stop();
        if (!motion || !item.visible) {
            item.opacity = 1;
            item.rise = 0;
            return;
        }
        // Hidden at once, started once the layout has placed it
        item.opacity = 0;
        Qt.callLater(() => {
            anim.delay = dash.revealDelay(item);
            anim.restart();
        });
    }
    Component.onCompleted: {
        _syncIds();
        startWave();
    }

    // The GitHub repository a story's notes came from ("owner/name"), for
    // the references in them
    function repoOf(st) {
        const m = /github\.com\/([^\/]+\/[^\/#?]+)/.exec((st && (st.notesUrl || st.homepage)) || "");
        return m ? m[1].replace(/\.git$/, "") : "";
    }
    // Where a line of notes points: a URL in it, a CVE, or a pull request
    // or issue of the project ("(#4411)")
    function linkOf(line, repo) {
        let m = /https?:\/\/[^\s)>\]]+/.exec(line);
        if (m)
            return m[0];
        m = /\bCVE-\d{4}-\d{4,}\b/i.exec(line);
        if (m)
            return "https://www.cve.org/CVERecord?id=" + m[0].toUpperCase();
        m = /(?:^|[\s(])#(\d+)\b/.exec(line);
        if (m && repo)
            return "https://github.com/" + repo + "/issues/" + m[1];
        return "";
    }

    // The order of "What is new": relevance, security, size, newest, name
    property string feedOrder: "relevance"
    readonly property var feedStories: {
        const list = stories.slice();
        switch (feedOrder) {
        case "security":
            return list.sort((a, b) => cvesOf(b) - cvesOf(a) || b.rank - a.rank);
        case "size":
            return list.sort((a, b) => storyBytes(b) - storyBytes(a) || b.rank - a.rank);
        case "newest":
            // What the project dated (a release, the last commit); the rest
            // after, by relevance
            return list.sort((a, b) => (b.notesDate || 0) - (a.notesDate || 0) || b.rank - a.rank);
        case "name":
            return list.sort((a, b) => a.name.localeCompare(b.name));
        }
        // Every project is listed; what "In short" already tells stays
        // folded here. Something worth reading first: routine commits alone
        // are not that
        const readable = st => inShort.indexOf(st.id) >= 0 || pickNotes(st, 1).lines.length > 0;
        return list.filter(readable).concat(list.filter(st => !readable(st)));
    }

    function toggleFavorite(id) {
        if (widgetRoot && typeof widgetRoot.toggleFavorite === "function")
            widgetRoot.toggleFavorite(id);
    }

    // How much an app is used, in words rather than a count: the launcher's
    // count is a sample, not a measurement
    function usage(f) {
        const uses = f.uses || 0;
        if (uses <= 0)
            return "";
        const ago = f.lastUsed > 0 ? Date.now() / 1000 - f.lastUsed : 1e9;
        const often = uses >= 10;
        if (often && ago < 36 * 3600)
            return "daily";
        if (often && ago < 7 * 86400)
            return "often";
        if (ago < 7 * 86400)
            return "week";
        if (often)
            return "before";
        return "sometimes";
    }
    function usageWord(f) {
        switch (usage(f)) {
        case "daily":
            return Tr.t("in daily use");
        case "often":
            return Tr.t("in regular use");
        case "week":
            return Tr.t("used this week");
        case "before":
            return Tr.t("used regularly before");
        case "sometimes":
            return Tr.t("in use");
        }
        return "";
    }

    // A version as it reads: without epoch, distribution tag or release,
    // and a git snapshot as its commit count ("git 5861"). The full string
    // is in the tooltip.
    function displayVersion(v) {
        let t = short(v).replace(/-\d+(\.\d+)*$/, "");
        let m = /^(.*?)[.^~+_-]?git[._]?(\d+)(?![0-9a-f])/i.exec(t) || /^(.*?)[.^~+](\d+)\.git[0-9a-f]{6,}/i.exec(t);
        if (m) {
            const base = m[1].replace(/[.^~+_-]+$/, "");
            return (base && !/^0(\.0)*$/.test(base) ? base + " " : "") + "git " + m[2];
        }
        return t;
    }
    readonly property bool hasTimeline: engine !== null && engine.runTimeline !== undefined
    readonly property real elapsed: live ? clock : (settling ? (engine.runElapsed || 0) : (edition ? (edition.duration || 0) : 0))
    readonly property real span: Math.max(10, live ? elapsed * 1.15 + 5 : (settling ? elapsed : (edition ? (edition.duration || 0) : 10)))
    // The time axis' gridlines: a round step, so they slide along as the
    // axis grows instead of being relabelled every frame
    readonly property int tickStep: {
        for (const st of [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600])
            if (span / st <= 5)
                return st;
        return 7200;
    }
    readonly property int tickCount: Math.floor(span / tickStep) + 1

    // The run's clock, read every frame while it runs: the engine reports
    // twice a second, and everything drawn against time follows this one
    // instead, so bars grow and the axes move smoothly
    property real clock: 0
    function _readClock() {
        if (!engine)
            return 0;
        const started = engine._runStartedAt || 0;
        return started > 0 ? (Date.now() - started) / 1000 : (engine.runElapsed || 0);
    }
    FrameAnimation {
        running: dash.live && dash.visible
        onTriggered: dash.clock = dash._readClock()
    }
    onLiveChanged: clock = _readClock()
    // Bytes per second, a sample every rateStep
    readonly property var rate: live || settling ? (engine.runRate || []) : (edition ? (edition.rate || []) : [])
    // Seconds between two of those samples
    readonly property real rateStep: live || settling ? (engine.runRateStep || 0.5) : (edition ? (edition.rateStep || 0.5) : 0.5)
    readonly property var phaseLog: live || settling ? (engine.runPhaseLog || []) : (edition ? (edition.phases || []) : [])
    readonly property var afterChecks: (!live && edition && edition.after) ? (edition.after.checks || []) : []
    property var dismissed: ({})
    property string selected: stories.length > 0 ? stories[0].id : ""

    // The timeline per story: from the edition after the run, from the engine
    // while it runs (a story's span is the span of its packages)
    function storySpans(st) {
        // Just after the run its edition is not there yet: the engine still
        // holds what it measured
        if (!live && !settling) {
            const t = st.t || ({});
            return t.dl || t.inst ? {
                dl: t.dl,
                inst: t.inst,
                work: null
            } : t;
        }
        const tl = engine.runTimeline || ({});
        const spans = {
            dl: null,
            inst: null,
            work: null
        };
        const keys = st.id.indexOf("system/") === 0 ? st.packages.map(n => "system/" + n) : [st.id];
        function widen(name, a, b) {
            for (const k of keys) {
                const e = tl[k];
                if (!e || e[a] === undefined)
                    continue;
                const cur = spans[name] || [e[a], e[b] !== undefined ? e[b] : null];
                cur[0] = Math.min(cur[0], e[a]);
                if (e[b] !== undefined)
                    cur[1] = Math.max(cur[1] || 0, e[b]);
                spans[name] = cur;
            }
        }
        widen("dl", "d0", "d1");
        widen("inst", "i0", "i1");
        // The generic "worked on" span is for passes without phases; a
        // package the helper reported phases for has those instead
        if (!spans.dl && !spans.inst)
            widen("work", "w0", "w1");
        return spans;
    }

    // "done", "active", "error" or "pending" for a story right now
    function storyState(st) {
        if (pending)
            return "pending";
        if (!live && !settling)
            return st.status === "error" ? "error" : "done";
        const states = engine.itemStates || ({});
        const keys = st.id.indexOf("system/") === 0 ? st.packages.map(n => "system/" + n) : [st.id];
        let done = 0, err = 0, active = 0, n = 0;
        for (const k of keys) {
            const s = states[k];
            if (!s)
                continue;
            n++;
            if (s.status === "done")
                done++;
            else if (s.status === "error")
                err++;
            else if (s.status === "active")
                active++;
        }
        if (n === 0)
            return "pending";
        if (err === n)
            return "error";
        if (done + err === n)
            return "done";
        return active > 0 || done > 0 ? "active" : "pending";
    }

    // "#rrggbb" at an alpha, as a CSS colour the canvas takes
    function withAlpha(hex, a) {
        const n = parseInt(String(hex).slice(1).slice(-6), 16);
        return "rgba(" + ((n >> 16) & 255) + "," + ((n >> 8) & 255) + "," + (n & 255) + "," + a + ")";
    }

    function fmtTime(s) {
        s = Math.max(0, Math.round(s || 0));
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }
    function mbps(bytesPerSecond) {
        const v = (bytesPerSecond || 0) / 1e6;
        return v < 10 ? v.toLocaleString(Qt.locale(), "f", 1) : Math.round(v).toString();
    }
    function bytes(n) {
        return engine ? engine.formatBytes(n || 0) : String(n);
    }
    function short(v) {
        return (v || "").replace(/^\d+:/, "").replace(/\.(fc|el)\d+.*$/, "");
    }

    // The facts of a story as short phrases, in the order they matter
    function factPhrases(st) {
        const f = st.facts || ({});
        const out = [];
        if (f.failedAll)
            out.push(Tr.t("not installed"));
        const adv = f.advisory;
        if (adv && adv.type === "security") {
            const n = f.cves !== undefined ? f.cves : (adv.ids || []).filter(i => i.toUpperCase().indexOf("CVE-") === 0).length;
            out.push(n > 0 ? (n === 1 ? Tr.t("1 CVE") : Tr.t("%1 CVEs").arg(n)) : Tr.t("security update"));
            if (adv.severity)
                out.push(severityLabel(adv.severity));
        } else if (adv && adv.type === "bugfix") {
            out.push(Tr.t("bug fix"));
        } else if (adv && adv.type === "enhancement") {
            out.push(Tr.t("enhancement"));
        }
        if (f.role === "kernel")
            out.push(Tr.t("kernel"));
        else if (f.role === "desktop")
            out.push(Tr.t("your desktop"));
        for (const u of (f.services || []))
            out.push(Tr.t("%1 is running").arg(u.replace(/\.service$/, "")));
        if (st.fav)
            out.unshift(Tr.t("favorite"));
        if (f.uses > 0)
            out.push(usageWord(f));
        if (f.jump === "major")
            out.push(Tr.t("major version"));
        if (f.jump === "git" && f.commits > 0)
            out.push(f.commits === 1 ? Tr.t("1 commit") : Tr.t("%1 commits").arg(f.commits));
        if (st.routine)
            out.push(Tr.t("updated often"));
        return out;
    }

    // ── In words ─────────────────────────────────────────────────────────────
    // What a run is going to do, is doing, or did, told in sentences: each a
    // template in the user's language over the facts, the notes quoted as
    // their authors wrote them. Tense-free on purpose, so the same sentence
    // holds before, during and after the run.
    function cap(t) {
        return t ? t.charAt(0).toUpperCase() + t.slice(1) : t;
    }
    // A story's CVEs, -1 when it is not about security. The advisory's, or
    // the ones its notes name: the same count the figure at the top adds
    // up, so the card and the figure never disagree.
    function cvesOf(st) {
        const f = st.facts || ({});
        const adv = f.advisory;
        if (adv && adv.type === "security")
            return f.cves !== undefined ? f.cves : (adv.ids || []).filter(i => i.toUpperCase().indexOf("CVE-") === 0).length;
        if ((f.cves || 0) > 0)
            return f.cves;
        if ((st.noteCves || []).length > 0)
            return st.noteCves.length;
        return -1;
    }
    function headline(st) {
        const f = st.facts || ({});
        const to = displayVersion(st.to);
        if (f.failedAll && !pending && !live)
            return Tr.t("%1 was not updated").arg(st.name);
        const n = cvesOf(st);
        if (n > 0)
            return n === 1 ? Tr.t("%1 %2 closes a vulnerability").arg(st.name).arg(to) : Tr.t("%1 %2 closes %3 vulnerabilities").arg(st.name).arg(to).arg(n);
        if (n === 0)
            return Tr.t("Security update for %1").arg(st.name);
        if (f.role === "kernel")
            return Tr.t("New kernel: %1").arg(to);
        if (f.role === "desktop" && f.commits > 0)
            return Tr.t("New build of %1, your desktop: %2 commits").arg(st.name).arg(f.commits);
        if (f.jump === "major")
            return Tr.t("%1 goes to version %2").arg(st.name).arg(to);
        // The kicker says how it is used; the headline says what it is
        if (f.uses > 0)
            return f.jump === "git" ? Tr.t("New build of %1").arg(st.name) : Tr.t("New version of %1: %2").arg(st.name).arg(to);
        return st.name + " " + displayVersion(st.to);
    }
    function kicker(st) {
        const k = _kicker(st);
        return st.fav ? "★ " + Tr.t("Favorite") + (k ? " · " + k : "") : k;
    }
    function _kicker(st) {
        const f = st.facts || ({});
        const adv = f.advisory;
        if (adv && adv.type === "security")
            return cap(Tr.t("security update")) + (adv.severity ? " · " + severityLabel(adv.severity) : "");
        if (f.role === "kernel")
            return cap(Tr.t("kernel"));
        if (f.role === "desktop")
            return cap(Tr.t("your desktop"));
        if ((f.services || []).length)
            return cap(Tr.t("%1 is running").arg(f.services[0].replace(/\.service$/, "")));
        if (f.uses > 0)
            return cap(usageWord(f));
        if (f.jump === "major")
            return cap(Tr.t("major version"));
        return "";
    }
    // A few sentences on what this means here
    function story(st) {
        const f = st.facts || ({});
        const out = [];
        const from = displayVersion(st.from), to = displayVersion(st.to);
        // The headline already counts a desktop build's commits
        if (f.jump === "git" && f.role === "desktop" && f.commits > 0) {
            // nothing to add
        } else if (f.jump === "git")
            out.push(f.commits > 0 ? (f.commits === 1 ? Tr.t("One commit since the previous build.") : Tr.t("%1 commits since the previous build.").arg(f.commits)) : Tr.t("A new build from the project's repository."));
        else if (f.jump === "major")
            out.push(Tr.t("A new major version: from %1 to %2.").arg(from).arg(to));
        else if (from && to)
            out.push(Tr.t("From %1 to %2.").arg(from).arg(to));
        const n = cvesOf(st);
        if (n > 0)
            out.push(n === 1 ? Tr.t("It fixes a known vulnerability, rated %1.").arg(severityLabel(f.advisory.severity || "")) : Tr.t("It fixes %1 known vulnerabilities, rated %2.").arg(n).arg(severityLabel(f.advisory.severity || "")));
        else if (n === 0)
            out.push(Tr.t("The distribution marks it as a security update, rated %1.").arg(severityLabel(f.advisory.severity || "")));
        if (f.role === "kernel")
            out.push(Tr.t("The new kernel is used after a restart."));
        else if (f.role === "desktop")
            out.push(Tr.t("It is part of your desktop."));
        const units = (f.services || []).map(u => u.replace(/\.service$/, ""));
        if (units.length)
            out.push(Tr.t("%1 runs on this system, so this concerns you directly.").arg(units.join(", ")));
        switch (usage(f)) {
        case "daily":
            out.push(Tr.t("You use it every day."));
            break;
        case "often":
            out.push(Tr.t("You use it regularly."));
            break;
        case "week":
            out.push(Tr.t("You used it this week."));
            break;
        case "before":
            out.push(Tr.t("You used it regularly before."));
            break;
        case "sometimes":
            out.push(Tr.t("It is one of the apps you use."));
            break;
        }
        if (f.uses > 0) {
            // said above
        }
        else if ((f.desktopIds || []).length > 0 && f.uses === 0)
            out.push(Tr.t("You have not opened it via the launcher."));
        if (st.routine)
            out.push(Tr.t("A routine build: it came along in recent runs too."));
        if (f.failed > 0 && !pending && !live)
            out.push(f.failedAll ? Tr.t("It was not installed.") : Tr.t("Part of it was not installed."));
        return out.join(" ");
    }
    // The labels of a story, each said once
    function chipsOf(st) {
        const f = st.facts || ({});
        const out = [];
        if (st.fav)
            out.push({ text: "★ " + Tr.t("favorite"), tone: "accent" });
        // One form for security: the severity here, the count in the sentence
        if (cvesOf(st) >= 0) {
            const sev = f.advisory && f.advisory.severity ? severityLabel(f.advisory.severity) : "";
            out.push({ text: Tr.t("security") + (sev ? " · " + sev : ""), tone: "error" });
        }
        if (f.role === "kernel")
            out.push({ text: Tr.t("kernel"), tone: "system" });
        else if (f.role === "desktop")
            out.push({ text: Tr.t("your desktop"), tone: "system" });
        for (const u of f.services || [])
            out.push({ text: Tr.t("%1 is running").arg(u.replace(/\.service$/, "")), tone: "system" });
        if (f.uses > 0)
            out.push({ text: usageWord(f), tone: "plain" });
        if (f.jump === "major")
            out.push({ text: Tr.t("major version"), tone: "plain" });
        if (st.routine)
            out.push({ text: Tr.t("updated often"), tone: "plain" });
        if (f.failedAll && !pending && !live)
            out.push({ text: Tr.t("not installed"), tone: "error" });
        return out;
    }
    // The one sentence that says what this means here: the weightiest fact
    function consequence(st) {
        const f = st.facts || ({});
        if (f.failed > 0 && !pending && !live)
            return f.failedAll ? Tr.t("It was not installed.") : Tr.t("Part of it was not installed.");
        const n = cvesOf(st);
        if (n > 0)
            return n === 1 ? Tr.t("It fixes a known vulnerability.") : Tr.t("It fixes %1 known vulnerabilities.").arg(n);
        if (n === 0)
            return Tr.t("The distribution marks it as a security update.");
        const units = (f.services || []).map(u => u.replace(/\.service$/, ""));
        if (units.length)
            return units.length === 1 ? Tr.t("%1 runs on this system.").arg(units[0]) : Tr.t("%1 run on this system.").arg(units.join(", "));
        if (f.role === "kernel")
            return Tr.t("The core of the system.");
        if (/^system\/(dms|quickshell)$/.test(st.id))
            return Tr.t("Your shell: the bar, the launcher, the notifications.");
        if (f.role === "desktop")
            return Tr.t("Your compositor: it draws and arranges every window.");
        switch (usage(f)) {
        case "daily":
            return Tr.t("You use it every day.");
        case "often":
            return Tr.t("You use it regularly.");
        case "week":
            return Tr.t("You used it this week.");
        case "before":
            return Tr.t("You used it regularly before.");
        case "sometimes":
            return Tr.t("It is one of the apps you use.");
        }
        if (f.jump === "git" && f.commits > 0)
            return f.commits === 1 ? Tr.t("One commit since the previous build.") : Tr.t("%1 commits since the previous build.").arg(f.commits);
        if (f.jump === "major")
            return Tr.t("A new major version.");
        return "";
    }
    // Commits that change nothing a user meets: build and CI plumbing,
    // version bumps, translation syncs, merges
    function routineNote(line) {
        return /^(ci|chore|build|nix|bump|test|tests|style|docs?|refactor)(\([^)]*\))?!?:/i.test(line) || /^(merge|bump|revert "?bump)\b/i.test(line) || /vendorHash|flake\.lock|\bi18n: sync\b|translations? (sync|update)/i.test(line);
    }
    // At most `max` lines worth reading, features and fixes first, with
    // their links; and how many were left out, and how many of those were
    // routine
    // A quoted line without what is not news: a trailing URL, the authors
    // in brackets, "(Changelog for …)"; a line that is only a heading goes
    function cleanNote(line) {
        return line.replace(/\s*https?:\/\/\S+/g, "").replace(/\s*\[[^\]]*\]\s*$/, "").replace(/\s*\(Changelog for [^)]*\)\s*$/i, "").trim();
    }
    function pickNotes(st, max) {
        const lines = st ? st.notes || [] : [], links = st ? st.noteLinks || [] : [];
        const items = lines.map((l, i) => ({ l: cleanNote(l), k: links[i] || linkOf(l, repoOf(st)), i: i })).filter(x => x.l.length > 0 && !/^\w+:?$/.test(x.l));
        const commits = st && st.notesFrom === "commits";
        const keep = commits ? items.filter(x => !routineNote(x.l)) : items;
        const rank = x => /^feat/i.test(x.l) ? 0 : (/^fix/i.test(x.l) ? 1 : 2);
        const ordered = commits ? keep.slice().sort((a, b) => rank(a) - rank(b) || a.i - b.i) : keep;
        const shown = ordered.slice(0, max);
        return { lines: shown.map(x => x.l), links: shown.map(x => x.k), rest: lines.length - shown.length, routine: Math.min(lines.length - shown.length, items.length - keep.length) };
    }

    // Who wrote the notes below a story
    function notesBy(st) {
        switch (st.notesFrom) {
        case "appstream":
        case "release":
            return Tr.t("The project writes:");
        case "commits":
            return Tr.t("The commits say:");
        case "changelog":
            return Tr.t("The packager writes:");
        }
        return "";
    }
    // The whole run in one or two sentences
    function deck() {
        if (!edition)
            return "";
        const n = live ? totalPackages : (pending ? pendingCount : edition.totals.packages);
        const p = stories.length;
        let head;
        if (pending)
            head = n === 1 ? Tr.t("1 update is ready.") : (p === 1 ? Tr.t("%1 updates in 1 project are ready.").arg(n) : Tr.t("%1 updates in %2 projects are ready.").arg(n).arg(p));
        else if (live)
            head = Tr.t("Updating %1 packages in %2 projects.").arg(n).arg(p);
        else
            head = Tr.t("The last run updated %1 packages in %2 projects, %3.").arg(n).arg(p).arg(when(edition.ts));
        const parts = [];
        const sec = stories.filter(st => cvesOf(st) >= 0).length;
        if (sec > 0)
            parts.push(totalCves > 0 ? (sec === 1 ? Tr.t("1 security update closing %1 vulnerabilities").arg(totalCves) : Tr.t("%1 security updates closing %2 vulnerabilities").arg(sec).arg(totalCves)) : (sec === 1 ? Tr.t("1 security update") : Tr.t("%1 security updates").arg(sec)));
        if (stories.some(st => (st.facts || {}).role === "kernel"))
            parts.push(Tr.t("a new kernel"));
        const desk = stories.filter(st => (st.facts || {}).role === "desktop").length;
        if (desk > 0)
            parts.push(Tr.t("%1 for your desktop").arg(desk));
        const used = stories.filter(st => ((st.facts || {}).uses || 0) > 0).length;
        if (used > 0)
            parts.push(used === 1 ? Tr.t("1 app you use") : Tr.t("%1 apps you use").arg(used));
        const major = stories.filter(st => (st.facts || {}).jump === "major").length;
        if (major > 0)
            parts.push(major === 1 ? Tr.t("1 major version") : Tr.t("%1 major versions").arg(major));
        let out = head;
        if (parts.length)
            out += " " + Tr.t("Among them: %1.").arg(parts.join(", "));
        const failed = !live && !pending ? failedTotal : 0;
        if (failed > 0)
            out += " " + (failed === 1 ? Tr.t("1 package failed.") : Tr.t("%1 packages failed.").arg(failed));
        return out;
    }
    // The status line at rest, as the overview's card had it
    function restLine() {
        if (checking)
            return Tr.t("Checking for updates…");
        if (SystemUpdateService.hasError)
            return Tr.t("Check failed");
        const parts = [];
        if (host && host.lastUpdateUnix > 0)
            parts.push(Tr.t("updated %1").arg(when(host.lastUpdateUnix)));
        const next = host ? host.formatIn(SystemUpdateService.nextCheckUnix) : "";
        if (next)
            parts.push(Tr.t("next check %1").arg(next));
        // What the overview's tiles said, only when there is something
        for (const r of host ? host.restStatusRows() : []) {
            if (r.label === Tr.t("Held") && Number(r.value) > 0)
                parts.push(Tr.t("%1 held").arg(r.value));
            if (r.label === "End-of-life" && Number(r.value) > 0)
                parts.push(Tr.t("%1 at end of life").arg(r.value));
            if (r.label === Tr.t("Automatic updates"))
                parts.push(Tr.t("automatically: %1").arg(r.value.toLowerCase()));
        }
        return parts.join(" · ");
    }

    // ── The band ─────────────────────────────────────────────────────────────
    // A moment as people say it: "today 10:11", "yesterday 21:47", a date
    function when(ts) {
        if (!ts)
            return "";
        const d = new Date(ts * 1000), now = new Date();
        const day = x => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
        const time = d.toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
        const diff = Math.round((day(now) - day(d)) / 86400000);
        if (diff === 0)
            return Tr.t("today %1").arg(time);
        if (diff === 1)
            return Tr.t("yesterday %1").arg(time);
        return d.toLocaleString(Qt.locale(), Locale.ShortFormat);
    }
    // While a run goes: how long it still takes, from how far it is, or
    // before that from how long runs take here; -1 when there is no telling
    readonly property real remaining: {
        if (!live || !engine)
            return -1;
        const frac = engine.overallFraction || 0;
        if (frac > 0.05)
            return Math.max(0, elapsed * (1 - frac) / frac);
        const est = widgetRoot && typeof widgetRoot.estimateRunSeconds === "function" ? widgetRoot.estimateRunSeconds(totalPackages) : -1;
        return est > 0 ? Math.max(0, est - elapsed) : -1;
    }
    // What a run will ask of the user afterwards, foreseen from the stories:
    // a restart for a kernel, logging in again for the desktop, the shell
    // restarting for the shell, a service restarting for a service
    function predictions() {
        const out = [];
        for (const st of stories) {
            const f = st.facts || ({});
            if (f.role === "kernel")
                out.push({ kind: "reboot", story: st.id, text: Tr.t("Restart to use the new kernel") });
            else if (/^system\/(dms|quickshell)$/.test(st.id))
                out.push({ kind: "shell", story: st.id, text: Tr.t("The shell restarts to use the new %1").arg(st.name) });
            else if (f.role === "desktop")
                out.push({ kind: "relogin", story: st.id, text: Tr.t("Log out and back in to use the new %1").arg(st.name) });
            for (const u of f.services || [])
                out.push({ kind: "service", story: st.id, unit: u, text: Tr.t("%1 uses the new version once it restarts").arg(u.replace(/\.service$/, "")) });
        }
        // The same order in every state: the weightiest first
        const order = { reboot: 0, relogin: 1, shell: 2, service: 3 };
        out.sort((a, b) => order[a.kind] - order[b.kind] || a.text.localeCompare(b.text));
        if (!out.some(x => x.kind === "reboot"))
            out.push({ kind: "calm", text: Tr.t("No restart of the computer needed") });
        return out;
    }
    // The apps the last run found on their old version, still running now
    // (looked up again: a restart or a reboot since settles them)
    readonly property var lastStale: {
        const ed = pending && widgetRoot ? widgetRoot.latestEdition : null;
        return ed && ed.after ? (ed.after.checks || []).filter(c => c.kind === "stale" && c.role !== "desktop" && (c.pids || []).length > 0).map(c => {
            const st = (ed.stories || []).find(x => x.id === c.story) || {};
            return {
                id: c.story,
                name: st.name || "",
                pids: c.pids,
                shell: /^system\/(dms|quickshell)$/.test(c.story || ""),
                desktopId: ((st.facts || {}).desktopIds || [])[0] || ""
            };
        }).filter(c => c.name !== "") : [];
    }
    // What the last run left to do that still waits, each with its action:
    // shown apart from what these updates will ask
    readonly property var carried: {
        const out = [];
        if (pending && widgetRoot && widgetRoot.rebootRecommended === true)
            out.push({ kind: "reboot", text: Tr.t("Restart the computer to finish the last run") });
        for (const c of aliveStale)
            out.push(Object.assign({ kind: "stale", text: Tr.t("%1 still runs its old version").arg(c.name) }, c));
        return out.filter(c => !dismissed["carried/" + c.kind + "/" + (c.id || "")]);
    }
    property var aliveStale: []
    onLastStaleChanged: probeStale()
    onPendingChanged: probeStale()
    function probeStale() {
        const pids = [].concat.apply([], lastStale.map(c => c.pids));
        if (!pending || pids.length === 0) {
            aliveStale = [];
            return;
        }
        staleProbe.command = ["ps", "-o", "pid=", "-p", pids.join(",")];
        staleProbe.running = true;
    }
    Process {
        id: staleProbe
        stdout: StdioCollector {
            onStreamFinished: {
                const alive = new Set(text.split(/\s+/).filter(x => x).map(Number));
                dash.aliveStale = dash.lastStale.filter(c => c.pids.some(p => alive.has(Number(p))));
            }
        }
    }
    readonly property bool checked: !live && edition !== null && edition.after !== null && edition.after !== undefined
    function tileSecurity() {
        const sec = stories.filter(st => cvesOf(st) >= 0);
        const n = totalCves;
        const names = sec.map(st => st.name + (cvesOf(st) > 0 ? " (" + cvesOf(st) + ")" : "")).join(", ");
        if (sec.length === 0)
            return { value: Tr.t("none"), label: Tr.t("security"), hint: Tr.t("No security fixes in these updates.") };
        if (live)
            return { value: n > 0 ? closedCves + " / " + n : String(sec.length), label: n > 0 ? Tr.t("vulnerabilities closed") : Tr.t("security updates"), hint: names };
        if (pending)
            return { value: n > 0 ? String(n) : String(sec.length), label: n > 0 ? Tr.t("vulnerabilities to close") : Tr.t("security updates"), hint: names };
        return { value: n > 0 ? String(n) : String(sec.length), label: n > 0 ? Tr.t("vulnerabilities closed") : Tr.t("security updates"), hint: names };
    }
    function tileTouches() {
        const names = [], lines = [];
        for (const st of stories) {
            const f = st.facts || ({});
            if (f.role === "kernel") {
                names.push(Tr.t("kernel"));
                lines.push(Tr.t("The kernel"));
            } else if (f.role === "desktop") {
                names.push(st.name);
                lines.push(Tr.t("%1, part of your desktop").arg(st.name));
            }
            for (const u of f.services || []) {
                const unit = u.replace(/\.service$/, "");
                names.push(unit);
                lines.push(Tr.t("%1, running on this system").arg(unit));
            }
        }
        const used = stories.filter(st => ((st.facts || {}).uses || 0) > 0);
        for (const st of used)
            lines.push(Tr.t("%1, an app you use").arg(st.name));
        if (!names.length && used.length)
            names.push(used.length === 1 ? used[0].name : Tr.t("%1 apps you use").arg(used.length));
        const shown = names.slice(0, 2).join(", ") + (names.length > 2 ? " +" + (names.length - 2) : "");
        return { value: shown || "—", hint: lines.length ? lines.join("\n") : Tr.t("Nothing that runs here or that you use.") };
    }
    function tileAfter() {
        if (checked) {
            const reboot = afterChecks.find(c => c.kind === "reboot");
            const stale = afterChecks.filter(c => c.kind === "stale");
            const names = stale.map(c => (stories.find(s => s.id === c.story) || {}).name || "").filter(x => x);
            if (reboot && reboot.needed)
                return { value: Tr.t("restart"), label: Tr.t("after this run"), hint: Tr.t("Something the system runs on was updated.") };
            if (stale.length)
                return { value: Tr.t("%1 to restart").arg(stale.length), label: Tr.t("still on the old version"), hint: names.join(", ") };
            return { value: Tr.t("nothing"), label: Tr.t("left to do"), hint: Tr.t("No restart, no app on an old version.") };
        }
        let pr = predictions().filter(x => x.kind !== "calm");
        const hint = pr.length ? pr.map(x => x.text).join("\n") : Tr.t("Nothing asks for a restart or for logging in again.");
        let value = Tr.t("nothing");
        pr = pr.filter(x => x.kind !== "calm");
        if (pr.some(x => x.kind === "reboot"))
            value = Tr.t("restart");
        else if (pr.some(x => x.kind === "relogin"))
            value = Tr.t("log in again");
        else if (pr.some(x => x.kind === "shell"))
            value = Tr.t("shell restarts");
        else if (pr.some(x => x.kind === "service"))
            value = Tr.t("service restart");
        return { value: value, label: live || pending ? Tr.t("after the update") : Tr.t("after this run"), hint: hint };
    }
    function tileSize() {
        if (resting) {
            if (!edition)
                return { value: "–", label: Tr.t("last run"), hint: "" };
            const measured = totalBytes > 0 && elapsed > 0;
            return {
                value: measured ? bytes(totalBytes) : (edition.totals.packages === 1 ? Tr.t("1 package") : Tr.t("%1 packages").arg(edition.totals.packages)),
                label: measured ? Tr.t("last run, in %1").arg(fmtTime(elapsed)) : Tr.t("last run, %1").arg(when(edition.ts)),
                hint: measured ? Tr.t("Downloaded; the line is the speed over the run.") : ""
            };
        }
        if (pending) {
            const parts = [];
            if (estimateSeconds > 0)
                parts.push("≈ " + engine.formatDuration(estimateSeconds));
            if (diskText())
                parts.push(diskText());
            const unsized = stories.filter(st => storyBytes(st) <= 0).length;
            const hint = [plan ? Tr.t("What the package manager will download for the system packages, after what is in its cache and what arrives as a delta.") : Tr.t("An upper bound: packages already in the download cache, and the parts a Flatpak shares with what is installed, are not downloaded again.")];
            if (unsized > 0)
                hint.push(unsized === 1 ? Tr.t("1 update has no known size beforehand and is not counted; Flatpak often only knows once it downloads.") : Tr.t("%1 updates have no known size beforehand and are not counted; Flatpak often only knows once it downloads.").arg(unsized));
            return { value: downloadText, label: parts.length ? parts.join(" · ") : Tr.t("to download"), hint: hint.join(" ") };
        }
        const now = rate.length ? rate[rate.length - 1] : 0;
        return {
            value: bytes(totalBytes),
            label: live ? mbps(now) + " MB/s · " + Tr.t("peak %1 MB/s").arg(mbps(peakRate)) : Tr.t("in %1").arg(fmtTime(elapsed)),
            hint: Tr.t("Downloaded; the line is the speed over the run.")
        };
    }
    // What follows, in a few words: from the checks after a run, foreseen
    // from the stories before and during one
    function followPhrase() {
        if (checked) {
            const reboot = afterChecks.find(c => c.kind === "reboot");
            const stale = afterChecks.filter(c => c.kind === "stale").map(c => (stories.find(x => x.id === c.story) || {}).name || "").filter(x => x);
            if (reboot && reboot.needed)
                return Tr.t("Restart the computer to finish.");
            if (stale.length)
                return Tr.t("Still on the old version: %1.").arg(stale.join(", "));
            return Tr.t("Nothing left to do.");
        }
        const pr = predictions();
        const name = kind => (stories.find(x => x.id === (pr.find(p => p.kind === kind) || {}).story) || {}).name || "";
        if (pr.some(x => x.kind === "reboot"))
            return Tr.t("Afterwards, restart the computer.");
        if (pr.some(x => x.kind === "relogin"))
            return Tr.t("Afterwards, log in again for %1.").arg(name("relogin"));
        if (pr.some(x => x.kind === "shell"))
            return Tr.t("Afterwards the shell restarts.");
        return Tr.t("Nothing to do afterwards.");
    }
    // The line beside the button: a conclusion in plain words, not the
    // figures again
    function bandLine() {
        if (checkShown)
            return Tr.t("Checking for updates…");
        if (live)
            return engine.phaseLabel.replace(/…$/, "") + " · " + Tr.t("%1 of %2").arg(installedPackages).arg(totalPackages);
        if (pending) {
            // How urgent: the worst severity among what is ready
            const rank = { critical: 3, important: 2, high: 2, moderate: 1, medium: 1, low: 0 };
            let worst = -1;
            for (const st of stories) {
                const adv = (st.facts || {}).advisory;
                if (cvesOf(st) >= 0)
                    worst = Math.max(worst, adv && adv.severity in rank ? rank[adv.severity] : 0);
            }
            const judgement = worst >= 3 ? Tr.t("Worth installing soon: it fixes a critical vulnerability.") : (worst === 2 ? Tr.t("Worth installing soon: it fixes an important vulnerability.") : (worst >= 0 ? Tr.t("Security fixes, none urgent.") : Tr.t("Nothing urgent.")));
            const extra = planLine();
            return judgement + (extra ? " " + extra : "");
        }
        if (resting)
            return restLine();
        if (!edition)
            return "";
        const failedNames = stories.filter(st => storyState(st) === "error").map(st => st.name);
        return failedTotal > 0 ? Tr.t("Finished, but not everything was installed: %1.").arg(failedNames.join(", ")) : Tr.t("Finished without errors.");
    }
    function severityLabel(sev) {
        switch (sev) {
        case "critical":
            return Tr.t("critical");
        case "important":
        case "high":
            return Tr.t("important");
        case "moderate":
        case "medium":
            return Tr.t("moderate");
        case "low":
            return Tr.t("low");
        }
        return sev;
    }
    function severityColor(sev) {
        if (sev === "critical" || sev === "important" || sev === "high")
            return Ui.failColor;
        return Theme.warning;
    }

    // Chart colours, all from the theme: the accent for downloading; for
    // installing the theme's tertiary when its hue is far enough from the
    // accent to tell apart (Material's secondary seldom is), else the
    // accent a step towards the background (a lighter one stood out white);
    // the rest in the quiet text colour.
    function _hueApart(a, b) {
        if (a.hslSaturation < 0.25 || b.hslSaturation < 0.25)
            return false;
        const d = Math.abs(a.hslHue - b.hslHue);
        return Math.min(d, 1 - d) >= 0.12;
    }
    readonly property var series: [String(Theme.primary), _hueApart(Theme.primary, Theme.tertiary) ? String(Theme.tertiary) : (_hueApart(Theme.primary, Theme.secondary) ? String(Theme.secondary) : String(Theme.withAlpha(Theme.surfaceText, 0.6))), String(Theme.withAlpha(Theme.surfaceVariantText, 0.5))]

    // An app still running its old program: closed (TERM to the processes
    // the check found) and opened again from its desktop entry
    function restartApp(pids, desktopId) {
        const ids = (pids || []).map(String).filter(x => /^\d+$/.test(x));
        const app = (desktopId || "").replace(/\.desktop$/, "");
        if (!ids.length || !/^[A-Za-z0-9._-]+$/.test(app))
            return;
        Quickshell.execDetached(["sh", "-c", "kill -TERM \"$@\" 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 \"$@\" 2>/dev/null || break; sleep 0.3; done; exec gtk-launch \"$0\"", app].concat(ids));
    }

    // ── Totals ───────────────────────────────────────────────────────────────
    readonly property int totalPackages: live ? (engine.plannedCount || 0) : (edition ? edition.totals.packages : 0)
    readonly property int installedPackages: live || settling ? (engine.completedCount || 0) : (edition ? edition.totals.packages - edition.totals.failed : 0)
    // What failed: the engine's count until the run's edition says it
    readonly property int failedTotal: settling ? (engine.failedCount || 0) : (edition ? edition.totals.failed || 0 : 0)
    readonly property int totalCves: edition ? (edition.totals.cves || 0) : 0
    readonly property int closedCves: {
        let n = 0;
        for (const st of stories) {
            const adv = (st.facts || {}).advisory;
            if (!adv || adv.type !== "security")
                continue;
            if (storyState(st) === "done")
                n += st.facts.cves !== undefined ? st.facts.cves : (adv.ids || []).filter(i => i.toUpperCase().indexOf("CVE-") === 0).length;
        }
        return n;
    }
    readonly property real totalBytes: {
        let sum = 0;
        for (const r of rate)
            sum += r * rateStep;
        return sum;
    }
    // What the run is to download: the resolver's estimate, or what the
    // stories add up to
    readonly property real plannedBytes: {
        const est = widgetRoot && widgetRoot.updateSizes ? (widgetRoot.updateSizes.totalBytes || 0) : 0;
        return est > 0 ? est : stories.reduce((n, st) => n + storyBytes(st), 0);
    }
    // A story's download: what the edition knew, or what the resolver has
    // said since, which can arrive after the edition was read
    function storyBytes(st) {
        // The resolver's figure first: what is really downloaded, the same
        // unit as the total at the top
        const ops = plan && plan.opBytes ? plan.opBytes : null;
        if (ops && (st.packages || []).some(p => ops[p] !== undefined))
            return (st.packages || []).reduce((n, p) => n + (ops[p] || 0), 0);
        if (st.bytes > 0)
            return st.bytes;
        const sizes = widgetRoot && widgetRoot.updateSizes ? (widgetRoot.updateSizes.rpmSizes || {}) : {};
        return (st.packages || []).reduce((n, p) => n + (sizes[p] || 0), 0);
    }
    // What the resolver will really do with the system packages, once it
    // has said: the download after cache and deltas, the room on disk,
    // dependencies, removals. The figure above, without it, is a bound.
    readonly property var plan: engine && engine.previewPlan ? engine.previewPlan : null
    readonly property string downloadText: plan ? bytes(plan.downloadBytes) : (widgetRoot && widgetRoot.updateSizeText ? widgetRoot.updateSizeText : "–")
    readonly property real estimateSeconds: widgetRoot && typeof widgetRoot.estimateRunSeconds === "function" ? widgetRoot.estimateRunSeconds(plan ? plan.total : pendingCount) : -1
    // Room on disk, beside the download it comes with
    function diskText() {
        if (!plan || !plan.diskDeltaBytes)
            return "";
        return plan.diskDeltaBytes > 0 ? Tr.t("+%1 on disk").arg(bytes(plan.diskDeltaBytes)) : Tr.t("frees %1").arg(bytes(-plan.diskDeltaBytes));
    }
    // The plan's other news, for the status line
    function planLine() {
        if (!plan)
            return "";
        const parts = [];
        if (plan.extra > 0)
            parts.push(Tr.t("%1 pulled in as dependencies").arg(plan.extra));
        if (plan.removals > 0)
            parts.push(Tr.t("%1 will be removed: %2").arg(plan.removals).arg((plan.removedNames || []).slice(0, 3).join(", ")));
        return parts.join(" · ");
    }
    readonly property int doneStories: live ? stories.filter(st => storyState(st) === "done").length : 0
    readonly property real peakRate: rate.length ? Math.max.apply(null, rate) : 0
    readonly property int staleApps: afterChecks.filter(c => c.kind === "stale").length

    // ── Layout ───────────────────────────────────────────────────────────────
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: grid.implicitHeight + Theme.spacingL
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Component.onCompleted: Ui.softenScrollbar(flick)

        GridLayout {
            id: grid
            width: flick.width
            columns: width > 900 ? 2 : 1
            columnSpacing: Theme.spacingS
            rowSpacing: Theme.spacingS
            readonly property bool wide: columns > 1
            // Two equal columns: each half panel asks for the same width
            readonly property real half: wide ? (width - columnSpacing) / 2 : width

            // ── Status ──
            // The band. One sentence says what is going on, one button does
            // the thing to do, and four figures mean the same in every
            // state: security, what it touches on this system, what follows,
            // and how big or how long.
            Panel {
                Layout.columnSpan: grid.wide ? 2 : 1
                Layout.preferredWidth: grid.width
                title: dash.live ? Tr.t("Update run · live") : (dash.reviewing ? Tr.t("Update run") : (dash.pending ? Tr.t("Ready to install") : (dash.resting ? Tr.t("Status") : Tr.t("Last update run"))))
                note: dash.edition && !dash.live && !dash.pending && !dash.resting ? dash.when(dash.edition.ts) : ""

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingL

                    Item {
                        id: ringBox
                        Layout.preferredWidth: 112
                        Layout.preferredHeight: 112
                        // Above the figures beside it, for the tooltip
                        z: 2
                        // With updates waiting the ring offers two things:
                        // the left half starts them, the right half checks
                        // again; otherwise one
                        readonly property bool split: dash.ringAction === "update"
                        readonly property string half: !ringHover.hovered ? "" : (split ? (ringHover.point.position.x < width / 2 ? "update" : "check") : dash.ringAction)

                        Canvas {
                            id: ring
                            anchors.fill: parent
                            property real frac: dash.live ? (dash.engine.overallFraction || 0) : dash.checkShown ? (dash.host ? dash.host.checkFraction || 0 : 0) : (dash.pending ? 0 : 1)
                            Behavior on frac {
                                NumberAnimation {
                                    duration: 700
                                    easing.type: Easing.OutCubic
                                }
                            }
                            // Ready to go: the empty ring breathes in the accent,
                            // and fills when the pointer is on it
                            property real glow: 0
                            readonly property bool inviting: dash.ringAction === "update"
                            SequentialAnimation on glow {
                                running: ring.inviting && !ringHover.hovered && dash.visible
                                loops: Animation.Infinite
                                NumberAnimation {
                                    from: 0
                                    to: 1
                                    duration: 1400
                                    easing.type: Easing.InOutSine
                                }
                                NumberAnimation {
                                    from: 1
                                    to: 0
                                    duration: 1400
                                    easing.type: Easing.InOutSine
                                }
                            }
                            onGlowChanged: requestPaint()
                            onInvitingChanged: requestPaint()
                            Connections {
                                target: ringHover
                                function onHoveredChanged() {
                                    ring.requestPaint();
                                }
                            }
                            // At rest the ring is quiet: the accent is for when
                            // there is something to do
                            readonly property color arc: dash.resting && !dash.checkShown ? Theme.withAlpha(Theme.surfaceVariantText, 0.45) : (!dash.live && !dash.resting && dash.edition && dash.failedTotal > 0 ? Ui.failColor : Theme.primary)
                            onFracChanged: requestPaint()
                            onArcChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.reset();
                                const r = width / 2 - 6;
                                ctx.lineWidth = 7;
                                ctx.lineCap = "round";
                                ctx.strokeStyle = !inviting ? Theme.withAlpha(Theme.surfaceText, 0.1) : (ringHover.hovered ? Theme.primary : Theme.withAlpha(Theme.primary, 0.3 + glow * 0.5));
                                ctx.beginPath();
                                ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2);
                                ctx.stroke();
                                if (frac <= 0)
                                    return;
                                ctx.strokeStyle = arc;
                                ctx.beginPath();
                                ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.001, frac));
                                ctx.stroke();
                            }
                        }

                        // Activity: a comet circling inside the ring while the
                        // run goes, the ring itself saying how far it is. Turned
                        // by the render thread, so it keeps going smoothly even
                        // when the window is busy.
                        Canvas {
                            id: orbit
                            anchors.fill: parent
                            // Also while a check runs: the same question, still being asked
                            visible: dash.live || dash.checkShown
                            readonly property color tint: Qt.lighter(Theme.primary, Theme.isLightMode ? 1.25 : 1.45)
                            onTintChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.reset();
                                // On the ring itself: a lighter sheen that runs
                                // over the fill and the empty track alike
                                const r = width / 2 - 6, cx = width / 2, cy = height / 2;
                                ctx.lineWidth = 7;
                                ctx.lineCap = "butt";
                                const parts = 24, length = Math.PI * 0.8;
                                for (let i = 0; i < parts; i++) {
                                    const k = (i + 1) / parts;
                                    ctx.strokeStyle = dash.withAlpha(String(tint), k * k * 0.75);
                                    ctx.beginPath();
                                    ctx.arc(cx, cy, r, -Math.PI / 2 + length * i / parts, -Math.PI / 2 + length * (i + 1) / parts);
                                    ctx.stroke();
                                }
                            }
                            RotationAnimator on rotation {
                                running: orbit.visible && dash.visible
                                from: 0
                                to: 360
                                duration: 1600
                                loops: Animation.Infinite
                            }
                        }

                        // Hovered, the ring says what a press does
                        DIcon {
                            anchors.centerIn: parent
                            visible: ringHover.hovered && dash.ringAction !== "" && !ringBox.split
                            name: dash.ringAction === "update" ? "play_arrow" : "refresh"
                            size: 48
                            color: Theme.primary
                        }
                        // Split: the half under the pointer lit, a line between
                        Canvas {
                            id: halves
                            anchors.fill: parent
                            visible: ringHover.hovered && ringBox.split
                            readonly property string lit: ringBox.half
                            onLitChanged: requestPaint()
                            onVisibleChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d");
                                ctx.reset();
                                const r = width / 2 - 11, cx = width / 2, cy = height / 2;
                                ctx.fillStyle = dash.withAlpha(String(Theme.primary), 0.14);
                                ctx.beginPath();
                                if (lit === "update")
                                    ctx.arc(cx, cy, r, Math.PI / 2, Math.PI * 1.5);
                                else
                                    ctx.arc(cx, cy, r, -Math.PI / 2, Math.PI / 2);
                                ctx.closePath();
                                ctx.fill();
                                ctx.strokeStyle = dash.withAlpha(String(Theme.surfaceText), 0.18);
                                ctx.lineWidth = 1;
                                ctx.beginPath();
                                ctx.moveTo(cx, cy - r + 8);
                                ctx.lineTo(cx, cy + r - 8);
                                ctx.stroke();
                            }
                        }
                        DIcon {
                            visible: halves.visible
                            x: ringBox.width * 0.3 - size / 2 + 2
                            anchors.verticalCenter: parent.verticalCenter
                            name: "play_arrow"
                            size: 34
                            color: ringBox.half === "update" ? Theme.primary : Theme.surfaceVariantText
                        }
                        DIcon {
                            visible: halves.visible
                            x: ringBox.width * 0.7 - size / 2 - 2
                            anchors.verticalCenter: parent.verticalCenter
                            name: "refresh"
                            size: 28
                            color: ringBox.half === "check" ? Theme.primary : Theme.surfaceVariantText
                        }
                        HoverHandler {
                            id: ringHover
                            enabled: dash.ringAction !== ""
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            enabled: dash.ringAction !== ""
                            onTapped: eventPoint => {
                                const what = ringBox.split ? (eventPoint.position.x < ringBox.width / 2 ? "update" : "check") : dash.ringAction;
                                if (what === "update")
                                    dash.engine.start({});
                                else if (what === "check")
                                    SystemUpdateService.checkForUpdates();
                            }
                        }
                        // Beside the ring, inside the card: below it, the next
                        // card is drawn over it
                        Tip {
                            visible: ringHover.hovered && dash.ringAction !== ""
                            anchors.left: parent.right
                            anchors.leftMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            z: 5
                            text: ringBox.half === "update" ? Tr.t("Update All") : Tr.t("Check for updates")
                        }

                        // While it runs: the time still to go, the time it has
                        // taken on hover
                        HoverHandler {
                            id: ringTime
                            enabled: dash.live
                        }
                        Tip {
                            visible: ringTime.hovered && dash.live
                            anchors.left: parent.right
                            anchors.leftMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            z: 5
                            text: Tr.t("running for %1").arg(dash.fmtTime(dash.elapsed))
                        }

                        DIcon {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -8
                            visible: dash.resting && !dash.checkShown && !(ringHover.hovered && dash.ringAction !== "")
                            name: "check"
                            size: 34
                            color: Theme.surfaceVariantText
                        }

                        Column {
                            anchors.centerIn: parent
                            visible: !(ringHover.hovered && dash.ringAction !== "")
                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: !(dash.resting && !dash.checkShown)
                                text: dash.checkShown ? dash.fmtTime(dash.host ? dash.host.checkElapsedSecs : 0) : dash.pending ? String(dash.pendingCount) : (dash.live ? (dash.remaining >= 0 ? dash.fmtTime(dash.remaining) : "…") : String(dash.installedPackages))
                                font.pixelSize: 24
                                font.family: Theme.monoFontFamily || "monospace"
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                            }
                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                topPadding: dash.resting && !dash.checkShown ? 34 : 0
                                text: dash.live ? Tr.t("to go · %1%").arg(Math.round((dash.engine.overallFraction || 0) * 100)) : dash.checkShown ? Math.round((dash.host ? dash.host.checkFraction || 0 : 0) * 100) + "%" : dash.pending ? (dash.pendingCount === 1 ? Tr.t("update") : Tr.t("updates")) : dash.resting ? Tr.t("up to date") : (dash.edition && dash.failedTotal > 0 ? Tr.t("with failures") : Tr.t("updated"))
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingS

                            StyledText {
                                Layout.fillWidth: true
                                // Something leaving is worth noticing before it goes
                                color: dash.pending && dash.plan && dash.plan.removals > 0 ? Theme.warning : Theme.surfaceText
                                text: dash.bandLine()
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }

                            // Only when looking back: the way to now
                            DButton {
                                visible: dash.reviewing && !dash.live
                                buttonHeight: 32
                                horizontalPadding: Theme.spacingM
                                iconName: "arrow_back"
                                iconSize: 16
                                text: Tr.t("Back to now")
                                backgroundColor: Ui.buttonFill("tonal", false)
                                textColor: Ui.buttonInk("tonal")
                                onClicked: dash.backToNow()
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: grid.wide ? 4 : 2
                            columnSpacing: Theme.spacingS
                            rowSpacing: Theme.spacingS

                            Kpi {
                                value: dash.tileSecurity().value
                                label: dash.tileSecurity().label
                                fill: dash.live && dash.totalCves > 0 ? dash.closedCves / dash.totalCves : -1
                                hint: dash.tileSecurity().hint
                            }
                            Kpi {
                                value: dash.tileTouches().value
                                label: dash.resting || (!dash.live && !dash.pending) ? Tr.t("touched by the last run") : Tr.t("touches this system")
                                hint: dash.tileTouches().hint
                            }
                            Kpi {
                                value: dash.tileAfter().value
                                label: dash.tileAfter().label
                                hint: dash.tileAfter().hint
                            }
                            Kpi {
                                value: dash.tileSize().value
                                label: dash.tileSize().label
                                hint: dash.tileSize().hint
                                fill: dash.live && dash.plannedBytes > 0 ? dash.totalBytes / dash.plannedBytes : -1
                                spark: dash.pending ? [] : dash.rate
                            }
                        }

                        // The phases, as long as each took; a name where there
                        // is room for it, on hover where there is not
                        Row {
                            id: phaseBar
                            visible: !dash.pending && !dash.resting && segments.length > 0
                            Layout.fillWidth: true
                            Layout.preferredHeight: 20
                            spacing: 3
                            readonly property var segments: {
                                const log = dash.phaseLog.filter(p => p[0] !== "idle");
                                const out = [];
                                const total = Math.max(1, dash.elapsed);
                                for (let i = 0; i < log.length; i++) {
                                    const a = log[i][1], b = i + 1 < log.length ? log[i + 1][1] : (dash.live ? null : dash.elapsed);
                                    const label = dash.phaseName(log[i][0]);
                                    if (out.length && out[out.length - 1].label === label)
                                        out[out.length - 1].b = b;
                                    else if (label)
                                        out.push({
                                            label: label,
                                            a: a,
                                            b: b,
                                            current: dash.live && i === log.length - 1
                                        });
                                }
                                // A phase of a few per cent is a sliver without a
                                // name: left out, the rest share the bar
                                return out.filter(x => x.current || ((x.b !== null ? x.b : dash.elapsed) - x.a) / total >= 0.03);
                            }

                            Repeater {
                                model: phaseBar.segments
                                delegate: Rectangle {
                                    id: seg
                                    required property var modelData
                                    readonly property real end: modelData.b !== null ? modelData.b : dash.elapsed
                                    readonly property real share: (end - modelData.a) / Math.max(1, dash.elapsed)
                                    // While it runs the ring has the time; after, how
                                    // long each took
                                    readonly property string text: dash.live ? modelData.label : modelData.label + " · " + dash.fmtTime(end - modelData.a)
                                    width: 10 + Math.max(0, phaseBar.width - 3 * (phaseBar.segments.length - 1) - 10 * phaseBar.segments.length) * share
                                    height: 20
                                    radius: 4
                                    color: modelData.current ? Theme.withAlpha(Theme.primary, 0.35) : Theme.withAlpha(Theme.surfaceText, 0.08)
                                    StyledText {
                                        id: segText
                                        anchors.fill: parent
                                        anchors.leftMargin: 6
                                        anchors.rightMargin: 4
                                        verticalAlignment: Text.AlignVCenter
                                        visible: implicitWidth <= width
                                        text: seg.text
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: seg.modelData.current ? Theme.surfaceText : Theme.surfaceVariantText
                                    }
                                    HoverHandler {
                                        id: segHover
                                        enabled: !segText.visible
                                    }
                                    Tip {
                                        visible: segHover.hovered
                                        y: -height - 4
                                        z: 5
                                        text: seg.text
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── In short ──
            // The run told in words: one sentence for all of it, then the
            // stories that matter most, each with what it means here
            Panel {
                id: shortPanel
                Layout.columnSpan: grid.wide ? 2 : 1
                Layout.preferredWidth: grid.width
                title: Tr.t("In short")
                visible: dash.edition !== null && dash.stories.length > 0
                readonly property var lead: dash.stories.length ? dash.stories[0] : null
                readonly property var subs: dash.shortSubs

                StyledText {
                    Layout.fillWidth: true
                    text: dash.deck()
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                // The lead across the width, the others in a row beneath it,
                // all of a row as tall as its tallest: no gaps between them
                StoryCard {
                    Layout.fillWidth: true
                    st: shortPanel.lead
                    big: true
                }

                RowLayout {
                    id: subRow
                    visible: shortPanel.subs.length > 0
                    Layout.fillWidth: true
                    spacing: Theme.spacingS
                    readonly property real cell: (width - spacing * (shortPanel.subs.length - 1)) / Math.max(1, shortPanel.subs.length)
                    Repeater {
                        model: dash.subIds
                        delegate: StoryCard {
                            required property var modelData
                            Layout.preferredWidth: subRow.cell
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            st: dash.storyById(modelData)
                        }
                    }
                }

                LinkText {
                    visible: !dash.live && !dash.pending && dash.host !== null
                    text: Tr.t("All runs, in the log") + " →"
                    onActivated: dash.host.openTab(4)
                }
            }

            // ── The kernel ──
            // Rare and consequential: its own card when a run has one,
            // with what changes and where to read more
            Panel {
                id: kernelPanel
                Layout.columnSpan: grid.wide ? 2 : 1
                Layout.preferredWidth: grid.width
                readonly property var st: dash.stories.find(x => (x.facts || {}).role === "kernel") || null
                readonly property string to: st ? dash.displayVersion(st.to) : ""
                readonly property string from: st ? dash.displayVersion(st.from) : ""
                readonly property var toParts: to.split(".")
                readonly property string series: toParts.length >= 2 ? toParts[0] + "." + toParts[1] : to
                readonly property bool newSeries: from !== "" && from.split(".").slice(0, 2).join(".") !== series
                readonly property string running: dash.host && dash.host.dashboard ? dash.displayVersion(dash.host.dashboard.kernel || "") : ""
                readonly property var reboot: dash.afterChecks.find(c => c.kind === "reboot") || null
                title: Tr.t("Kernel")
                note: st ? (from ? from + " → " + to : to) : ""
                // At rest only while it still waits for a restart
                visible: st !== null && (!dash.resting || (reboot !== null && reboot.needed === true))

                StyledText {
                    Layout.fillWidth: true
                    text: "Linux " + kernelPanel.to
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                    text: {
                        const out = [];
                        out.push(kernelPanel.newSeries ? Tr.t("A new kernel series, %1: new drivers and features, besides the fixes.").arg(kernelPanel.series) : Tr.t("A maintenance release in the %1 series: fixes, no new features.").arg(kernelPanel.series));
                        if (kernelPanel.st && dash.cvesOf(kernelPanel.st) > 0)
                            out.push(Tr.t("It fixes %1 known vulnerabilities, rated %2.").arg(dash.cvesOf(kernelPanel.st)).arg(dash.severityLabel(kernelPanel.st.facts.advisory.severity || "")));
                        if (kernelPanel.reboot)
                            out.push(kernelPanel.reboot.needed ? Tr.t("Restart to start using it.") : Tr.t("It is in use."));
                        else if (kernelPanel.running)
                            out.push(Tr.t("This system runs %1 now; the new kernel is used after a restart.").arg(kernelPanel.running));
                        return out.join(" ");
                    }
                }
                Repeater {
                    model: kernelPanel.st ? (kernelPanel.st.notes || []).slice(0, 4) : []
                    delegate: StyledText {
                        required property string modelData
                        Layout.fillWidth: true
                        text: "› " + modelData
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.monoFontFamily || "monospace"
                        color: Theme.surfaceText
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }
                RowLayout {
                    spacing: Theme.spacingL
                    LinkText {
                        visible: kernelPanel.toParts.length >= 2
                        text: Tr.t("Changelog on kernel.org") + " ↗"
                        onActivated: Qt.openUrlExternally("https://cdn.kernel.org/pub/linux/kernel/v" + kernelPanel.toParts[0] + ".x/ChangeLog-" + kernelPanel.to)
                    }
                    LinkText {
                        visible: kernelPanel.newSeries
                        text: Tr.t("What is new in Linux %1").arg(kernelPanel.series) + " ↗"
                        onActivated: Qt.openUrlExternally("https://kernelnewbies.org/Linux_" + kernelPanel.series.replace(".", "."))
                    }
                }
            }

            // ── Firmware ──
            // Rarer still, and easy to miss: every device with new firmware
            Panel {
                id: fwPanel
                Layout.columnSpan: grid.wide ? 2 : 1
                Layout.preferredWidth: grid.width
                readonly property var updates: dash.host && dash.host.firmware ? (dash.host.firmware.updates || []) : []
                title: Tr.t("Firmware")
                note: updates.length === 1 ? Tr.t("1 device") : Tr.t("%1 devices").arg(updates.length)
                visible: updates.length > 0 && !dash.live

                Repeater {
                    model: fwPanel.updates
                    delegate: Rectangle {
                        id: fwRow
                        required property var modelData
                        readonly property bool urgent: ["critical", "high"].indexOf((modelData.urgency || "").toLowerCase()) >= 0
                        Layout.fillWidth: true
                        implicitHeight: fwCol.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius / 2
                        color: Theme.withAlpha(Theme.surfaceText, 0.03)
                        HoverHandler {
                            id: fwHover
                        }
                        RowLayout {
                            id: fwCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM
                            Rectangle {
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                Layout.alignment: Qt.AlignTop
                                radius: 9
                                color: Theme.withAlpha(fwRow.urgent ? Ui.failColor : Theme.primary, 0.16)
                                DIcon {
                                    anchors.centerIn: parent
                                    name: "memory"
                                    size: 20
                                    color: fwRow.urgent ? Ui.failColor : Theme.primary
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS
                                    StyledText {
                                        text: fwRow.modelData.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: (fwRow.modelData.current ? fwRow.modelData.current + " → " : "") + fwRow.modelData.next
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        font.family: Theme.monoFontFamily || "monospace"
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                    DActionButton {
                                        visible: fwHover.hovered && (fwRow.modelData.homepage || "") !== ""
                                        buttonSize: 24
                                        iconName: "open_in_new"
                                        iconSize: 16
                                        iconColor: Theme.surfaceVariantText
                                        tooltipText: Tr.t("Website")
                                        onClicked: Qt.openUrlExternally(fwRow.modelData.homepage)
                                    }
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: [fwRow.urgent ? Tr.t("urgent") : "", fwRow.modelData.summary || ""].filter(x => x).join(" · ")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: fwRow.urgent ? Ui.failColor : Theme.primary
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: (fwRow.modelData.notesHtml || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 4
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    visible: (fwRow.modelData.blocker || "") !== ""
                                    text: fwRow.modelData.blocker || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.warning
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
                LinkText {
                    text: Tr.t("Firmware") + " →"
                    onActivated: dash.host.openTab(3)
                }
            }

            // ── To download (before a run) ──
            Panel {
                id: sizePanel
                Layout.preferredWidth: grid.half
                Layout.fillHeight: true
                title: Tr.t("to download")
                // What each project downloads once the resolver has said;
                // the package size until then
                note: dash.plan ? Tr.t("download, %1 in all").arg(dash.downloadText) : Tr.t("package size")
                visible: dash.pending
                property bool all: false
                readonly property var sized: dash.stories.map(st => ({
                            name: st.name,
                            bytes: dash.storyBytes(st)
                        })).filter(r => r.bytes > 0).sort((a, b) => b.bytes - a.bytes)
                readonly property var rows: all ? sized : sized.slice(0, 10)
                readonly property int unsized: dash.stories.length - sized.length
                readonly property real most: rows.length ? rows[0].bytes : 1

                StyledText {
                    visible: sizePanel.rows.length === 0
                    text: Tr.t("No sizes known yet")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
                Repeater {
                    model: sizePanel.rows
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacingS
                        StyledText {
                            Layout.preferredWidth: Math.min(170, sizePanel.width * 0.3)
                            horizontalAlignment: Text.AlignRight
                            text: modelData.name
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 12
                            Rectangle {
                                width: Math.max(3, parent.width * modelData.bytes / sizePanel.most)
                                height: parent.height
                                radius: 3
                                color: dash.series[0]
                            }
                        }
                        StyledText {
                            Layout.preferredWidth: 64
                            text: dash.bytes(modelData.bytes)
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.family: Theme.monoFontFamily || "monospace"
                            color: Theme.surfaceVariantText
                        }
                    }
                }
                MoreLine {
                    shown: sizePanel.rows.length
                    total: sizePanel.sized.length
                    all: sizePanel.all
                    onToggled: sizePanel.all = !sizePanel.all
                    extra: sizePanel.unsized > 0 ? (sizePanel.unsized === 1 ? Tr.t("1 without a known size") : Tr.t("%1 without a known size").arg(sizePanel.unsized)) : ""
                }
            }

            // ── System (at rest) ──
            Panel {
                Layout.preferredWidth: grid.half
                Layout.fillHeight: true
                title: Tr.t("System")
                visible: dash.resting && dash.host !== null
                Repeater {
                    model: dash.resting && dash.host ? dash.host.restSystemRows() : []
                    delegate: FactRow {
                        required property var modelData
                        label: modelData.label
                        value: modelData.value
                    }
                }
                // What is installed, in one line: the Installed tab has it all
                LinkText {
                    Layout.topMargin: 4
                    text: dash.host ? dash.host.restInstalledRows().filter(r => r.count > 0).map(r => r.count + " " + r.label).join(" · ") + " →" : ""
                    onActivated: dash.host.openTab(1)
                }
            }

            // ── Timeline ──
            Panel {
                Layout.preferredWidth: grid.half
                Layout.fillHeight: true
                title: Tr.t("Timeline per story")
                note: Tr.t("download and install")
                visible: dash.stories.length > 0 && !dash.pending && !dash.resting

                Item {
                    id: timeline
                    Layout.fillWidth: true
                    property bool all: false
                    readonly property var rows: all ? dash.stories : dash.stories.slice(0, 8)
                    readonly property int labelW: Math.min(170, width * 0.3)
                    readonly property int rowH: 20
                    Layout.preferredHeight: rows.length * rowH + 22
                    function px(t) {
                        return labelW + (width - labelW - 4) * Math.max(0, t) / dash.span;
                    }

                    Repeater {
                        model: dash.tickCount
                        delegate: Item {
                            required property int index
                            readonly property real at: index * dash.tickStep
                            x: timeline.px(at)
                            height: timeline.height
                            Rectangle {
                                width: 1
                                height: timeline.rows.length * timeline.rowH
                                color: Theme.withAlpha(Theme.surfaceText, 0.07)
                            }
                            StyledText {
                                y: timeline.rows.length * timeline.rowH + 4
                                x: Math.max(-parent.x + timeline.labelW, Math.min(timeline.width - parent.x - width, -width / 2))
                                text: dash.fmtTime(parent.at)
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    Repeater {
                        model: timeline.rows
                        delegate: Item {
                            id: tRow
                            required property var modelData
                            required property int index
                            readonly property var spans: dash.storySpans(modelData)
                            y: index * timeline.rowH
                            width: timeline.width
                            height: timeline.rowH

                            Rectangle {
                                anchors.fill: parent
                                radius: 4
                                color: dash.selected === tRow.modelData.id ? Theme.withAlpha(Theme.primary, 0.1) : (rowHover.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.04) : "transparent")
                            }
                            StyledText {
                                width: timeline.labelW - 10
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: tRow.modelData.name
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceText
                                wrapMode: Text.NoWrap
                                maximumLineCount: 1
                                elide: Text.ElideRight
                            }
                            Repeater {
                                model: [["dl", 0], ["inst", 1], ["work", 2]]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property var span: tRow.spans[modelData[0]] || null
                                    visible: span !== null
                                    x: span ? timeline.px(span[0]) : 0
                                    width: span ? Math.max(4, timeline.px(span[1] !== null && span[1] !== undefined ? span[1] : dash.elapsed) - x) : 0
                                    y: 5
                                    height: timeline.rowH - 10
                                    radius: 3
                                    // A story that failed in the error colour
                                    color: dash.storyState(tRow.modelData) === "error" ? Ui.failColor : dash.series[modelData[1]]
                                    opacity: dash.live && span && (span[1] === null || span[1] === undefined) ? 0.55 : 1
                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: 300
                                        }
                                    }
                                }
                            }
                            MouseArea {
                                id: rowHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dash.select(tRow.modelData.id)
                            }
                            Tip {
                                visible: rowHover.containsMouse
                                x: Math.min(tRow.width - width, timeline.labelW)
                                y: -height - 2
                                z: 5
                                text: {
                                    const s = tRow.spans, out = [tRow.modelData.name];
                                    if (s.dl)
                                        out.push(Tr.t("download %1–%2").arg(dash.fmtTime(s.dl[0])).arg(s.dl[1] !== null ? dash.fmtTime(s.dl[1]) : "…"));
                                    if (s.inst)
                                        out.push(Tr.t("install %1–%2").arg(dash.fmtTime(s.inst[0])).arg(s.inst[1] !== null ? dash.fmtTime(s.inst[1]) : "…"));
                                    if (s.work)
                                        out.push(Tr.t("work %1–%2").arg(dash.fmtTime(s.work[0])).arg(s.work[1] !== null ? dash.fmtTime(s.work[1]) : "…"));
                                    if (tRow.modelData.bytes > 0)
                                        out.push(dash.bytes(tRow.modelData.bytes));
                                    return out.join(" · ");
                                }
                            }

                        }
                    }

                    // Now
                    Rectangle {
                        visible: dash.live
                        x: timeline.px(dash.elapsed)
                        width: 2
                        height: timeline.rows.length * timeline.rowH
                        color: Theme.primary
                    }
                }

                MoreLine {
                    shown: timeline.rows.length
                    total: dash.stories.length
                    all: timeline.all
                    onToggled: timeline.all = !timeline.all
                }
                Legend {
                    entries: [[Tr.t("download"), dash.series[0]], [Tr.t("install"), dash.series[1]], [Tr.t("other"), dash.series[2]]]
                }
            }

            // ── What it means: security, and what follows ──
            ColumnLayout {
                Layout.preferredWidth: grid.half
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignTop
                spacing: Theme.spacingS
                // From the same facts as the cards in it: a child's
                // visibility follows its parent's, so asking theirs would
                // keep a column hidden once it had been
                visible: dash.edition !== null

                // ── Security ──
                Panel {
                    id: secPanel
                    Layout.fillWidth: true
                    title: Tr.t("Security")
                    // Only when there is something to say: "none" is in the band
                    visible: advised.length > 0
                    readonly property var advised: dash.stories.filter(st => dash.cvesOf(st) >= 0)
                    note: advised.length === 1 ? Tr.t("1 advisory") : Tr.t("%1 advisories").arg(advised.length)

                    StyledText {
                        visible: secPanel.advised.length === 0
                        Layout.fillWidth: true
                        text: Tr.t("No security advisories in this run.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        model: secPanel.advised
                        delegate: Rectangle {
                            id: advRow
                            required property var modelData
                            readonly property var adv: modelData.facts.advisory || ({})
                            // CVEs the notes name, for a story without an advisory
                            readonly property int cves: dash.cvesOf(modelData)
                            readonly property bool fixed: dash.storyState(modelData) === "done"
                            Layout.fillWidth: true
                            implicitHeight: advCol.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.surfaceText, 0.04)

                            RowLayout {
                                id: advCol
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Rectangle {
                                    Layout.preferredWidth: 24
                                    Layout.preferredHeight: 24
                                    radius: 7
                                    color: advRow.fixed ? Theme.success : dash.severityColor(advRow.adv.severity)
                                    DIcon {
                                        anchors.centerIn: parent
                                        name: advRow.fixed ? "check" : "priority_high"
                                        size: 16
                                        color: Ui.onColor(parent.color)
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: advRow.modelData.name + " " + dash.short(advRow.modelData.to)
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: (advRow.cves > 0 ? (advRow.cves === 1 ? Tr.t("1 CVE") : Tr.t("%1 CVEs").arg(advRow.cves)) : Tr.t("no CVE number")) + " · " + (advRow.adv.severity ? dash.severityLabel(advRow.adv.severity) : Tr.t("named in the notes"))
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }
                                StyledText {
                                    text: advRow.fixed ? Tr.t("fixed") : (dash.live || dash.pending ? Tr.t("open") : Tr.t("not installed"))
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.weight: Font.Medium
                                    color: advRow.fixed ? Theme.success : dash.severityColor(advRow.adv.severity)
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dash.select(advRow.modelData.id)
                            }
                        }
                    }
                }

                // ── After the run ──
                Panel {
                    id: afterPanel
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Before and during a run, what it will ask of you, foreseen
                    // from what it updates; after it, what this system says
                    title: Tr.t("After this run")
                    // A replay is never checked: it did not happen here
                    // Foreseen before it is checked; a replay is never checked,
                    // as it did not happen here
                    note: dash.checked && !dash.edition.replay ? Tr.t("checked on this system") : (dash.edition && dash.edition.replay && !dash.live && !dash.pending ? Tr.t("foreseen; a replay is not checked") : (dash.live || dash.pending ? (dash.carried.length > 0 ? "" : Tr.t("foreseen")) : Tr.t("checking…")))
                    visible: dash.edition !== null

                    // Still open from the last run: checked now, so above
                    // what is only foreseen
                    StyledText {
                        visible: dash.carried.length > 0
                        text: Tr.t("Still open from the last run")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }
                    Repeater {
                        model: dash.carried
                        delegate: Rectangle {
                            id: carry
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: carryRow.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.warning, 0.08)
                            RowLayout {
                                id: carryRow
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS
                                Rectangle {
                                    Layout.preferredWidth: 24
                                    Layout.preferredHeight: 24
                                    Layout.alignment: Qt.AlignTop
                                    radius: 7
                                    color: Theme.withAlpha(Theme.warning, 0.18)
                                    DIcon {
                                        anchors.centerIn: parent
                                        name: carry.modelData.kind === "reboot" ? "restart_alt" : "history"
                                        size: 15
                                        color: Theme.warning
                                    }
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: carry.modelData.text
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }
                                DButton {
                                    visible: carry.modelData.kind === "reboot"
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: dash.widgetRoot && dash.widgetRoot.confirmReboot ? Tr.t("Press again to restart") : Tr.t("Restart")
                                    backgroundColor: Ui.buttonFill("filled", false)
                                    textColor: Ui.buttonInk("filled")
                                    onClicked: dash.widgetRoot.requestReboot()
                                }
                                // Closed and opened again; asked twice, since
                                // unsaved work in it would be lost
                                DButton {
                                    id: carryRestart
                                    property bool armed: false
                                    visible: carry.modelData.kind === "stale" && (carry.modelData.shell || carry.modelData.desktopId !== "")
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: carry.modelData.shell ? Tr.t("Restart the shell") : (armed ? Tr.t("Press again: unsaved work is lost") : Tr.t("Restart %1").arg(carry.modelData.name))
                                    backgroundColor: Ui.buttonFill("filled", false)
                                    textColor: Ui.buttonInk("filled")
                                    onClicked: {
                                        if (carry.modelData.shell) {
                                            Quickshell.execDetached(["dms", "restart"]);
                                            return;
                                        }
                                        if (!armed) {
                                            armed = true;
                                            carryDisarm.restart();
                                            return;
                                        }
                                        armed = false;
                                        dash.restartApp(carry.modelData.pids || [], carry.modelData.desktopId);
                                        // Looked up again once it has had time to go
                                        carryProbe.restart();
                                    }
                                    Timer {
                                        id: carryDisarm
                                        interval: 4000
                                        onTriggered: carryRestart.armed = false
                                    }
                                    Timer {
                                        id: carryProbe
                                        interval: 4000
                                        onTriggered: dash.probeStale()
                                    }
                                }
                                DButton {
                                    visible: carry.modelData.kind === "stale"
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: Tr.t("Later")
                                    backgroundColor: Ui.buttonFill("tonal", false)
                                    textColor: Ui.buttonInk("tonal")
                                    onClicked: {
                                        const d = Object.assign({}, dash.dismissed);
                                        d["carried/" + carry.modelData.kind + "/" + (carry.modelData.id || "")] = true;
                                        dash.dismissed = d;
                                    }
                                }
                            }
                        }
                    }
                    StyledText {
                        visible: dash.carried.length > 0 && !dash.checked
                        Layout.topMargin: Theme.spacingS
                        text: Tr.t("Foreseen for these updates")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: dash.checked ? [] : dash.predictions()
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: predRow.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.surfaceText, 0.04)
                            RowLayout {
                                id: predRow
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS
                                Rectangle {
                                    Layout.preferredWidth: 24
                                    Layout.preferredHeight: 24
                                    radius: 7
                                    color: Theme.withAlpha(Theme.tertiary, 0.18)
                                    DIcon {
                                        anchors.centerIn: parent
                                        name: parent.parent.parent.modelData.kind === "calm" ? "check" : (parent.parent.parent.modelData.kind === "reboot" ? "restart_alt" : (parent.parent.parent.modelData.kind === "relogin" ? "logout" : "autorenew"))
                                        size: 15
                                        color: parent.parent.parent.modelData.kind === "calm" ? Theme.success : Theme.tertiary
                                    }
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: parent.parent.modelData.text
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                    StyledText {
                        visible: false
                        Layout.fillWidth: true
                        text: Tr.t("Nothing in these updates asks for a restart or for logging in again.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        // What asks for something first; "no restart needed" last,
                        // and only said when nothing else does
                        model: {
                            const open = dash.afterChecks.filter(c => !dash.dismissed[c.kind + "/" + (c.story || c.unit || "")]);
                            const calm = c => (c.kind === "reboot" && !c.needed) || (c.kind === "service" && c.restarted);
                            // What asks something of you, then what is fine, then
                            // the tidy-up tips
                            const tip = c => c.kind === "unused";
                            return open.filter(c => !calm(c) && !tip(c)).concat(open.filter(calm), open.filter(tip));
                        }
                        delegate: Rectangle {
                            id: act
                            required property var modelData
                            readonly property var story: dash.stories.find(s => s.id === modelData.story) || null
                            readonly property string name: story ? story.name : ""
                            readonly property bool good: (modelData.kind === "reboot" && !modelData.needed) || (modelData.kind === "service" && modelData.restarted)
                            readonly property bool warn: !good && modelData.kind !== "unused"
                            Layout.fillWidth: true
                            implicitHeight: actRow.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.surfaceText, 0.04)

                            RowLayout {
                                id: actRow
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Rectangle {
                                    Layout.preferredWidth: 24
                                    Layout.preferredHeight: 24
                                    Layout.alignment: Qt.AlignTop
                                    radius: 7
                                    color: act.good ? Theme.success : (act.warn ? Theme.warning : Theme.withAlpha(Theme.surfaceText, 0.25))
                                    DIcon {
                                        anchors.centerIn: parent
                                        name: act.good ? "check" : (act.modelData.kind === "unused" ? "help" : "restart_alt")
                                        size: 15
                                        color: Ui.onColor(parent.color)
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: {
                                            const c = act.modelData;
                                            switch (c.kind) {
                                            case "reboot":
                                                return c.needed ? Tr.t("A restart is needed") : Tr.t("No restart of the computer needed");
                                            case "service":
                                                return c.restarted ? Tr.t("%1 already runs the new version").arg(c.unit.replace(/\.service$/, "")) : Tr.t("%1 still runs the old version").arg(c.unit.replace(/\.service$/, ""));
                                            case "stale":
                                                return Tr.t("%1 still runs the previous version").arg(act.name);
                                            case "unused":
                                                return Tr.t("%1 is never opened from the launcher").arg(act.name);
                                            }
                                            return "";
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: {
                                            const c = act.modelData;
                                            switch (c.kind) {
                                            case "reboot":
                                                return c.needed ? Tr.t("Something the system runs on was updated.") : Tr.t("No kernel, core library or system service asks for it.");
                                            case "service":
                                                return c.restarted ? Tr.t("Restarted by itself at %1.").arg(new Date(c.at * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)) : Tr.t("It picks up the new version when it restarts, or at the next boot.");
                                            case "stale":
                                                if (c.role === "desktop")
                                                    return Tr.t("The new version starts when you log out and back in.");
                                                return Tr.t("Open since %1. Restart it to use the new version.").arg(dash.when(c.since));
                                            case "unused":
                                                // A tip, not a consequence: what keeping it costs
                                                return c.cves > 0 ? Tr.t("Updated anyway, with %1 security fixes. Remove it if you do not need it.").arg(c.cves) : (c.bytes > 1e6 ? Tr.t("Updated anyway: %1. Remove it if you do not need it.").arg(dash.bytes(c.bytes)) : Tr.t("Updated anyway. Remove it if you do not need it."));
                                            }
                                            return "";
                                        }
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                DButton {
                                    Layout.alignment: Qt.AlignTop
                                    visible: act.modelData.kind === "reboot" && act.modelData.needed && dash.widgetRoot !== null
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: dash.widgetRoot && dash.widgetRoot.confirmReboot ? Tr.t("Press again to restart") : Tr.t("Restart")
                                    backgroundColor: Ui.buttonFill("filled", false)
                                    textColor: Ui.buttonInk("filled")
                                    onClicked: dash.widgetRoot.requestReboot()
                                }
                                DButton {
                                    Layout.alignment: Qt.AlignTop
                                    visible: act.modelData.kind === "unused" && act.story !== null && dash.showInstalled !== null
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: Tr.t("Show")
                                    backgroundColor: Ui.buttonFill("tonal", false)
                                    textColor: Ui.buttonInk("tonal")
                                    onClicked: dash.showInstalled(act.story.source)
                                }
                                // The thing to do: restart the shell, or the app
                                // (closed and opened again; asked twice, since
                                // unsaved work in it would be lost)
                                DButton {
                                    id: restartApp
                                    Layout.alignment: Qt.AlignTop
                                    property bool armed: false
                                    readonly property bool shell: act.story !== null && /^system\/(dms|quickshell)$/.test(act.story.id)
                                    readonly property string desktopId: act.story && ((act.story.facts || {}).desktopIds || []).length ? act.story.facts.desktopIds[0] : ""
                                    visible: act.modelData.kind === "stale" && act.modelData.role !== "desktop" && (shell || desktopId !== "")
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: shell ? Tr.t("Restart the shell") : (armed ? Tr.t("Press again: unsaved work is lost") : Tr.t("Restart %1").arg(act.name))
                                    backgroundColor: Ui.buttonFill("filled", false)
                                    textColor: Ui.buttonInk("filled")
                                    onClicked: {
                                        if (shell) {
                                            Quickshell.execDetached(["dms", "restart"]);
                                            return;
                                        }
                                        if (!armed) {
                                            armed = true;
                                            return;
                                        }
                                        armed = false;
                                        dash.restartApp(act.modelData.pids || [], desktopId);
                                        const d = Object.assign({}, dash.dismissed);
                                        d[act.modelData.kind + "/" + (act.modelData.story || "")] = true;
                                        dash.dismissed = d;
                                    }
                                }
                                DButton {
                                    Layout.alignment: Qt.AlignTop
                                    visible: act.modelData.kind === "stale" || act.modelData.kind === "unused"
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: Tr.t("Later")
                                    backgroundColor: Ui.buttonFill("tonal", false)
                                    textColor: Ui.buttonInk("tonal")
                                    onClicked: {
                                        const d = Object.assign({}, dash.dismissed);
                                        d[act.modelData.kind + "/" + (act.modelData.story || act.modelData.unit || "")] = true;
                                        dash.dismissed = d;
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: dash.checked && dash.edition.replay === true
                        Layout.fillWidth: true
                        text: Tr.t("A replay plays a recorded run; what is left to do is about this machine, so it is not checked.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        visible: dash.edition !== null && dash.edition.after !== null && dash.afterChecks.length === 0
                        Layout.fillWidth: true
                        text: Tr.t("Nothing left to do.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }


            }

            // ── What is new ──
            // ── What is new ──
            Panel {
                id: feedPanel
                // The whole width while the run goes, when there is nothing
                // to put beside it yet
                Layout.columnSpan: grid.wide ? 2 : 1
                Layout.preferredWidth: grid.width
                title: Tr.t("What is new")
                note: dash.widgetRoot && dash.widgetRoot.editionBusy ? Tr.t("collecting notes…") : ""
                // The order, as a row of words: the one in use in the accent
                tools: Component {
                    Row {
                        spacing: Theme.spacingS
                        StyledText {
                            text: Tr.t("Sort:")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.surfaceVariantText
                        }
                        Repeater {
                            model: [["relevance", Tr.t("relevance")], ["security", Tr.t("security")], ["size", Tr.t("size")], ["newest", Tr.t("newest")], ["name", Tr.t("name")]]
                            delegate: StyledText {
                                required property var modelData
                                readonly property bool on: dash.feedOrder === modelData[0]
                                text: modelData[1]
                                font.pixelSize: Theme.fontSizeSmall - 2
                                font.weight: on ? Font.DemiBold : Font.Normal
                                font.underline: sortHover.hovered && !on
                                color: on ? Theme.primary : Theme.surfaceVariantText
                                HoverHandler {
                                    id: sortHover
                                    cursorShape: Qt.PointingHandCursor
                                }
                                // Why this order, where the order is chosen
                                Tip {
                                    visible: sortHover.hovered && parent.modelData[0] === "relevance"
                                    maxWidth: 340
                                    y: parent.height + 4
                                    x: -width + parent.width
                                    z: 10
                                    text: Tr.t("First what touches this system: security fixes, services that run here, the kernel. Then your favourites, your desktop, the apps you use, and the size of the step.")
                                }
                                TapHandler {
                                    onTapped: dash.feedOrder = parent.modelData[0]
                                }
                            }
                        }
                    }
                }
                visible: dash.feedShown

                ListView {
                    id: feed
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(520, contentHeight)
                    clip: true
                    spacing: Theme.spacingS
                    model: dash.feedIds
                    // Another order: the cards come in again, one by one
                    property bool sorting: false
                    Connections {
                        target: dash
                        function onFeedOrderChanged() {
                            feed.sorting = true;
                            sortSettle.restart();
                        }
                    }
                    Timer {
                        id: sortSettle
                        interval: 600
                        onTriggered: feed.sorting = false
                    }
                    boundsBehavior: Flickable.StopAtBounds
                    Component.onCompleted: Ui.softenScrollbar(feed)

                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        required property int index
                        readonly property var story: dash.storyById(modelData) || ({})
                        // Grows and shrinks to what it holds (notes arriving,
                        // opened, closed) instead of jumping
                        property real rise: 0
                        transform: Translate {
                            y: card.rise
                        }
                        property bool settled: false
                        clip: cardGrow.running
                        Behavior on implicitHeight {
                            enabled: card.settled && dash.motion
                            NumberAnimation {
                                id: cardGrow
                                duration: 260
                                easing.type: Easing.OutCubic
                            }
                        }
                        Reveal {
                            id: cardIn
                            target: card
                        }
                        Timer {
                            interval: 500
                            running: true
                            onTriggered: card.settled = true
                        }
                        Component.onCompleted: if (dash.inWave() || feed.sorting) dash.reveal(card, cardIn)
                        Connections {
                            target: dash
                            function onWaveChanged() {
                                dash.reveal(card, cardIn);
                            }
                        }
                        // What matters most is read in full without a press
                        // Read in full without a press when it matters, unless
                        // "In short" above already tells it
                        readonly property bool told: dash.inShort.indexOf(story.id) >= 0
                        property bool expanded: !told && story.fav === true
                        readonly property string state_: dash.storyState(story)
                        readonly property string link: story.notesUrl || story.homepage || ""
                        readonly property var notes: story.notes || []
                        width: feed.width
                        implicitHeight: cardCol.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius / 2
                        color: dash.selected === story.id ? Theme.withAlpha(Theme.primary, 0.08) : Theme.withAlpha(Theme.surfaceText, 0.03)
                        border.width: dash.selected === story.id ? 1 : 0
                        border.color: Theme.withAlpha(Theme.primary, 0.5)

                        MouseArea {
                            anchors.fill: parent
                            onClicked: dash.selected = card.story.id
                        }
                        HoverHandler {
                            id: cardHover
                        }

                        RowLayout {
                            id: cardCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            Item {
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                Layout.alignment: Qt.AlignTop
                                Image {
                                    id: storyIcon
                                    // Themed like the icons everywhere else; a
                                    // trademark is shown as it is
                                    layer.enabled: Ui.tintAppIcons && dash.tintable(card.story)
                                    layer.effect: TintedIconEffect {}
                                    anchors.fill: parent
                                    source: dash.iconFor(card.story)
                                    sourceSize: Qt.size(72, 72)
                                    smooth: true
                                    visible: status === Image.Ready
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    visible: !storyIcon.visible
                                    radius: 9
                                    color: Theme.withAlpha(Theme.primary, 0.16)
                                    DIcon {
                                        anchors.centerIn: parent
                                        name: dash.symbolFor(card.story)
                                        size: 20
                                        color: Theme.primary
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS
                                    StyledText {
                                        text: card.story.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                    // Where it goes; where from, in full, on hover
                                    StyledText {
                                        Layout.fillWidth: true
                                        text: dash.displayVersion(card.story.to)
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                        HoverHandler {
                                            id: verHover
                                        }
                                        Tip {
                                            visible: verHover.hovered
                                            y: -height - 4
                                            z: 5
                                            text: (card.story.from ? card.story.from + " → " : "") + card.story.to
                                        }
                                    }
                                    // Shown on hover; a favourite's star always
                                    // Their room is kept while hidden, so a card
                                    // does not change height under the pointer
                                    DActionButton {
                                        opacity: cardHover.hovered || card.story.fav === true ? 1 : 0
                                        enabled: opacity > 0
                                        buttonSize: 24
                                        iconName: "star"
                                        iconFilled: card.story.fav === true
                                        iconSize: 16
                                        iconColor: card.story.fav === true ? Theme.primary : Theme.surfaceVariantText
                                        tooltipText: card.story.fav === true ? Tr.t("Remove from favorites") : Tr.t("Mark as favorite")
                                        onClicked: dash.toggleFavorite(card.story.id)
                                    }
                                    DActionButton {
                                        visible: card.link !== ""
                                        opacity: cardHover.hovered ? 1 : 0
                                        enabled: opacity > 0
                                        buttonSize: 24
                                        iconName: "open_in_new"
                                        iconSize: 16
                                        iconColor: Theme.surfaceVariantText
                                        tooltipText: card.story.notesUrl ? (card.story.notesFrom === "commits" ? Tr.t("The commits") : Tr.t("Release notes")) : Tr.t("Website")
                                        onClicked: Qt.openUrlExternally(card.link)
                                    }
                                    Rectangle {
                                        // Done or failed: "in progress" on every row says nothing
                                        // A failure always; "installed" only while the run
                                        // goes, after it every row would say it
                                        visible: card.state_ === "error" || (dash.live && card.state_ === "done")
                                        Layout.preferredHeight: 20
                                        Layout.preferredWidth: stateText.implicitWidth + 14
                                        radius: 10
                                        color: card.state_ === "done" ? Theme.withAlpha(Theme.success, 0.16) : (card.state_ === "error" ? Theme.withAlpha(Ui.failColor, 0.16) : (card.state_ === "active" ? Theme.withAlpha(Theme.primary, 0.16) : Theme.withAlpha(Theme.surfaceText, 0.06)))
                                        StyledText {
                                            id: stateText
                                            anchors.centerIn: parent
                                            text: card.state_ === "done" ? "✓ " + Tr.t("installed") : (card.state_ === "error" ? Tr.t("failed") : (card.state_ === "active" ? Tr.t("in progress") : Tr.t("waiting")))
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                            color: card.state_ === "done" ? Theme.success : (card.state_ === "error" ? Ui.failColor : Theme.surfaceVariantText)
                                        }
                                    }
                                }

                                Chips {
                                    Layout.fillWidth: true
                                    st: card.story
                                    noFavorite: true
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: card.story.status === "error" && (card.story.error || "") !== ""
                                    text: card.story.error || ""
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Ui.failColor
                                    wrapMode: Text.WordWrap
                                }

                                StyledText {
                                    // Only above lines that are shown
                                    visible: text !== "" && (card.expanded ? card.notes.length > 0 : (!card.told && dash.pickNotes(card.story, 3).lines.length > 0))
                                    text: dash.notesBy(card.story)
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }
                                NotesList {
                                    Layout.fillWidth: true
                                    // Folded: the lines worth reading, without the
                                    // routine commits; open, all of them
                                    lines: card.expanded ? card.notes : (card.told ? [] : dash.pickNotes(card.story, 3).lines)
                                    maxHeight: 220
                                    small: true
                                    repo: dash.repoOf(card.story)
                                    links: card.expanded ? (card.story.noteLinks || []) : (card.told ? [] : dash.pickNotes(card.story, 3).links)
                                }
                                BusyText {
                                    visible: card.notes.length === 0
                                    text: dash.notesLoading ? Tr.t("loading notes…") : Tr.t("no notes")
                                    pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }

                                RowLayout {
                                    spacing: Theme.spacingM
                                    LinkText {
                                        readonly property var picked: dash.pickNotes(card.story, 3)
                                        readonly property int shown: card.told ? 0 : picked.lines.length
                                        visible: !card.expanded && card.notes.length > shown
                                        // Said the way "In short" says it
                                        text: card.told ? Tr.t("Show the notes (%1)").arg(card.notes.length) : dash.moreText(card.story, picked)
                                        onActivated: card.expanded = true
                                    }
                                    LinkText {
                                        visible: card.expanded && card.notes.length > (card.told ? 0 : dash.pickNotes(card.story, 3).lines.length)
                                        text: Tr.t("Less")
                                        onActivated: card.expanded = false
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Reclaimable space (at rest) ──
            // The overview's card itself, from the window
            Loader {
                Layout.columnSpan: grid.wide ? 2 : 1
                Layout.fillWidth: true
                active: dash.resting && dash.host !== null
                sourceComponent: dash.host ? dash.host.cleanupCard : null
                visible: active && item !== null && item.wanted
                onLoaded: item.color = Ui.cardSurface
            }
        }
    }

    function select(id) {
        selected = id;
        const i = stories.findIndex(s => s.id === id);
        if (i >= 0)
            feed.positionViewAtIndex(i, ListView.Beginning);
    }

    function phaseName(p) {
        if (p.indexOf("download") !== -1)
            return Tr.t("download");
        if (p === "dnf-install" || p.indexOf("install") !== -1)
            return Tr.t("install");
        switch (p) {
        case "starting":
            return Tr.t("authorise");
        case "verifying":
            return Tr.t("verify");
        case "flatpak":
            return "Flatpak";
        case "snap":
            return "Snap";
        case "firmware":
            return Tr.t("firmware");
        case "appimage":
            return "AppImage";
        case "brew":
            return "Homebrew";
        case "plugins":
            return Tr.t("plugins");
        case "aur":
            return "AUR";
        case "dms":
            return "Dux Shell";
        case "done":
        case "failed":
        case "cancelled":
            return "";
        }
        return p;
    }

    // ── Small parts ──────────────────────────────────────────────────────────
    // Notes as their authors wrote them, one per line; past maxHeight the
    // block scrolls rather than pushing the page down
    component NotesList: Flickable {
        id: nl
        property var lines: []
        property int maxHeight: 200
        property bool small: false
        // "owner/name", for "#123" in a line
        property string repo: ""
        // Parallel to lines: where each leads when the line itself does not
        // say (a commit)
        property var links: []
        visible: lines.length > 0
        // Lines that arrive later (the notes, fetched) fade in
        onVisibleChanged: if (visible && dash.motion) nlFade.restart()
        NumberAnimation {
            id: nlFade
            target: nl
            property: "opacity"
            from: 0
            to: 1
            duration: 320
            easing.type: Easing.OutCubic
        }
        implicitHeight: Math.min(maxHeight, nlCol.implicitHeight)
        contentHeight: nlCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        Component.onCompleted: Ui.softenScrollbar(nl)
        Column {
            id: nlCol
            width: nl.width - (nl.interactive ? 10 : 0)
            spacing: 2
            Repeater {
                model: nl.lines
                // A line that points somewhere lights up under the pointer
                // and opens it in the browser
                delegate: Rectangle {
                    id: noteLine
                    required property string modelData
                    required property int index
                    readonly property string link: dash.linkOf(modelData, nl.repo) || (nl.links[index] || "")
                    width: nlCol.width
                    height: noteText.implicitHeight + 2
                    radius: 4
                    color: noteHover.hovered && link !== "" ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                    StyledText {
                        id: noteText
                        x: 2
                        y: 1
                        // Room for the arrow kept whether it shows or not, so
                        // the line does not rewrap under the pointer
                        width: parent.width - 4 - (noteLine.link !== "" ? 18 : 0)
                        text: "› " + noteLine.modelData
                        // Quoted, so set apart: monospace, a size down and in
                        // the quiet colour, under the sentences of our own
                        font.pixelSize: Theme.fontSizeSmall - (nl.small ? 2 : 1)
                        font.family: Theme.monoFontFamily || "monospace"
                        color: noteHover.hovered && noteLine.link !== "" ? Theme.primary : Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    DIcon {
                        visible: noteHover.hovered && noteLine.link !== ""
                        anchors.right: parent.right
                        anchors.rightMargin: 2
                        anchors.top: parent.top
                        anchors.topMargin: 2
                        name: "open_in_new"
                        size: 14
                        color: Theme.primary
                    }
                    HoverHandler {
                        id: noteHover
                        enabled: noteLine.link !== ""
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        enabled: noteLine.link !== ""
                        onTapped: Qt.openUrlExternally(noteLine.link)
                    }
                }
            }
        }
    }

    // A story told: what it is about (chips), what it is (name, from →
    // to), what it means here (one sentence), and what its authors wrote,
    // the routine commits left out
    component StoryCard: Rectangle {
        id: sc
        property var st: null
        property bool big: false
        implicitHeight: scCol.implicitHeight + Theme.spacingM * 2
        property real rise: 0
        transform: Translate {
            y: sc.rise
        }
        property bool settled: false
        clip: scGrow.running
        Behavior on implicitHeight {
            enabled: sc.settled && dash.motion
            NumberAnimation {
                id: scGrow
                duration: 260
                easing.type: Easing.OutCubic
            }
        }
        Reveal {
            id: scIn
            target: sc
        }
        Timer {
            interval: 500
            running: true
            onTriggered: sc.settled = true
        }
        Component.onCompleted: if (dash.inWave()) dash.reveal(sc, scIn)
        Connections {
            target: dash
            function onWaveChanged() {
                dash.reveal(sc, scIn);
            }
        }
        radius: Theme.cornerRadius / 2
        color: st && dash.selected === st.id ? Theme.withAlpha(Theme.primary, 0.08) : Theme.withAlpha(Theme.surfaceText, 0.03)
        visible: st !== null
        property bool all: false
        readonly property var picked: dash.pickNotes(st, big ? 4 : 3)
        readonly property string state_: st && dash.live ? dash.storyState(st) : ""

        Item {
            id: scIcon
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            width: sc.big ? 40 : 32
            height: width
            Image {
                id: scImage
                anchors.fill: parent
                source: dash.iconFor(sc.st)
                sourceSize: Qt.size(80, 80)
                smooth: true
                visible: status === Image.Ready
                layer.enabled: Ui.tintAppIcons && dash.tintable(sc.st)
                layer.effect: TintedIconEffect {}
            }
            Rectangle {
                anchors.fill: parent
                visible: !scImage.visible
                radius: 9
                color: Theme.withAlpha(Theme.primary, 0.16)
                DIcon {
                    anchors.centerIn: parent
                    name: dash.symbolFor(sc.st)
                    size: sc.big ? 22 : 18
                    color: Theme.primary
                }
            }
        }

        ColumnLayout {
            id: scCol
            anchors.left: scIcon.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                Chips {
                    Layout.fillWidth: true
                    st: sc.st
                }
                // While a run goes, where this story is
                StateBadge {
                        visible: sc.state_ === "done" || sc.state_ === "error"
                        state_: sc.state_
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                StyledText {
                    text: sc.st ? sc.st.name : ""
                    font.pixelSize: sc.big ? Theme.fontSizeLarge : Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                StyledText {
                    Layout.fillWidth: true
                    text: sc.st ? (sc.st.from ? dash.displayVersion(sc.st.from) + " → " : "") + dash.displayVersion(sc.st.to) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }
            StyledText {
                Layout.fillWidth: true
                visible: text !== ""
                text: sc.st ? dash.consequence(sc.st) : ""
                font.pixelSize: sc.big ? Theme.fontSizeMedium : Theme.fontSizeSmall
                color: Theme.surfaceText
                wrapMode: Text.WordWrap
            }
            StyledText {
                Layout.fillWidth: true
                Layout.topMargin: 2
                visible: sc.picked.lines.length > 0 && text !== ""
                text: sc.st ? dash.notesBy(sc.st) : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
            BusyText {
                Layout.topMargin: 2
                visible: dash.notesLoading && sc.st !== null && (sc.st.notes || []).length === 0
                text: Tr.t("loading notes…")
                pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
            NotesList {
                Layout.fillWidth: true
                lines: sc.all ? (sc.st ? sc.st.notes || [] : []) : sc.picked.lines
                links: sc.all ? (sc.st ? sc.st.noteLinks || [] : []) : sc.picked.links
                repo: dash.repoOf(sc.st)
                maxHeight: 220
                small: true
            }
            LinkText {
                visible: sc.picked.rest > 0 || sc.all
                text: sc.all ? Tr.t("Fewer") : dash.moreText(sc.st, sc.picked)
                onActivated: sc.all = !sc.all
            }
        }
        TapHandler {
            onTapped: if (sc.st) dash.select(sc.st.id)
        }
    }

    // What a story is about, as small labels: the user's star, security,
    // what it touches here, how it is used
    component Chips: Flow {
        id: chips
        property var st: null
        // Where the star is a button beside it, it is not said twice
        property bool noFavorite: false
        spacing: 4
        Repeater {
            model: chips.st ? dash.chipsOf(chips.st).filter(c => !(chips.noFavorite && c.tone === "accent")) : []
            delegate: Rectangle {
                required property var modelData
                height: 20
                width: chipText.implicitWidth + 14
                radius: 10
                color: Theme.withAlpha(modelData.tone === "error" ? Ui.failColor : (modelData.tone === "accent" ? Theme.primary : (modelData.tone === "system" ? Theme.tertiary : Theme.surfaceText)), modelData.tone === "plain" ? 0.06 : 0.14)
                StyledText {
                    id: chipText
                    anchors.centerIn: parent
                    text: parent.modelData.text
                    font.pixelSize: Theme.fontSizeSmall - 2
                    font.weight: Font.Medium
                    color: parent.modelData.tone === "error" ? Ui.failColor : (parent.modelData.tone === "accent" ? Theme.primary : (parent.modelData.tone === "system" ? Theme.tertiary : Theme.surfaceVariantText))
                }
            }
        }
    }

    // Waiting, downloading, installed, failed
    component StateBadge: Rectangle {
        property string state_: ""
        implicitHeight: 20
        implicitWidth: badgeText.implicitWidth + 14
        radius: 10
        color: state_ === "done" ? Theme.withAlpha(Theme.success, 0.16) : (state_ === "error" ? Theme.withAlpha(Ui.failColor, 0.16) : (state_ === "active" ? Theme.withAlpha(Theme.primary, 0.16) : Theme.withAlpha(Theme.surfaceText, 0.06)))
        StyledText {
            id: badgeText
            anchors.centerIn: parent
            text: parent.state_ === "done" ? "✓ " + Tr.t("installed") : (parent.state_ === "error" ? Tr.t("failed") : (parent.state_ === "active" ? Tr.t("in progress") : Tr.t("waiting")))
            font.pixelSize: Theme.fontSizeSmall - 2
            color: parent.state_ === "done" ? Theme.success : (parent.state_ === "error" ? Ui.failColor : Theme.surfaceVariantText)
        }
    }

    // A label and its value, as the overview's cards list them
    component FactRow: RowLayout {
        property string icon: ""
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        spacing: Theme.spacingS
        DIcon {
            visible: parent.icon !== ""
            name: parent.icon
            size: 16
            color: Theme.surfaceVariantText
        }
        StyledText {
            Layout.preferredWidth: 110
            text: parent.label
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
        }
        StyledText {
            Layout.fillWidth: true
            text: parent.value
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
            elide: Text.ElideRight
            horizontalAlignment: parent.icon !== "" ? Text.AlignRight : Text.AlignLeft
        }
    }

    // The entrance: hidden, a pause for its turn, then a fade and a short
    // rise. The target carries a "rise" property under a Translate.
    component Reveal: SequentialAnimation {
        id: rv
        property Item target: null
        property int delay: 0
        PropertyAction {
            target: rv.target
            property: "opacity"
            value: 0
        }
        PropertyAction {
            target: rv.target
            property: "rise"
            value: 14
        }
        PauseAnimation {
            duration: rv.delay
        }
        ParallelAnimation {
            NumberAnimation {
                target: rv.target
                property: "opacity"
                to: 1
                duration: 300
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: rv.target
                property: "rise"
                to: 0
                duration: 380
                easing.type: Easing.OutCubic
            }
        }
    }

    component Panel: Rectangle {
        id: panel
        property string title: ""
        property string note: ""
        // In the header, before the note: controls of the card's own
        property Component tools: null
        default property alias content: body.data
        Layout.fillWidth: true
        implicitHeight: body.implicitHeight + head.implicitHeight + Theme.spacingM * 2 + Theme.spacingS
        radius: Theme.cornerRadius
        color: Ui.cardSurface
        // A card that comes in fades in and rises, in its turn, so a change
        // of state reads as one and not as the page being swapped
        property real rise: 0
        transform: Translate {
            y: panel.rise
        }
        onVisibleChanged: if (visible) dash.reveal(panel, panelIn)
        Reveal {
            id: panelIn
            target: panel
        }
        Connections {
            target: dash
            function onWaveChanged() {
                dash.reveal(panel, panelIn);
            }
        }

        RowLayout {
            id: head
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            StyledText {
                text: panel.title.toUpperCase()
                font.pixelSize: Theme.fontSizeSmall - 2
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
                color: Theme.surfaceVariantText
            }
            Item {
                Layout.fillWidth: true
            }
            Loader {
                active: panel.tools !== null
                sourceComponent: panel.tools
            }
            StyledText {
                visible: text !== ""
                text: panel.note
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }
        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: head.bottom
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            anchors.topMargin: Theme.spacingS
            spacing: Theme.spacingS
        }
    }

    component Kpi: Rectangle {
        id: kpi
        property real rise: 0
        transform: Translate {
            y: kpi.rise
        }
        Reveal {
            id: kpiIn
            target: kpi
        }
        Connections {
            target: dash
            function onWaveChanged() {
                dash.reveal(kpi, kpiIn);
            }
        }
        property string value: ""
        property string label: ""
        // How far along, 0–1, as a line filling along the bottom while a run
        // goes; below zero, no line
        property real fill: -1
        // What the figure does and does not count, on hover
        property string hint: ""
        // Samples drawn as a faint line behind the figure (the download speed)
        property var spark: []
        Canvas {
            id: sparkLine
            visible: kpi.spark.length > 1
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 6
            anchors.bottomMargin: 8
            width: parent.width * 0.46
            height: parent.height * 0.6
            onVisibleChanged: requestPaint()
            Connections {
                target: kpi
                function onSparkChanged() {
                    sparkLine.requestPaint();
                }
            }
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const v = kpi.spark, n = v.length;
                if (n < 2)
                    return;
                const step = Math.max(1, Math.ceil(n / 80));
                const pts = [];
                let most = 1;
                for (let i = 0; i < n; i += step) {
                    let sum = 0, m = 0;
                    for (let j = i; j < Math.min(n, i + step); j++, m++)
                        sum += v[j];
                    pts.push(sum / m);
                    most = Math.max(most, sum / m);
                }
                const x = i => width * i / Math.max(1, pts.length - 1);
                const y = val => height - 2 - (height - 4) * val / most;
                ctx.beginPath();
                ctx.moveTo(0, height);
                for (let i = 0; i < pts.length; i++)
                    ctx.lineTo(x(i), y(pts[i]));
                ctx.lineTo(width, height);
                ctx.closePath();
                ctx.fillStyle = dash.withAlpha(String(Theme.primary), 0.12);
                ctx.fill();
                ctx.beginPath();
                for (let i = 0; i < pts.length; i++)
                    i === 0 ? ctx.moveTo(x(i), y(pts[i])) : ctx.lineTo(x(i), y(pts[i]));
                ctx.strokeStyle = dash.withAlpha(String(Theme.primary), 0.6);
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }
        }
        HoverHandler {
            id: kpiHover
            enabled: kpi.hint !== ""
        }
        // Above the figure: below it, the next card is drawn over it
        Tip {
            visible: kpiHover.hovered && kpi.hint !== ""
            maxWidth: 380
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            // Left-aligned when it fits the tile, else ending where the tile
            // ends: the rightmost tile is at the window's edge
            x: Math.min(0, kpi.width - width)
            z: 10
            text: kpi.hint
        }
        property real _shown: Math.max(0, Math.min(1, fill))
        Behavior on _shown {
            NumberAnimation {
                duration: 600
                easing.type: Easing.OutCubic
            }
        }
        Rectangle {
            visible: kpi.fill >= 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            anchors.bottomMargin: 4
            height: 3
            radius: 1.5
            color: Theme.withAlpha(Theme.primary, 0.18)
            Rectangle {
                width: parent.width * kpi._shown
                height: parent.height
                radius: parent.radius
                color: Theme.primary
            }
        }
        Layout.fillWidth: true
        implicitHeight: kpiCol.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius / 2
        color: Theme.withAlpha(Theme.surfaceText, 0.04)
        Column {
            id: kpiCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Theme.spacingS
            // The line has the right half; the words keep the left
            anchors.rightMargin: kpi.spark.length > 1 ? parent.width * 0.5 : Theme.spacingS
            StyledText {
                width: parent.width
                text: parent.parent.value
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.DemiBold
                color: Theme.surfaceText
                elide: Text.ElideRight
            }
            StyledText {
                width: parent.width
                text: parent.parent.label
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }
    }

    component Tip: Rectangle {
        id: tip
        property string text: ""
        // Above zero, longer text wraps at this width
        property int maxWidth: 0
        width: maxWidth > 0 ? Math.min(maxWidth, tipText.implicitWidth + 16) : tipText.implicitWidth + 16
        height: tipText.height + 10
        radius: 6
        color: Theme.tooltipSurface !== undefined ? Theme.tooltipSurface : Theme.surfaceContainerHighest
        StyledText {
            id: tipText
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: tip.maxWidth > 0 ? tip.width - 16 : implicitWidth
            text: tip.text
            wrapMode: tip.maxWidth > 0 ? Text.WordWrap : Text.NoWrap
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.tooltipText !== undefined ? Theme.tooltipText : Theme.surfaceText
        }
    }

    component Legend: Flow {
        property var entries: []
        Layout.fillWidth: true
        spacing: Theme.spacingM
        Repeater {
            model: parent.entries
            delegate: Row {
                required property var modelData
                spacing: 5
                Rectangle {
                    width: 10
                    height: 10
                    radius: 3
                    color: modelData[1]
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: modelData[0]
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    // "+7 more · show all", or "show fewer": so a card that shows part of
    // a run never reads as all of it
    component MoreLine: RowLayout {
        id: more
        property int shown: 0
        property int total: 0
        property bool all: false
        property string extra: ""
        signal toggled
        visible: total > shown || all || extra !== ""
        spacing: Theme.spacingS
        LinkText {
            visible: more.total > more.shown || more.all
            text: more.all ? Tr.t("Show fewer") : Tr.t("Show all %1").arg(more.total)
            onActivated: more.toggled()
        }
        StyledText {
            visible: more.extra !== ""
            text: (more.total > more.shown || more.all ? "· " : "") + more.extra
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }
    }

    component LinkText: StyledText {
        signal activated
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.primary
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.activated()
        }
    }
}
