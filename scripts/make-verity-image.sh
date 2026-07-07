#!/usr/bin/env bash
# Craft the dm-verity MITIGATION disk: same PARTUUID confusion, but the rootfs is
# mapped through dm-verity with the GOLDEN rootfs's root hash. dm-verity rejects the
# evil partition. Runs inside the build container (needs veritysetup + dm tooling).
# Output: out/image/disk.img (+ out/image/EXPECT = EVIL-BLOCKED)
set -euo pipefail

OUT=out/image; mkdir -p "$OUT"; DISK="$OUT/disk.img"
KERNEL=out/kernel/Image
EVIL=out/rootfs/evil.img
GOOD=out/rootfs/good.img
GUID_X="11111111-2222-3333-4444-555555555555"   # PARTUUID the verity data dev targets
GUID_Y="22222222-3333-4444-5555-666666666666"   # distinct (good-control: no collision)
PARTUUID="${GUID_X,,}"
for f in "$KERNEL" "$EVIL" "$GOOD"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done

# MODE=evil (default): p1 evil shares PARTUUID X -> verity data resolves to evil -> PANIC.
# MODE=good: p1 evil has a DISTINCT GUID, so PARTUUID X -> only p3 (good) -> verity PASSES
#            and the golden rootfs runs (read-only) — proves verity isn't always failing.
MODE="${1:-evil}"
case "$MODE" in
  evil) P1_GUID="$GUID_X"; EXPECT=EVIL-BLOCKED ;;
  good) P1_GUID="$GUID_Y"; EXPECT=GOOD-VERIFIED ;;
  *) echo "unknown mode: $MODE (evil|good)"; exit 2 ;;
esac
command -v veritysetup >/dev/null || { echo "veritysetup missing — rebuild the image (make env)"; exit 1; }

# 1. verity hash tree over the GOLDEN rootfs (8192 blocks x 4096 = 32 MiB)
rm -f "$OUT/hash.img"; truncate -s 16M "$OUT/hash.img"
V="$(veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
        --data-blocks=8192 "$GOOD" "$OUT/hash.img")"
echo "$V"
ROOTHASH="$(echo "$V" | awk '/Root hash:/{print $NF}')"
SALT="$(echo "$V" | awk '/Salt:/{print $NF}')"
[ ${#ROOTHASH} -eq 64 ] || { echo "bad root hash: '$ROOTHASH'"; exit 1; }
echo "[verity] root hash = $ROOTHASH"
echo "[verity] salt      = $SALT"

# 2. boot.scr with the verity dm-mod.create cmdline
stage="$(mktemp -d)"; cp "$KERNEL" "$stage/Image"
sed -e "s/@@PARTUUID@@/$PARTUUID/g" \
    -e "s/@@ROOTHASH@@/$ROOTHASH/g" \
    -e "s/@@SALT@@/$SALT/g" \
    uboot/boot-verity.cmd > "$stage/boot.cmd"
mkimage -A arm64 -O linux -T script -C none -n partguid-verity \
    -d "$stage/boot.cmd" "$stage/boot.scr" >/dev/null
rm -f "$OUT/boot.img"; mke2fs -q -t ext4 -L boot -d "$stage" "$OUT/boot.img" 96M; rm -rf "$stage"

# 3. GPT: p1 evil(X), p2 boot, p3 good(X), p4 verity-hash
rm -f "$DISK"; truncate -s 320M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk \
    -n 1:0:+48M  -t 1:8300 -c 1:rootfs-decoy -u 1:"$P1_GUID" \
    -n 2:0:+128M -t 2:8300 -c 2:boot \
    -n 3:0:+48M  -t 3:8300 -c 3:rootfs -u 3:"$GUID_X" \
    -n 4:0:+16M  -t 4:8300 -c 4:verity-hash \
    "$DISK" >/dev/null
first_lba(){ sgdisk -i "$1" "$DISK" | awk '/First sector/{print $3}'; }
place(){ dd if="$1" of="$DISK" bs=512 seek="$(first_lba "$2")" conv=notrunc status=none; echo "[verity]   placed $(basename "$1") at p$2"; }
place "$EVIL"          1
place "$OUT/boot.img"  2
place "$GOOD"          3
place "$OUT/hash.img"  4

echo "$EXPECT" > "$OUT/EXPECT"
echo "[verity] mode=$MODE done -> $DISK  (expect: $EXPECT)"
