#!/bin/sh
# Static check for the QML, which is most of this plugin and had no checker.
#
# Two things make this awkward, and both are handled here:
#
#  * The `qs.*` imports are not modules on disk. Quickshell synthesises them
#    from the running shell's root, so qmllint cannot resolve DToggle,
#    Theme or PluginService and drowns the output — 2586 warnings against
#    code that is fine. So mirror that root into a scratch tree with a
#    generated qmldir per directory, and hand qmllint the tree: the same run
#    drops to a couple of hundred, nearly all explainable.
#
#  * That root only exists while DMS is running, under $XDG_RUNTIME_DIR. There
#    is no such thing in CI, which is why this is a local tool and not a
#    workflow step.
#
# Usage: scripts/qmllint.sh [file.qml ...]      (default: every .qml in $PWD,
#        so it follows the working tree you are standing in, worktrees included)
set -e

# Dux Shell 2.0 unpacks under dms-shell/, older versions under danklinux-shell/
runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
root=$(for d in dms-shell danklinux-shell; do ls -d "$runtime/$d"/*/ 2>/dev/null || true; done | head -1)
if [ -z "$root" ]; then
    echo "no running DMS found under \$XDG_RUNTIME_DIR/dms-shell or danklinux-shell — start the shell first" >&2
    exit 2
fi

tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT

python3 - "$root" "$tree" <<'PY'
import pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]) / "qs"
out.mkdir(parents=True)
for src in [root] + [p for p in root.rglob("*") if p.is_dir()]:
    qmls = sorted(src.glob("*.qml"))
    if not qmls:
        continue
    dst = out / src.relative_to(root)
    dst.mkdir(parents=True, exist_ok=True)
    lines = []
    for q in qmls:
        (dst / q.name).symlink_to(q)
        singleton = q.read_text(errors="ignore").lstrip().startswith("pragma Singleton")
        lines.append(("singleton " if singleton else "") + f"{q.stem} 1.0 {q.name}")
    (dst / "qmldir").write_text("\n".join(lines) + "\n")
PY

[ "$#" -gt 0 ] && set -- "$@" || set -- *.qml
exec qmllint-qt6 -I "$tree" "$@"
