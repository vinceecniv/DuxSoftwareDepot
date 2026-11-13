# Package-helper event protocol

The QML layer never scrapes package-manager output. Every transaction runs
through a small privileged helper that talks to the package manager's
*library* and reports newline-delimited JSON (NDJSON) events on stdout.
These helpers implement the protocol today:

| Helper | Library | Covers |
|---|---|---|
| `scripts/rpm_helper.py` | libdnf5 (python3-libdnf5) | rpm install / remove / upgrade / downgrade / plan |
| `scripts/dnf4_helper.py` | dnf 4 (python3-dnf) | the same, on RHEL and its rebuilds, which have no libdnf5; `rpm_helper.py` hands over to it |
| `scripts/ostree_helper.py` | rpm-ostree (command line) | atomic Fedora: layering, removal and whole-deployment upgrades |
| `scripts/apt_helper.py` | python-apt (python3-apt) | deb install / remove / upgrade / downgrade / plan |
| `scripts/pacman_helper.py` | pyalpm | pacman install / remove / upgrade / plan (official repos only, no AUR) |
| `scripts/flatpak_helper.py` | libflatpak (gi) | flatpak update / install (+ eol listing) |

`Backend.qml` picks the transaction helper from the detected distro
family (`/etc/os-release`). The protocol is deliberately package-
manager-agnostic — the QML layer needs no changes per backend. See
[Porting inventory](#porting-inventory) for what lives outside it.

## CLI contract

```
<helper> [plan] <action> <spec>...
```

- Actions: `install`, `remove`, `upgrade`, `downgrade`.
- `<spec>` is a package name or name-version in the package manager's
  native spec syntax. Dependencies are the resolver's job — callers pass
  the packages the user chose, never a dependency closure.
- Transactions require root (run via `pkexec`). Prefixing any action with
  `plan` resolves it against the existing metadata cache, prints the
  `plan` event and exits — it must work unprivileged and make no changes.
  That prefix is what lets a UI show the consequences of a transaction
  *before* asking for a password: the helper runs under `pkexec`, which
  prompts when the process starts, so a plan produced inside the real run
  would arrive after the authentication it is meant to inform.
- One pacman-only action: `sysupgrade [<name>...]` is `pacman -Su`, every
  installed package the repositories have newer, except the names given —
  which here are the ones to leave alone, not the targets. The update run
  uses it on Arch: it refreshes the databases first, and they can know of
  updates its list was checked too early to show; upgrading only the listed
  ones after that refresh would be a partial upgrade, which Arch does not
  support. It names the held packages and the shell's own (those have a
  final pass of their own); `IgnorePkg` is pacman's to apply. `done.failed`
  stays empty for it, the names given not being its targets.
- One pacman-only option: `--via-sudo` before the action runs it as the
  user, for a machine where sudo lets the user run `/usr/bin/pacman` without
  a password (`scripts/sudoers_rule.py` writes that rule). `sudo pacman -Sy`
  refreshes, pyalpm resolves against a private database directory — the
  same `plan` event — and `sudo pacman -S` (or `-R`) downloads into the
  system cache and installs. Progress comes from the file system: a
  package's file appearing in the cache (pacman moves it there whole) is
  its download `op-done`, its directory appearing in the local database (or
  going, for a removal) its install `op-done`. When sudo would ask, or a pacman lock that no
  running package manager explains is in the way (clearing it needs root,
  which the rule does not give), the helper does nothing, sends one `status`
  event saying which (`sudo-asks` or `stale-lock`) and exits 3;
  `Backend.helperCommand` then takes the usual pkexec path, and the window
  shows that reason while the password prompt is up — the prompt's own text
  is polkit's and cannot carry it. A lock a running
  package manager holds is reported as such, with no prompt.
- One rpm-only option: `install --copr <owner/project> <spec>...` enables
  that Copr before resolving, so a package found by the Copr search costs
  one authorisation instead of two (the repository and the install are one
  thing to the person pressing the button). It is refused with any other
  action and skipped under `plan`, which is unprivileged. No other helper
  has an equivalent, because no other family has Copr.
