#!/usr/bin/env python3
"""Checks that an AppImage is read, never run.

The depot looks inside AppImages that were only opened, or that sit in
~/AppImages, to show their name and icon. That used to go through
--appimage-extract, which executes the file's embedded runtime. These checks
build a small AppImage-shaped file — an ELF header with a squashfs behind it —
and confirm the reader finds the desktop entry, follows .DirIcon, reads a
file spanning several blocks, survives a symlink loop and a file that is not
an AppImage at all, and starts no process while doing any of it.
"""
import os
import stat
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import appimage  # noqa: E402  (reads Gearlever's folder from dconf on import)
import appimage_squashfs  # noqa: E402

failures = []


def check(label, got, want):
    ok = got == want
    print(("ok   " if ok else "FOUT ") + label + ("" if ok else f": {got!r} != {want!r}"))
    if not ok:
        failures.append(label)


# ── A minimal squashfs writer ──────────────────────────────────────────────
# Only what the reader needs to be exercised: basic directory, file and
# symlink inodes, one metadata block per table, no fragments. One data block
# and the inode table are zlib-compressed, the rest stored, so both paths of
# the reader run.

BLOCK = 4096
PNG = b"\x89PNG\r\n\x1a\n" + b"icon-bytes" * 20
BIG = bytes(range(256)) * 40  # 10240 bytes: three blocks
DESKTOP = b"[Desktop Entry]\nType=Application\nName=Probe App\nIcon=probe\nCategories=Utility;\nX-AppImage-Version=2.4.1\n"

TREE = {
    "probe.desktop": DESKTOP,
    "probe.png": PNG,
    ".DirIcon": ("link", "probe.png"),
    "loop": ("link", "loop"),
    "AppRun": BIG,
    "usr": {"share": {"icons": {"hicolor": {"48x48": {"apps": {"probe.png": PNG}}}}}},
}


def build_squashfs(tree):
    nodes = []  # (path, kind, payload, children)

    def collect(name, value):
        index = len(nodes)
        if isinstance(value, dict):
            nodes.append([name, "dir", None, []])
            for child in sorted(value):
                nodes[index][3].append((child, collect(child, value[child])))
        elif isinstance(value, tuple):
            nodes.append([name, "link", value[1].encode(), None])
        else:
            nodes.append([name, "file", value, None])
        return index

    root = collect("", tree)

    # Data blocks come straight after the superblock
    data = b""
    data_at = {}
    sizes = {}
    for i, (_, kind, payload, _) in enumerate(nodes):
        if kind != "file":
            continue
        data_at[i] = 96 + len(data)
        sizes[i] = []
        for j, start in enumerate(range(0, len(payload), BLOCK)):
            chunk = payload[start:start + BLOCK]
            if i == len(nodes) - 1 or j == 1:
                packed = zlib.compress(chunk)
                sizes[i].append(len(packed))
            else:
                packed = chunk
                sizes[i].append(len(chunk) | 0x1000000)
            data += packed

    def inode_size(i):
        kind, payload = nodes[i][1], nodes[i][2]
        if kind == "dir":
            return 32
        if kind == "link":
            return 24 + len(payload)
        return 32 + 4 * len(sizes[i])

    inode_at, pos = {}, 0
    for i in range(len(nodes)):
        inode_at[i] = pos
        pos += inode_size(i)

    type_code = {"dir": 1, "file": 2, "link": 3}
    listings, listing_at, dpos = {}, {}, 0
    for i, (_, kind, _, children) in enumerate(nodes):
        if kind != "dir":
            continue
        body = b""
        if children:
            first = children[0][1] + 1
            body = struct.pack("<III", len(children) - 1, 0, first)
            for name, child in children:
                raw = name.encode()
                body += struct.pack("<HhHH", inode_at[child], (child + 1) - first,
                                    type_code[nodes[child][1]], len(raw) - 1) + raw
        listings[i] = body
        listing_at[i] = dpos
        dpos += len(body)

    inodes = b""
    for i, (_, kind, payload, _) in enumerate(nodes):
        header = struct.pack("<HHHHII", type_code[kind], 0o755, 0, 0, 0, i + 1)
        if kind == "dir":
            inodes += header + struct.pack("<IIHHI", 0, 2, len(listings[i]) + 3, listing_at[i], 0)
        elif kind == "link":
            inodes += header + struct.pack("<II", 1, len(payload)) + payload
        else:
            inodes += header + struct.pack("<IIII", data_at[i], 0xFFFFFFFF, 0, len(payload))
            inodes += struct.pack("<%dI" % len(sizes[i]), *sizes[i])

    packed_inodes = zlib.compress(inodes)
    inode_table = struct.pack("<H", len(packed_inodes)) + packed_inodes
    dir_body = b"".join(listings[i] for i in sorted(listings, key=lambda k: listing_at[k]))
    dir_table = struct.pack("<H", len(dir_body) | 0x8000) + dir_body

    inode_start = 96 + len(data)
    dir_start = inode_start + len(inode_table)
    end = dir_start + len(dir_table)
    none = 0xFFFFFFFFFFFFFFFF
    superblock = struct.pack(
        "<IIIIIHHHHHHQQQQQQQQ", 0x73717368, len(nodes), 0, BLOCK, 0, 1, 12,
        0x0010, 1, 4, 0, inode_at[root], end, none, none, inode_start, dir_start, none, none)
    return superblock + data + inode_table + dir_table


