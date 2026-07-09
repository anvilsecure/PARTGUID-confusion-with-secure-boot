#!/usr/bin/env bash
# dm-verity MITIGATION demo — the correct fix (binds root integrity to a hash):
#   evil : same PARTUUID confusion -> verity data resolves to evil -> PANIC, evil never runs
#   good : no collision -> verity data resolves to golden -> verity PASSES, golden runs (ro)
#   multi-disk : attacker USB (evil) vs internal golden hash tree -> PANIC across disks too
# Run on the HOST (container crafts the disk, host QEMU boots it).
set -euo pipefail
cd "$(dirname "$0")/.."

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
rc=0

run_one() { # $1=mode  $2=log  $3=must-appear regex  $4=must-NOT-appear regex
    local mode="$1" log="$2" want="$3" absent="$4"
    echo; echo "=================== verity mode: $mode ==================="
    pkill -9 -f qemu-system-aarch64 2>/dev/null || true
    "${DRUN[@]}" scripts/make-verity-image.sh "$mode"
    TIMEOUT=90 bash scripts/run-qemu.sh --capture
    cp out/boot.log "$log"
    if grep -qE "$want" "$log" && ! grep -qE "$absent" "$log"; then
        echo "[verity:$mode] OK"
    else
        echo "[verity:$mode] FAIL"; tail -15 "$log"; rc=1
    fi
}

# evil: dm-verity must panic on the confused (evil) partition; golden banner must NOT appear
run_one evil results/boot-verity.log \
    'dm-verity device corrupted|verity: .*(is corrupted|reached maximum errors)' \
    'ROOTFS IDENTITY : EVIL'

# good: verity must pass and the golden rootfs must run (proves verity isn't always failing)
run_one good results/boot-verity-good.log \
    'ROOTFS IDENTITY : GOOD' \
    'dm-verity device corrupted'

# multi-disk: attacker USB (evil) vs the internal golden hash tree -> panic across disks too
echo; echo "=================== verity mode: multi-disk ==================="
pkill -9 -f qemu-system-aarch64 2>/dev/null || true
"${DRUN[@]}" scripts/make-verity-multidisk.sh
DISK2=out/image/disk2.img TIMEOUT=90 bash scripts/run-qemu.sh --capture
cp out/boot.log results/boot-verity-mldisk.log
if grep -qE 'dm-verity device corrupted|verity: .*(is corrupted|reached maximum errors)' results/boot-verity-mldisk.log \
   && ! grep -qE 'ROOTFS IDENTITY : EVIL' results/boot-verity-mldisk.log; then
    echo "[verity:multi-disk] OK"
else
    echo "[verity:multi-disk] FAIL"; tail -15 results/boot-verity-mldisk.log; rc=1
fi

echo
if [ "$rc" = 0 ]; then
    echo "[verity] OK — dm-verity BLOCKS the confused/evil partition and PASSES the golden one"
else
    echo "[verity] FAIL"
fi
exit "$rc"
