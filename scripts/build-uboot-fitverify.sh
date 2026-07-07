#!/usr/bin/env bash
# Build a U-Boot that enforces FIT signature verification, keeping OF_BOARD on.
# The public key is NOT embedded in u-boot.bin; instead it is written into a copy of
# QEMU's virt DTB (out/stage-b/keyed.dtb), which run-qemu.sh passes back via -dtb.
# Runs inside the build container.
#
# Outputs:
#   out/uboot-fit/u-boot.bin   U-Boot with FIT_SIGNATURE (uses QEMU's -dtb control FDT)
#   out/stage-b/kernel.itb     signed FIT (kernel + fdt, sha256/rsa2048)
#   out/stage-b/keyed.dtb      QEMU virt DTB + /signature/key-dev (pass with -dtb)
#   keys/dev.{key,crt}         dev signing key (gitignored)
set -euo pipefail

UBOOT_REF="${UBOOT_REF:-v2024.07}"
SRC=src/u-boot
OUTU=out/uboot-fit
KEYS=keys
DTB=out/stage-b/qemu-virt.dtb
KEYED=out/stage-b/keyed.dtb
KERNEL=out/kernel/Image
ITB=out/stage-b/kernel.itb
mkdir -p "$OUTU" "$KEYS" out/stage-b

[ -f "$DTB" ]    || { echo "missing $DTB — dump qemu virt dtb on the host first"; exit 1; }
[ -f "$KERNEL" ] || { echo "missing $KERNEL — run build-kernel.sh first"; exit 1; }
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$UBOOT_REF" \
    https://source.denx.de/u-boot/u-boot.git "$SRC"

export ARCH=arm CROSS_COMPILE=aarch64-linux-gnu-

# 1. dev signing keypair (RSA-2048)
if [ ! -f "$KEYS/dev.key" ]; then
    openssl genpkey -algorithm RSA -out "$KEYS/dev.key" \
        -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537
    openssl req -batch -new -x509 -key "$KEYS/dev.key" -out "$KEYS/dev.crt" \
        -subj "/CN=partguid-lab"
fi

# 2. Build U-Boot with FIT_SIGNATURE (OF_BOARD stays on — uses QEMU's control DTB).
( cd "$SRC"
  make qemu_arm64_defconfig
  ./scripts/kconfig/merge_config.sh -m .config ../../configs/uboot-fitverify.fragment
  make olddefconfig
  grep -q '^CONFIG_FIT_SIGNATURE=y' .config || { echo "FIT_SIGNATURE not set"; exit 1; }
  make -j"$(nproc)" )
cp "$SRC/u-boot.bin" "$OUTU/u-boot.bin"

# 3. Signed FIT (.its in a staging dir; incbin paths relative to it).
STG="$(mktemp -d)"
cp "$KERNEL" "$STG/Image"; cp "$DTB" "$STG/virt.dtb"
# Kernel-only FIT: NO fdt node. bootm then boots the (signed) kernel using U-Boot's
# control FDT = QEMU's live DTB (passed via -dtb). Embedding the dumped DTB as the
# FIT fdt makes the kernel go silent after "Starting kernel"; the live QEMU DTB works
# (same one Stage A's booti used). The kernel is what's signed — that is the point.
cat > "$STG/kernel.its" <<'ITS'
/dts-v1/;
/ {
    description = "partguid-lab signed kernel (RSA-2048)";
    #address-cells = <1>;
    images {
        kernel {
            data = /incbin/("./Image");
            type = "kernel"; arch = "arm64"; os = "linux"; compression = "none";
            load = <0x40400000>; entry = <0x40400000>;
            hash-1 { algo = "sha256"; };
        };
    };
    configurations {
        default = "conf-1";
        conf-1 {
            kernel = "kernel";
            signature { algo = "sha256,rsa2048"; key-name-hint = "dev"; sign-images = "kernel"; };
        };
    };
};
ITS

# 4. Sign the FIT AND write the pubkey into a copy of QEMU's virt DTB (-> keyed.dtb).
cp "$DTB" "$KEYED"
KEYS_ABS="$(cd "$KEYS" && pwd)"
mkimage -f "$STG/kernel.its" -k "$KEYS_ABS" -K "$KEYED" -r "$STG/kernel.itb"
cp "$STG/kernel.itb" "$ITB"
rm -rf "$STG"

echo "[fitverify] /signature in keyed.dtb:"; fdtget -l "$KEYED" /signature 2>/dev/null || echo "  (none!)"
echo "[fitverify] done -> $OUTU/u-boot.bin + $ITB + $KEYED"
