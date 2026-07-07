#!/usr/bin/env bash
# Diagnostic: map how U-Boot vs Linux enumerate two virtio-mmio disks.
# Builds two disks, each with a distinct-labelled rootfs partition (p1) and a boot
# slot (p2, so U-Boot's `virtio 0:2` bootcmd works whichever disk is virtio 0).
# Boots rootfs by PARTUUID=<diskA's guid>; the log then shows U-Boot's part list for
# virtio 0/1 and Linux's vda/vdb scan + which device carried diskA's PARTUUID.
set -euo pipefail
OUT=out/image; mkdir -p "$OUT"
K=out/kernel/Image; G=out/rootfs/good.img
GA=aaaaaaaa-0000-0000-0000-000000000001   # unique GUID on diskA p1
GB=bbbbbbbb-0000-0000-0000-000000000002   # unique GUID on diskB p1

stage="$(mktemp -d)"; cp "$K" "$stage/Image"
cat > "$stage/boot.cmd" <<'EOF'
virtio scan
echo "UBOOT-VIRTIO0-PARTS:"
part list virtio 0
echo "UBOOT-VIRTIO1-PARTS:"
part list virtio 1
ext4load virtio 0:2 ${kernel_addr_r} /Image
setenv bootargs 'console=ttyAMA0 root=PARTUUID=aaaaaaaa-0000-0000-0000-000000000001 rootfstype=ext4 rootwait rw init=/sbin/init panic=-1'
booti ${kernel_addr_r} - ${fdtcontroladdr}
EOF
mkimage -A arm64 -O linux -T script -C none -d "$stage/boot.cmd" "$stage/boot.scr" >/dev/null
rm -f "$OUT/boot.img"; mke2fs -q -t ext4 -b 4096 -L boot -d "$stage" "$OUT/boot.img" 96M; rm -rf "$stage"

first_lba(){ sgdisk -i "$1" "$2" | awk '/First sector/{print $3}'; }
build(){ # $1=img $2=name $3=guid
    rm -f "$1"; truncate -s 224M "$1"; sgdisk -Z "$1" >/dev/null
    sgdisk -n 1:0:+48M -t 1:8300 -c 1:"$2" -u 1:"$3" -n 2:0:+128M -t 2:8300 -c 2:boot "$1" >/dev/null
    dd if="$G"           of="$1" bs=512 seek="$(first_lba 1 "$1")" conv=notrunc status=none
    dd if="$OUT/boot.img" of="$1" bs=512 seek="$(first_lba 2 "$1")" conv=notrunc status=none
}
build "$OUT/disk.img"  diskA "$GA"   # hd0
build "$OUT/disk2.img" diskB "$GB"   # hd1
echo "[diag] built disk.img(diskA/hd0) + disk2.img(diskB/hd1)"
