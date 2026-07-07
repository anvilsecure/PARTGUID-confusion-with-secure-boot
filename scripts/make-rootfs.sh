#!/usr/bin/env bash
# Assemble two ext4 rootfs images (good + evil) from a busybox skeleton.
# Populated with `mke2fs -d` so no root / loop mount is needed.
# Runs inside the build container. Output: out/rootfs/{good,evil}.img
set -euo pipefail

OUT=out/rootfs
BB=out/busybox/busybox
SIZE="${ROOTFS_SIZE:-32M}"
mkdir -p "$OUT"

[ -f "$BB" ] || { echo "missing $BB — run scripts/build-busybox.sh first"; exit 1; }

build_one() {
    local flavor="$1"          # good | evil
    local stage; stage="$(mktemp -d)"

    mkdir -p "$stage"/{bin,sbin,proc,sys,dev,etc,root,tmp}
    install -m 0755 "$BB" "$stage/bin/busybox"
    install -m 0755 rootfs/init.sh "$stage/sbin/init"
    # Pre-create applet symlinks at BUILD time so they exist on a READ-ONLY root
    # (dm-verity mounts ro; `busybox --install` at runtime would fail to write them).
    for app in sh cat ls echo mount umount sync poweroff reboot findmnt blkid awk cut grep cp; do
        ln -sf busybox "$stage/bin/$app"
    done
    # per-flavor identity marker
    install -D -m 0644 "rootfs/$flavor/etc/rootfs-id" "$stage/etc/rootfs-id"
    # minimal /etc so the shell is pleasant
    echo "root:x:0:0:root:/root:/bin/sh" > "$stage/etc/passwd"
    echo "partguid-$flavor" > "$stage/etc/hostname"

    rm -f "$OUT/$flavor.img"
    # -b 4096: match dm-verity's data-block-size (4096). mke2fs defaults to 1024-byte
    # blocks at 32M, which the verity device (logical block size 4096) can't mount.
    mke2fs -q -t ext4 -b 4096 -L "root-$flavor" -d "$stage" "$OUT/$flavor.img" "$SIZE"
    rm -rf "$stage"
    echo "[rootfs] built $OUT/$flavor.img ($SIZE, label root-$flavor)"
}

build_one good
build_one evil
echo "[rootfs] done"
