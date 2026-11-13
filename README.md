# <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icons/dux-software-depot-dark.svg"><img src="assets/icons/dux-software-depot-light.svg" alt="" width="42"></picture> Dux Software Depot

[![Release](https://img.shields.io/github/v/release/vinceecniv/DuxSoftwareDepot?label=release&color=6750A4)](https://github.com/vinceecniv/DuxSoftwareDepot/releases)
[![Checks](https://github.com/vinceecniv/DuxSoftwareDepot/actions/workflows/checks.yml/badge.svg)](https://github.com/vinceecniv/DuxSoftwareDepot/actions/workflows/checks.yml)
[![License](https://img.shields.io/badge/license-MIT-informational)](LICENSE)
![Status](https://img.shields.io/badge/status-beta-orange)
![DMS](https://img.shields.io/badge/DMS-%E2%89%A5%202.0-6750A4)
[![Languages](https://img.shields.io/badge/languages-16-6750A4)](#languages)

**Manages** ![System packages](https://img.shields.io/badge/system%20packages-dnf%20%C2%B7%20apt%20%C2%B7%20pacman%20%C2%B7%20rpm--ostree-4A4458)
![Flatpak](https://img.shields.io/badge/Flatpak-4A4458)
![AppImage](https://img.shields.io/badge/AppImage-4A4458)
![Firmware](https://img.shields.io/badge/firmware-fwupd%20%C2%B7%20LVFS-4A4458)
![DMS plugins](https://img.shields.io/badge/DMS%20plugins-4A4458)
![Homebrew](https://img.shields.io/badge/Homebrew-4A4458)

A full software & updates center plugin for
[Dux Shell](https://github.com/duxlabs-dev/dux-shell) (DMS, formerly
DankMaterialShell):
everything the built-in updater does, plus app logos, release notes, reviews,
honest per-package progress, an app store, [full AppImage
management](#appimages-end-to-end), firmware support and an action log — and no
terminal output anywhere.

> [!NOTE]
> **Unofficial.** Dux Software Depot is a community plugin, made and maintained
> by an independent developer. It is not a Dux Labs product, and Dux Labs does
> not support it: problems with it belong in [this repository's
> issues](https://github.com/vinceecniv/DuxSoftwareDepot/issues), not with them.
> The name is used with their permission.

Until October 2026 this plugin was called **Dank Software Depot**; it follows
the shell's rename. Existing installs keep working and keep their settings:
the plugin id is still `dankSoftwareDepot`.

![The Updates tab: pending system packages as cards, each with its old and new
version, above Update All](screenshot.png)

Built on the DMS system update service: the `dms` daemon does update detection,
and polkit prompts appear through the DMS agent.

## Status

- **Beta** — actively developed, things may move around
- **Fedora, Nobara** — the supported case: libdnf5 and Fedora AppStream
  metadata
- **RHEL, CentOS Stream, AlmaLinux, Rocky** — the same, through dnf 4, which
  is all they ship. Tested on CentOS Stream 10 and AlmaLinux 10. Package
  changelogs are not shown there, because dnf 4 does not download them by
  default
- **Debian/Ubuntu, Arch, atomic Fedora** — implemented, experimental, and said
  so in a banner. Atomic runs through `rpm-ostree`, so everything lands in the
  *next* boot. On Arch, AUR updates are detected by the DMS daemon and by
  default installed through its own paru/yay pass, in a terminal. *Update AUR
  packages without a terminal* in the settings runs paru or yay in the
  background instead, with no PKGBUILD review. *Run pacman without a
  password* adds a sudoers rule for `/usr/bin/pacman` (one prompt to set it
  up), after which installing, removing and updating packages, AUR included,
  asks nothing.
  `-git` packages join that pass once devel is on in your helper:
  `yay -Y --devel --save`, or `Devel` in `paru.conf`
- **Flatpak, AppImage and firmware** work the same everywhere

[PROTOCOL.md](PROTOCOL.md) has the table of differences per backend.

## The five tabs

### 1 · Updates

- **Rich update cards** — logo, name, summary, `old → new`, homepage, release
  notes, and an update button per app
- **Sections** — Applications, System, Runtimes, Firmware, Homebrew, DMS
  plugins, Held — each with its own *Update these* button, headings staying put
  as you scroll
- **Held packages** — dnf versionlock and excludepkgs found automatically, plus
  your own holds; never counted, never updated. A hold on top of a security fix
  says so
- **Security advisories** from the distro's updateinfo, read locally: graded
  critical to low, with CVE numbers in the details
- **Real byte progress per package** during a run, the list regrouped into In
  progress, Waiting and Completed
- **A failure keeps its reason** on the card, with the tool's verbatim output
  under *Show details*
- **Notes for git builds** come from the upstream forge, since a `*-git`
  package has no distro release to describe
- **Arch Linux news** where it is published — announced only when something is
  unread, kept in an archive afterwards
- **Homebrew and DMS plugins** update in their own phases; DMS's own packages
  run last, because they reload the shell
- **Reboot notice** and end-of-life Flatpaks
- **Upgrading to the next Fedora release** — what it involves (size,
  packages, removals, repositories not ready yet) before anything is
  downloaded, the download in the background, then restart and upgrade
- **Automatic updates** — off, notify only, or auto-install Flatpaks
- **A dashboard when there is nothing to do** — counts per source, system info,
  reclaimable space, and what the last year of the log adds up to

| ![A run in progress: phase stepper, downloaded bytes, and a progress bar per package](screenshots/update-in-progress.png) | ![The up-to-date dashboard with installed-software counts, system info and recently updated packages](screenshots/updates-dashboard.png) |
|---|---|
| **A run in progress.** The list regroups around what is happening, and every row carries its own byte-accurate progress bar. | **Nothing to do.** Counts per source, system information, what was updated recently — and the reboot banner when one is recommended. |

### 2 · Installed

- **Everything in one list** — Flatpaks, system packages, AppImages, Homebrew
  formulae and DMS plugins, with live search, source filters and sorting by
  name, size or date
- **Applications first**, supporting packages after
- **A details popup** with description, screenshots, ODRS ratings and reviews,
  release notes, homepage and sandbox permissions — and you can write a review
- **Where it comes from** — the same side-by-side source comparison the Install
  tab uses, with the one you have marked
- **Actions** — uninstall, hold, open, and restore a previous version (Flatpak
  commits, rpm downgrade)
- **Link an AppImage to a GitHub project** and its releases become its update
  channel
- Phase text and a progress bar on every change, never terminal output

| ![The Installed tab: search, source filters, applications grouped before supporting packages](screenshots/installed-library.png) | ![The details popup for VLC with screenshots, description, sandbox permissions and reviews](screenshots/app-details.png) |
|---|---|
| **Everything installed, in one list.** Flatpaks, system packages and AppImages together, applications first. | **The details popup**, shared with the Install tab: screenshots, permissions, install counts and ODRS reviews. |

### 3 · Install

- **A storefront to walk through** — thirteen Flathub categories,
  most-downloaded first, each heading opening onto the whole section rather
  than a shelf. Games is nearly 900 apps
- **Search across system repos, Flathub and package names**, so plain CLI tools
  are found too, with chips to narrow to one kind
- **One Install button.** When an app has more than one source a picker puts
  them side by side — version, size, sandboxing, permissions, who stands behind
  it, and what each kind of packaging costs you
- **Search Copr** for what no configured repository carries: one deliberate
  press, only projects building for this Fedora, and enabling the repository is
  part of the same transaction
- **Search Homebrew** where brew is installed — macOS-only formulae are greyed
  with the reason rather than dropped
- **Software sources** — repositories and Flatpak remotes with switches,
  one-click RPM Fusion and Flathub, Copr add and remove (dnf family; apt and
  pacman read-only)
- ODRS ratings, live install progress, [AppImages](#appimages-end-to-end), and
  a button through to DMS's own plugin screen

| ![The Install tab storefront: popular apps by category with ratings and a source button per app](screenshots/install-storefront.png) | ![The Software sources dialog with Flatpak remotes, well-known sources to add, and repository switches](screenshots/software-sources.png) |
|---|---|
| **The storefront** before you type anything: sections by category, most-downloaded first, each heading opening onto the whole section. | **Software sources.** Flatpak remotes, one-click Flathub and RPM Fusion, and the configured repositories with debug and source ones folded away. |

### 4 · Firmware

fwupd device inventory: which hardware supports firmware updates, current
versions, on-demand LVFS release notes. Pending firmware updates appear in the
Updates tab and run in the firmware phase of Update All.

![The Firmware tab: fwupd devices with vendor, current firmware version and an updatable
chip](screenshots/firmware-devices.png)

### 5 · Log

- **Everything the plugin did** — runs, installs, removals, restores, holds —
  expanding to per-package detail
- **A row that never finished says so**: a clock, not a tick, and it heals
  itself when a later check finds the package did land
- **What it cannot account for** — packages changed by a terminal, a timer or
  another software centre, counted and named separately
- **Follows the interface language**, because an entry is stored as a key and
  its numbers rather than as a finished sentence
- Searchable, and kept for two years

| ![The Log tab: a timeline of update runs, installs and removals, with a notice about packages changed outside the app](screenshots/log-history.png) | ![The details popup for a Firefox update: description, a critical security fix, and what is new](screenshots/security-changelog.png) |
|---|---|
| **What happened, and when.** Grouped by day, with the packages that changed outside this app called out separately. | **What an entry closes.** Release notes and rpm changelogs, CVE numbers included, read from what is already on the machine. |

## AppImages, end to end

An AppImage is a file, not a package: nothing knows it exists, nothing tells
you when it changes, and deleting it leaves its menu entry behind. The whole
life of one is handled here.

- **Find one** in the appimage.github.io index (1400+ apps), listed beside repo
  and Flathub results
- **Install one** from GitHub releases, a URL, or a file you already have. They
  land in `~/AppImages` — Gearlever's folder, and its setting is honoured
- **Double-click a `.appimage`** and this window offers to install it, or to
  replace the build you already have. A fresh download is never executable,
  which is exactly when double-clicking otherwise does nothing at all. This
  is a switch in the plugin settings, off until you turn it on
- **It shows up like an app** — icon and desktop entry read from the image.
  They are read straight out of its filesystem, so nothing in the file runs
  until you start the app yourself
- **Existing AppImages are adopted**, including ones installed before this
  plugin existed
- **Updates** come from a linked GitHub project and run in their own phase
- **Uninstall** takes the file, its desktop entry, its icon and its record

![Double-clicking an .appimage opens this dialog, which recognises the build already installed
and offers to replace it](screenshots/appimage-install.png)

## Bar widget & popout

- **The pill** shows the effective update count, spins while checking, counts
  completed/planned during a run, and turns into a restart icon when a reboot
  is recommended
- **The popout** has the enriched list, Update All, and the phase and item
  during a run. A check pulses the DMS logo rather than replacing it
- Optionally: hide the pill when up to date, or have a click open the window

## Settings & command palette

Everything the plugin decides for itself is in one dialog behind the gear;
everything it can do is one **Ctrl+K** away. Check interval and ignored
packages stay with DMS, and the dialog links straight to them. The same
switches appear on the plugin's page in DMS Settings → Plugins, so whichever
one you find first is the whole set.

Two worth knowing about:

- **App icons in the theme colour.** Off by default — an app's icon is its own
  identity — but some palettes make a wall of unrelated logos look like
  confetti.
- **Authorise with sudo.** Off by default, for machines with a `NOPASSWD`
  sudoers rule: privileged commands then run under `sudo -n` instead of
  `pkexec`, falling back to the polkit prompt whenever sudo would ask. DMS's
  own packages and firmware keep their own polkit actions either way.

| ![The plugin settings dialog with switches for the bar pill, firmware, the launcher entry and the .appimage association](screenshots/plugin-settings.png) | ![The command palette listing tabs, check for updates, software sources and settings](screenshots/command-palette.png) |
|---|---|
| **Plugin settings.** What the pill shows, whether firmware joins Update All, the launcher entry, themed app icons, and who opens `.appimage` files. | **Ctrl+K.** Every tab, the actions around them, and the two dialogs — without going looking for a button. |

## Languages

English, Dutch, German, French, Spanish, Portuguese, Italian, Polish, Swedish,
Ukrainian, Russian, Hungarian, Japanese, Korean, Vietnamese and Chinese
(Simplified) — sixteen. DMS has no per-plugin i18n mechanism, so the plugin
brings its own: `translations/<lang>.json`, keyed by the English source string,
following the DMS/system locale and falling back to the DMS catalog and then
English. Add a language by dropping a file next to the others.

## Requirements

- A Fedora-based distribution — or an atomic Fedora, Debian/Ubuntu or Arch
  (all three experimental)
- DMS ≥ 2.0 with the `sysupdate` daemon capability
- `python3` and `flatpak`, optionally `fwupd`, optionally Homebrew
- Package-manager bindings for your distro:
  - Fedora: `python3-libdnf5` (**not** part of a default install)
  - RHEL, CentOS Stream, AlmaLinux, Rocky: `python3-dnf` (always installed)
  - Atomic Fedora: nothing extra — `rpm-ostree` is the image's own tool
  - Debian/Ubuntu: `python3-apt` (usually preinstalled)
  - Arch: `pyalpm`
- Flatpak bindings — PyGObject *and* the Flatpak typelib, which are two
  packages:
  - Fedora: `python3-gobject-base` (the typelib comes with `flatpak-libs`)
  - Debian/Ubuntu: `python3-gi` **and** `gir1.2-flatpak-1.0`, which `flatpak`
    does not pull in
  - Arch: `python-gobject`

Without the package-manager bindings no system package can be installed,
updated or removed; without the Flatpak ones no Flatpak can. The plugin checks
both at startup and offers to install what is missing, naming the packages for
your distribution.

Optional, for AppImage icons on Python older than 3.14: `python3-zstandard`
(`python-zstandard` on Arch). Most AppImages are zstd-compressed, and the
plugin reads their icon and name without running them; without a zstd module
those show a generic icon. Python 3.14 has one built in.

Optional, for richer app information: the AppStream catalog for your distro —
`appstream-data` on Fedora, `appstream` on Debian/Ubuntu,
`archlinux-appstream-data` on Arch. Without it the plugin falls back to package
summaries and the icons in your desktop entries, so apps still look like apps.

## Install

```bash
dms plugins install dankSoftwareDepot
dms restart
```

Or by hand — `~/.config/dms` since Dux Shell 2.0, `~/.config/DankMaterialShell`
before it:

```bash
git clone https://github.com/vinceecniv/DuxSoftwareDepot ~/.config/dms/plugins/dankSoftwareDepot
dms restart
```

Enable **Dux Software Depot** in DMS Settings → Plugins; its settings page puts
the widget on the bar.

To launch it from the app launcher, let the app place the entry: the Updates
tab offers it once, and **Settings → Show in app launcher** toggles it any
time. Entry and icon go into your home directory — no root — and switching it
off removes them again. The entry calls the IPC below, so DMS has to be
running.

<details>
<summary>The same by hand</summary>

```bash
sed "s|@OPEN@|$PWD/scripts/open.sh|" io.github.vinceecniv.DuxSoftwareDepot.desktop \
  > ~/.local/share/applications/io.github.vinceecniv.DuxSoftwareDepot.desktop
chmod +x scripts/open.sh
install -Dm644 assets/icons/dux-software-depot-dark.svg \
  ~/.local/share/icons/hicolor/scalable/apps/dux-software-depot.svg
install -Dm644 assets/icons/dux-software-depot-symbolic.svg \
  ~/.local/share/icons/hicolor/symbolic/apps/dux-software-depot-symbolic.svg
update-desktop-database ~/.local/share/applications
```

The icon step is not optional: the entry names an icon, and without it the
launcher shows a blank one. An entry written by an older version of the plugin
is rewritten once, automatically, the next time the window opens — including
one from before the rename, which is replaced by the new name along with its
icon and any .appimage association.

</details>

### IPC

```bash
dms ipc call dankSoftwareDepot open      # open the window
dms ipc call dankSoftwareDepot toggle
dms ipc call dankSoftwareDepot tab 2     # a specific tab (0-4)
dms ipc call dankSoftwareDepot check     # trigger an update check
dms ipc call dankSoftwareDepot updateAll
dms ipc call dankSoftwareDepot updateFlatpakOne org.example.App
dms ipc call dankSoftwareDepot openAppimage /path/to/App.AppImage
```

## Network and privacy

The plugin contains **no tracking of any kind**: no analytics, no telemetry, no
crash reporting, no identifier that follows you. There is no server belonging
to this project — nothing is ever sent to its author.

One request happens without you asking: half a minute after the shell starts,
and once a day after that, the plugin fetches its own `plugin.json` and
`CHANGELOG.md` from GitHub to see whether a newer version exists. Plain file
fetches, nothing identifying, skipped entirely on a development checkout.
Everything else below happens because you opened, checked or pressed something.

| Where | What for | When |
|---|---|---|
| your configured repositories, Flatpak remotes, LVFS | the package work itself: metadata, downloads, firmware | checking and updating |
| `raw.githubusercontent.com` | this plugin's own `plugin.json` and `CHANGELOG.md`, to offer its update | 30 seconds after the shell starts, then daily; never on a symlinked install |
| `odrs.gnome.org` | star ratings and review texts (Open Desktop Ratings Service) | opening an app's details |
| `flathub.org/api/v2` | install counts, download size, sandbox permissions, verified status | opening a Flatpak app's details |
| `flathub.org/api/v2` | installs over the last month for the thousand most-installed apps, which is what orders the storefront | once a day, when the Install tab is loaded |
| the screenshot URLs in AppStream data | the screenshots themselves, cached locally for 30 days | opening an app's details |
| `appimage.github.io`, `api.github.com` | the AppImage catalogue and the releases of an AppImage's linked project | the Install tab and AppImage updates |
| `api.github.com` | for a package built from git, the notes of the release being installed or the commits between two snapshots | opening the details of such an update; cached a day, and a package not built from git never asks |
| `bodhi.fedoraproject.org` | which Fedora releases are current, for the release-upgrade notice | the upgrade check |
| `formulae.brew.sh`, `github.com`, `ghcr.io` | Homebrew's own traffic, run by brew rather than by this plugin | only where brew is installed — the index at most every six hours, bottles only during an update you started |
| `archlinux.org` | the Arch news feed | on Arch only, at most every six hours while the window is open |
| `copr.fedorainfracloud.org` | which Coprs build a package matching your search, and for which Fedora | only when you press Search Copr; cached six hours |
| `mirrors.rpmfusion.org`, `dl.flathub.org`, `nightly.gnome.org`, `cdn.kde.org`, `registry.fedoraproject.org` | fetching a source you asked to add | only when you press Add in Software sources |

Two details worth stating plainly, because they are the only places where
anything about you leaves the machine:

- **Reading reviews** sends a `user_hash` that is the same constant for every
  installation (`sha1("dankSoftwareDepot")`). ODRS requires the field; this one
  identifies nobody.
- **Writing a review** is the only outgoing request carrying anything
  machine-specific. ODRS deduplicates and moderates by user, so the submission
  carries a hash of your username and `/etc/machine-id`, along with the display
  name you type — leave that empty and your login name is published instead,
  which is why the field says so before you press send. Nothing is submitted
  unless you write a review and press the button.

## If you use it

Two links, and they cost nothing:

- **[Upvote it in the DMS plugin
  directory](https://github.com/duxlabs-dev/dux-plugin-registry/issues/720)** —
  a 👍 on the registry issue. That reaction count is how the directory knows
  which plugins people actually run.
- **[Star the repository](https://github.com/vinceecniv/DuxSoftwareDepot)** —
  if it is doing its job on your machine.

Bug reports and feature requests are welcome as
[issues](https://github.com/vinceecniv/DuxSoftwareDepot/issues) — the
templates ask for the distribution and the versions, because with four package
managers behind this thing that is usually what decides where the fault is.

## Development

Architecture, the helper protocol, the checks, and how to record an update run
and play it back: [DEVELOPMENT.md](DEVELOPMENT.md) and
[PROTOCOL.md](PROTOCOL.md).

## License

MIT — see [LICENSE](LICENSE).
