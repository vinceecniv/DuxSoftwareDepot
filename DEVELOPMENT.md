# Development

This plugin is developed with [Claude Code](https://claude.com/claude-code)
and built with [Vito](https://vito.talk) — voice-driven development
([GitHub](https://github.com/vinceecniv/Vito)).

The transaction helpers speak a documented NDJSON event protocol — see
[PROTOCOL.md](PROTOCOL.md), which also carries the porting inventory for
non-dnf backends.

## Architecture

Update detection, check interval and ignored packages stay with DMS itself
(Settings → System Updater); this plugin consumes that state.

All release-note and HTML content from external sources is reduced to an
escaped minimal markup subset before rendering.

**Text worth copying can be selected**: release notes and the CVE numbers in
them, changelogs, descriptions, announcements, and the verbatim tool output
behind a failure; in an app's details popup also its name, the `old → new`
version step, the licence and a plugin's directory. Not every label — a
selectable element takes the mouse with it, and a card whose title was
selectable would stop being a card you can click.

### QML

| Piece | Role |
|---|---|
| `UpdaterWidget.qml` | Bar pill, popout, IPC, reboot logic, settings |
| `UpdaterWindow.qml` | Tabbed window (Updates / Installed / Install / Firmware / Log) |
| `UpdateEngine.qml` | Run orchestration (system packages → Flatpak → fwupd → AppImages → plugins → Homebrew → DMS packages) and per-package progress |
| `Backend.qml` | The package-backend seam: every entry point specific to the system package manager, plus how a privileged command is authorised |
| `UpdateCard.qml` | Rich per-update card |
| `InstalledView.qml` | Installed software browser + actions |
| `InstallView.qml` | Storefront + cross-source search & install |
| `FirmwareView.qml` | fwupd device inventory |
| `LogView.qml` | Action history browser |
| `AppDetailsDialog.qml` | Shared app-details popup (info, reviews, actions) |
| `SourcePickerDialog.qml` | Which source to install from, when an app has more than one |
| `OriginComparison.qml` | The sources side by side — version, size, sandbox, who stands behind it, which one is installed. Used by both the picker and the details popup, so the two cannot disagree |
| `AppimageOfferDialog.qml` | Installing an AppImage from a file or URL |
| `NewsDialog.qml` | Arch Linux announcements: unread, plus the archive |
| `RetrospectCard.qml` | The year the action log remembers, on the Updates dashboard |
| `MetadataStore.qml` | Async enrichment cache + held-state persistence |
| `ActionLog.qml` | Persistent action history (two-year retention) |
| `FirmwareService.qml` | fwupd update detection |
| `TintedIconEffect.qml` | Themed app icons, in one place because six views draw icons |
| `SelectableText.qml` | StyledText you can select and copy |
| `FieldPlaceholder.qml` | A hint that stays while a field is empty |
| `SearchField.qml` | The search bar of a tab: fully rounded, and highlighted only once something is typed |
| `PhaseIndicator.qml` · `PulseRings.qml` | Material phase stepper; the shell's System Check pulse |
| `Tr.qml` | Plugin-local translation singleton |

### Python helpers

| Piece | Role |
|---|---|
| `scripts/enrich.py` | AppStream parsing, dnf fallbacks, holds, the search index (which is also the storefront), per-source versions, ODRS ratings, Flathub figures, upstream notes for git builds, caching, sanitizing |
| `scripts/rpm_helper.py` | libdnf5 transactions with exact byte progress |
| `scripts/dnf4_helper.py` | The same protocol on dnf 4, for RHEL and its rebuilds; `rpm_helper.py` hands over to it when libdnf5 will not import |
| `scripts/ostree_helper.py` | rpm-ostree counterpart — atomic Fedora (layering, staged until reboot) |
| `scripts/apt_helper.py` · `scripts/pacman_helper.py` | python-apt and pyalpm counterparts (Arch: official repos, no AUR) |
| `scripts/pkg_backend.py` | Per-distro metadata backend (search, sizes, inventory, holds, changelogs); also which packages own a launchable desktop entry |
| `scripts/flatpak_helper.py` | libflatpak transactions with exact byte progress, and end-of-life detection |
| `scripts/appimage.py` | AppImage catalog, install/replace/update/uninstall, GitHub update sources, folder scanning, the `.appimage` association |
| `scripts/appimage_squashfs.py` | Reads the desktop entry and icon out of an AppImage's squashfs without running the image |
| `scripts/repo_backend.py` | Software sources: repositories and Flatpak remotes, Copr, RPM Fusion, Flathub (dnf family only) |
| `scripts/brew_helper.py` | Homebrew: installed, outdated, upgrade — per-formula events read out of brew's own prose |
| `scripts/plugin_notes.py` | What a DMS plugin update changes: its GitHub release, else its CHANGELOG.md section, else the commits in its own directory — read from the compare link the daemon reports |
| `scripts/arch_news.py` | The Arch news feed: fetch, reduce, archive, track what has been read |
| `scripts/action_log.py` · `scripts/reconcile.py` | Log append/prune; comparing install times against the log to find what changed outside this app |
| `scripts/interp.py` | Re-exec under an interpreter that can see the distro's bindings — a pyenv or virtualenv python3 cannot |
| `scripts/simulate.py` | Record an update run and play it back (below) |
| `scripts/open.sh` | What the desktop entry runs: finds `dms` on a launcher's narrower PATH, and turns a failed call into a notification instead of silence |

### Checks

Everything in CI runs on any distribution, with the network and the package
managers stubbed: `check_translations.py` (the 15 catalogs against the QML),
`test_dep11.py`, `test_gitnotes.py`, `test_plugin_notes.py`, `test_reconcile.py`, `test_ostree_helper.py`,
`test_arch_news.py`, `test_brew_helper.py`, `test_pacman_helper.py`,
`test_flatpak_helper.py`, `test_simulate.py`, `test_appimage_squashfs.py`, and
`test_shell_portability.py` —
which reads every `sh -c` snippet in the QML for bash-only syntax, because
`/bin/sh` is dash on Debian and Ubuntu and a bashism there produces no error,
only wrong output.

`test_flatpak_files.py` is the exception: installing a `.flatpak` or
`.flatpakref` is tested against the real libflatpak, in throwaway
installations and from a repository it builds itself, so it needs `flatpak`
and its typelib (CI installs them in an Ubuntu container). Without them it
skips.

None of that reads the QML as QML, which is most of this plugin.
`scripts/qmllint.sh` does, and it is a local tool rather than a CI step for a
reason worth knowing: the `qs.*` imports are not modules on disk — Quickshell
synthesises them from the running shell's root under `$XDG_RUNTIME_DIR`, which
no runner has. Without them qmllint cannot resolve `DankToggle`, `Theme` or
`PluginService` and answers with 2586 warnings about code that is fine; the
script mirrors that root into a scratch tree with a generated `qmldir` per
directory first, and the same run comes back with a couple of hundred, nearly
all of them the same handful of unprovable shapes (`Loader.item`, a `view`
property typed as `Item` that callers hand a `DankListView`).

So: run it against a running DMS, and read it as a diff against that floor
rather than as a list to empty. What it is good at is the declarative
mistake — a property assigned that the type does not have, a required
property left unset, two interceptors on one property. What it does not see
is the same mistake made in JavaScript: `someProcess.arguments = [...]` on a
`Process`, which has no such property, passes without a word.

## Recording a run, and playing it back

Nothing the updater window draws comes from the system directly: every phase,
row, byte counter and error arrives as NDJSON on some helper's stdout. So a
recording of those streams is a recording of everything the window can show,
and playing one back puts the whole interface through a real run — same rows,
same order, same pauses — without root, without a network, and without waiting
for a distribution to ship thirty updates. Otherwise the visual side of a run
can only be worked on when there happens to be something to install, and then
only once, because installing it is what makes it stop being pending.

The seam is one function: every process a run starts asks
`Backend.instrument()` for its command and gets back the real one, the real one
wrapped in a recorder, or `scripts/simulate.py` reading a recording. The engine
above it cannot tell which — a simulation taking a different path through the
engine would be a simulation of a different program.

Under the gear, on a working copy only, there is a **Developer** section: arm
*Record the next update run*, update as usual, and the run lands in
`recordings/`. Each recording is then a row with a **Play** button and a
playback speed. The same without the mouse:

```sh
dms ipc call dankSoftwareDepotDev record on          # arm the recorder
dms ipc call dankSoftwareDepotDev recordings         # what is on disk
dms ipc call dankSoftwareDepotDev simulate run-20260905-101500
dms ipc call dankSoftwareDepotDev simstatus          # where a replay stalled
dms ipc call dankSoftwareDepotDev simulate off
```

A working copy means the plugin directory is a symlink — the same test the
self-update makes before refusing to update a checkout. The dev IPC target is
`enabled:` on it, and a handler that is not enabled registers nothing, so a
normal install neither lists it in `dms ipc show` nor can call it.

A recording is a directory: `meta.json` holds what was pending when it was
taken (the daemon cannot be asked afterwards — the packages are installed), and
one `<pass>.jsonl` per stream, each line carrying its own timestamp. They are
gitignored, being one machine's package inventory at one moment; `git add -f`
one worth sharing.

Two things a replay leaves out, both for want of a stream of ours to record:
the shell's own packages, which go through the DMS daemon, and anything a
simulated run would otherwise write down — the action log, the reboot notice,
the "last updated" time and the duration estimate all sit out a replay, because
none of it happened.

Recording is deliberately hard to fail with: it sits between the shell and a
transaction that is really installing packages, so anything that goes wrong
setting up the recording falls through to running the command untouched.

One thing to know when working on `Backend.qml`: it is a QML singleton, and
`dms ipc call plugins reload` rebuilds the widget while keeping the singleton.
Changes to it need the shell itself restarted. The same goes, less visibly,
for the other files the widget instantiates — `MetadataStore.qml`, say: the
reload builds the new `UpdaterWidget.qml` on the type compiled earlier, so a
function added to the store does not exist yet, and a binding that calls it
evaluates to `undefined` without a word in the log.

## Screenshots

The README's pictures are made by the plugin itself, so they can be brought
up to date in one command instead of thirteen sessions with a screenshot
tool:

```sh
python3 scripts/screenshots.py          # light mode; --dark for dark
```

It needs a working copy (the same symlink test as above), a running shell
with the plugin enabled, and Pillow. What it does:

- **English, whatever the machine speaks.** `Tr.forcedLang` overrides the
  catalog, the fallback to DMS's own catalog and the date formats, and a
  file in the runtime dir (`dsd-lang`) tells `enrich.py` to pick English
  AppStream text. Both are undone at the end, also when a step fails.
- **Pending updates from the action log.** `simulate.py from-log` turns the
  newest updates the log records into `recordings/screenshots-demo`, played
  as a replay so the Updates tab and its details popup have something to
  show; `screenshots-empty` gives the up-to-date dashboard. The run in
  progress plays a real recording: the one with the most packages up to 50,
  or `--run NAME`.
- **Light mode and a fixed size.** The shell is switched to light mode and,
  on niri, the window floats at 883 × 938 for the duration; both go back
  afterwards. Elsewhere the window is shot at the size it has.
- **The shots themselves** are taken in QML by `ScreenshotDirector.qml`,
  one scene after another (`dms ipc call dankSoftwareDepotDev shots …`,
  `shotstatus` for progress). Each scene waits until it has settled — data
  loaded, popup filled — and a step that never settles is shot anyway and
  named in the status. The window's own root item cannot be grabbed from
  QML (Quickshell creates it in C++, without a QML engine), so
  `UpdaterWindow.grabWindow` hangs every child under a stage item for the
  length of one grab.
- **The frame** — the gradient the hand-made screenshots had, measured from
  them, rounded corners with transparency, a soft shadow — is added by the
  script, into `screenshots/` and `screenshot.png`.

Everything else in the pictures is the machine as it is: the installed
software, the firmware, the log. Look them over before committing.
