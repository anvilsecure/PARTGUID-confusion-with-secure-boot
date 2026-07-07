#!/usr/bin/env bash
# Sign the kernel FIT (RSA-2048) and write the public key into a control DTB.
# Runs inside the build container.
#
# Usage: sign-fit.sh [base-control-dtb]
#   default base: out/stage-b/live.dtb if present (known-bootable, ~8KB, extracted from
#   a working boot), else out/stage-b/qemu-virt.dtb (from -machine dumpdtb — NOTE this
#   1 MiB dump does NOT boot the kernel when fed back via -dtb; prefer live.dtb).
#
# Outputs: out/stage-b/kernel.itb (signed) + out/stage-b/keyed.dtb (base + pubkey).
set -euo pipefail

KERNEL=out/kernel/Image
KEYS=keys
ITB=out/stage-b/kernel.itb
KEYED=out/stage-b/keyed.dtb
mkdir -p out/stage-b "$KEYS"

BASE="${1:-}"
if [ -z "$BASE" ]; then
    if [ -f out/stage-b/live.dtb ]; then BASE=out/stage-b/live.dtb; else BASE=out/stage-b/qemu-virt.dtb; fi
fi
[ -f "$KERNEL" ] || { echo "missing $KERNEL"; exit 1; }
[ -f "$BASE" ]   || { echo "missing base control dtb $BASE"; exit 1; }

if [ ! -f "$KEYS/dev.key" ]; then
    openssl genpkey -algorithm RSA -out "$KEYS/dev.key" \
        -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537
    openssl req -batch -new -x509 -key "$KEYS/dev.key" -out "$KEYS/dev.crt" -subj "/CN=partguid-lab"
fi

STG="$(mktemp -d)"
cp "$KERNEL" "$STG/Image"
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

# Control DTB = base + room for the key node; then stamp the pubkey in.
dtc -I dtb -O dtb -p 8192 "$BASE" -o "$KEYED" 2>/dev/null
mkimage -f "$STG/kernel.its" -k "$(cd "$KEYS" && pwd)" -K "$KEYED" -r "$ITB" >/dev/null
rm -rf "$STG"

echo "[sign-fit] base control dtb : $BASE ($(stat -c%s "$BASE") bytes)"
echo "[sign-fit] /signature node  : $(fdtget -l "$KEYED" /signature 2>/dev/null || echo MISSING)"
echo "[sign-fit] signed FIT        : $ITB"
echo "[sign-fit] keyed control dtb : $KEYED"
