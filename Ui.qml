pragma Singleton
import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services

// Small UI helpers shared across the plugin views.
Item {
    id: ui

    // ── Surface roles, with a floor ─────────────────────────────────────────
    // DMS names the surfaces a plugin draws on — a card, a chip, a chip
    // inside a chip — and lets the user set each one, so a plugin that names
    // the underlying container instead ignores that choice while the rest of
    // the shell follows it.
    //
    // The names arrived after 1.6.2, which is the current stable release, and
    // plugin.json asks only for 1.5.0. On a shell without them the property
    // reads as undefined and the colour is simply invalid — not a fallback, a
    // hole. So they are asked for here, once, with the container each one
    // defaults to as the floor. Identical pixels either way; the difference
    // is whether a newer shell's setting reaches us.
    readonly property color cardSurface: Theme.cardSurface !== undefined ? Theme.cardSurface : Theme.surfaceContainer
    readonly property color chipSurface: Theme.chipSurface !== undefined ? Theme.chipSurface : Theme.surfaceContainerHigh
    readonly property color chipSurfaceNested: Theme.chipSurfaceNested !== undefined ? Theme.chipSurfaceNested : Theme.surfaceContainerHighest

    // ── Button emphasis ─────────────────────────────────────────────────────
    // Material 3 Expressive draws a button with its fill, not an outline, and
    // says how important it is by how strong that fill is (issue #28). An
    // area gets at most one filled button, its main action; everything next
    // to it is tonal; "show more" kinds of links are text. With that, a row
    // of buttons no longer turns into a row of equally loud ones, which is
    // what the outlines were working around.
    //
    //   filled       the main action: the shell's button colours, so the
    //                user's choice in Settings → Theme reaches it
    //   tonal        a secondary action, on the surface a chip inside a
    //                card would use
    //   accent       tonal, but leaning towards the accent: the recommended
    //                one of several equal choices (Flathub among sources)
    //   text         lowest emphasis: no fill until hovered
    //   danger       filled red: a destructive action, once confirmed
    //   dangerTonal  tonal with red ink: a destructive action, at rest
    //   warning      filled amber: acting on a warning banner
    //   icon         a standard icon button: no container
    //   iconSelected an icon button that is switched on
    //
    // Hover is a state layer — the ink over the fill at 8%, as in DankButton
    // — not a different colour.
    function buttonFill(kind, hovered) {
        let fill;
        switch (kind) {
        case "filled":
            fill = Theme.buttonBg;
            break;
        case "accent":
            fill = Theme.primaryContainer;
            break;
        case "danger":
            fill = Theme.error;
            break;
        case "warning":
            fill = Theme.warning;
            break;
        case "text":
        case "icon":
            fill = Theme.withAlpha(buttonInk(kind), 0);
            break;
        case "iconSelected":
            fill = Theme.secondaryContainer;
            break;
        default:
            fill = chipSurfaceNested;
        }
        if (!hovered)
            return fill;
        const ink = buttonInk(kind);
        return fill.a === 0 ? Theme.withAlpha(ink, 0.08) : mix(fill, Qt.rgba(ink.r, ink.g, ink.b, fill.a), 0.08);
    }

    function buttonInk(kind) {
        switch (kind) {
        case "filled":
            return Theme.buttonText;
        case "accent":
        case "text":
            return Theme.primary;
        case "danger":
            return onColor(Theme.error);
        case "warning":
            return onColor(Theme.warning);
        case "dangerTonal":
            return failColor;
        case "icon":
            return Theme.surfaceVariantText;
        default:
            return Theme.surfaceText;
        }
    }

    // ── List rows ───────────────────────────────────────────────────────────
    // A row is a surface of its own, like a card, rather than a near-clear
    // fill held together by an outline. States tint that surface: hover is
    // the accent at 8%, a selected (open, active) row twice that, and a row
    // that failed or is already there takes the error or success colour.
    // `base` is the surface the row has at rest: by default the one the
    // dashboard's cards use, since the window itself is the card surface.
    function rowFill(hovered, selected, tone, base) {
        const surface = base !== undefined ? base : Theme.withAlpha(chipSurface, 0.45);
        if (tone === "error")
            return mix(surface, Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, surface.a), hovered ? 0.18 : 0.12);
        if (tone === "success")
            return mix(surface, Qt.rgba(Theme.success.r, Theme.success.g, Theme.success.b, surface.a), hovered ? 0.20 : 0.12);
        const strength = (selected ? 0.16 : 0) + (hovered ? 0.08 : 0);
        return strength === 0 ? surface : mix(surface, Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, surface.a), strength);
    }

    // ── Themed app icons ────────────────────────────────────────────────────
    // On by default. The argument against it is that an app's icon is its own
    // identity and a catalog where every one is the same colour is harder to
    // scan; the argument for it is that this window belongs to a shell whose
    // whole point is that everything follows one accent, and a wall of
    // unrelated logos is the one place that stops being true. The second
    // argument won, and the switch is still there for anyone the first one
    // convinced.
    //
    // `!== false` rather than `=== true`: it is the difference between a
    // default and an override. Somebody who turned this off has a `false` on
    // disk and keeps it; somebody who never touched it has nothing on disk
    // and gets what the plugin thinks is best today.
    //
    // Read here rather than threaded through six views, because the leaf that
    // draws an icon is a long way from the settings page and everything in
    // between would only be passing it on.
    property bool tintAppIcons: PluginService.loadPluginData("dankSoftwareDepot", "tintAppIcons", true) !== false

    Connections {
        target: PluginService

        function onPluginDataChanged(pluginId) {
            if (pluginId === "dankSoftwareDepot")
                ui.tintAppIcons = PluginService.loadPluginData("dankSoftwareDepot", "tintAppIcons", true) !== false;
        }
    }

    // ── Where a package came from ───────────────────────────────────────────
    // One vocabulary, because it had been written out four times and every
    // copy had a different hole in it: the update card knew Flatpak and DMS
    // plugins, the action log knew four kinds, the details popup knew three,
    // and not one of them knew Homebrew. Everything that fell through called
    // itself a system package, which is how five brew formulae ended up
    // labelled System on somebody's Ubuntu (#10) — under a section header
    // correctly reading Homebrew, three centimetres away.
    //
    // The names are identifiers as much as labels: the log stores this string
    // on disk and reads it back to work out what an old entry was about, so
    // they stay in English and stay stable. sourceLabel is the one to draw.
    // yay and paru, with devel turned on, list a -git package whose upstream
    // has moved on without knowing the version it will build to: they print
    // this in the version's place (#26). The daemon passes it through as is.
    readonly property string develTarget: "latest-commit"

    // A spinner or a pulse says "busy", and busy has a cadence of its own:
    // it is not a transition, so it does not follow DMS's animation speed.
    // Tied to it (from 1.2.0 on), a short setting spun the refresh icon five
    // times a second and "Off" restarted it every frame. A fixed cycle, as
    // before 1.2.0 — and none at all where motion is off or reduced, where
    // the colour and the text already say that something is running.
    readonly property int busyCycle: 1000
    readonly property bool busyMotion: Theme.currentAnimationBaseDuration > 0 && SettingsData.reduceMotion !== true

    // rpm's ordering of two version strings (rpmvercmp): runs of digits
    // compare as numbers, runs of letters as text, a number beats a letter,
    // and "~" sorts before anything, even the end of the string. Epochs are
    // the caller's business. -1, 0 or 1.
    function compareVersions(a, b) {
        const x = String(a || "");
        const y = String(b || "");
        let i = 0;
        let j = 0;
        const sep = c => !/[A-Za-z0-9~^]/.test(c);
        while (i < x.length || j < y.length) {
            while (i < x.length && sep(x[i]))
                i++;
            while (j < y.length && sep(y[j]))
                j++;
            if (x[i] === "~" || y[j] === "~") {
                if (x[i] !== "~")
                    return 1;
                if (y[j] !== "~")
                    return -1;
                i++;
                j++;
                continue;
            }
            if (x[i] === "^" || y[j] === "^") {
                if (i >= x.length)
                    return -1;
                if (j >= y.length)
                    return 1;
                if (x[i] !== "^")
                    return 1;
                if (y[j] !== "^")
                    return -1;
                i++;
                j++;
                continue;
            }
            if (i >= x.length || j >= y.length)
                break;
            const numeric = /[0-9]/.test(x[i]);
            const run = numeric ? /^[0-9]+/ : /^[A-Za-z]+/;
            const p = (x.slice(i).match(run) || [""])[0];
            const q = (y.slice(j).match(run) || [""])[0];
            if (q === "")
                return numeric ? 1 : -1;
            i += p.length;
            j += q.length;
            if (numeric) {
                const pn = p.replace(/^0+/, "");
                const qn = q.replace(/^0+/, "");
                if (pn.length !== qn.length)
                    return pn.length > qn.length ? 1 : -1;
                if (pn !== qn)
                    return pn > qn ? 1 : -1;
            } else if (p !== q) {
                return p > q ? 1 : -1;
            }
        }
        if (i >= x.length && j >= y.length)
            return 0;
        return i >= x.length ? -1 : 1;
    }

    function versionLabel(version) {
        return version === develTarget ? Tr.t("latest commit") : (version || "");
    }

    function sourceName(repo) {
        switch (repo) {
        case "flatpak":
            return "Flatpak";
        case "appimage":
            return "AppImage";
        case "firmware":
            return "Firmware";
        case "dmsplugin":
            return "DMS";
        case "brew":
            return "Homebrew";
        default:
            return "System";
        }
    }

    // A repo this does not recognise is a package from the distribution, which
    // is what an empty repo has always meant here — the daemon fills it in for
    // some paths and not others, and "System" is right in both.
    function sourceLabel(repo) {
        const name = sourceName(repo);
        return name === "System" ? Tr.t("System") : name;
    }

    // The glyph standing in where there is no logo to draw. Firmware and
    // system packages share one, as they do on the dashboard: a chip is what
    // both of them are about.
    function sourceIcon(repo) {
        switch (repo) {
        case "flatpak":
            return "apps";
        case "appimage":
            return "deployed_code";
        case "dmsplugin":
            return "extension";
        case "brew":
            return "local_drink";
        default:
            return "memory";
        }
    }

    // Failure color that stays readable everywhere: some palettes leave
    // Theme.error on the light M3 tone in light mode, which washes out to
    // an unreadable salmon on light surfaces.
    readonly property color failColor: (Theme.isLightMode && Theme.error.hslLightness > 0.55) ? Qt.darker(Theme.error, 1.8) : Theme.error

    // Text color with guaranteed contrast on a colored fill: the theme has
    // no on-error tone, and Theme.primaryText can land on the same side of
    // the lightness scale as Theme.error.
    //
    // Judged on perceived luminance rather than HSL lightness: a saturated
    // purple or red sits high on the lightness scale while still reading as
    // dark, and black text on it is barely legible. 0.179 is where white and
    // black give the same contrast ratio.
    function onColor(bg) {
        const channel = c => c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        const luminance = 0.2126 * channel(bg.r) + 0.7152 * channel(bg.g) + 0.0722 * channel(bg.b);
        return luminance > 0.179 ? Qt.rgba(0, 0, 0, 0.87) : "#FFFFFF";
    }

    // Linear blend between two colours, for gradients that have to be built
    // out of separate items rather than a single fill.
    //
    // Accepts "#RRGGBB" strings as well as colours: a colour written in a JS
    // model stays a string, and a string has no .r/.g/.b — blending one
    // silently yields an invalid colour, which draws as nothing at all.
    function _asColor(value) {
        if (typeof value !== "string")
            return value;
        const hex = value.replace("#", "");
        if (hex.length < 6)
            return value;
        return Qt.rgba(parseInt(hex.substring(0, 2), 16) / 255, parseInt(hex.substring(2, 4), 16) / 255, parseInt(hex.substring(4, 6), 16) / 255, hex.length >= 8 ? parseInt(hex.substring(6, 8), 16) / 255 : 1);
    }

    function mix(fromValue, toValue, t) {
        const from = _asColor(fromValue);
        const to = _asColor(toValue);
        const k = Math.max(0, Math.min(1, t));
        return Qt.rgba(from.r + (to.r - from.r) * k, from.g + (to.g - from.g) * k, from.b + (to.b - from.b) * k, from.a + (to.a - from.a) * k);
    }

    // Search-field caret: hidden while the field is empty (focus is already
    // visible through the field border); once text is entered a normally
    // blinking caret appears. Custom cursorDelegates don't blink by
    // themselves, so the delegate runs its own blink cycle.
    Component {
        id: steadyCursor

        Rectangle {
            width: 2
            color: Theme.primary
            visible: parent !== null && (parent.text || "") !== ""

            SequentialAnimation on opacity {
                running: visible
                loops: Animation.Infinite

                PropertyAction {
                    value: 1
                }

                PauseAnimation {
                    duration: 550
                }

                PropertyAction {
                    value: 0
                }

                PauseAnimation {
                    duration: 550
                }
            }
        }
    }

    // Make a DankListView/DankFlickable scrollbar semi-transparent. The bar
    // is attached as a child of the view; duck-type it and re-bind its
    // handle opacity.
    // The scrollbar of each view, found while it is still the view's child:
    // DMS moves it to a host item once it has worked out where it goes
    property var _scrollbars: new Map()

    function _scrollbarOf(view) {
        const known = _scrollbars.get(view);
        if (known)
            return known;
        // The attached property names it wherever it has been moved to; the
        // children are the fallback for a view that sets none
        let bar = view.ScrollBar ? view.ScrollBar.vertical : null;
        if (!bar) {
            const kids = view.children || [];
            for (let i = 0; i < kids.length; i++) {
                const child = kids[i];
                if (child && child.contentItem !== undefined && child.policy !== undefined && child.minimumSize !== undefined) {
                    bar = child;
                    break;
                }
            }
        }
        if (bar)
            _scrollbars.set(view, bar);
        return bar;
    }

    function softenScrollbar(view) {
        const bar = _scrollbarOf(view);
        if (bar)
            bar.contentItem.opacity = Qt.binding(() => bar.pressed ? 0.85 : 0.5);
    }

    // DMS shows a list's scrollbar while the list moves, and its own wheel
    // handler says so explicitly. The smooth wheels in Installed, Install and
    // the details dialog replace that handler and animate contentY, which is
    // not "moving" to Qt — so the scrollbar stayed hidden while scrolling and
    // only appeared with the pointer next to it. They call this instead.
    function showScrollbar(view) {
        const bar = _scrollbarOf(view);
        if (!bar || bar._scrollBarActive === undefined)
            return;
        bar._scrollBarActive = true;
        if (bar.hideTimer)
            bar.hideTimer.restart();
    }

    // The smooth wheels in Installed, Install and the details dialog animate
    // a mouse wheel's notches, which DankFlickable / DankListView jump
    // through. Everything else — a touchpad, a high-resolution wheel — is the
    // shell's: its handler is where the momentum lives. #21 switched that
    // handler off and let the smooth wheel take every event, so each small
    // touchpad step became a 120px jump: stutter, and no momentum at all.
    //
    // Which is which is read from the event, as DMS does (WheelInput.js):
    // Qt on Wayland reports a touchpad as a mouse, so acceptedDevices cannot
    // tell them apart. The shell's handler stays disabled, so the two never
    // both act on one event, and is handed the events that are its own by
    // emitting its wheel signal.
    function takeOverWheel(view) {
        if (!view) return;
        _scrollbarOf(view);
        const kids = view.children || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (child && child.acceptedDevices !== undefined && child.touchpadSpeed !== undefined) {
                child.enabled = false;
                _shellWheels.set(view, child);
            }
        }
    }

    property var _shellWheels: new Map()

    // ── Scroll benchmark (development installs only, via the Dev IPC) ───────
    // Drives a registered list downwards at a fixed speed (px/s, a brisk
    // flick by default) for at most ten seconds, and keeps
    // every frame time, so "this list stutters and that one does not" can be
    // measured and compared, and a change can be judged by numbers.
    property var _benchViews: ({})
    property var _bench: null
    property string benchResult: "no run yet"

    function registerBench(name, view) {
        _benchViews[name] = view;
    }

    function bench(name, speed) {
        const view = _benchViews[name];
        if (!view)
            return "no list registered as " + name + " (" + Object.keys(_benchViews).join(", ") + ")";
        if (!view.visible)
            return name + " is not on screen";
        view.contentY = view.originY;
        _bench = { view: view, name: name, speed: speed > 0 ? speed : 1500, elapsed: 0, frames: [] };
        benchResult = "running";
        benchFrames.running = true;
        return "benchmarking " + name;
    }

    FrameAnimation {
        id: benchFrames
        running: false
        onTriggered: {
            const b = ui._bench;
            if (!b) {
                running = false;
                return;
            }
            // The first frame's time is the gap since the call, not a frame
            if (b.elapsed > 0)
                b.frames.push(frameTime * 1000);
            b.elapsed += frameTime;
            const end = Math.max(0, b.view.contentHeight - b.view.height);
            const span = Math.min(end, b.speed * b.elapsed);
            b.view.contentY = b.view.originY + span;
            if (span < end && b.elapsed < 10)
                return;
            running = false;
            const f = b.frames.slice().sort((x, y) => x - y);
            const pct = p => f[Math.min(f.length - 1, Math.floor(f.length * p))].toFixed(1);
            const over = ms => f.filter(x => x > ms).length;
            ui.benchResult = b.name + ": " + f.length + " frames over " + Math.round(span) + "px"
                + " · median " + pct(0.5) + "ms · p95 " + pct(0.95) + "ms · max " + f[f.length - 1].toFixed(1) + "ms"
                + " · >20ms " + over(20) + " · >33ms " + over(33) + " · >50ms " + over(50);
            ui._bench = null;
        }
    }

    // True when the event went to the shell's handler and the smooth wheel
    // should leave it alone.
    function wheelToShell(view, event) {
        const touchpad = event.phase !== Qt.NoScrollPhase && (event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0);
        const notched = event.angleDelta.y !== 0 && event.angleDelta.y % 120 === 0;
        if (!touchpad && notched)
            return false;
        const shell = _shellWheels.get(view);
        if (shell)
            shell.wheel(event);
        return true;
    }

    // AND-search: every whitespace-separated word must occur somewhere in the
    // haystack, order-independent.
    function matchesWords(haystack, query) {
        const words = query.toLowerCase().split(/\s+/);
        for (const word of words) {
            if (word !== "" && haystack.indexOf(word) === -1)
                return false;
        }
        return true;
    }

    // Apply the caret behaviour to the TextInput inside a DankTextField
    function steadyCursorFor(fieldRoot) {
        const stack = [fieldRoot];
        while (stack.length > 0) {
            const item = stack.pop();
            if (!item)
                continue;
            if (item.cursorDelegate !== undefined && item.cursorPosition !== undefined) {
                item.cursorDelegate = steadyCursor;
                return;
            }
            const kids = item.children || [];
            for (let i = 0; i < kids.length; i++)
                stack.push(kids[i]);
        }
    }
}
