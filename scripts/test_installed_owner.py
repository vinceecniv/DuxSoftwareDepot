#!/usr/bin/env python3
"""Checks that an app installed under a package its catalog does not name
shows as installed, under the package that is really there.

The case is #49: CachyOS's chatgpt-desktop-bin ships a metainfo file that
names "chatgpt", which no repository has. The Install tab showed Install,
and Install ran `pacman -S chatgpt`. The package manager is replaced by
stand-ins here: what matters is which questions are asked and what is done
with the answers, not pacman's output format, which _owners_of already
parses for the desktop-owners path.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import enrich  # noqa: E402
import pkg_backend  # noqa: E402

failures = []


def check(label, got, want):
    if got == want:
        print(f"  ok   {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label}\n       got:  {got!r}\n       want: {want!r}")


ON_DISK = {
    "/usr/share/metainfo/com.openai.chatgpt.metainfo.xml": "chatgpt-desktop-bin",
    "/usr/share/applications/org.gnome.Loupe.desktop": "loupe",
    "/usr/share/metainfo/org.libreoffice.Writer.metainfo.xml": "libreoffice-writer",
}
INSTALLED = {"chatgpt-desktop-bin", "loupe", "libreoffice-writer", "libreoffice-still"}
asked = []

pkg_backend.os.path.exists = lambda path: path in ON_DISK
pkg_backend._owners_of = lambda paths: [(p, ON_DISK[p]) for p in paths if p in ON_DISK]


def installed_subset(names):
    asked.append(list(names))
    return set(names) & INSTALLED


pkg_backend._installed_subset = installed_subset

print("installed_app_owners")
owners = pkg_backend.installed_app_owners({
    "com.openai.chatgpt": "chatgpt",          # the catalog's name does not exist
    "org.gnome.Loupe": "loupe",               # right name: nothing to say
    "org.libreoffice.Writer": "libreoffice-still",  # installed metapackage: keep it
    "org.example.NotHere": "nothere",          # not on disk: never asked about
})
check("the package that owns the metainfo replaces the missing name", owners, {"com.openai.chatgpt": "chatgpt-desktop-bin"})
check("only names that disagree with the owner are checked", asked, [["chatgpt", "libreoffice-still"]])

asked.clear()
check("nothing on disk, nothing asked", pkg_backend.installed_app_owners({"org.example.NotHere": "nothere"}), {})
check("not even whether anything is installed", asked, [])

print("correct_installed_refs")
items = [
    {"id": "com.openai.chatgpt", "sources": [{"source": "fedora", "kind": "dnf", "ref": "chatgpt"},
                                             {"source": "flathub", "kind": "flatpak", "ref": "com.openai.chatgpt"}]},
    {"id": "org.gnome.Loupe", "sources": [{"source": "fedora", "kind": "dnf", "ref": "loupe"}]},
]
enrich.correct_installed_refs(items)
check("the system source points at the installed package", items[0]["sources"][0]["ref"], "chatgpt-desktop-bin")
check("a Flatpak source of the same app is left alone", items[0]["sources"][1]["ref"], "com.openai.chatgpt")
check("a right name stays", items[1]["sources"][0]["ref"], "loupe")

print()
if failures:
    print(f"{len(failures)} check(s) failed")
    sys.exit(1)
print("all checks passed")
