# dm-verity MITIGATION boot script (compiled to boot.scr by the verity image builders).
# Placeholders @@...@@ substituted at build time.
#
# The rootfs is mapped through dm-verity via the kernel `dm-mod.create=` cmdline
# (CONFIG_DM_INIT). The verity DATA device is located by @@VDATA@@ (so the #116
# confusion still selects the attacker partition), but the verity ROOT HASH is the
# fixed hash of the GOLDEN rootfs. dm-verity hashes the attacker blocks, finds they do
# not match the golden root hash, and PANICS — the evil rootfs never runs. When the
# data device genuinely is the golden rootfs, verity passes and it boots read-only.
# Mitigation: integrity is bound to a cryptographic hash, not a re-resolvable id.

echo "=================================================================="
echo " dm-verity MITIGATION: root via /dev/dm-0; verity root hash = GOLDEN rootfs"
echo " verity data = @@VDATA@@ (Linux resolves this) ; hash dev = @@VHASH@@"
echo " => a wrong/attacker data partition fails the hash and PANICS."
echo "=================================================================="

ext4load virtio ${bootdev}:2 ${kernel_addr_r} /Image

# Single-quoted so U-Boot keeps the dm-mod.create="..." value (with spaces) intact.
setenv bootargs 'console=ttyAMA0 root=/dev/dm-0 ro rootwait panic=-1 partguid.verified dm-mod.create="vroot,,0,ro,0 65536 verity 1 @@VDATA@@ @@VHASH@@ 4096 4096 8192 1 sha256 @@ROOTHASH@@ @@SALT@@ 1 panic_on_corruption"'

booti ${kernel_addr_r} - ${fdtcontroladdr}
