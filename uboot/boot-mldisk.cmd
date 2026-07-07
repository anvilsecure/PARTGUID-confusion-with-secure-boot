# Multi-disk PARTLABEL boot script (compiled to boot.scr by make-multidisk.sh).
# Models: U-Boot verifies the rootfs on the eMMC (virtio 1, golden) by NAME, then hands
# Linux root=PARTLABEL=rootfs. An attacker's removable disk (virtio 0 / vda) also has a
# partition labelled 'rootfs'. Linux enumerates vda before vdb, so it mounts the
# attacker's rootfs — a DIFFERENT device than the one U-Boot verified. This is the
# multi-disk enumeration divergence #116 describes for PARTLABEL.

echo "=================================================================="
echo " multi-disk PARTLABEL: virtio 0 = removable/SD (attacker), virtio 1 = eMMC (golden)"
echo " U-Boot verifies 'rootfs' on the eMMC (virtio 1); Linux roots by PARTLABEL=rootfs"
echo "=================================================================="

# kernel comes from the boot slot on this device (virtio 0:2)
ext4load virtio 0:2 ${kernel_addr_r} /Image

# verify the GOLDEN rootfs by name on the eMMC (virtio 1)
ext4load virtio 1#rootfs 0x46000000 /etc/rootfs-id
hash sha256 0x46000000 ${filesize} vhash
if test "${vhash}" = "@@GOODHASH@@"; then
    echo " U-Boot: eMMC(virtio 1) 'rootfs' VERIFIED OK -> U-Boot trusts the eMMC golden rootfs"
else
    echo " U-Boot: eMMC 'rootfs' VERIFICATION FAILED -> refusing to boot"
    reset
fi

setenv bootargs 'console=ttyAMA0 root=@@ROOTSPEC@@ rootfstype=ext4 rootwait rw init=/sbin/init panic=-1 partguid.verified'
echo " Linux will resolve @@ROOTSPEC@@ independently (watch vda vs vdb)."
booti ${kernel_addr_r} - ${fdtcontroladdr}
