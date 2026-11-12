#!/bin/sh
# Downloads Alpine's riscv64 minirootfs and linux-lts kernel and builds linux64/Image and an
# initramfs for the machine, with extra Alpine packages baked in.
# Usage: [INITRD=file] tools/fetch-alpine.sh [package...]   (from the project root; needs curl,
# tar, gunzip, python3). The default is linux64/initrd.cpio.gz with bash, Node.js, and the GNU
# coreutils and grep that scripts such as nvm expect. Naming packages replaces that list.
# A package written npm:name@version comes from the npm registry instead (tools/npm-package.py).
set -eu
INITRD=${INITRD:-linux64/initrd.cpio.gz}
PACKAGES= NPM=
for p in ${*:-bash coreutils grep nodejs}; do
    case "$p" in
    npm:*) NPM="$NPM ${p#npm:}" ;;
    *) PACKAGES="$PACKAGES $p" ;;
    esac
done
ALPINE=3.24
ROOTFS=alpine-minirootfs-3.24.3-riscv64.tar.gz
ROOTFS_SHA256=9714553757e7bf645eff5dcc52bdd206f358a7bed77874842567852e8326a51d
KERNEL_APK=linux-lts-6.18.58-r0.apk
MIRROR=https://dl-cdn.alpinelinux.org/alpine/v$ALPINE

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -sSfL -o "$work/$ROOTFS" "$MIRROR/releases/riscv64/$ROOTFS"
echo "$ROOTFS_SHA256  $work/$ROOTFS" | sha256sum -c -
curl -sSfL -o "$work/$KERNEL_APK" "$MIRROR/main/riscv64/$KERNEL_APK"
mkdir "$work/kernel"
tar -xzf "$work/$KERNEL_APK" -C "$work/kernel" boot/vmlinuz-lts 2>/dev/null
mkdir -p linux64
gunzip -c "$work/kernel/boot/vmlinuz-lts" > linux64/Image
python3 tools/alpine-packages.py "$work/$ROOTFS" "$work/apk" $PACKAGES
mkdir "$work/npm"
for p in $NPM; do python3 tools/npm-package.py "$p" "$work/npm"; done
python3 tools/mkinitrd.py "$work/$ROOTFS" "$INITRD" "$work"/apk/*.apk $(ls "$work"/npm/*.tgz 2>/dev/null)
ls -l linux64
