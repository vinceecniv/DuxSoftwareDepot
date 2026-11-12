#!/bin/sh
# Stands in for sudo when paru/yay run without a terminal: they call it for
# `pacman -U`, dependency installs and makedepends removal. sudo is used when
# it would run this very command without a password — a sudoers line for
# pacman is enough, and the settings can add one; otherwise polkit draws the
# prompt (through the DMS agent).
#
# sudo and pkexec are found on the caller's PATH; what they are handed is the
# system's, since sudo passes the caller's PATH on to pacman unless
# secure_path is set, and pacman on to the hooks it runs as root.
sudo_bin=$(command -v sudo)
pkexec_bin=$(command -v pkexec)
PATH=/usr/local/sbin:/usr/local/bin:/usr/bin
export PATH
if [ -n "$sudo_bin" ] && "$sudo_bin" -n -l "$@" >/dev/null 2>&1; then
    exec "$sudo_bin" -n "$@"
fi
exec "${pkexec_bin:-pkexec}" "$@"
