#!/usr/bin/env bash
# PARTUUID/PARTLABEL confusion matrix, grouped by identifier type. The container crafts
# the artifacts; the host QEMU boots them. Each row asserts on its captured log.
#
# Every row now boots a SIGNED kernel FIT from U-Boot whose boot logic is embedded in
# the binary (no boot.scr on disk, no environment read from storage), so each row also
# proves the boot chain itself was verified — the confusion is the only thing left.
#
#   BASELINE   verification works: accepts the golden rootfs, rejects an evil one
#   PARTUUID   duplicate-PARTUUID bypass (single disk AND across two disks)
#   PARTLABEL  shared PARTLABEL: caught on one disk, bypassed across two disks
#   DM-VERITY  the mitigation (root hash anchored in a signed FIT); runs under `all`
set -uo pipefail   # NOT -e: a failing row must not abort the suite
cd "$(dirname "$0")/.."

GROUP="${1:-all}"
case "$GROUP" in all|partuuid|partlabel) ;; *) echo "usage: $0 [all|partuuid|partlabel]"; exit 2;; esac
want(){ [ "$GROUP" = all ] || [ "$GROUP" = "$1" ]; }

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
UB_PU=out/uboot-partuuid/u-boot.bin      # env derives root=PARTUUID= from the verified part
UB_PL=out/uboot-partlabel/u-boot.bin     # env uses root=PARTLABEL=
KDTB=out/fit/keyed.dtb                   # control FDT carrying the RSA public key
RC=0
declare -a ROWS_BASE ROWS_PU ROWS_PL ROWS_DV
qkill(){ pkill -9 -f qemu-system-aarch64 2>/dev/null || true; }

res(){
    local g="$1" lab="$2" log="$3"; shift 3
    local ok=1 p
    for p in "$@"; do
        if [[ "$p" == '!'* ]]; then grep -qE "${p#!}" "$log" 2>/dev/null && ok=0
        else grep -qE "$p" "$log" 2>/dev/null || ok=0; fi
    done
    local tag="[OK]  "; [ "$ok" = 1 ] || { tag="[FAIL]"; RC=1; }
    case "$g" in base) ROWS_BASE+=("$tag $lab");; pu) ROWS_PU+=("$tag $lab");; pl) ROWS_PL+=("$tag $lab");; dv) ROWS_DV+=("$tag $lab");; esac
}
cap(){ TIMEOUT="${TIMEOUT:-90}" bash scripts/run-qemu.sh --capture >/dev/null 2>&1; cp out/boot.log "results/$1"; }

########################## build the signed boot artifacts ##########################
echo "[exp] building signed boot artifacts (U-Boot env is embedded, kernel FIT is signed)"
[ -f "$UB_PU" ] || "${DRUN[@]}" scripts/build-uboot.sh partuuid
[ -f "$UB_PL" ] || "${DRUN[@]}" scripts/build-uboot.sh partlabel
[ -f out/fit/kernel.itb ] || "${DRUN[@]}" scripts/sign-kernel-fit.sh
for f in "$UB_PU" "$UB_PL" "$KDTB" out/fit/kernel.itb; do
    [ -f "$f" ] || { echo "[exp] FATAL: missing $f"; exit 1; }
done

