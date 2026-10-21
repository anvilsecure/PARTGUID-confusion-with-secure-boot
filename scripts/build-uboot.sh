#!/usr/bin/env bash
# Build U-Boot for QEMU arm64 'virt' with the lab's boot logic EMBEDDED in the binary.
# Runs inside the build container.
#
# Why embedded: a boot.scr on disk is attacker-writable, so verifying the rootfs from a
# disk-resident script is a secure-boot bypass in itself. Here the whole boot flow lives
# in U-Boot's built-in environment (CONFIG_ENV_SOURCE_FILE) and U-Boot never reads an
# environment from storage (CONFIG_ENV_IS_NOWHERE). The kernel is a SIGNED FIT.
#
# Usage: build-uboot.sh [partuuid|partlabel]
#   partuuid  - setup_bootargs derives root=PARTUUID=<uuid of the partition it verified>
#   partlabel - setup_bootargs uses root=PARTLABEL=<rootname>
# Output: out/uboot-<mode>/u-boot.bin
set -euo pipefail

MODE="${1:-partuuid}"
UBOOT_REF="${UBOOT_REF:-v2024.07}"
SRC=src/u-boot
OUT="out/uboot-$MODE"
GOOD=out/rootfs/good.img
BOOTNAME=boot
ROOTNAME=rootfs
mkdir -p "$OUT"

case "$MODE" in
  partuuid)  ROOTSPEC='part uuid virtio ${bootdev}:${rootpart} rootuuid; setenv rootspec PARTUUID=${rootuuid};' ;;
  partlabel) ROOTSPEC='setenv rootspec PARTLABEL=${rootname};' ;;
  *) echo "unknown mode: $MODE (partuuid|partlabel)"; exit 2 ;;
esac

# The golden hash is baked into the TRUSTED environment, so U-Boot must be built after
# the rootfs exists. It is the sha256 of the WHOLE rootfs partition, which equals the
# image because make-image.sh sizes the partition exactly like good.img.
[ -f "$GOOD" ] || { echo "missing $GOOD — build the rootfs first (make rootfs)"; exit 1; }
GOODHASH="$(sha256sum "$GOOD" | awk '{print $1}')"
echo "[uboot:$MODE] goodhash (sha256 of the whole golden rootfs) = $GOODHASH"

[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$UBOOT_REF" \
    https://source.denx.de/u-boot/u-boot.git "$SRC"

# CONFIG_ENV_SOURCE_FILE is a BASENAME resolved as board/<vendor>/<board>/<name>.env,
# so the generated env has to be dropped into the qemu-arm board directory.
ENVDST="$SRC/board/emulation/qemu-arm/partguid.env"
sed -e "s/@@BOOTNAME@@/$BOOTNAME/g" \
    -e "s/@@ROOTNAME@@/$ROOTNAME/g" \
    -e "s/@@GOODHASH@@/$GOODHASH/g" \
    -e "s#@@ROOTSPEC@@#$ROOTSPEC#g" \
    uboot/partguid.env.in > "$ENVDST"
grep -q '@@' "$ENVDST" && { echo "unsubstituted placeholder left in $ENVDST"; exit 1; }
echo "[uboot:$MODE] env -> $ENVDST"

export CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm
( cd "$SRC"
  make qemu_arm64_defconfig
  ./scripts/kconfig/merge_config.sh -m .config ../../configs/uboot-signed.fragment
  make olddefconfig
  for s in CONFIG_FIT_SIGNATURE CONFIG_ENV_IS_NOWHERE CONFIG_CMD_HASH CONFIG_CMD_SETEXPR CONFIG_CMD_PART; do
      grep -q "^$s=y" .config || { echo "MISSING $s in .config"; exit 1; }
  done
  grep -q '^CONFIG_USE_BOOTCOMMAND=y' .config && { echo "USE_BOOTCOMMAND still set"; exit 1; }
  make -j"$(nproc)" )
cp "$SRC/u-boot.bin" "$OUT/u-boot.bin"
echo "[uboot:$MODE] done -> $OUT/u-boot.bin"
