#!/usr/bin/env python3
"""Checks the command Backend.qml builds for a pacman transaction with
"Authorise with sudo" on, run as written with the helper, sudo and pkexec
stood in for: the helper first tries as the user (--via-sudo), and only its
"sudo would ask" answer (3) sends the request down the usual path. With the
setting off, the command is privileged()'s, as on every other system.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


src = open(os.path.join(os.path.dirname(HERE), "Backend.qml"), encoding="utf-8").read()
body = src[src.index("function _pacmanCommand"):]
body = body[:body.index("\n    }\n")]
check(re.search(r"if \(!useSudo\)\s*return privileged\(\[python, packageHelper, action\]\.concat\(specs\)\);", body),
      "with Authorise with sudo off, a pacman transaction takes privileged() and never --via-sudo")
check(body.index("if (!useSudo)") < body.index("--via-sudo"), "the setting is checked before --via-sudo is tried")
shell = body[body.index('return ["sh", "-c"'):]
shell = shell[:shell.index('"sh", python')]
script = "".join(json.loads('"%s"' % p) for p in re.findall(r'"((?:[^"\\]|\\.)*)"', shell)
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
    # Only the stand-ins: the real sudo or pkexec would run (or ask) for real
    for tool in ("sudo", "pkexec"):
        if shutil.which(tool, path=bindir) != os.path.join(bindir, tool):
            raise SystemExit("refusing to run: %s is not the stand-in" % tool)
    py = os.path.join(bindir, "py")

    def route(rc, allow):
        open(log, "w").close()
        proc = subprocess.run(["/bin/sh", "-c", script, "sh", py, "H", "upgrade", "glibc"],
                              capture_output=True, text=True,
                              env={"PATH": bindir, "LOG": log, "RC": str(rc), "ALLOW": allow})
        return proc.returncode, open(log).read().splitlines()

    first = "py H --via-sudo upgrade glibc"
    for label, args, want, want_rc in (
            ("the helper as the user, when sudo lets pacman run", (0, "0"), [first], 0),
            ("a failed run is never run again another way", (1, "1"), [first], 1),
            ("sudo would ask for pacman and for the helper: pkexec", (3, "0"),
             [first, "pkexec %s H upgrade glibc" % py], 0),
            ("sudo would ask for pacman but not for the helper: sudo, as privileged() does",
             (3, "1"), [first, "sudo -n %s H upgrade glibc" % py], 0)):
        rc, got = route(*args)
        check(got == want and rc == want_rc, "%s: %r (exit %d)" % (label, got, rc))

for line in failures:
    print("FAIL: " + line)
print("all passed" if not failures else "%d failed" % len(failures))
sys.exit(1 if failures else 0)
