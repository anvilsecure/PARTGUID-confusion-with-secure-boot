#!/usr/bin/env bash
# COMPLETE SOLUTION: dm-verity whose root hash is anchored in an RSA-signed FIT.
# Runs inside the build container. Needs veritysetup + mkimage + dtc/fdtput + the dev
# key (build-uboot-fitverify.sh) + a known-bootable base DTB (out/stage-b/live.dtb).
#
# What it builds (single disk, SAME PARTUUID collision as the attack):
#   1. a dm-verity hash tree over the GOLDEN rootfs -> root hash H(golden)
#   2. a verity cmdline (root=/dev/dm-0 + dm-mod.create=... carrying H(golden)) placed in
#      the /chosen/bootargs of a device tree (verity.dtb)
#   3. a FIT { kernel, fdt=verity.dtb } SIGNED with RSA-2048; the pubkey is stamped into
#      the control DTB (keyed.dtb). Because the cmdline (hence the root hash) is inside
#      the signed FIT, an attacker cannot swap in a non-verity cmdline: tampering breaks
#      the signature and U-Boot refuses to boot.
#   4. a GPT disk: p1 evil, p2 boot slot (the signed kernel.itb), p3 good, p4 verity-hash.
#
# MODE=evil (default): p1 shares PARTUUID X -> verity data resolves to evil -> PANIC.
# MODE=good           : p1 has a DISTINCT GUID -> PARTUUID X -> only p3 (good) -> PASSES.
# Output: out/image/disk.img, out/stage-b/{kernel.itb,keyed.dtb} (+ out/image/EXPECT)
set -euo pipefail

OUT=out/image; mkdir -p "$OUT" out/stage-b
DISK="$OUT/disk.img"
KERNEL=out/kernel/Image; EVIL=out/rootfs/evil.img; GOOD=out/rootfs/good.img
KEYS=keys; ITB=out/stage-b/kernel.itb; KEYED=out/stage-b/keyed.dtb
BASE="${BASE:-out/stage-b/live.dtb}"
GUID_X="11111111-2222-3333-4444-555555555555"   # PARTUUID the verity data dev targets
GUID_Y="22222222-3333-4444-5555-666666666666"   # distinct (good control: no collision)
PARTUUID="${GUID_X,,}"

for f in "$KERNEL" "$EVIL" "$GOOD" "$BASE" "$KEYS/dev.key"; do
    [ -f "$f" ] || { echo "missing $f (run build-uboot-fitverify.sh + bootstrap live DTB first)"; exit 1; }
done
command -v veritysetup >/dev/null || { echo "veritysetup missing — make env"; exit 1; }

MODE="${1:-evil}"
case "$MODE" in
  evil)   P1_GUID="$GUID_X"; EXPECT=EVIL-BLOCKED ;;
  good)   P1_GUID="$GUID_Y"; EXPECT=GOOD-VERIFIED ;;
  tamper) P1_GUID="$GUID_X"; EXPECT=TAMPER-REFUSED ;;   # flip a byte in the signed FIT
  *) echo "unknown mode: $MODE (evil|good|tamper)"; exit 2 ;;
esac

# 1. verity hash tree over the GOLDEN rootfs (8192 blocks x 4096 = 32 MiB)
rm -f "$OUT/hash.img"; truncate -s 16M "$OUT/hash.img"
V="$(veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
        --data-blocks=8192 "$GOOD" "$OUT/hash.img")"
