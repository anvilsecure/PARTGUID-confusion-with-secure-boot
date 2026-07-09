#!/usr/bin/env bash
# Realistic two-disk model (embedded device + attacker USB). Runs in the container.
#
#   disk.img  = INTERNAL media (eMMC): p1 rootfs (golden or evil) + p2 BOOT SLOT
#               (kernel + boot.scr). Boots on its own.
#   disk2.img = ATTACKER USB: p1 rootfs (evil), NO boot slot — just an inserted stick.
#
# Enumeration (measured): with BOTH disks, disk.img=hd0->virtio1/vdb, disk2.img=hd1->
# virtio0/vda. U-Boot's scanning bootcmd tries virtio0:2 (the USB — no boot slot, fails)
# then virtio1:2 (the internal disk — boots), so ${bootdev}=1 and it verifies the
# internal golden rootfs. Linux enumerates vda (the USB) first and mounts its evil
# rootfs. With ONE disk attached it is virtio0/vda and ${bootdev}=0.
#
# Usage: make-multidisk.sh [scenario]
#   scenario: partlabel|partuuid  -> bypass, build BOTH disks (internal=golden, USB=evil)
#             good-only|evil-only -> baseline, build only the internal disk (boot alone)
set -euo pipefail
OUT=out/image; mkdir -p "$OUT"
DISK="$OUT/disk.img"; DISK2="$OUT/disk2.img"
KERNEL=out/kernel/Image; EVIL=out/rootfs/evil.img; GOOD=out/rootfs/good.img
for f in "$KERNEL" "$EVIL" "$GOOD"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
GOODHASH="$(sha256sum rootfs/good/etc/rootfs-id | awk '{print $1}')"
ROOTNAME=rootfs
GUID_X="11111111-2222-3333-4444-555555555555"

SCEN="${1:-partlabel}"
INT_FS="$GOOD"; ATT=1; ROOTSPEC="PARTLABEL=rootfs"; IGUID=(); AGUID=(); EXPECT=EVIL
case "$SCEN" in
  partlabel) ;;                                                                # both disks, distinct auto GUIDs
  partuuid)  ROOTSPEC="PARTUUID=${GUID_X,,}"; IGUID=(-u 1:"$GUID_X"); AGUID=(-u 1:"$GUID_X") ;;
  good-only) ATT=0; EXPECT=GOOD ;;                                             # internal golden, boot alone
  evil-only) ATT=0; INT_FS="$EVIL"; EXPECT=VERIFY-FAIL ;;                       # internal evil -> U-Boot rejects
  *) echo "unknown scenario: $SCEN (partlabel|partuuid|good-only|evil-only)"; exit 2 ;;
esac

# boot.scr on the internal disk's boot slot (uses ${bootdev} at runtime)
stage="$(mktemp -d)"
cp "$KERNEL" "$stage/Image"; TPL=uboot/boot.cmd
sed -e "s/@@ROOTNAME@@/$ROOTNAME/g" -e "s#@@ROOTSPEC@@#$ROOTSPEC#g" -e "s/@@GOODHASH@@/$GOODHASH/g" \
    "$TPL" > "$stage/boot.cmd"
mkimage -A arm64 -O linux -T script -C none -n partguid-mldisk -d "$stage/boot.cmd" "$stage/boot.scr" >/dev/null
rm -f "$OUT/boot.img"; mke2fs -q -t ext4 -b 4096 -L boot -d "$stage" "$OUT/boot.img" 96M; rm -rf "$stage"

first_lba(){ sgdisk -i "$1" "$2" | awk '/First sector/{print $3}'; }

# INTERNAL disk: p1 rootfs (INT_FS) + p2 boot slot
rm -f "$DISK"; truncate -s 224M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk -n 1:0:+48M  -t 1:8300 -c 1:rootfs "${IGUID[@]}" \
       -n 2:0:+128M -t 2:8300 -c 2:boot "$DISK" >/dev/null
dd if="$INT_FS"       of="$DISK" bs=512 seek="$(first_lba 1 "$DISK")" conv=notrunc status=none
dd if="$OUT/boot.img" of="$DISK" bs=512 seek="$(first_lba 2 "$DISK")" conv=notrunc status=none
echo "[mldisk] disk.img  (internal, boots on its own): p1 rootfs=$(basename "$INT_FS" .img) + p2 boot slot"

# ATTACKER USB: p1 evil rootfs only, no boot slot (bypass scenarios only)
if [ "$ATT" = 1 ]; then
    rm -f "$DISK2"; truncate -s 64M "$DISK2"; sgdisk -Z "$DISK2" >/dev/null
    sgdisk -n 1:0:+48M -t 1:8300 -c 1:rootfs "${AGUID[@]}" "$DISK2" >/dev/null
    dd if="$EVIL" of="$DISK2" bs=512 seek="$(first_lba 1 "$DISK2")" conv=notrunc status=none
    echo "[mldisk] disk2.img (attacker USB): p1 rootfs=evil, NO boot slot"
else
    rm -f "$DISK2"
    echo "[mldisk] (baseline: no attacker USB — boot the internal disk alone)"
fi

echo "$EXPECT" > "$OUT/EXPECT"
echo "[mldisk] scenario=$SCEN root=$ROOTSPEC expect=$EXPECT"
