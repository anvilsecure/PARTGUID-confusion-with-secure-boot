#!/usr/bin/env bash
# Build a static aarch64 busybox to use as /bin/busybox + init in both rootfs images.
# Runs inside the build container. Output: out/busybox/busybox
set -euo pipefail

BB_VER="${BB_VER:-1.36.1}"
SRC="src/busybox"
OUT=out/busybox
mkdir -p "$OUT" src

# Validity is "has a Makefile", not "dir exists" — a half-extracted tree must be
# refetched. Clean inside the container to avoid host/container rm races.
if [ ! -f "$SRC/Makefile" ]; then
    echo "[busybox] (re)fetching $BB_VER"
    rm -rf "$SRC"
    wget -O /tmp/busybox.tar.bz2 "https://busybox.net/downloads/busybox-${BB_VER}.tar.bz2"
    mkdir -p "$SRC"
    tar -xjf /tmp/busybox.tar.bz2 -C "$SRC" --strip-components=1
    test -f "$SRC/Makefile" || { echo "[busybox] extraction failed"; exit 1; }
fi

cd "$SRC"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

make defconfig
# static build so the rootfs needs no shared libraries at all.
# Disable a couple of applets that don't cross-compile cleanly against the
# static cross libc. olddefconfig (NOT oldconfig) resolves everything else
# non-interactively, taking defaults for any new symbols.
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
# busybox kconfig has 'oldconfig' (not 'olddefconfig'). Feed EOF via </dev/null so
# any new symbol takes its default; avoid `yes |` which trips pipefail via SIGPIPE.
make oldconfig </dev/null

make -j"$(nproc)"

cp -v busybox "../../$OUT/busybox"
echo "[busybox] done -> $OUT/busybox"
