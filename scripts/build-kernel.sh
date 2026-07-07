#!/usr/bin/env bash
# Build a minimal arm64 Linux kernel Image that mounts an ext4 root via
# root=PARTUUID= with no initramfs. Runs inside the build container.
# Output: out/kernel/Image
set -euo pipefail

LINUX_REF="${LINUX_REF:-v6.6}"
SRC=src/linux
OUT=out/kernel
mkdir -p "$OUT"

if [ ! -d "$SRC/.git" ]; then
    echo "[kernel] cloning $LINUX_REF (this is large; shallow clone)"
    git clone --depth 1 --branch "$LINUX_REF" \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$SRC"
fi

cd "$SRC"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

make defconfig
./scripts/kconfig/merge_config.sh -m .config ../../configs/kernel.fragment
make olddefconfig

make -j"$(nproc)" Image

cp -v arch/arm64/boot/Image "../../$OUT/Image"
echo "[kernel] done -> $OUT/Image"