- stdout carries only NDJSON events. stderr is free-form (never parsed).
- Exit code 0 on success, 1 on failure, 2 on usage errors. Regardless of
  the exit path, the last event on stdout is always `done`.

## Events

One JSON object per line. Unknown fields and unknown event types must be
ignored by consumers (forward compatibility).

| Event | Fields | Meaning |
|---|---|---|
| `status` | `message` | Coarse state before the plan exists (`"repos"` = refreshing repo metadata; pacman `--via-sudo` handing over to the usual path: `"sudo-asks"`, `"stale-lock"`) |
| `plan` | `ops: [{name, evr, action, downloadBytes, installBytes, fromEvr?}]`, `totalDownloadBytes`, `installDeltaBytes` | The resolved transaction — **the whole of it**, including packages the caller never asked for: dependencies pulled in, and anything the resolver decided to remove. `action` is a human string (`Install`, `Upgrade`, `Remove`, …); outbound-only ops have `downloadBytes: 0`. `installDeltaBytes` is the net disk change, incoming sizes minus outgoing. `fromEvr` (pacman) is the version installed now, where there is one |
| `op-start` | `name`, `phase`, `bytesTotal`? (download), `index`/`total`? (install/remove) | Work on one package begins in the given phase |
| `progress` | `name`, `phase`, `percent`, download also: `bytesTransferred`, `bytesTotal`, `totalTransferred` | Per-package progress. `percent` is the package's own 0–100 |
| `op-done` | `name`, `phase`, `totalTransferred`? | The package finished this phase |
| `op-error` | `name`, `phase`, `message` | The package failed this phase |
| `script` | `name` | A scriptlet/hook of that package is running |
| `warning` | `message` | Non-fatal problem worth surfacing in logs |
| `error` | `message` | Fatal problem (resolution, transaction). Followed by `done` |
| `done` | `ok`, `failed: [spec]`, `nothingToDo`?, `staged`? | Always the final event. `staged: true` means the transaction succeeded but changed the *next* boot rather than the running system — an image-based helper's answer, and the UI says so instead of claiming the package is in use |

Phases: `download`, `install`, `remove`. Package managers without a
distinct download phase simply never emit it.

### Invariants

- `totalTransferred` is the byte sum across **all** downloads of the
  transaction and is monotonically non-decreasing. UIs derive their
  overall download bar from `totalTransferred / totalDownloadBytes` —
  never from interleaved per-package percentages (parallel downloads make
  those jump).
- When a download ends, any bytes not yet reported are folded into
  `totalTransferred`, so it reaches `totalDownloadBytes` exactly.
- Install/remove phases are serial: `index`/`total` on `op-start` order
  the transaction; `percent` covers the current package only.
- Events for a package may interleave with other packages during the
  download phase, never during install/remove.
- Emitting `progress` at most on integer-percent changes keeps event
  volume bounded.

## Porting inventory

What a Debian/Arch port must provide, beyond a protocol helper:

**Neutral already** (no work): `flatpak_helper.py`, `appimage.py`, fwupd
firmware (fwupdmgr/LVFS), reviews (ODRS), Flathub metadata, the whole QML
layer at transaction level.

**The transaction seam** — `Backend.qml` holds the helper path the QML
call sites use. A port swaps this (or branches on the detected distro).

**Distro-specific, outside the protocol.** The metadata layer dispatches
per backend: on Fedora the dnf code paths in `enrich.py` run; on the
Debian family `scripts/pkg_backend.py` provides the apt implementations.

