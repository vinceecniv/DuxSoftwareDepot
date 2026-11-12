# Security

This plugin installs, updates and removes software. It hands transactions to
the DMS daemon, adds repositories, writes desktop entries into your home
directory, and renders release notes fetched from the network. Any of those is
worth a careful report.

## Reporting

Use GitHub's private reporting:
**[Report a vulnerability](https://github.com/vinceecniv/DuxSoftwareDepot/security/advisories/new)**.
It opens a private advisory that only you and the maintainer can see.

Please do not open a public issue for something exploitable. This is a
single-maintainer project, so expect an acknowledgement within a week rather
than within a day; if a fix is warranted it ships in the next release and the
advisory says what changed.

Include the plugin version, the distribution, and what an attacker would have
to control to make it happen.

## Supported versions

The plugin is in beta and moves quickly. Only the latest release is fixed;
there are no backports to earlier versions.

## In scope

- The Python helpers in `scripts/` — anything that turns untrusted input into
  a command, a path or a package name: search results, AppImage file contents,
  repository definitions, changelog and AppStream data
- The `.appimage` default-handler association, and what happens to a file that
  is opened but not yet trusted
- Release notes and reviews rendered in the UI: everything external is reduced
  to an escaped minimal markup subset, and a way past that is a bug
- The opt-in sudoers rule on Arch (`scripts/sudoers_rule.py`): it is meant to
  be one line naming `/usr/bin/pacman` for the user who asked. A rule that
  grants more, or reaches another user, is a bug
- Repository and Copr handling, including anything that would enable a source
  or accept a key without the user pressing the button that says so
- Data leaving the machine beyond what the README's *Network and privacy*
  table describes

## Not in scope

- Dux Shell (DMS), its update daemon and its polkit policy — report
  those at [Dux Shell](https://github.com/duxlabs-dev/dux-shell)
- Vulnerabilities in dnf, rpm-ostree, apt, pacman, flatpak or fwupd themselves
- Vulnerabilities in the software you install with it
- The third-party services it reads from (ODRS, Flathub, LVFS, appimage.github.io)
- That an AppImage is unsandboxed code you chose to run. The plugin manages
  such files; it does not vouch for them
