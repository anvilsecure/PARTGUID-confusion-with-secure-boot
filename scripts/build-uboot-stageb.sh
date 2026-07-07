#!/usr/bin/env bash
# Stage B: build a U-Boot that ENFORCES FIT signature verification, with the RSA
# public key embedded in its control FDT, plus a signed kernel.itb.
# Runs inside the build container.
#
# Outputs:
#   out/uboot-stageb/u-boot.bin   U-Boot with embedded key-bearing control DTB
#   out/stage-b/kernel.itb        signed FIT (kernel + qemu virt fdt, sha256/rsa2048)
#   keys/dev.{key,crt}            dev signing key (gitignored)
#
# Prereq (host): scripts dumped out/stage-b/qemu-virt.dtb via
#   qemu-system-aarch64 -M virt,dumpdtb=... -cpu cortex-a57 -m 512
# using the SAME -m/-cpu as run-qemu.sh, or the kernel will see wrong memory.
set -euo pipefail

UBOOT_REF="${UBOOT_REF:-v2024.07}"
SRC=src/u-boot
OUTU=out/uboot-stageb
KEYS=keys
DTB=out/stage-b/qemu-virt.dtb
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
    echo "[stageb] generating RSA-2048 dev key"
    openssl genpkey -algorithm RSA -out "$KEYS/dev.key" \
        -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537
    openssl req -batch -new -x509 -key "$KEYS/dev.key" -out "$KEYS/dev.crt" \
        -subj "/CN=partguid-lab"
fi

# 2. Control-FDT source = QEMU's REAL virt DTB (so it describes the hw correctly)
#    plus an empty /signature node for mkimage -K to populate.
echo "[stageb] installing qemu virt dtb as U-Boot control device tree"
{ dtc -I dtb -O dts "$DTB" 2>/dev/null; printf '\n/ { signature { }; };\n'; } \
    > "$SRC/arch/arm/dts/qemu-arm64.dts"

# 3. Permit disabling OF_BOARD for this board (else scripts/check-of.sh aborts).
grep -qx 'qemu-arm' "$SRC/scripts/of_allowlist.txt" || echo 'qemu-arm' >> "$SRC/scripts/of_allowlist.txt"

# 4. Configure + first build.
( cd "$SRC"
  make qemu_arm64_defconfig
  ./scripts/kconfig/merge_config.sh -m .config ../../configs/uboot-stage-b.fragment
  make olddefconfig
  grep -qE '^CONFIG_OF_BOARD=y' .config && { echo "OF_BOARD still on!"; exit 1; }
  make -j"$(nproc)" )

# 5. Build the FIT .its in a staging dir (incbin paths are relative to it).
STG="$(mktemp -d)"
cp "$KERNEL" "$STG/Image"
cp "$DTB"    "$STG/virt.dtb"
cat > "$STG/kernel.its" <<'ITS'
/dts-v1/;
/ {
    description = "partguid-lab signed kernel + fdt";
    #address-cells = <1>;
    images {
        kernel {
            description = "Linux kernel";
            data = /incbin/("./Image");
            type = "kernel"; arch = "arm64"; os = "linux"; compression = "none";
            load = <0x40400000>; entry = <0x40400000>;
            hash-1 { algo = "sha256"; };
        };
        fdt-1 {
            description = "qemu virt control fdt";
            data = /incbin/("./virt.dtb");
            type = "flat_dt"; arch = "arm64"; compression = "none";
            hash-1 { algo = "sha256"; };
        };
    };
    configurations {
        default = "conf-1";
        conf-1 {
            description = "kernel + fdt";
            kernel = "kernel"; fdt = "fdt-1";
            signature {
                algo = "sha256,rsa2048";
                key-name-hint = "dev";
                sign-images = "fdt", "kernel";
            };
        };
    };
};
ITS

# 6. Sign the FIT AND stamp the public key into U-Boot's compiled control DTB.
KEYS_ABS="$(cd "$KEYS" && pwd)"
DTDTB="$SRC/dts/dt.dtb"
echo "[stageb] signing FIT and writing pubkey into $DTDTB"
mkimage -f "$STG/kernel.its" -k "$KEYS_ABS" -K "$DTDTB" -r "$STG/kernel.itb"
cp "$STG/kernel.itb" "$ITB"

# 7. Relink u-boot.bin so the KEYED dt.dtb is the embedded control FDT. mkimage -K
#    bumped dt.dtb's mtime above its .dts source, so make re-concatenates rather than
#    recompiling (which would discard the key) — the documented vboot relink trick.
( cd "$SRC"; make u-boot.bin )
cp "$SRC/u-boot.bin" "$OUTU/u-boot.bin"

# 8. Sanity: the key node must be present in the embedded control DTB.
echo "[stageb] /signature in embedded control dtb:"
fdtget -l "$DTDTB" /signature 2>/dev/null || echo "  (none — verification will fail!)"
rm -rf "$STG"
echo "[stageb] done -> $OUTU/u-boot.bin + $ITB"
