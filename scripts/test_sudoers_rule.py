#!/usr/bin/env python3
"""Checks scripts/sudoers_rule.py in a scratch root, without root, and the
command Backend.qml builds for a pacman transaction.

The rule is checked by visudo when sudo is installed. The command is run as
written, with the helper, sudo and pkexec stood in for: the helper first
tries as the user (--via-sudo), and only its "sudo would ask" answer (3)
sends the request down the usual path.
"""
import json
import os
import re
import stat
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "sudoers_rule.py")
sys.path.insert(0, HERE)
import sudoers_rule  # noqa: E402

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def run(root, command, env_extra=None):
    env = {k: v for k, v in os.environ.items() if k not in ("PKEXEC_UID", "SUDO_UID", "DSD_SYSTEM_ROOT")}
    if root:
        env["DSD_SYSTEM_ROOT"] = root
    env.update(env_extra or {})
    return subprocess.run([sys.executable, "-I", SCRIPT, command], capture_output=True,
                          text=True, env=env, timeout=60)


check(sudoers_rule.rule("someone") == "someone ALL=(root) NOPASSWD: /usr/bin/pacman", "the rule is pacman and nothing else")

have_visudo = shutil.which("visudo") is not None
proc = run(None, "install")
check(proc.returncode == 1 and "needs root" in proc.stderr, "install refuses without root")

with tempfile.TemporaryDirectory() as root:
    os.makedirs(root + "/etc")
    with open(root + "/etc/sudoers", "w") as fh:
        fh.write("root ALL=(ALL:ALL) ALL\n")
    proc = run(root, "install")
    if have_visudo:
        check(proc.returncode == 1 and "does not read /etc/sudoers.d" in proc.stderr,
              "install refuses when sudoers.d is not read: " + proc.stderr)
        check(not os.path.exists(root + sudoers_rule.SUDOERS), "and writes nothing")

    with open(root + "/etc/sudoers", "w") as fh:
        fh.write("root ALL=(ALL:ALL) ALL\n@includedir /etc/sudoers.d\n")
    status = json.loads(run(root, "status").stdout)
    check(status["rule"] == sudoers_rule.rule(sudoers_rule.caller()), "status shows the rule for this user: %r" % status)

    proc = run(root, "install")
    if have_visudo:
        path = root + sudoers_rule.SUDOERS
        check(proc.returncode == 0, "install in a scratch root: " + proc.stderr)
        check(stat.S_IMODE(os.stat(path).st_mode) == 0o440, "the rule file is 0440")
        check(sudoers_rule.rule(sudoers_rule.caller()) in open(path).read(), "the file holds the rule")
        check(not [n for n in os.listdir(root + "/etc/sudoers.d") if n.startswith(".")],
              "no temporary file is left in sudoers.d")
        check(subprocess.run(["visudo", "-c", "-f", path], capture_output=True).returncode == 0,
              "visudo accepts the file as written")
        proc = run(root, "install", {"PKEXEC_UID": "2147483646"})
        check(proc.returncode == 1 and "which user" in proc.stderr, "a caller with no account is refused")
        proc = run(root, "remove")
        check(proc.returncode == 0 and not os.path.exists(path), "remove takes the rule away")
    else:
        check(proc.returncode == 1 and "sudo is not installed" in proc.stderr, "install says sudo is missing")
        print("note: no visudo here, the rule's syntax is not checked")

# Backend.qml's pacman command, run as written
src = open(os.path.join(os.path.dirname(HERE), "Backend.qml"), encoding="utf-8").read()
body = src[src.index("function _pacmanCommand"):]
body = body[:body.index('"sh", python')]
script = "".join(json.loads('"%s"' % p) for p in re.findall(r'"((?:[^"\\]|\\.)*)"', body)
                 if p not in ("sh", "-c"))
with tempfile.TemporaryDirectory() as tmp:
    bindir = os.path.join(tmp, "bin")
    os.mkdir(bindir)
    log = os.path.join(tmp, "log")
    stubs = {
        # the helper: --via-sudo answers $RC, anything else succeeds
        "py": 'echo "py $*" >> "$LOG"\n[ "$2" = "--via-sudo" ] && exit "$RC"\nexit 0\n',
        "sudo": 'case "$*" in "-n -l "*) [ "$ALLOW" = 1 ]; exit $?;; esac\necho "sudo $*" >> "$LOG"\n',
        "pkexec": 'echo "pkexec $*" >> "$LOG"\n',
    }
    for name, text in stubs.items():
        with open(os.path.join(bindir, name), "w") as fh:
            fh.write("#!/bin/sh\n" + text)
        os.chmod(os.path.join(bindir, name), 0o755)
    py = os.path.join(bindir, "py")

    def route(rc, sudo_first, allow):
        open(log, "w").close()
        proc = subprocess.run(["/bin/sh", "-c", script, "sh", py, "H", sudo_first, "upgrade", "glibc"],
                              capture_output=True, text=True,
                              env={"PATH": bindir, "LOG": log, "RC": str(rc), "ALLOW": allow})
        return proc.returncode, open(log).read().splitlines()

    first = "py H --via-sudo upgrade glibc"
    for label, args, want, want_rc in (
            ("the helper as the user, when sudo lets pacman run", (0, "0", "0"), [first], 0),
            ("a failed run is never run again another way", (1, "1", "1"), [first], 1),
            ("sudo would ask: pkexec, as before", (3, "0", "1"), [first, "pkexec %s H upgrade glibc" % py], 0),
            ("sudo would ask for pacman but not for the helper: sudo, as before",
             (3, "1", "1"), [first, "sudo -n %s H upgrade glibc" % py], 0),
            ("and when it would ask for both: pkexec", (3, "1", "0"), [first, "pkexec %s H upgrade glibc" % py], 0)):
        rc, got = route(*args)
        check(got == want and rc == want_rc, "%s: %r (exit %d)" % (label, got, rc))

for line in failures:
    print("FAIL: " + line)
print("all passed" if not failures else "%d failed" % len(failures))
sys.exit(1 if failures else 0)
