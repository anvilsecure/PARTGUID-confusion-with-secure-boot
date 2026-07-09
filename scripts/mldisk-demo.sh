#!/usr/bin/env bash
# Multi-disk PARTLABEL divergence demo. Run on the HOST.
# U-Boot verifies 'rootfs' on the internal media (virtio 1 / vdb); Linux resolves
# root=PARTLABEL=rootfs to the attacker disk (vda, enumerated first) -> EVIL runs.
set -euo pipefail
cd "$(dirname "$0")/.."

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
MODE="${1:-partlabel}"        # partlabel | partuuid
LOG="results/boot-mldisk.log"; [ "$MODE" = partuuid ] && LOG="results/boot-mldisk-partuuid.log"
pkill -9 -f qemu-system-aarch64 2>/dev/null || true

"${DRUN[@]}" scripts/make-multidisk.sh "$MODE"
echo "[mldisk] booting two disks (vda=attacker, vdb=internal/golden), mode=$MODE..."
DISK2=out/image/disk2.img TIMEOUT=90 bash scripts/run-qemu.sh --capture
cp out/boot.log "$LOG"

if grep -qE 'VERIFIED OK' "$LOG" && grep -qE 'ROOTFS IDENTITY : EVIL' "$LOG"; then
    echo "[mldisk] OK ($MODE) — U-Boot verified the internal disk (virtio 1 / vdb), but Linux"
    echo "         mounted the attacker disk (vda) via $MODE. Multi-disk divergence."
else
    echo "[mldisk] FAIL ($MODE) — expected golden verified AND evil (vda) mounted"
    tail -20 "$LOG"; exit 1
fi
