#!/usr/bin/env bash
# Craft the GPT disk for a chosen confusion scenario. Runs inside the build container.
# Output: out/image/disk.img (+ out/image/EXPECT)
#
# There is NO boot script on the disk: the whole boot flow is embedded in U-Boot's
# built-in environment and the kernel is a SIGNED FIT (out/fit/kernel.itb) placed in the
# boot slot. The only thing the disk contributes is the partition table and the rootfs
# content — which is exactly the surface this lab is about.
#
# The rootfs partitions are sized EXACTLY like the rootfs images, because U-Boot hashes
# the WHOLE partition: sha256(partition) == sha256(good.img) == the goodhash baked into
# U-Boot's environment.
#
# Usage: make-image.sh [good-only|evil-only|partuuid|partlabel]
set -euo pipefail

STRATEGY="${1:-partuuid}"
OUT=out/image; mkdir -p "$OUT"
DISK="$OUT/disk.img"
ITB=out/fit/kernel.itb
EVIL_FS=out/rootfs/evil.img
GOOD_FS=out/rootfs/good.img
for f in "$ITB" "$EVIL_FS" "$GOOD_FS"; do
    [ -f "$f" ] || { echo "missing $f — run build + sign-kernel-fit.sh first"; exit 1; }
done

GUID_X="11111111-2222-3333-4444-555555555555"   # shared PARTUUID (partuuid case)
GUID_A="aaaaaaaa-1111-2222-3333-444444444444"   # distinct (partlabel / baseline case)
GUID_B="bbbbbbbb-1111-2222-3333-444444444444"
ROOTSZ=$(( $(stat -c%s "$GOOD_FS") / 1048576 ))M   # partition == image, so the whole-
                                                   # partition hash equals the image hash

case "$STRATEGY" in
  good-only)
    # baseline: the only partition named 'rootfs' is GOLDEN -> verify OK -> boots good
    P1_FS="$GOOD_FS"; P1_NAME=spare;  P1_GUID="$GUID_A"
    P3_FS="$GOOD_FS"; P3_NAME=rootfs; P3_GUID="$GUID_X"
    EXPECT=GOOD ;;
  evil-only)
    # baseline: the only partition named 'rootfs' is EVIL -> hash mismatch -> reset
    P1_FS="$EVIL_FS"; P1_NAME=spare;  P1_GUID="$GUID_A"
    P3_FS="$EVIL_FS"; P3_NAME=rootfs; P3_GUID="$GUID_X"
    EXPECT=VERIFY-FAIL ;;
  partuuid)
    # p1 evil (named rootfs-decoy) and p3 golden (named rootfs) SHARE PARTUUID X.
    # U-Boot verifies p3 by name and derives root=PARTUUID=X from it; Linux resolves
    # that same X to the FIRST match = p1 (evil).
    P1_FS="$EVIL_FS"; P1_NAME=rootfs-decoy; P1_GUID="$GUID_X"
    P3_FS="$GOOD_FS"; P3_NAME=rootfs;       P3_GUID="$GUID_X"
    EXPECT=EVIL ;;
  partlabel)
    # both named 'rootfs', distinct PARTUUIDs, evil at the lower index: U-Boot's
    # by-name lookup and Linux's PARTLABEL both pick the first one -> they agree.
    P1_FS="$EVIL_FS"; P1_NAME=rootfs; P1_GUID="$GUID_A"
    P3_FS="$GOOD_FS"; P3_NAME=rootfs; P3_GUID="$GUID_B"
    EXPECT=VERIFY-FAIL ;;
  *)
    echo "unknown scenario: $STRATEGY (good-only | evil-only | partuuid | partlabel)"; exit 2 ;;
esac
echo "[image] scenario=$STRATEGY  rootfs partitions=$ROOTSZ  expect=$EXPECT"

# --- boot slot: just the signed FIT -------------------------------------------
stage="$(mktemp -d)"; cp "$ITB" "$stage/kernel.itb"
rm -f "$OUT/boot.img"
mke2fs -q -t ext4 -L boot -d "$stage" "$OUT/boot.img" 96M
rm -rf "$stage"

# --- GPT ----------------------------------------------------------------------
rm -f "$DISK"; truncate -s 256M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk \
    -n 1:0:+$ROOTSZ -t 1:8300 -c 1:"$P1_NAME" -u 1:"$P1_GUID" \
    -n 2:0:+128M    -t 2:8300 -c 2:boot \
    -n 3:0:+$ROOTSZ -t 3:8300 -c 3:"$P3_NAME" -u 3:"$P3_GUID" \
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
echo "[image] done -> $DISK (expect $EXPECT)"