| Area | dnf | apt |
|---|---|---|
| Update checks & counts | DMS `SystemUpdateService` daemon | same daemon (backend support on the DMS side) |
| Shell self-update pass | DMS daemon — must survive the shell reload | same |
| Post-run verification | `rpm -q` version compare | `dpkg-query -W` (via `Backend.installedVersionsCommand`) |
| Name search fallback | dnf repoquery | `pkg_backend.name_search` |
| Package info fallback | dnf repoquery --info | `pkg_backend.package_info` |
| Update sizes | dnf repoquery --info | `pkg_backend.update_sizes` |
| Previous versions / restore | `dnf repoquery` + helper `downgrade` | `pkg_backend.available_versions` + helper `downgrade name=version` |
| Held packages | dnf versionlock/excludepkgs + DMS ignored list | `apt-mark showhold` + DMS ignored list |
| Installed inventory & dashboard | `rpm -qa` | `pkg_backend.installed_table` / `dashboard` (`.list` mtimes as install times) |
| Reboot recommendation | kernel/glibc/… name pattern | linux-image/libc6/… pattern (`Backend.rebootPackagePattern`) |
| Distro upgrade notice | Bodhi (Fedora releases) | not offered |
| Package changelogs | dnf/rpm changelog | `/usr/share/doc/<pkg>/changelog.Debian.gz` — the installed version, read locally |
| Notes for git builds | upstream GitHub, keyed on the rpm URL field | same, keyed on `pkg_backend.package_info` homepage |
| AppStream catalog for system apps | Fedora swcatalog XML | DEP-11 YAML from apt's lists and the appstream cache |

The pacman column of `pkg_backend.py` mirrors the same functions via a
read-only libalpm handle: real install dates, IgnorePkg holds, an
AUR/foreign count on the dashboard, and an always-empty previous-versions
answer (pacman repos keep no history). Its changelog answer comes from
`pacman -Qc`, which is empty for the many packages that ship none; Arch
reads its AppStream catalog from the same XML paths as Fedora, filled by
`archlinux-appstream-data`. AUR is deliberately out of scope for the
transaction helpers: detection comes from the DMS daemon's AUR backend
(paru/yay `-Qua`), and by default upgrades ride that same daemon pass —
`paru -Syu` in a visible terminal, the shell updater's own answer, with
the interactive PKGBUILD review. The opt-in *Update AUR packages without a
terminal* runs `scripts/aur_helper.py` instead: `paru -S --skipreview
--batchinstall` (or yay with its menus answered `None`) with no tty, sudo
replaced by `scripts/aur_sudo.sh`: sudo where it would not ask, polkit
otherwise. The AUR pass always follows the full official upgrade, which
refreshes the sync databases and brings the system up to them. It speaks a subset of
the protocol — `op-start`/`op-done` per build, `output`, `error`, `done` —
and the package database decides what arrived, as after a daemon pass.

### An atomic Fedora is a fourth backend, not a broken third

Silverblue, Kinoite, Bazzite and Bluefin run rpm packages but no rpm
transactions: `/usr` belongs to the image. `Backend.qml` detects them by
`/run/ostree-booted` — the one answer that does not depend on what the
image calls itself — and routes to `scripts/ostree_helper.py`.

| Area | mutable Fedora | atomic Fedora |
|---|---|---|
| Install / remove | libdnf5 transaction | `rpm-ostree install` / `uninstall`, layered, live at the next boot |
| Upgrade | per package | the whole deployment; the specs are reported, the transaction is the image |
| Downgrade / previous versions | `dnf repoquery` + `downgrade` | refused: going back is the previous deployment (`rpm-ostree rollback`) |
| Plan | resolved unprivileged against the cache | answered from what was asked: rpm-ostree resolves inside its daemon, which asks polkit even for `--dry-run` |
| Repository list & switches | libdnf5 | the `.repo` files themselves (`repo_backend.list_repo_files`) |
| Adding a Copr | `dnf copr enable` | the hub's own `.repo` file, fetched and written — the same file under the same name |
| Removing a base package | ordinary removal | refused with a reason: it needs `rpm-ostree override remove`, which changes what the image is |
| After a successful run | in use | `done` carries `staged: true`, the UI says "takes effect after reboot" and raises the reboot notice |

Two notes on the metadata sources, both of which apply to Fedora too:
changelogs and AppStream data are only as present as their distro
package (`appstream-data`, `appstream`, `archlinux-appstream-data`) —
without it, names and icons fall back to the package manager and the
desktop entries on disk. And a package's changelog outside dnf describes
the *installed* version: fetching the pending version's changelog would
mean a network round trip inside a synchronous popup, which is not worth
it.

Known open item for parity: confirming the DMS daemon's update checks on
real installs of both families. The metadata layer itself is complete.
