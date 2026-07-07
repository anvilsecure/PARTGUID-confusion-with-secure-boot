# dm-verity MITIGATION boot script (compiled to boot.scr by make-verity-image.sh).
# Placeholders @@...@@ substituted at build time.
#
# The rootfs is mapped through dm-verity via the kernel `dm-mod.create=` cmdline
# (CONFIG_DM_INIT). The verity DATA device is located by PARTUUID (so the #116
# confusion still selects the evil partition), but the verity ROOT HASH is the fixed
# hash of the GOLDEN rootfs. dm-verity therefore hashes the evil blocks, finds they
# do not match the golden root hash, and PANICS — the evil rootfs never runs.
# This is the mitigation: integrity is bound to a cryptographic hash, not to a
# re-resolvable partition identifier.

echo "=================================================================="
echo " dm-verity MITIGATION: root via /dev/dm-0; verity root hash = GOLDEN rootfs"
part uuid virtio 0:1 p1uuid && echo "   virtio 0:1 PARTUUID=${p1uuid}  (evil, lower index)"
part uuid virtio 0:3 p3uuid && echo "   virtio 0:3 PARTUUID=${p3uuid}  (golden; hash tree built from this)"
echo " verity DATA dev = PARTUUID (Linux picks first = evil); ROOT HASH is fixed."
echo " => dm-verity must detect the mismatch and REFUSE (panic), not run evil."
echo "=================================================================="

ext4load virtio 0:2 ${kernel_addr_r} /Image

# Single-quoted so U-Boot keeps the dm-mod.create="..." value (with spaces) intact.
setenv bootargs 'console=ttyAMA0 root=/dev/dm-0 ro rootwait panic=-1 partguid.verified dm-mod.create="vroot,,0,ro,0 65536 verity 1 PARTUUID=@@PARTUUID@@ /dev/vda4 4096 4096 8192 1 sha256 @@ROOTHASH@@ @@SALT@@ 1 panic_on_corruption"'

booti ${kernel_addr_r} - ${fdtcontroladdr}
