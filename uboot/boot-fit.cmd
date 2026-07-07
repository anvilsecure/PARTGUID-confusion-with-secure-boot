# FIT-verify boot script template (compiled to boot.scr by make-image.sh STAGE=fit).
# Combines BOTH verification steps from the #116 model:
#   - verify the rootfs U-Boot finds BY NAME '@@ROOTNAME@@' (sha256 of a marker)
#   - boot a REAL RSA-signed kernel FIT (U-Boot enforces the signature via the key in
#     QEMU's control DTB, injected with -dtb)
# ...yet Linux still mounts a DIFFERENT partition (root=PARTUUID=@@PARTUUID@@).

echo "=================================================================="
echo " U-Boot: PARTUUIDs as U-Boot sees them"
part uuid virtio 0:1 p1uuid && echo "   virtio 0:1 PARTUUID = ${p1uuid}"
part uuid virtio 0:3 p3uuid && echo "   virtio 0:3 PARTUUID = ${p3uuid}"

echo " --- verify_image(rootfs): locate BY NAME '@@ROOTNAME@@' and hash-check ---"
ext4load virtio 0#@@ROOTNAME@@ 0x46000000 /etc/rootfs-id
hash sha256 0x46000000 ${filesize} vhash
if test "${vhash}" = "@@GOODHASH@@"; then
    echo " U-Boot: ROOTFS(name=@@ROOTNAME@@) VERIFIED OK (golden partition)"
else
    echo " U-Boot: ROOTFS VERIFICATION FAILED -> refusing to boot"; reset
fi

echo " --- load + verify SIGNED kernel FIT (RSA-2048) ---"
ext4load virtio 0:2 0x44000000 /kernel.itb
setenv bootargs "console=ttyAMA0 root=PARTUUID=@@PARTUUID@@ rootfstype=ext4 rootwait rw init=/sbin/init panic=-1 partguid.verified"
echo "=================================================================="

# bootm verifies the FIT signature against the key in the control DTB, then boots the
# kernel with QEMU's live control FDT (3rd arg) — the FIT has no fdt of its own, so we
# hand it ${fdtcontroladdr} explicitly (same working DTB Stage A's booti used).
# If verification fails (tampered FIT), bootm returns and we reset rather than drop to
# an interactive prompt — a bootloader that halts at a shell is its own bypass.
bootm 0x44000000#conf-1 - ${fdtcontroladdr}
echo "!!! bootm returned — FIT verification FAILED, resetting !!!"
reset
