# Stage B boot script template (compiled to boot.scr by make-image.sh STAGE=b).
# Loads the SIGNED kernel.itb from the golden slot and bootm's it; U-Boot enforces
# the FIT signature against the key in its control DTB (refuses a tampered FIT).
#
# Load the FIT to a HIGH scratch address (0x44000000), NOT kernel_addr_r (0x40400000):
# the kernel inside the FIT has load=0x40400000, so extracting it from a FIT sitting
# at the same address triggers "new format image overwritten - must RESET".

echo "==================================================================="
echo " U-Boot (Stage B, resolver #1): loading SIGNED FIT from golden slot virtio 0:2"
part uuid virtio 0:1 p1uuid && echo "   virtio 0:1 PARTUUID = ${p1uuid}"
part uuid virtio 0:3 p3uuid && echo "   virtio 0:3 PARTUUID = ${p3uuid}"
echo " cmdline will root by PARTUUID=@@PARTUUID@@ (Linux re-resolves this independently)"
echo "==================================================================="

ext4load virtio 0:2 0x44000000 /kernel.itb

setenv bootargs "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 root=PARTUUID=@@PARTUUID@@ rootfstype=ext4 rootwait rw init=/sbin/init panic=-1 partguid.verified"

# bootm verifies the FIT signature, then boots the kernel + signed fdt from conf-1.
bootm 0x44000000#conf-1
