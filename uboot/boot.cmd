# U-Boot boot script template (compiled to boot.scr by make-image.sh).
# Placeholders @@...@@ are substituted per scenario before mkimage.
#
# Models the vendor bootcmd from RAT #116:
#   load_kernel && verify_image && load_rootfs && verify_image && setup_bootargs && boot
#
# The crux: U-Boot finds and VERIFIES the rootfs BY NAME (partlabel '@@ROOTNAME@@'),
# then tells Linux to mount root BY @@ROOTSPEC@@. Linux re-resolves that identifier
# on its own and can land on a DIFFERENT partition (a duplicate). U-Boot verified one
# partition; Linux mounts another. verify_image is modelled with sha256 (a stand-in
# for a signature check) — the confusion is identical regardless of the crypto used.

echo "=================================================================="
echo " U-Boot GPT view of virtio 0:"
part list virtio 0

echo " --- load_kernel (from fixed boot slot virtio 0:@@BOOTPART@@) ---"
ext4load virtio 0:@@BOOTPART@@ ${kernel_addr_r} /Image

echo " --- load_rootfs + verify_image: locate rootfs BY NAME '@@ROOTNAME@@' ---"
ext4load virtio 0#@@ROOTNAME@@ 0x46000000 /etc/rootfs-id
hash sha256 0x46000000 ${filesize} vhash
echo " U-Boot: rootfs(name=@@ROOTNAME@@) marker sha256 = ${vhash}"
if test "${vhash}" = "@@GOODHASH@@"; then
    echo " U-Boot: ROOTFS VERIFIED OK -> U-Boot TRUSTS the partition named '@@ROOTNAME@@'"
else
    echo " U-Boot: ROOTFS VERIFICATION FAILED -> refusing to boot"
    reset
fi

echo " --- setup_bootargs: Linux will locate root BY @@ROOTSPEC@@ ---"
setenv bootargs "console=ttyAMA0 root=@@ROOTSPEC@@ rootfstype=ext4 rootwait rw init=/sbin/init panic=-1 partguid.verified"
echo " NOTE: Linux re-resolves @@ROOTSPEC@@ independently — watch which vdaN it mounts."
echo "=================================================================="

# Boot the verified kernel using the control FDT QEMU handed U-Boot.
booti ${kernel_addr_r} - ${fdtcontroladdr}
