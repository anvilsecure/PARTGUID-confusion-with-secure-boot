#!/usr/bin/env bash
# Craft the GPT disk for a chosen confusion scenario (RAT #116).
# Runs inside the build container. Output: out/image/disk.img (+ out/image/EXPECT)
#
# Usage: make-image.sh [scenario]
#
#   partuuid   (default) two partitions share one PARTUUID; the GOLDEN rootfs is
#              named 'rootfs' at p3, the attacker copy is at p1 (lower index).
#              U-Boot verifies the partition BY NAME ('rootfs' = good); Linux mounts
#              root=PARTUUID=<X> and picks the first match = p1 (evil).  => EVIL
#
#   partlabel  two partitions share the NAME 'rootfs' (distinct PARTUUIDs). Boot by
#              root=PARTLABEL=rootfs. Used to observe whether U-Boot's #rootfs and
#              Linux's PARTLABEL= resolve to the same partition (single-disk case).
set -euo pipefail

STRATEGY="${1:-partuuid}"
OUT=out/image
mkdir -p "$OUT"
DISK="$OUT/disk.img"

KERNEL=out/kernel/Image
EVIL_FS=out/rootfs/evil.img
GOOD_FS=out/rootfs/good.img
for f in "$KERNEL" "$EVIL_FS" "$GOOD_FS"; do
    [ -f "$f" ] || { echo "missing $f — build it first"; exit 1; }
done

GUID_X="11111111-2222-3333-4444-555555555555"   # shared PARTUUID (partuuid case)
GUID_A="aaaaaaaa-1111-2222-3333-444444444444"   # distinct (partlabel case)
GUID_B="bbbbbbbb-1111-2222-3333-444444444444"
BOOTPART=2
ROOTNAME=rootfs                                  # the name U-Boot verifies

# sha256 of the GOLDEN rootfs marker — U-Boot recomputes this over the file it loads
# from the partition named '$ROOTNAME' and compares (models signature verification).
GOODHASH="$(sha256sum rootfs/good/etc/rootfs-id | awk '{print $1}')"

case "$STRATEGY" in
  good-only)
    # baseline: the only 'rootfs' partition is GOOD -> U-Boot verifies OK -> boots good
    P1_FS="$GOOD_FS"; P1_NAME=spare;  P1_GUID="$GUID_A"
    P3_FS="$GOOD_FS"; P3_NAME=rootfs; P3_GUID="$GUID_X"
    ROOTSPEC="PARTUUID=${GUID_X,,}"
    EXPECT=GOOD ;;
  evil-only)
    # baseline: the only 'rootfs' partition is EVIL -> U-Boot hash-verify FAILS -> reset
    P1_FS="$EVIL_FS"; P1_NAME=spare;  P1_GUID="$GUID_A"
    P3_FS="$EVIL_FS"; P3_NAME=rootfs; P3_GUID="$GUID_X"
    ROOTSPEC="PARTUUID=${GUID_X,,}"
    EXPECT=VERIFY-FAIL ;;
  partuuid)
    # p1 evil (name rootfs-decoy, guid X) ; p3 good (name rootfs, guid X)
    P1_FS="$EVIL_FS"; P1_NAME=rootfs-decoy; P1_GUID="$GUID_X"
    P3_FS="$GOOD_FS"; P3_NAME=rootfs;       P3_GUID="$GUID_X"
    ROOTSPEC="PARTUUID=${GUID_X,,}"
    EXPECT=EVIL ;;
  partlabel)
    # both named 'rootfs', distinct PARTUUIDs; evil at lower index
    P1_FS="$EVIL_FS"; P1_NAME=rootfs; P1_GUID="$GUID_A"
    P3_FS="$GOOD_FS"; P3_NAME=rootfs; P3_GUID="$GUID_B"
    ROOTSPEC="PARTLABEL=rootfs"
    EXPECT=EVIL ;;
  *)
    echo "unknown scenario: $STRATEGY (use: good-only | evil-only | partuuid | partlabel)"; exit 2 ;;
esac

# STAGE=a (default): boot slot = raw Image + boot.scr (hash-verify rootfs, booti).
# STAGE=fit: boot slot = SIGNED kernel.itb + boot.scr (hash-verify rootfs, then bootm
#            the RSA-signed FIT). Boot with u-boot-fit.bin + `-dtb keyed.dtb`.
STAGE="${2:-a}"
echo "[image] scenario=$STRATEGY  root=$ROOTSPEC  U-Boot verifies name='$ROOTNAME'  stage=$STAGE  expect=$EXPECT"

# --- boot partition fs --------------------------------------------------------
stage="$(mktemp -d)"
if [ "$STAGE" = "fit" ]; then
    [ -f out/stage-b/kernel.itb ] || { echo "missing out/stage-b/kernel.itb — run build-uboot-fitverify.sh"; exit 1; }
    cp out/stage-b/kernel.itb "$stage/kernel.itb"
    sed -e "s/@@ROOTNAME@@/$ROOTNAME/g" \
        -e "s#@@ROOTSPEC@@#$ROOTSPEC#g" \
        -e "s/@@VERIFYDEV@@/0/g" \
        -e "s/@@GOODHASH@@/$GOODHASH/g" \
        uboot/boot-fit.cmd > "$stage/boot.cmd"
else
    cp "$KERNEL" "$stage/Image"
    sed -e "s/@@BOOTPART@@/$BOOTPART/g" \
        -e "s/@@ROOTNAME@@/$ROOTNAME/g" \
        -e "s#@@ROOTSPEC@@#$ROOTSPEC#g" \
        -e "s/@@VERIFYDEV@@/0/g" \
        -e "s/@@GOODHASH@@/$GOODHASH/g" \
        uboot/boot.cmd > "$stage/boot.cmd"
fi
mkimage -A arm64 -O linux -T script -C none -n partguid-lab \
    -d "$stage/boot.cmd" "$stage/boot.scr" >/dev/null
rm -f "$OUT/boot.img"
mke2fs -q -t ext4 -L boot -d "$stage" "$OUT/boot.img" 96M
rm -rf "$stage"

# --- lay out the GPT ----------------------------------------------------------
rm -f "$DISK"; truncate -s 256M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk \
    -n 1:0:+48M  -t 1:8300 -c 1:"$P1_NAME" -u 1:"$P1_GUID" \
    -n 2:0:+128M -t 2:8300 -c 2:boot \
    -n 3:0:+48M  -t 3:8300 -c 3:"$P3_NAME" -u 3:"$P3_GUID" \
    "$DISK" >/dev/null

first_lba() { sgdisk -i "$1" "$DISK" | awk '/First sector/{print $3}'; }
place() { dd if="$1" of="$DISK" bs=512 seek="$(first_lba "$2")" conv=notrunc status=none
          echo "[image]   placed $(basename "$1") at partition $2 (name=$3)"; }

place "$P1_FS"        1 "$P1_NAME"
place "$OUT/boot.img" 2 boot
place "$P3_FS"        3 "$P3_NAME"

echo "$EXPECT" > "$OUT/EXPECT"

echo "[image] partitions (num / name / PARTUUID):"
for i in 1 2 3; do
    printf "  p%s  %-14s %s\n" "$i" \
        "$(sgdisk -i "$i" "$DISK" | awk -F': ' '/Partition name/{gsub(/'\''/,"",$2);print $2}')" \
        "$(sgdisk -i "$i" "$DISK" | awk -F': ' '/Partition unique GUID/{print $2}')"
done
echo "[image] done -> $DISK  (verified-hash=$GOODHASH, expect $EXPECT mounted)"