ROOTHASH="$(echo "$V" | awk '/Root hash:/{print $NF}')"
SALT="$(echo "$V" | awk '/Salt:/{print $NF}')"
[ ${#ROOTHASH} -eq 64 ] || { echo "bad root hash '$ROOTHASH'"; exit 1; }
echo "[verity-signed] root hash = $ROOTHASH"

# 2. verity cmdline -> /chosen/bootargs of verity.dtb (data dev = PARTUUID=X, hash = vda4)
CMDLINE="console=ttyAMA0 root=/dev/dm-0 ro rootwait panic=-1 partguid.verified dm-mod.create=\"vroot,,0,ro,0 65536 verity 1 PARTUUID=$PARTUUID /dev/vda4 4096 4096 8192 1 sha256 $ROOTHASH $SALT 1 panic_on_corruption\""
STG="$(mktemp -d)"
cp "$KERNEL" "$STG/Image"
dtc -I dtb -O dtb -p 8192 "$BASE" -o "$STG/verity.dtb" 2>/dev/null
fdtput -p -t s "$STG/verity.dtb" /chosen bootargs "$CMDLINE"
echo "[verity-signed] signed cmdline set in verity.dtb /chosen/bootargs"

# 3. SIGNED FIT { kernel, fdt=verity.dtb }; stamp the pubkey into the control DTB.
cat > "$STG/verity.its" <<'ITS'
/dts-v1/;
/ {
    description = "partguid-lab signed dm-verity boot (RSA-2048)";
    #address-cells = <1>;
    images {
        kernel {
            data = /incbin/("./Image");
            type = "kernel"; arch = "arm64"; os = "linux"; compression = "none";
            load = <0x40400000>; entry = <0x40400000>;
            hash-1 { algo = "sha256"; };
        };
        fdt-1 {
            data = /incbin/("./verity.dtb");
            type = "flat_dt"; arch = "arm64"; compression = "none";
            hash-1 { algo = "sha256"; };
        };
    };
    configurations {
        default = "conf-1";
        conf-1 {
            kernel = "kernel"; fdt = "fdt-1";
            signature { algo = "sha256,rsa2048"; key-name-hint = "dev"; sign-images = "kernel", "fdt"; };
        };
    };
};
ITS
dtc -I dtb -O dtb -p 8192 "$BASE" -o "$KEYED" 2>/dev/null   # control DTB base + room for key
mkimage -f "$STG/verity.its" -k "$(cd "$KEYS" && pwd)" -K "$KEYED" -r "$STG/kernel.itb" >/dev/null
cp "$STG/kernel.itb" "$ITB"
echo "[verity-signed] /signature in keyed.dtb: $(fdtget -l "$KEYED" /signature 2>/dev/null || echo MISSING)"

# boot slot fs carrying the signed FIT
rm -f "$OUT/boot.img"
mkdir -p "$STG/boot"; cp "$ITB" "$STG/boot/kernel.itb"
if [ "$MODE" = tamper ]; then
    # flip one byte inside the signed FIT's kernel payload -> sha256 hash fails ->
    # U-Boot must refuse (proves the FIT, incl. the fdt carrying the root hash, is
    # integrity-protected: an attacker cannot alter any of it without breaking the sig).
    sz=$(stat -c%s "$STG/boot/kernel.itb"); off=$((sz/2))
    printf '\xa5' | dd of="$STG/boot/kernel.itb" bs=1 seek="$off" count=1 conv=notrunc status=none
    echo "[verity-signed] TAMPER: flipped byte at offset $off of the signed FIT"
fi
mke2fs -q -t ext4 -L boot -d "$STG/boot" "$OUT/boot.img" 96M
rm -rf "$STG"

# 4. GPT: p1 evil(P1_GUID), p2 boot(signed FIT), p3 good(X), p4 verity-hash
rm -f "$DISK"; truncate -s 320M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk \
    -n 1:0:+48M  -t 1:8300 -c 1:rootfs-decoy -u 1:"$P1_GUID" \
    -n 2:0:+128M -t 2:8300 -c 2:boot \
    -n 3:0:+48M  -t 3:8300 -c 3:rootfs -u 3:"$GUID_X" \
    -n 4:0:+16M  -t 4:8300 -c 4:verity-hash \
    "$DISK" >/dev/null
first_lba(){ sgdisk -i "$1" "$DISK" | awk '/First sector/{print $3}'; }
place(){ dd if="$1" of="$DISK" bs=512 seek="$(first_lba "$2")" conv=notrunc status=none; echo "[verity-signed]   placed $(basename "$1") at p$2"; }
place "$EVIL"          1
place "$OUT/boot.img"  2
place "$GOOD"          3
place "$OUT/hash.img"  4

echo "$EXPECT" > "$OUT/EXPECT"
echo "[verity-signed] mode=$MODE done -> $DISK (signed FIT: $ITB, control DTB: $KEYED, expect $EXPECT)"
