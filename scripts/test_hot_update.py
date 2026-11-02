#!/usr/bin/env python3
"""Checks that an update in place can load without a shell restart.

The shell updates a plugin while it runs, and until it restarts it rebuilds
only the plugin's entry files: the ones plugin.json names (the widget and
the settings page), which it loads under a fresh `?revision=` URL. For
everything else it keeps what it had:

- every other QML file stays as the shell compiled it at startup, so the new
  entry file runs on the old versions of the files it uses;
- the plugin folder stays as the shell listed it at startup, so a QML or JS
  file the update adds cannot be found at all — not by type name ("X is not
  a type") and not by path ("File name case mismatch").

The second one fails loudly: an entry file that names a newer file does not
load, and the plugin is gone until the shell restarts (#42: FedoraUpgrade,
new in 1.8, used by the widget). Reinstalling does not help either.

So the entry files may only use sibling files that every version a user
might update from already had. That is BASELINE: the folder as 1.0.0 shipped
it. Something newer that the widget needs goes in UpdaterWidget.qml as an
inline component (`component Name: Item { … }`, as FedoraUpgradeJob does);
files that only other files use can be added freely, because until the
restart those other files are still the old ones and do not ask for them.

A name is resolved when the file is compiled, whether or not that part ever
runs, so an inactive Loader with a `sourceComponent: NewType { … }` fails
just the same. A path inside an inactive Loader is only looked up when it
loads: those are listed in BY_PATH, each with why it does not load in a
stale shell.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The plugin folder's QML and JS files as 1.0.0 (2026-08-19) shipped them:
#   git ls-tree --name-only v1.0.0 | grep -E '\.(qml|js)$'
# Moving this forward drops in-place updates from older versions.
BASELINE = frozenset("""
    ActionLog.qml AppDetailsDialog.qml AppimageOfferDialog.qml Backend.qml
    BusyText.qml CommandPalette.qml FieldPlaceholder.qml FirmwareService.qml
    FirmwareView.qml InstalledView.qml InstallView.qml LogView.qml
    MetadataStore.qml NewsDialog.qml OriginComparison.qml PaletteRow.qml
    PhaseIndicator.qml PulseRings.qml RepositoriesDialog.qml
    RetrospectCard.qml SelectableText.qml SourcePickerDialog.qml
    SupportChips.qml TintedIconEffect.qml Tr.qml Ui.qml UpdateCard.qml
    UpdateEngine.qml UpdaterSettings.qml UpdaterWidget.qml UpdaterWindow.qml
""".split())

# Newer files an entry file loads by path, and why that is safe
BY_PATH = {
    "ScreenshotDirector.qml": "loaded only in a development install (a working copy, never updated by the shell)",
}

failures = []


def check(label, ok, detail=""):
    if ok:
        print(f"  ok   {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label}" + (f"\n       {detail}" if detail else ""))


def sibling_types(root):
    """Every type name a file in the plugin folder can use: what qmldir
    registers, and — as QML imports its own folder implicitly — each QML
    file by its name."""
    types = {name[:-4]: name for name in os.listdir(root) if name.endswith(".qml")}
    with open(os.path.join(root, "qmldir"), encoding="utf-8") as f:
        for line in f:
            words = line.split()
            if not words or words[0] in ("module", "plugin", "#"):
                continue
            if words[0] == "singleton":
                words = words[1:]
            if len(words) == 3:
                types[words[0]] = words[2]
    return types


def strip(source):
    """The code without comments, and with string literals emptied."""
    out, i, n = [], 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("//", i):
            i = source.find("\n", i)
            i = n if i < 0 else i
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif c in "\"'`":
            end = i + 1
            while end < n and source[end] != c:
                end += 2 if source[end] == "\\" else 1
            out.append(c + c)
            i = end + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def references(source, types):
    """(type names, file paths) an entry file refers to."""
    code = strip(source)
    # A type name: not a member (`x.Name`), not a property name (`Name:`
    # would be odd but cheap to rule out), and not this file's own inline
    # components
    inline = set(re.findall(r"\bcomponent\s+(\w+)\s*:", code))
    names = set()
    for name in types:
        if name in inline:
            continue
        if re.search(rf"(?<![\w.]){re.escape(name)}\b(?!\s*:(?!:))", code):
            names.add(name)
    # Paths: Qt.resolvedUrl("X.qml"), `source: "X.qml"`, import "x.js"
    paths = set(re.findall(r'["\']([\w./-]+\.(?:qml|js))["\']', re.sub(r"//[^\n]*", "", source)))
    return names, paths


def entry_files(root):
    with open(os.path.join(root, "plugin.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    files = []
    for key, value in manifest.items():
        if isinstance(value, str) and value.endswith(".qml") and (
                key in ("component", "settings") or key.endswith("Component")):
            files.append(os.path.normpath(value))
    return sorted(set(files))


def problems_in(root, entries, types):
    found = []
    for entry in entries:
        with open(os.path.join(root, entry), encoding="utf-8") as f:
            names, paths = references(f.read(), types)
        for name in sorted(names):
            target = types[name]
            if target not in BASELINE:
                found.append(f"{entry} names {name} ({target}), which 1.0.0 did not have: "
                             f"make it an inline component in {entry}")
        for path in sorted(paths):
            target = os.path.normpath(path)
            if os.path.dirname(target):
                continue        # not a sibling: scripts/, assets/ …
            if target not in BASELINE and target not in BY_PATH:
                found.append(f"{entry} loads {target} by path, which 1.0.0 did not have: "
                             f"make it an inline component in {entry}")
    return found


def self_test():
    print("The check itself")
    types = {"Old": "Old.qml", "New": "New.qml", "Tr": "Tr.qml"}

    def flagged(src):
        names, paths = references(src, types)
        return sorted(names), sorted(paths)

    check("an instance by name is found",
          flagged("Item {\n    New {\n        id: x\n    }\n}")[0] == ["New"])
    check("inside an inactive Loader too",
          flagged("Loader {\n    active: false\n    sourceComponent: New { }\n}")[0] == ["New"])
    check("a singleton by name is found", flagged("Text { text: Tr.t(\"x\") }")[0] == ["Tr"])
    check("a member of the same name is not",
          flagged("Item { property var a: root.New }")[0] == [])
    check("a property of the same name is not", flagged("Item { New: 3 }")[0] == [])
    check("a comment or a string is not",
          flagged("// New { }\n/* New */ Text { text: \"New\" }")[0] == [])
    check("an inline component of the same name is not",
          flagged("Item {\n    component New: Item { }\n    New { }\n}")[0] == [])
    check("a path is found", flagged('Loader { source: Qt.resolvedUrl("New.qml") }')[1] == ["New.qml"])
    check("an import of a JS file is found", flagged('import "lib.js" as Lib\nItem { }')[1] == ["lib.js"])


def main():
    self_test()

    print("\nThe plugin")
    types = sibling_types(ROOT)
    entries = entry_files(ROOT)
    check("plugin.json names the widget and the settings page",
          "UpdaterWidget.qml" in entries and "UpdaterSettings.qml" in entries, f"got {entries}")
    found = problems_in(ROOT, entries, types)
    check("the entry files use only what 1.0.0 had", not found, "\n       ".join(found))
    for path, why in BY_PATH.items():
        check(f"{path} is still loaded by path only", any(
            path in references(open(os.path.join(ROOT, e), encoding="utf-8").read(), types)[1] for e in entries))

    print(f"\n{len(failures)} failed" if failures else "\nall passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
