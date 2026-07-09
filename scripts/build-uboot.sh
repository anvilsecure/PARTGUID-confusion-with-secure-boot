#!/usr/bin/env bash
# Build U-Boot for the QEMU arm64 'virt' machine.
# Runs inside the build container. Output: out/uboot/u-boot.bin
set -euo pipefail

UBOOT_REF="${UBOOT_REF:-v2024.07}"
SRC=src/u-boot
OUT=out/uboot
mkdir -p "$OUT"

if [ ! -d "$SRC/.git" ]; then
    echo "[uboot] cloning $UBOOT_REF"
    git clone --depth 1 --branch "$UBOOT_REF" \
        https://source.denx.de/u-boot/u-boot.git "$SRC"
fi

cd "$SRC"
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm

make qemu_arm64_defconfig

# stock config already scans partitions for /boot.scr; the fragment adds the extra
# commands the boot script needs (hash verify of the rootfs, part lookup by name).
if [ -f ../../configs/uboot.fragment ]; then
    ./scripts/kconfig/merge_config.sh -m .config ../../configs/uboot.fragment
    make olddefconfig
fi

make -j"$(nproc)"

cp -v u-boot.bin "../../$OUT/u-boot.bin"
echo "[uboot] done -> $OUT/u-boot.bin"
