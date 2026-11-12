#!/usr/bin/env python3
"""Checks scripts/aur_helper.py against stub paru and yay, with neither installed.

What matters: the flags that keep paru/yay from waiting on a terminal, the
sudo stand-in, the events the engine reads, and a refused polkit prompt
being told apart from a failed build.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "aur_helper.py")

# Recorded from paru 2.2.0 under LC_ALL=C: makepkg names a package several
# times per build, and the helper must report it once
STUB = """#!/bin/sh
# builtins only: PATH holds nothing but the stubs
printf '%s\\n' "$0 $*" > "$ARGV_LOG"
echo ':: Resolving dependencies...'
echo '==> Making package: foo-git r1.abc-1 (Tue Nov 10 15:12:04 2026)'
echo '==> Making package: foo-git r1.abc-1 (Tue Nov 10 15:12:04 2026)'
echo '==> Making package: bar 2-1 (Tue Nov 10 15:12:06 2026)'
case "$MODE" in
  fail) echo 'error: failed to build bar' >&2; exit 1 ;;
  refused) echo 'Error executing command as another user: Request dismissed' >&2; exit 1 ;;
esac
exit 0
"""

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def run(tools, names, mode="", extra=()):
    with tempfile.TemporaryDirectory() as tmp:
        bindir = os.path.join(tmp, "bin")
        os.mkdir(bindir)
        for tool in tools:
            path = os.path.join(bindir, tool)
            with open(path, "w") as f:
                f.write(STUB)
            os.chmod(path, 0o755)
        log = os.path.join(tmp, "argv")
        # The stubs' directory only: with /usr/bin on PATH a machine that has
        # the real paru would run it, and really build and install the target
        env = {"PATH": bindir, "ARGV_LOG": log, "MODE": mode}
        proc = subprocess.run([sys.executable, "-I", HELPER] + list(extra) + names,
                              capture_output=True, text=True, env=env, cwd=tmp, timeout=30)
        events = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
        argv = open(log).read().split() if os.path.exists(log) else []
        return proc.returncode, events, argv


# paru: menus answered, no sudo loop, one install at the end, polkit as sudo
code, events, argv = run(["paru", "yay"], ["foo-git", "bar"])
check(code == 0, "paru success exits 0")
check(os.path.basename(argv[0]) == "paru", "paru is preferred over yay")
for flag in ("-S", "--skipreview", "--nosudoloop", "--batchinstall", "--noconfirm"):
    check(flag in argv, "paru gets " + flag)
check("--rebuild" not in argv, "a package built earlier is reused, not rebuilt")
check("-Sy" not in argv, "no refresh unless asked: the official pass did it")
check(argv[argv.index("--sudo") + 1].endswith("aur_sudo.sh"), "sudo is replaced by aur_sudo.sh")
check(argv[-2:] == ["foo-git", "bar"], "the packages are passed as targets")
kinds = [(e["event"], e.get("name")) for e in events]
check(kinds == [("op-start", "foo-git"), ("op-done", "foo-git"), ("op-start", "bar"),
                ("op-done", "bar"), ("output", None), ("done", None)], "paru events: %r" % kinds)
check(events[-1] == {"event": "done", "ok": True, "failed": []}, "done reports success")
check("Making package: bar" in events[-2]["text"], "the output tail is passed on even on success")

# yay: its own menu answers, and no paru-only flags
code, events, argv = run(["yay"], ["bar"])
check(os.path.basename(argv[0]) == "yay", "yay is used when paru is missing")
for flag in ("--answerclean", "--answerdiff", "--answeredit"):
    check(flag in argv and argv[argv.index(flag) + 1] == "None", "yay gets %s None" % flag)
check("--nosudoloop" not in argv and "--skipreview" not in argv, "yay gets no paru-only flags")

# --refresh: the run had no official pass to refresh the databases first
_, _, argv = run(["paru"], ["bar"], extra=["--refresh"])
check(argv[1] == "-Sy" and "--refresh" not in argv, "paru --refresh refreshes: %r" % argv)
_, _, argv = run(["yay"], ["bar"], extra=["--refresh"])
check(argv[1] == "-Sy" and "--refresh" not in argv, "yay --refresh refreshes: %r" % argv)

# A failed build: the error carries the output, the packages are failed
code, events, _ = run(["paru"], ["foo-git", "bar"], mode="fail")
check(code == 1, "a failed build exits 1")
err = [e for e in events if e["event"] == "error"]
check(len(err) == 1 and "failed to build bar" in err[0]["message"] and err[0]["refused"] is False,
      "a failed build is an error with paru's words, not a refusal")
check(events[-1] == {"event": "done", "ok": False, "failed": ["foo-git", "bar"]}, "done names the packages")
check(("op-done", "bar") not in [(e["event"], e.get("name")) for e in events],
      "an unfinished build is not reported done")

# A dismissed polkit prompt is a refusal
_, events, _ = run(["paru"], ["bar"], mode="refused")
err = [e for e in events if e["event"] == "error"]
check(len(err) == 1 and err[0]["refused"] is True, "a dismissed prompt is reported as refused")


# Neither helper installed: said inside the protocol
code, events, _ = run([], ["bar"])
check(code == 1 and events[0]["event"] == "error" and events[-1]["failed"] == ["bar"],
      "no paru or yay is an error event, then done")

# Nothing to do
code, events, _ = run(["paru"], [])
check(code == 0 and events == [{"event": "done", "ok": True, "failed": []}], "no names is a clean no-op")

# Who runs a privileged command: sudo, when it would run *that* command
# without a password (a sudoers line for pacman alone is enough), otherwise
# pkexec. aur_sudo.sh and Backend.privileged() must agree on it.
import re  # noqa: E402

src = open(os.path.join(os.path.dirname(HERE), "Backend.qml"), encoding="utf-8").read()
body = src[src.index("function privileged(words)"):]
body = body[body.index('["sh", "-c", '):body.index(', "sh"]')]
privileged = json.loads(re.findall(r'"((?:[^"\\]|\\.)*)"', body)[2].join('""'))
with tempfile.TemporaryDirectory() as tmp:
    bindir = os.path.join(tmp, "bin")
    os.mkdir(bindir)
    log = os.path.join(tmp, "log")
    # This sudo lets pacman run without a password, and nothing else
    stubs = {"sudo": 'echo "sudo $*" >> "$LOG"\necho "$PATH" > "$LOG.path"\n'
                     'case "$*" in "-n -l pacman "*|"-n pacman "*) exit 0;; *) exit 1;; esac\n',
             "pkexec": 'echo "pkexec $*" >> "$LOG"\n'}
    for name, text in stubs.items():
        with open(os.path.join(bindir, name), "w") as fh:
            fh.write("#!/bin/sh\n" + text)
        os.chmod(os.path.join(bindir, name), 0o755)

    def ran(argv, env_extra=None):
        open(log, "w").close()
        env = {"PATH": bindir, "LOG": log}
        env.update(env_extra or {})
        proc = subprocess.run(argv, capture_output=True, text=True, env=env)
        return [l for l in open(log).read().splitlines() if not l.startswith("sudo -n -l ")], proc.stderr

    # aur_sudo.sh finds sudo and pkexec on this PATH; anything but the
    # stand-ins is the real thing, which would run (or ask to run) for real
    for tool in ("sudo", "pkexec"):
        if shutil.which(tool, path=bindir) != os.path.join(bindir, tool):
            raise SystemExit("refusing to run: %s is not the stand-in" % tool)
    sudo_sh = os.path.join(HERE, "aur_sudo.sh")
    pacman_u = ["pacman", "--upgrade", "--noconfirm", "--", "/nonexistent/dsd-test.pkg.tar.zst"]
    got, err = ran(["/bin/sh", sudo_sh] + pacman_u)
    check(got == ["sudo -n " + " ".join(pacman_u)] and err == "", "aur_sudo.sh: a rule for pacman alone is enough: %r" % got)
    check(open(log + ".path").read().strip() == "/usr/local/sbin:/usr/local/bin:/usr/bin",
          "aur_sudo.sh: sudo, and the pacman it runs, get the system's PATH")
    got, _ = ran(["/bin/sh", sudo_sh, "/usr/bin/true", "dsd-test"])
    check(got == ["pkexec /usr/bin/true dsd-test"], "aur_sudo.sh: what the rule does not cover goes to polkit: %r" % got)
    got, err = ran(["/bin/sh", "-c", privileged, "sh"] + pacman_u)
    check(got == ["sudo -n " + " ".join(pacman_u)] and err == "", "privileged(): sudo for a command it allows: %r" % got)
    got, _ = ran(["/bin/sh", "-c", privileged, "sh", "/usr/bin/python3", "/x/pacman_helper.py", "upgrade", "glibc"])
    check(got == ["pkexec /usr/bin/python3 /x/pacman_helper.py upgrade glibc"],
          "privileged(): pkexec for one it does not, never a failed sudo: %r" % got)

for line in failures:
    print("FAIL: " + line)
print("all passed" if not failures else "%d failed" % len(failures))
sys.exit(1 if failures else 0)
