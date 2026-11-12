#!/usr/bin/env python3
"""Downloads an npm package tarball to bake into the initramfs (see mkinitrd.py).

Usage: python3 npm-package.py <name@version> <out dir>

The tarball is checked against the registry's "integrity" (sha512) before it is saved. Only the
package itself is fetched, not its dependencies: this is for packages that bundle all they need.
"""
import base64
import hashlib
import json
import os
import sys
import urllib.parse
import urllib.request

REGISTRY = "https://registry.npmjs.org"


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def main():
    spec, out_dir = sys.argv[1], sys.argv[2]
    name, _, version = spec.rpartition("@")
    if not name or not version:
        sys.exit(f"npm-package: expected name@version, got {spec}")
    meta = json.loads(fetch(f"{REGISTRY}/{urllib.parse.quote(name, safe='@')}/{version}"))
    dist = meta["dist"]
    algo, _, digest = dist["integrity"].partition("-")
    if algo != "sha512":
        sys.exit(f"npm-package: unexpected integrity {algo} for {spec}")
    data = fetch(dist["tarball"])
    if hashlib.sha512(data).digest() != base64.b64decode(digest):
        sys.exit(f"npm-package: checksum mismatch for {spec}")
    os.makedirs(out_dir, exist_ok=True)
    filename = f"{name.lstrip('@').replace('/', '-')}-{version}.tgz"
    with open(os.path.join(out_dir, filename), "wb") as out:
        out.write(data)
    print(f"{filename} ({len(data) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
