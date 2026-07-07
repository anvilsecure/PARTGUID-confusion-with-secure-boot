#!/usr/bin/env bash
# End-to-end REAL verified-boot demo: U-Boot cryptographically verifies an RSA-2048
# signed kernel FIT, yet the PARTUUID confusion still mounts the evil rootfs.
# Run on the HOST (container builds, host QEMU boots).
set -euo pipefail
cd "$(dirname "$0")/.."

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
pkill -9 -f qemu-system-aarch64 2>/dev/null || true

# 0. FIT-enforcing U-Boot (+ signed itb + keyed dtb from whatever base exists so far)
[ -f out/uboot-fit/u-boot.bin ] || "${DRUN[@]}" scripts/build-uboot-fitverify.sh

# 1. Bootstrap a KNOWN-BOOTABLE control DTB. qemu's `dumpdtb` blob (1 MiB) does not
#    boot the kernel via -dtb; the DTB QEMU really hands the payload (~8 KiB) does.
#    Grab it from a working (stage-a, live-DTB) boot: init writes /sys/firmware/fdt.
if [ ! -f out/stage-b/live.dtb ]; then
    echo "[fit] bootstrapping known-bootable live DTB..."
    "${DRUN[@]}" scripts/make-image.sh partuuid >/dev/null
    TIMEOUT=90 bash scripts/run-qemu.sh --capture >/dev/null
    "${DRUN[@]}" bash -c '
        seek=$(sgdisk -i 1 out/image/disk.img | awk "/First sector/{print \$3}")
        dd if=out/image/disk.img of=/tmp/p1.img bs=512 skip=$seek count=98304 status=none
        debugfs -R "dump /live.dtb out/stage-b/live.dtb" /tmp/p1.img'
    [ -f out/stage-b/live.dtb ] || { echo "[fit] failed to extract live DTB"; exit 1; }
fi

# 2. Sign the FIT and stamp the pubkey into the live DTB; build the FIT disk.
"${DRUN[@]}" bash -c 'scripts/sign-fit.sh out/stage-b/live.dtb && scripts/make-image.sh partuuid fit'

# 3. Boot: FIT-enforcing U-Boot + key-bearing live DTB via -dtb.
echo "[fit] booting real signed FIT..."
UBOOT=out/uboot-fit/u-boot.bin DTB=out/stage-b/keyed.dtb TIMEOUT=120 bash scripts/run-qemu.sh --capture
cp out/boot.log results/boot-fit-partuuid.log

if grep -qE 'rsa2048:dev\+ OK' results/boot-fit-partuuid.log \
   && grep -qE 'ROOTFS IDENTITY : EVIL' results/boot-fit-partuuid.log; then
    echo "[fit] OK — real RSA-2048 FIT VERIFIED, yet EVIL rootfs mounted (verified-boot bypassed)"
else
    echo "[fit] FAIL — expected both a verified FIT and an EVIL mount"; exit 1
fi
