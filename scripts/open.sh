#!/bin/sh
# Exec target of the desktop entry, standing in for a bare `dms ipc call`.
#
# The entry used to run `dms` straight from PATH and trust the exit code.
# Both halves of that were wrong. A launcher passes on neither stderr nor a
# missing command, so an entry that could not find `dms` did nothing at all
# — no window, no error, nothing to look at. And `dms ipc call` answers 0
# even when it reached nobody: it prints "Target not found." and succeeds.
# Any output at all is the failure; silence is the success.
#
#   open.sh            open the window
#   open.sh <file>     open it on the AppImage that was double-clicked

set -u

APP_NAME="Dux Software Depot"

# A launcher hands down the session's PATH, which is routinely shorter than
# the one an interactive shell builds from the profile — and `dms ipc` needs
# more than itself: it shells out to `qs`. That is why the same command can
# work in a terminal and do nothing from a menu entry. Widen it here so both
# have the same places to look.
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export PATH

say() {
    dms notify -a "$APP_NAME" -i dux-software-depot "$APP_NAME" "$1"
    echo "$APP_NAME: $1" >&2
    exit 1
}

dms_bin=""
for candidate in dms "$HOME/.local/bin/dms" /usr/local/bin/dms /usr/bin/dms; do
    if command -v "$candidate" >/dev/null 2>&1; then
        dms_bin=$candidate
        break
    fi
done

[ -n "$dms_bin" ] || say "The dms command was not found. It ships separately from the shell (the dms-cli package on Fedora); without it nothing can ask the shell to open this window."

file=""
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    file=$1
    # %f hands over a path, but a file manager that insists on %u would send
    # a URL — take either rather than fail on the one we did not ask for
    case $file in
        file://*) file=$(printf '%s' "$file" | sed 's|^file://||') ;;
    esac
fi

if [ -n "$file" ]; then
    answer=$("$dms_bin" ipc call dankSoftwareDepot openAppimage "$file" 2>&1)
else
    answer=$("$dms_bin" ipc call dankSoftwareDepot open 2>&1)
fi

[ -z "$answer" ] || say "The shell did not take the request: $answer — is Dux Shell running with the Dux Software Depot plugin enabled?"
