#!/usr/bin/env python3
"""pacman without a password, on pacman systems: the sudoers rule behind the setting.

    sudoers_rule.py status     {"allowed": bool, "rule": str} as JSON (no root)
    sudoers_rule.py install    write the rule (root, through pkexec)
    sudoers_rule.py remove     take it away again (root)

The rule is one line in /etc/sudoers.d/dux-software-depot:

    <user> ALL=(root) NOPASSWD: /usr/bin/pacman

With it, pacman_helper.py --via-sudo installs, removes and updates packages
with no prompt, and paru or yay build AUR packages with none either
(scripts/aur_sudo.sh). It is a choice the user makes knowingly: anything
running as that user can then run pacman as root, and pacman can install any
package file. The setting says so.

"allowed" is sudo's own answer (`sudo -n -l`), not whether this file exists —
/etc/sudoers.d is not readable without root, and a rule elsewhere counts the
same. Installing never edits /etc/sudoers: the rule is checked by visudo
before it is put in place and the whole configuration checked after, and a
rule visudo does not accept is never left behind.
"""
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile

PACMAN = "/usr/bin/pacman"
SUDOERS = "/etc/sudoers.d/dux-software-depot"
# What a user name may be and still be one word to sudoers: nothing that
# separates (space, comma, colon, equals), quotes, escapes or comments
USER = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$")


def root(path):
    """Where a system path is. Tests point it into a scratch directory, never
    as root: a root process that let the environment choose where it writes
    could be steered into writing anywhere."""
    base = os.environ.get("DSD_SYSTEM_ROOT") if os.geteuid() != 0 else None
    return base + path if base else path


def rule(user):
    return "%s ALL=(root) NOPASSWD: %s" % (user, PACMAN)


def caller():
    """The user who asked for this, as pkexec (or sudo) recorded it."""
    for var in ("PKEXEC_UID", "SUDO_UID"):
        value = os.environ.get(var, "")
        if value.isdigit():
            try:
                name = pwd.getpwuid(int(value)).pw_name
            except KeyError:
                return ""
            return name if USER.match(name) else ""
    if os.geteuid() != 0:
        name = pwd.getpwuid(os.geteuid()).pw_name
        return name if USER.match(name) else ""
    return ""


def allowed():
    if not shutil.which("sudo"):
        return False
    try:
        return subprocess.run(["sudo", "-n", "-l", PACMAN, "--sync", "--noconfirm"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def fail(message):
    print(message, file=sys.stderr)
    return 1


def reads_sudoers_d():
    try:
        with open(root("/etc/sudoers")) as fh:
            text = fh.read()
    except OSError:
        return False
    return re.search(r"^\s*[@#]includedir\s+/etc/sudoers\.d\s*$", text, re.M) is not None


def visudo(*args):
    """"" when visudo accepts it, otherwise what visudo said. Not `-q`: that
    is the flag that keeps the reason to itself."""
    try:
        proc = subprocess.run(["visudo", "-c"] + list(args), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=30,
                              env=dict(os.environ, LC_ALL="C"))
    except (OSError, subprocess.SubprocessError) as exc:
        return str(exc)
    if proc.returncode == 0:
        return ""
    # Check mode lists every file it parsed, "parsed OK" or not; only the
    # rest is the reason
    said = [line.strip() for line in (proc.stderr + proc.stdout).splitlines()
            if line.strip() and not line.strip().endswith("parsed OK")]
    return "; ".join(said) or "visudo exited with code %d" % proc.returncode


def install():
    testing = os.geteuid() != 0
    if testing and not os.environ.get("DSD_SYSTEM_ROOT"):
        return fail("this needs root: run it through pkexec")
    user = caller()
    if not user:
        return fail("could not tell which user this is for")
    if not shutil.which("visudo"):
        return fail("sudo is not installed")
    if not reads_sudoers_d():
        return fail("/etc/sudoers does not read /etc/sudoers.d, so a rule there would do nothing")
    # What visudo already holds against this configuration — commonly a file
    # someone put in sudoers.d with a mode other than 0440, which sudo itself
    # accepts. Not this rule's doing, so not a reason to refuse it; only a
    # problem that appears with the rule is
    before = "" if testing else visudo()
    folder = root("/etc/sudoers.d")
    os.makedirs(folder, mode=0o750, exist_ok=True)
    text = ("# Dux Software Depot: pacman without a password, for installing, removing\n"
            "# and updating packages from its settings. Remove it there, or delete this file.\n"
            + rule(user) + "\n")
    # A dot in the name: sudo skips such files in /etc/sudoers.d, so the rule
    # does nothing until visudo has accepted it and it is renamed into place
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".dsd-")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o440)
        if not testing:
            os.chown(tmp, 0, 0)
        problem = visudo("-f", tmp)
        if problem:
            return fail("visudo refused the rule: " + problem)
        os.replace(tmp, root(SUDOERS))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    if not testing:
        after = visudo()
        if after and after != before:
            os.unlink(SUDOERS)
            return fail("the sudo configuration did not check with the rule in it, so it was taken out: " + after)
    if before:
        print("installed for %s; visudo already reported, before the rule: %s" % (user, before))
    else:
        print("installed for %s" % user)
    return 0


def remove():
    if os.geteuid() != 0 and not os.environ.get("DSD_SYSTEM_ROOT"):
        return fail("this needs root: run it through pkexec")
    try:
        os.unlink(root(SUDOERS))
    except FileNotFoundError:
        pass
    print("removed")
    return 0


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "status":
        print(json.dumps({"allowed": allowed(), "rule": rule(caller() or "user")}))
        return 0
    if command == "install":
        return install()
    if command == "remove":
        return remove()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