def elf_header():
    # ELF64 with no section headers: the payload starts right after it
    head = bytearray(64)
    head[:4] = b"\x7fELF"
    head[4] = 2
    head[5] = 1
    struct.pack_into("<Q", head, 0x28, 64)
    struct.pack_into("<HH", head, 0x3A, 0, 0)
    return bytes(head)


tmp = tempfile.mkdtemp(prefix="dsd-test-squashfs-")
image_path = os.path.join(tmp, "Probe.AppImage")
with open(image_path, "wb") as f:
    f.write(elf_header() + build_squashfs(TREE))
os.chmod(image_path, 0o644)  # as a fresh download arrives

# ── The reader ─────────────────────────────────────────────────────────────

with appimage_squashfs.Image(image_path) as image:
    check("root lists every entry", image.listdir(),
          [".DirIcon", "AppRun", "loop", "probe.desktop", "probe.png", "usr"])
    check("desktop entry reads back", image.read("probe.desktop"), DESKTOP)
    check(".DirIcon follows its symlink", image.read(".DirIcon"), PNG)
    check("a file over three blocks, one compressed", image.read("AppRun"), BIG)
    check("nested icon is found", image.walk("usr/share/icons"),
          ["usr/share/icons/hicolor/48x48/apps/probe.png"])
    check("nested icon reads (compressed block)",
          image.read("usr/share/icons/hicolor/48x48/apps/probe.png"), PNG)
    check("a missing path is None", image.read("nope.txt"), None)
    try:
        image.read("loop")
        check("symlink loop is refused", "no error", "SquashfsError")
    except appimage_squashfs.SquashfsError:
        check("symlink loop is refused", "SquashfsError", "SquashfsError")

# ── The depot's use of it, with nothing allowed to start ────────────────────

started = []


def audit(event, args):
    if event in ("subprocess.Popen", "os.exec", "os.posix_spawn", "os.spawn", "os.system", "os.fork"):
        started.append(event)


sys.addaudithook(audit)

appimage.ICON_DIR = os.path.join(tmp, "icons")
meta = appimage.extract_metadata(image_path, "probe")
check("name from the desktop entry", meta["desktopName"], "Probe App")
check("categories", meta["categories"], "Utility;")
check("version", meta["version"], "2.4.1")
check("icon written as png", meta["icon"], os.path.join(tmp, "icons", "dsd-appimage-probe.png"))
with open(meta["icon"], "rb") as f:
    check("icon bytes", f.read(), PNG)

junk = os.path.join(tmp, "junk.AppImage")
with open(junk, "wb") as f:
    f.write(b"#!/bin/sh\necho this must never run\n")
os.chmod(junk, 0o755)
check("a file that is no AppImage gives nothing",
      appimage.extract_metadata(junk, "junk"),
      {"icon": "", "desktopName": "", "categories": "", "version": ""})

# ── What a file is, by its bytes (#41) ──────────────────────────────────────

check("an ELF with a squashfs behind it is an AppImage", appimage.file_kind(image_path), "appimage")
marked = os.path.join(tmp, "Marked.AppImage")
with open(marked, "wb") as f:
    head = bytearray(elf_header())
    head[8:11] = b"AI\x02"
    f.write(bytes(head) + b"\0" * 64)
check("an ELF marked AI\\x02 is an AppImage", appimage.file_kind(marked), "appimage")
bare_elf = os.path.join(tmp, "tool.AppImage")
with open(bare_elf, "wb") as f:
    f.write(elf_header() + b"\0" * 64)
check("a plain ELF is not", appimage.file_kind(bare_elf), "")
check("a script is not", appimage.file_kind(junk), "")
bundle = os.path.join(tmp, "Some.App.flatpak")
with open(bundle, "wb") as f:
    f.write(b"flatpak\0\1\0\x89\xe5\0u\b\0ref\0\0\0\0\0app/org.example.App/x86_64/stable")
check("a Flatpak bundle is named as one", appimage.file_kind(bundle), "flatpak-bundle")
ref = os.path.join(tmp, "app.flatpakref")
with open(ref, "w") as f:
    f.write("# from a web page\n\n[Flatpak Ref]\nName=org.example.App\n")
check("a .flatpakref is named as one", appimage.file_kind(ref), "flatpakref")
check("a missing file is nothing", appimage.file_kind(os.path.join(tmp, "gone")), "")

check("no process was started", started, [])
check("the file is still not executable", bool(os.stat(image_path).st_mode & stat.S_IXUSR), False)

import shutil  # noqa: E402
shutil.rmtree(tmp)
print()
if failures:
    print(f"{len(failures)} controle(s) mislukt")
    sys.exit(1)
print("alles goed")
