#!/usr/bin/env bash
# dm-verity MITIGATION, realistic two-disk (device + attacker USB). Runs in container.
#
#   disk.img  = INTERNAL media: p1 verity-hash(GOLDEN) + p2 BOOT SLOT (kernel+scr).
#               Boots on its own. -> hd0 -> virtio1/vdb (hash at /dev/vdb1).
#   disk2.img = ATTACKER USB: p1 rootfs=EVIL, no boot slot. -> hd1 -> virtio0/vda.
#
# U-Boot's scanning bootcmd boots the internal disk (${bootdev}=1). The verity data
# device is root=PARTLABEL=rootfs -> Linux vda1 (EVIL); the hash device is /dev/vdb1
# (golden tree); the root hash is GOLDEN. dm-verity hashes the evil blocks, they don't
# match -> PANIC. The mitigation rejects the attacker USB even across disks.
# Output: out/image/disk.img + out/image/disk2.img (+ EXPECT=EVIL-BLOCKED)
set -euo pipefail
OUT=out/image; mkdir -p "$OUT"
DISK="$OUT/disk.img"; DISK2="$OUT/disk2.img"
KERNEL=out/kernel/Image; EVIL=out/rootfs/evil.img; GOOD=out/rootfs/good.img
for f in "$KERNEL" "$EVIL" "$GOOD"; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
command -v veritysetup >/dev/null || { echo "veritysetup missing — make env"; exit 1; }

# 1. verity hash tree over the GOLDEN rootfs
rm -f "$OUT/hash.img"; truncate -s 16M "$OUT/hash.img"
V="$(veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
        --data-blocks=8192 "$GOOD" "$OUT/hash.img")"
ROOTHASH="$(echo "$V" | awk '/Root hash:/{print $NF}')"
SALT="$(echo "$V" | awk '/Salt:/{print $NF}')"
[ ${#ROOTHASH} -eq 64 ] || { echo "bad root hash '$ROOTHASH'"; exit 1; }
echo "[verity-ml] root hash = $ROOTHASH"

# 2. boot.scr: kernel from ${bootdev}; verity data=PARTLABEL=rootfs (vda1 evil), hash=/dev/vdb1
stage="$(mktemp -d)"; cp "$KERNEL" "$stage/Image"
sed -e "s#@@VDATA@@#PARTLABEL=rootfs#g" -e "s#@@VHASH@@#/dev/vdb1#g" \
    -e "s/@@ROOTHASH@@/$ROOTHASH/g" -e "s/@@SALT@@/$SALT/g" \
    uboot/boot-verity.cmd > "$stage/boot.cmd"
mkimage -A arm64 -O linux -T script -C none -n partguid-verity-ml \
    -d "$stage/boot.cmd" "$stage/boot.scr" >/dev/null
rm -f "$OUT/boot.img"; mke2fs -q -t ext4 -b 4096 -L boot -d "$stage" "$OUT/boot.img" 96M; rm -rf "$stage"

first_lba(){ sgdisk -i "$1" "$2" | awk '/First sector/{print $3}'; }

# INTERNAL disk (hd0 -> vdb): p1 verity-hash, p2 boot slot
rm -f "$DISK"; truncate -s 160M "$DISK"; sgdisk -Z "$DISK" >/dev/null
sgdisk -n 1:0:+16M  -t 1:8300 -c 1:verity-hash \
       -n 2:0:+128M -t 2:8300 -c 2:boot "$DISK" >/dev/null
dd if="$OUT/hash.img" of="$DISK" bs=512 seek="$(first_lba 1 "$DISK")" conv=notrunc status=none
dd if="$OUT/boot.img" of="$DISK" bs=512 seek="$(first_lba 2 "$DISK")" conv=notrunc status=none
echo "[verity-ml] disk.img  (internal, vdb): p1 verity-hash(/dev/vdb1) + p2 boot slot"

# ATTACKER USB (hd1 -> vda): p1 evil rootfs 'rootfs'
rm -f "$DISK2"; truncate -s 64M "$DISK2"; sgdisk -Z "$DISK2" >/dev/null
sgdisk -n 1:0:+48M -t 1:8300 -c 1:rootfs "$DISK2" >/dev/null
dd if="$EVIL" of="$DISK2" bs=512 seek="$(first_lba 1 "$DISK2")" conv=notrunc status=none
echo "[verity-ml] disk2.img (attacker USB, vda): p1 rootfs=evil"

echo "EVIL-BLOCKED" > "$OUT/EXPECT"
echo "[verity-ml] done (expect: dm-verity PANIC on vda1/evil vs golden root hash)"
