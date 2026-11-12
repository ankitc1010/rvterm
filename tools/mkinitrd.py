#!/usr/bin/env python3
"""Builds the 64-bit machine's initramfs from an Alpine minirootfs tarball.

Usage: python3 mkinitrd.py <alpine-minirootfs.tar.gz> <out initrd.cpio.gz> [package.apk|package.tgz...]

Converts the tarball straight to a gzipped cpio (newc) archive, so ownership stays root and
device nodes can be included without being root here, then adds /init and /dev/console. Alpine
packages (from alpine-packages.py) are unpacked on top; their install scripts are not run. npm
packages (.tgz, from npm-package.py) go to /usr/local/lib/node_modules with their commands linked
into /usr/local/bin, as `npm install -g` would do.
"""
import gzip
import json
import os
import sys
import tarfile

INIT = b"""#!/bin/sh
# rvterm init: mount the virtual filesystems, then keep a login shell running on the serial console.
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run
hostname rvterm
export HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM=xterm
cd /root
shell=/bin/sh
[ -x /bin/bash ] && shell=/bin/bash
while true; do
    setsid -c $shell -l </dev/ttyS0 >/dev/ttyS0 2>&1
done
"""

# Claude Code 2.1.112 is the last release written in JavaScript; later ones are native x64/arm64
# programs, so it must not update itself. The ripgrep it bundles is for other CPUs: use Alpine's.
CLAUDE_CODE_PROFILE = b"""# Claude Code on rvterm (see tools/mkinitrd.py)
export DISABLE_AUTOUPDATER=1 USE_BUILTIN_RIPGREP=0
"""

# A login bash reads ~/.bash_profile, not ~/.bashrc, where tools such as nvm add themselves.
BASH_PROFILE = b"""# Login shells read this file; keep everything in ~/.bashrc.
[ -f ~/.bashrc ] && . ~/.bashrc
"""
BASHRC = b"""# Interactive bash settings. Installers such as nvm append to this file.
"""


class Cpio:
    def __init__(self):
        self.out = bytearray()
        self.ino = 1

    def add(self, name, mode, data=b"", rdev=(0, 0), mtime=0):
        name_b = name.encode() + b"\0"
        fields = [self.ino, mode, 0, 0, 1, mtime, len(data), 0, 0, rdev[0], rdev[1], len(name_b), 0]
        self.ino += 1
        self.out += b"070701" + b"".join(b"%08x" % f for f in fields) + name_b
        self.out += b"\0" * (-len(self.out) % 4)
        self.out += data
        self.out += b"\0" * (-len(self.out) % 4)

    def finish(self):
        self.ino = 0
        self.add("TRAILER!!!", 0)
        return bytes(self.out)


def add_tar(cpio, path, skip_control=False):
    """Adds every entry of a tarball (an apk is three concatenated gzipped tar segments)."""
    with tarfile.open(path, "r:gz") as tar:
        members = {m.name: m for m in tar.getmembers()}
        for m in tar.getmembers():
            name = m.name.lstrip("./") or "."
            if name in (".", "init") or (skip_control and name.startswith(".")):
                continue
            perm = m.mode & 0o7777
            if m.isdir():
                cpio.add(name, 0o040000 | perm, mtime=m.mtime)
            elif m.issym():
                cpio.add(name, 0o120000 | 0o777, m.linkname.encode(), mtime=m.mtime)
            elif m.islnk():  # hard link: store another copy of the target's contents
                target = members.get(m.linkname) or members.get("./" + m.linkname)
                cpio.add(name, 0o100000 | perm, tar.extractfile(target).read(), mtime=m.mtime)
            elif m.isfile():
                cpio.add(name, 0o100000 | perm, tar.extractfile(m).read(), mtime=m.mtime)
            elif m.ischr() or m.isblk():
                kind = 0o020000 if m.ischr() else 0o060000
                cpio.add(name, kind | perm, rdev=(m.devmajor, m.devminor), mtime=m.mtime)
    return members


def add_npm(cpio, path, dirs):
    """Adds an npm tarball (files under package/) as a global package with its commands.

    Its vendor/ directory is left out: npm packages ship prebuilt binaries there for x64 and
    arm64, which cannot run on RISC-V.
    """
    def mkdirs(path):
        parts = path.split("/")
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                cpio.add(d, 0o040755)

    with tarfile.open(path, "r:gz") as tar:
        meta = json.load(tar.extractfile("package/package.json"))
        name = meta["name"]
        bins = meta.get("bin") or {}
        if isinstance(bins, str):
            bins = {name.split("/")[-1]: bins}
        root = "usr/local/lib/node_modules/" + name
        targets = {os.path.normpath(t) for t in bins.values()}
        for m in tar.getmembers():
            rel = os.path.normpath(m.name.split("/", 1)[1]) if "/" in m.name else ""
            if not m.isfile() or not rel or rel.split("/")[0] == "vendor":
                continue
            mkdirs(os.path.dirname(root + "/" + rel))
            perm = 0o755 if rel in targets else m.mode & 0o777 | 0o644
            cpio.add(root + "/" + rel, 0o100000 | perm, tar.extractfile(m).read())
    mkdirs("usr/local/bin")
    for cmd, target in bins.items():
        link = os.path.relpath(root + "/" + os.path.normpath(target), "usr/local/bin")
        cpio.add("usr/local/bin/" + cmd, 0o120777, link.encode())
    return name


def main():
    src, dst, packages = sys.argv[1], sys.argv[2], sys.argv[3:]
    cpio = Cpio()
    members = add_tar(cpio, src)
    dirs = {m.lstrip("./") for m, info in members.items() if info.isdir()}
    npm = []
    for pkg in packages:
        if pkg.endswith(".tgz"):
            npm.append(add_npm(cpio, pkg, dirs))
        else:
            add_tar(cpio, pkg, skip_control=True)  # .PKGINFO, .SIGN.*, install scripts
    if "@anthropic-ai/claude-code" in npm:
        cpio.add("etc/profile.d/claude-code.sh", 0o100644, CLAUDE_CODE_PROFILE)
    if "dev" not in members and "./dev" not in members:
        cpio.add("dev", 0o040755)
    cpio.add("dev/console", 0o020600, rdev=(5, 1))
    cpio.add("dev/null", 0o020666, rdev=(1, 3))
    cpio.add("init", 0o100755, INIT)
    if any(os.path.basename(p).startswith("bash-") for p in packages):
        cpio.add("root/.bash_profile", 0o100644, BASH_PROFILE)
        cpio.add("root/.bashrc", 0o100644, BASHRC)
    # No init daemon runs to act on poweroff/reboot requests, so these go straight to the kernel.
    for d in ("usr/local", "usr/local/sbin"):
        if d not in members and "./" + d not in members:
            cpio.add(d, 0o040755)
    for cmd in ("poweroff", "reboot", "halt"):
        cpio.add("usr/local/sbin/" + cmd, 0o100755, b"#!/bin/sh\nexec /bin/busybox %s -f\n" % cmd.encode())
    entries = cpio.ino - 1
    data = gzip.compress(cpio.finish(), compresslevel=9, mtime=0)
    with open(dst, "wb") as f:
        f.write(data)
    print("%s: %d entries, %.1f MB" % (dst, entries, len(data) / 1048576))


if __name__ == "__main__":
    main()
