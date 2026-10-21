#!/usr/bin/env bash
# Realistic two-disk model (embedded device + attacker USB). Runs in the container.
#
#   disk.img  = INTERNAL media: p1 rootfs (golden or evil) + p2 BOOT SLOT (signed FIT).
#               Boots on its own. -> QEMU hd0 -> U-Boot virtio 1 / Linux vdb.
#   disk2.img = ATTACKER USB: p1 rootfs (evil), NO boot slot — just an inserted stick.
#               -> QEMU hd1 -> U-Boot virtio 0 / Linux vda.
#
# U-Boot's embedded bootcmd tries virtio 0 (the USB: no boot slot, no signed FIT) and
# falls through to virtio 1, where it verifies the internal golden rootfs. Linux then
# enumerates vda (the USB) first and mounts ITS rootfs.
#
# Usage: make-multidisk.sh [partlabel|partuuid|good-only|evil-only]
set -euo pipefail
OUT=out/image; mkdir -p "$OUT"
DISK="$OUT/disk.img"; DISK2="$OUT/disk2.img"
ITB=out/fit/kernel.itb; EVIL=out/rootfs/evil.img; GOOD=out/rootfs/good.img
for f in "$ITB" "$EVIL" "$GOOD"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
GUID_X="11111111-2222-3333-4444-555555555555"
ROOTSZ=$(( $(stat -c%s "$GOOD") / 1048576 ))M      # partition == image (whole-part hash)

SCEN="${1:-partlabel}"
INT_FS="$GOOD"; ATT=1; IGUID=(); AGUID=(); EXPECT=EVIL
case "$SCEN" in
  partlabel) ;;                                                   # both p1 named rootfs, distinct GUIDs
  partuuid)  IGUID=(-u 1:"$GUID_X"); AGUID=(-u 1:"$GUID_X") ;;    # both p1 share PARTUUID X
  good-only) ATT=0; EXPECT=GOOD ;;                                # internal golden, boots alone
  evil-only) ATT=0; INT_FS="$EVIL"; EXPECT=VERIFY-FAIL ;;         # internal evil -> U-Boot rejects
  *) echo "unknown scenario: $SCEN (partlabel|partuuid|good-only|evil-only)"; exit 2 ;;
esac

# boot slot: only the signed FIT (no boot script anywhere on disk)
stage="$(mktemp -d)"; cp "$ITB" "$stage/kernel.itb"
rm -f "$OUT/boot.img"; mke2fs -q -t ext4 -b 4096 -L boot -d "$stage" "$OUT/boot.img" 96M; rm -rf "$stage"

first_lba(){ sgdisk -i "$1" "$2" | awk '/First sector/{print $3}'; }

# INTERNAL disk: p1 rootfs + p2 boot slot
rm -f "$DISK"; truncate -s 224M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk -n 1:0:+$ROOTSZ -t 1:8300 -c 1:rootfs "${IGUID[@]}" \
       -n 2:0:+128M    -t 2:8300 -c 2:boot "$DISK" >/dev/null
dd if="$INT_FS"       of="$DISK" bs=512 seek="$(first_lba 1 "$DISK")" conv=notrunc status=none
dd if="$OUT/boot.img" of="$DISK" bs=512 seek="$(first_lba 2 "$DISK")" conv=notrunc status=none
echo "[mldisk] disk.img  (internal, boots on its own): p1 rootfs=$(basename "$INT_FS" .img) + p2 boot slot"

# ATTACKER USB: p1 evil rootfs only, no boot slot
if [ "$ATT" = 1 ]; then
    rm -f "$DISK2"; truncate -s 64M "$DISK2"; sgdisk -Z "$DISK2" >/dev/null
    sgdisk -n 1:0:+$ROOTSZ -t 1:8300 -c 1:rootfs "${AGUID[@]}" "$DISK2" >/dev/null
    dd if="$EVIL" of="$DISK2" bs=512 seek="$(first_lba 1 "$DISK2")" conv=notrunc status=none
    echo "[mldisk] disk2.img (attacker USB): p1 rootfs=evil, NO boot slot"
else
    rm -f "$DISK2"
    echo "[mldisk] (baseline: no attacker USB — boot the internal disk alone)"
fi

echo "$EXPECT" > "$OUT/EXPECT"
echo "[mldisk] scenario=$SCEN rootfs partitions=$ROOTSZ expect=$EXPECT"