echo "[exp] rootfs ground-truth UUIDs:"; "${DRUN[@]}" bash -c '
  for f in good evil; do echo "  $f.img = $(dumpe2fs -h out/rootfs/$f.img 2>/dev/null | awk -F: "/Filesystem UUID/{gsub(/ /,\"\",\$2);print \$2}")"; done' | tee results/rootfs-uuids.txt

EVIL='ROOTFS IDENTITY : EVIL'; GOOD='ROOTFS IDENTITY : GOOD'; FAIL='ROOTFS VERIFICATION FAILED'
PANIC='dm-verity device corrupted'; RSA='rsa2048:dev\+ OK'; BADFIT='Bad Data Hash|can.t get kernel image'

########################## BASELINE (always) ##########################
echo; echo "########## BASELINE (verification accepts good, rejects evil) ##########"
qkill; "${DRUN[@]}" scripts/make-image.sh good-only >/dev/null;  UBOOT=$UB_PU DTB=$KDTB cap boot-good-only.log
res base "1. good-only boots (GOOD)"                     results/boot-good-only.log "$GOOD" "$RSA" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-image.sh evil-only >/dev/null;  UBOOT=$UB_PU DTB=$KDTB cap boot-evil-only.log
res base "2. evil-only refused (no boot)"                results/boot-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh good-only >/dev/null; UBOOT=$UB_PU DTB=$KDTB cap boot-mldisk-good-only.log
res base "5. multi-disk internal-only boots (GOOD)"      results/boot-mldisk-good-only.log "$GOOD" "$RSA" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh evil-only >/dev/null; UBOOT=$UB_PU DTB=$KDTB cap boot-mldisk-evil-only.log
res base "6. multi-disk internal-evil refused (no boot)" results/boot-mldisk-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"

########################## PARTUUID ##########################
if want partuuid; then
echo; echo "########## PARTUUID (duplicate-PARTUUID bypass) ##########"
qkill; "${DRUN[@]}" scripts/make-image.sh partuuid >/dev/null; UBOOT=$UB_PU DTB=$KDTB cap boot-partuuid.log
res pu "3. PARTUUID single-disk bypass (rsa OK + EVIL)"  results/boot-partuuid.log "$EVIL" "$RSA"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partuuid >/dev/null; UBOOT=$UB_PU DTB=$KDTB DISK2=out/image/disk2.img cap boot-mldisk-partuuid.log
res pu "7. PARTUUID multi-disk bypass (rsa OK + EVIL)"   results/boot-mldisk-partuuid.log "$EVIL" "$RSA"
fi

########################## PARTLABEL ##########################
if want partlabel; then
echo; echo "########## PARTLABEL (caught single-disk, bypassed multi-disk) ##########"
qkill; "${DRUN[@]}" scripts/make-image.sh partlabel >/dev/null; UBOOT=$UB_PL DTB=$KDTB cap boot-partlabel.log
res pl "4. PARTLABEL single-disk: U-Boot catches it (no boot)" results/boot-partlabel.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partlabel >/dev/null; UBOOT=$UB_PL DTB=$KDTB DISK2=out/image/disk2.img cap boot-mldisk-partlabel.log
res pl "8. PARTLABEL multi-disk bypass (rsa OK + EVIL)"  results/boot-mldisk-partlabel.log "$EVIL" "$RSA"
fi

########################## DM-VERITY — signed FIT (all only) ##########################
if [ "$GROUP" = all ]; then
echo; echo "########## DM-VERITY (root hash anchored in a signed FIT) ##########"
qkill; bash scripts/verity-signed-demo.sh >/dev/null 2>&1 || true
res dv "verity-signed good (rsa OK + GOOD boots)"        results/boot-vsigned-good.log   "$GOOD" "$RSA" "!$PANIC"
res dv "verity-signed / PARTUUID: evil blocked (panic)"  results/boot-vsigned-evil.log   "$PANIC" "$RSA" "!$EVIL"
res dv "verity-signed / tampered FIT refused"            results/boot-vsigned-tamper.log "$BADFIT" "!ROOTFS IDENTITY :"
fi

qkill
echo; echo "==================== EXPERIMENT SUMMARY ===================="
echo "BASELINE";              for r in "${ROWS_BASE[@]}"; do echo "  $r"; done
if want partuuid;  then echo; echo "PARTUUID";  for r in "${ROWS_PU[@]}"; do echo "  $r"; done; fi
if want partlabel; then echo; echo "PARTLABEL"; for r in "${ROWS_PL[@]}"; do echo "  $r"; done; fi
if [ "$GROUP" = all ]; then echo; echo "DM-VERITY"; for r in "${ROWS_DV[@]}"; do echo "  $r"; done; fi
echo "==========================================================="
[ "$RC" = 0 ] && echo "[exp] ALL ROWS MATCHED EXPECTATIONS" || echo "[exp] SOME ROW FAILED"
exit "$RC"
