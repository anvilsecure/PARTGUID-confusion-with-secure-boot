#!/usr/bin/env bash
# COMPLETE SOLUTION demo: dm-verity whose root hash is anchored in an RSA-signed FIT.
# Three boots on the host (container builds the artifacts, host QEMU boots them):
#   good   : FIT verified (rsa OK) + verity PASSES the golden data -> GOOD boots
#   evil   : FIT verified (rsa OK) + verity data resolves to evil -> PANIC (evil blocked)
#   tamper : one byte flipped in the signed FIT -> U-Boot REFUSES (signature enforced)
set -euo pipefail
cd "$(dirname "$0")/.."

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
UBF=out/uboot-fit/u-boot.bin
rc=0
qkill(){ pkill -9 -f qemu-system-aarch64 2>/dev/null || true; }

# 0. FIT-enforcing U-Boot + dev key. Rebuild if missing OR stale (a leftover binary from
#    an older approach whose bootcmd sources /boot.scr instead of bootm'ing kernel.itb).
if ! { [ -f "$UBF" ] && strings "$UBF" 2>/dev/null | grep -q 'kernel.itb'; }; then
    echo "[vsigned] building FIT-enforcing U-Boot..."
    "${DRUN[@]}" scripts/build-uboot-fitverify.sh
fi

# 1. Bootstrap a known-bootable ~8KB control DTB. qemu's dumpdtb blob (1 MiB) does not
#    boot the kernel via -dtb; the DTB QEMU really hands the payload does. Grab it from a
#    normal (plain-U-Boot, stage-a) boot: init.sh writes /sys/firmware/fdt to /live.dtb.
if [ ! -f out/stage-b/live.dtb ]; then
    echo "[vsigned] bootstrapping known-bootable live DTB..."
    qkill; "${DRUN[@]}" scripts/make-image.sh partuuid >/dev/null
    TIMEOUT=90 bash scripts/run-qemu.sh --capture >/dev/null
    "${DRUN[@]}" bash -c '
        mkdir -p out/stage-b
        seek=$(sgdisk -i 1 out/image/disk.img | awk "/First sector/{print \$3}")
        dd if=out/image/disk.img of=/tmp/p1.img bs=512 skip=$seek count=98304 status=none
        debugfs -R "dump /live.dtb out/stage-b/live.dtb" /tmp/p1.img'
    [ -s out/stage-b/live.dtb ] || { echo "[vsigned] failed to extract live DTB"; exit 1; }
    echo "[vsigned] live.dtb = $(stat -f%z out/stage-b/live.dtb 2>/dev/null || stat -c%s out/stage-b/live.dtb) bytes"
fi

run_one(){ # $1=mode $2=log $3=must-appear $4=must-NOT-appear
    local mode="$1" log="$2" want="$3" absent="$4"
    echo; echo "=============== signed-verity mode: $mode ==============="
    qkill
    "${DRUN[@]}" scripts/make-verity-signed.sh "$mode"
    UBOOT="$UBF" DTB=out/stage-b/keyed.dtb TIMEOUT=120 bash scripts/run-qemu.sh --capture
    cp out/boot.log "$log"
    if grep -qE "$want" "$log" && ! grep -qE "$absent" "$log"; then echo "[vsigned:$mode] OK"
    else echo "[vsigned:$mode] FAIL"; tail -20 "$log"; rc=1; fi
}

# good: FIT signature verified AND golden rootfs runs (proves the signed path boots)
run_one good   results/boot-vsigned-good.log \
    'rsa2048:dev\+ OK' 'dm-verity device corrupted|ROOTFS IDENTITY : EVIL'
grep -qE 'ROOTFS IDENTITY : GOOD' results/boot-vsigned-good.log || { echo "[vsigned:good] FAIL (no GOOD banner)"; rc=1; }

# evil: FIT signature verified, yet verity blocks the confused evil partition (panic)
run_one evil   results/boot-vsigned-evil.log \
    'dm-verity device corrupted' 'ROOTFS IDENTITY : EVIL'
grep -qE 'rsa2048:dev\+ OK' results/boot-vsigned-evil.log || { echo "[vsigned:evil] FAIL (FIT not verified)"; rc=1; }

# tamper: a modified signed FIT must be refused (no kernel, no rootfs of any kind)
run_one tamper results/boot-vsigned-tamper.log \
    'Bad Data Hash|Bad hash value|can.t get kernel image|signature' 'ROOTFS IDENTITY :'

echo
if [ "$rc" = 0 ]; then
    echo "[vsigned] OK — root hash anchored in a signed FIT: golden boots, evil panics, tampered FIT refused"
else echo "[vsigned] FAIL"; fi
qkill
exit "$rc"
