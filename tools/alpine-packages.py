#!/usr/bin/env python3
"""Downloads Alpine riscv64 packages, with their dependencies, to bake into the 64-bit initramfs.

Usage: python3 alpine-packages.py <minirootfs.tar.gz> <out dir> <package>...

Packages the minirootfs already has (its /lib/apk/db/installed) are skipped. Each download is
checked against the index: an apk's "C:" field is "Q1" + base64(SHA-1) of its control segment,
the second gzip member of the file.
"""
import base64
import hashlib
import io
import os
import sys
import tarfile
import urllib.request
import zlib

MIRROR = "https://dl-cdn.alpinelinux.org/alpine/v3.24"
REPOS = ("main", "community")
ARCH = "riscv64"


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def parse_index(data, repo):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        text = tar.extractfile("APKINDEX").read().decode()
    for block in text.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if len(line) > 2 and line[1] == ":":
                fields.setdefault(line[0], line[2:])
        if "P" in fields:
            fields["repo"] = repo
            yield fields


def control_sha1(apk):
    """SHA-1 of the second gzip member (the control segment), as raw compressed bytes."""
    starts = [0]
    rest = apk
    for _ in range(2):
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        d.decompress(rest)
        consumed = len(rest) - len(d.unused_data)
        starts.append(starts[-1] + consumed)
        rest = d.unused_data
    return hashlib.sha1(apk[starts[1]:starts[2]]).digest()


def main():
    rootfs, out_dir, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
    with tarfile.open(rootfs, "r:gz") as tar:
        member = next(m for m in tar.getmembers() if m.name.lstrip("./") == "lib/apk/db/installed")
        installed = {l[2:] for l in tar.extractfile(member).read().decode().splitlines() if l.startswith("P:")}

    packages, provides = {}, {}
    for repo in REPOS:
        for f in parse_index(fetch(f"{MIRROR}/{repo}/{ARCH}/APKINDEX.tar.gz"), repo):
            packages.setdefault(f["P"], f)
            for p in f.get("p", "").split():
                provides.setdefault(p.split("=")[0], f["P"])

    chosen = []

    def add(name):
        name = name if name in packages else provides.get(name, name)
        if name in installed or name in chosen:
            return
        if name not in packages:
            sys.exit(f"alpine-packages: no package provides {name}")
        chosen.append(name)
        for dep in packages[name].get("D", "").split():
            if not dep.startswith("!"):
                add(dep.split("=")[0].split(">")[0].split("<")[0].split("~")[0])

    for w in wanted:
        add(w)
    os.makedirs(out_dir, exist_ok=True)
    for name in chosen:
        f = packages[name]
        filename = f"{name}-{f['V']}.apk"
        apk = fetch(f"{MIRROR}/{f['repo']}/{ARCH}/{filename}")
        expected = base64.b64decode(f["C"][2:])
        if not f["C"].startswith("Q1") or control_sha1(apk) != expected:
            sys.exit(f"alpine-packages: checksum mismatch for {filename}")
        with open(os.path.join(out_dir, filename), "wb") as out:
            out.write(apk)
        print(f"{filename} ({len(apk) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
