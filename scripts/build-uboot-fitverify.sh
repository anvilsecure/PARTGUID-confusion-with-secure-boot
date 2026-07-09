#!/usr/bin/env bash
# Build a U-Boot that ENFORCES FIT signature verification (for `make verity-signed`).
# Keeps OF_BOARD on: the RSA public key is NOT embedded in u-boot.bin, it is injected
# into a copy of QEMU's control DTB later (make-verity-signed.sh -> keyed.dtb, passed via
# -dtb). This script only builds the binary and the dev keypair; the per-image signing
# happens in make-verity-signed.sh. Runs inside the build container.
#
# Outputs:
#   out/uboot-fit/u-boot.bin   U-Boot with CONFIG_FIT_SIGNATURE
#   keys/dev.{key,crt}         RSA-2048 dev signing keypair (gitignored)
set -euo pipefail

UBOOT_REF="${UBOOT_REF:-v2024.07}"
SRC=src/u-boot
OUTU=out/uboot-fit
KEYS=keys
mkdir -p "$OUTU" "$KEYS"

[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$UBOOT_REF" \
    https://source.denx.de/u-boot/u-boot.git "$SRC"

export ARCH=arm CROSS_COMPILE=aarch64-linux-gnu-

# RSA-2048 dev keypair used to sign the FIT (and whose pubkey is stamped into keyed.dtb).
if [ ! -f "$KEYS/dev.key" ]; then
    openssl genpkey -algorithm RSA -out "$KEYS/dev.key" \
        -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537
    openssl req -batch -new -x509 -key "$KEYS/dev.key" -out "$KEYS/dev.crt" \
        -subj "/CN=partguid-lab"
fi

( cd "$SRC"
  make qemu_arm64_defconfig
  ./scripts/kconfig/merge_config.sh -m .config ../../configs/uboot-fitverify.fragment
  make olddefconfig
  grep -q '^CONFIG_FIT_SIGNATURE=y' .config || { echo "FIT_SIGNATURE not set"; exit 1; }
  make -j"$(nproc)" )
cp "$SRC/u-boot.bin" "$OUTU/u-boot.bin"

echo "[uboot-fit] done -> $OUTU/u-boot.bin (FIT_SIGNATURE enforced)"
