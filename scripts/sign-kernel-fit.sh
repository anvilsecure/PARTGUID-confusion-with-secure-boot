#!/usr/bin/env bash
# Sign the kernel as a FIT (RSA-2048) for the hash-verify lab, and stamp the public key
# into a control DTB. Runs inside the build container.
#
# The FIT here is KERNEL-ONLY: the kernel command line is built by U-Boot's embedded
# environment (setup_bootargs), so there is no fdt in the FIT and bootm is handed
# ${fdtcontroladdr} as its third argument.
#
# Outputs: out/fit/kernel.itb (signed)  +  out/fit/keyed.dtb (control FDT + pubkey)
set -euo pipefail

KERNEL=out/kernel/Image
KEYS=keys
OUT=out/fit
BASE="${BASE:-out/stage-b/live.dtb}"
mkdir -p "$OUT" "$KEYS"

[ -f "$KERNEL" ] || { echo "missing $KERNEL"; exit 1; }
[ -f "$BASE" ]   || { echo "missing control-DTB base $BASE"; exit 1; }

if [ ! -f "$KEYS/dev.key" ]; then
    openssl genpkey -algorithm RSA -out "$KEYS/dev.key" \
        -pkeyopt rsa_keygen_bits:2048 -pkeyopt rsa_keygen_pubexp:65537
    openssl req -batch -new -x509 -key "$KEYS/dev.key" -out "$KEYS/dev.crt" -subj "/CN=partguid-lab"
fi

STG="$(mktemp -d)"; cp "$KERNEL" "$STG/Image"
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
dtc -I dtb -O dtb -p 8192 "$BASE" -o "$OUT/keyed.dtb" 2>/dev/null
mkimage -f "$STG/kernel.its" -k "$(cd "$KEYS" && pwd)" -K "$OUT/keyed.dtb" -r "$OUT/kernel.itb" >/dev/null
rm -rf "$STG"

echo "[sign-fit] /signature in keyed.dtb: $(fdtget -l "$OUT/keyed.dtb" /signature 2>/dev/null || echo MISSING)"
echo "[sign-fit] done -> $OUT/kernel.itb ($(stat -c%s "$OUT/kernel.itb") bytes) + $OUT/keyed.dtb"
