#!/usr/bin/env bash
# Full narrative suite for RAT #116, run in order. Container crafts images/artifacts;
# host QEMU boots them. Each phase asserts on its captured log.
#
#   1. good-only   only the golden rootfs      -> U-Boot verifies OK -> GOOD boots
#   2. evil-only   only an evil rootfs          -> U-Boot hash-verify FAILS -> no boot
#   3. hash bypass / PARTUUID   dup PARTUUID, single disk       -> EVIL mounted
#   4. hash bypass / PARTLABEL  two disks, same label           -> EVIL mounted
#   5. FIT bypass / PARTUUID    real RSA-2048 signed kernel     -> EVIL mounted
#   6. dm-verity MITIGATION     evil rejected (panic) + good verified
#
# Phases 1-4 use the Stage-A U-Boot; phase 5 the FIT-enforcing U-Boot; phase 6 the
# dm-verity kernel. Prereq: `make all` (and phase 5 builds the FIT U-Boot if missing).
set -uo pipefail   # NOT -e: a failing phase should not abort the whole suite
cd "$(dirname "$0")/.."

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
RC=0; declare -a ROWS
qkill(){ pkill -9 -f qemu-system-aarch64 2>/dev/null || true; }
note(){ echo; echo "############ $* ############"; }
check(){ # $1=label  $2=log  $3=want-regex  [$4=must-NOT-regex]
    local ok=1
    grep -qE "$3" "$2" 2>/dev/null || ok=0
    [ -n "${4:-}" ] && grep -qE "$4" "$2" 2>/dev/null && ok=0
    if [ "$ok" = 1 ]; then ROWS+=("[OK]   $1"); else ROWS+=("[FAIL] $1"); RC=1; fi
}

echo "[exp] rootfs ground-truth UUIDs:"; "${DRUN[@]}" bash -c '
  for f in good evil; do echo "  $f.img = $(dumpe2fs -h out/rootfs/$f.img 2>/dev/null | awk -F: "/Filesystem UUID/{gsub(/ /,\"\",\$2);print \$2}")"; done' | tee results/rootfs-uuids.txt

# 1) good-only — the only 'rootfs' is golden -> verify OK -> boots GOOD
note "1) good-only: golden rootfs boots"
qkill; "${DRUN[@]}" scripts/make-image.sh good-only
TIMEOUT=90 bash scripts/run-qemu.sh --capture; cp out/boot.log results/boot-good-only.log
check "1. good-only boots (GOOD)" results/boot-good-only.log "ROOTFS IDENTITY : GOOD" "ROOTFS IDENTITY : EVIL"

# 2) evil-only — the only 'rootfs' is evil -> U-Boot hash-verify FAILS -> reset (no boot)
note "2) evil-only: verification rejects it, system does not boot"
qkill; "${DRUN[@]}" scripts/make-image.sh evil-only
TIMEOUT=90 bash scripts/run-qemu.sh --capture; cp out/boot.log results/boot-evil-only.log
check "2. evil-only refused (no boot)" results/boot-evil-only.log "ROOTFS VERIFICATION FAILED" "ROOTFS IDENTITY :"

# 3) hash bypass / PARTUUID — dup PARTUUID on one disk
note "3) hash bypass on PARTUUID (single disk)"
qkill; "${DRUN[@]}" scripts/make-image.sh partuuid
TIMEOUT=90 bash scripts/run-qemu.sh --capture; cp out/boot.log results/boot-partuuid.log
check "3. hash bypass / PARTUUID (EVIL)" results/boot-partuuid.log "ROOTFS IDENTITY : EVIL"

# 4) hash bypass / PARTLABEL — two disks sharing the label 'rootfs'
note "4) hash bypass on PARTLABEL (multi-disk)"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partlabel
DISK2=out/image/disk2.img TIMEOUT=90 bash scripts/run-qemu.sh --capture; cp out/boot.log results/boot-mldisk.log
check "4. hash bypass / PARTLABEL multi-disk (EVIL)" results/boot-mldisk.log "ROOTFS IDENTITY : EVIL"

# 4b) hash bypass / PARTUUID across two disks — duplicate GUID on another drive
note "4b) hash bypass on PARTUUID (multi-disk: duplicate GUID across drives)"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partuuid
DISK2=out/image/disk2.img TIMEOUT=90 bash scripts/run-qemu.sh --capture; cp out/boot.log results/boot-mldisk-partuuid.log
check "4b. hash bypass / PARTUUID multi-disk (EVIL)" results/boot-mldisk-partuuid.log "ROOTFS IDENTITY : EVIL"

# 5) FIT bypass / PARTUUID — real RSA-2048 signed kernel, still bypassed
note "5) FIT bypass on PARTUUID (real RSA verified boot)"
qkill; scripts/fit-demo.sh || true    # builds FIT U-Boot if needed; writes results/boot-fit-partuuid.log
check "5. FIT bypass / PARTUUID (rsa OK + EVIL)" results/boot-fit-partuuid.log "rsa2048:dev\+ OK"
grep -qE "ROOTFS IDENTITY : EVIL" results/boot-fit-partuuid.log 2>/dev/null || { ROWS+=("[FAIL] 5b. FIT evil mounted"); RC=1; }

# 6) dm-verity MITIGATION — evil rejected (panic) + good verified
note "6) MITIGATION: dm-verity (evil blocked, good verified)"
qkill; scripts/verity-demo.sh || true  # runs both modes; writes results/boot-verity{,-good}.log
check "6a. verity BLOCKS evil (panic)" results/boot-verity.log "dm-verity device corrupted" "ROOTFS IDENTITY : EVIL"
check "6b. verity PASSES good" results/boot-verity-good.log "ROOTFS IDENTITY : GOOD" "dm-verity device corrupted"

qkill
echo; echo "==================== EXPERIMENT SUMMARY ===================="
i=1; for r in "${ROWS[@]}"; do printf "  %s\n" "$r"; done
echo "==========================================================="
[ "$RC" = 0 ] && echo "[exp] ALL PHASES MATCHED EXPECTATIONS" || echo "[exp] SOME PHASE FAILED"
exit "$RC"
