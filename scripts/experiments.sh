#!/usr/bin/env bash
# Full PARTUUID/PARTLABEL confusion matrix, grouped by verification mechanism. Container crafts artifacts;
# host QEMU boots them. Each row asserts on its captured log (results/boot-*.log).
# QEMU enumeration is deterministic here, so every row is single-shot (no REPEAT).
#
#   U-Boot    hash-based verify (Stage-A u-boot, booti)
#   FIT       real RSA-2048 signed kernel + rootfs hash (uboot-fit + -dtb, bootm)
#   DM-VERITY the mitigation (root bound to a hash; wrong partition panics)
set -uo pipefail   # NOT -e: a failing row must not abort the suite
cd "$(dirname "$0")/.."

# GROUP selects which group(s) to run: ub | fit | dv | all (default). Running one
# group at a time keeps each invocation short (the full matrix is ~25 min; a single
# background task can be terminated for running too long).
GROUP="${1:-all}"
want_grp(){ [ "$GROUP" = all ] || [ "$GROUP" = "$1" ]; }

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
FITUBOOT=out/uboot-fit/u-boot.bin
KEYDTB=out/stage-b/keyed.dtb
RC=0
declare -a ROWS_UB ROWS_FIT ROWS_DV
qkill(){ pkill -9 -f qemu-system-aarch64 2>/dev/null || true; }

# res <group> <label> <log> <pattern...>   ('!re' = must be ABSENT)
res(){
    local g="$1" lab="$2" log="$3"; shift 3
    local ok=1 p
    for p in "$@"; do
        if [[ "$p" == '!'* ]]; then grep -qE "${p#!}" "$log" 2>/dev/null && ok=0
        else grep -qE "$p" "$log" 2>/dev/null || ok=0; fi
    done
    local tag="[OK]  "; [ "$ok" = 1 ] || { tag="[FAIL]"; RC=1; }
    case "$g" in ub) ROWS_UB+=("$tag $lab");; fit) ROWS_FIT+=("$tag $lab");; dv) ROWS_DV+=("$tag $lab");; esac
}
cap(){ TIMEOUT="${TIMEOUT:-90}" bash scripts/run-qemu.sh --capture >/dev/null 2>&1; cp out/boot.log "results/$1"; }

echo "[exp] rootfs ground-truth UUIDs:"; "${DRUN[@]}" bash -c '
  for f in good evil; do echo "  $f.img = $(dumpe2fs -h out/rootfs/$f.img 2>/dev/null | awk -F: "/Filesystem UUID/{gsub(/ /,\"\",\$2);print \$2}")"; done' | tee results/rootfs-uuids.txt

EVIL='ROOTFS IDENTITY : EVIL'; GOOD='ROOTFS IDENTITY : GOOD'
FAIL='ROOTFS VERIFICATION FAILED'; RSA='rsa2048:dev\+ OK'; PANIC='dm-verity device corrupted'

########################## U-Boot (hash verify) ##########################
if want_grp ub; then
echo; echo "########## HASH group (Stage-A U-Boot, booti) ##########"
# -- single disk --
qkill; "${DRUN[@]}" scripts/make-image.sh good-only >/dev/null;  cap boot-good-only.log
res ub "1. good-only boots (GOOD)"                 results/boot-good-only.log "$GOOD" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-image.sh evil-only >/dev/null;  cap boot-evil-only.log
res ub "2. evil-only refused (no boot)"            results/boot-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-image.sh partuuid  >/dev/null;  cap boot-partuuid.log
res ub "3. hash bypass / PARTUUID (EVIL)"          results/boot-partuuid.log "$EVIL"
qkill; "${DRUN[@]}" scripts/make-image.sh partlabel >/dev/null;  cap boot-partlabel.log
res ub "4. PARTLABEL single-disk: U-Boot catches it (no boot)" results/boot-partlabel.log "$FAIL" "!ROOTFS IDENTITY :"
# -- multi disk (internal media + attacker USB) --
# baselines boot the INTERNAL disk alone (no USB); bypass adds the attacker USB (DISK2)
qkill; "${DRUN[@]}" scripts/make-multidisk.sh good-only >/dev/null; cap boot-mldisk-good-only.log
res ub "5. multi-disk internal-only boots (GOOD)"       results/boot-mldisk-good-only.log "$GOOD" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh evil-only >/dev/null; cap boot-mldisk-evil-only.log
res ub "6. multi-disk internal-evil refused (no boot)"  results/boot-mldisk-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partuuid  >/dev/null; DISK2=out/image/disk2.img cap boot-mldisk-partuuid.log
res ub "7. hash bypass / PARTUUID multi-disk (EVIL)"    results/boot-mldisk-partuuid.log "$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partlabel >/dev/null; DISK2=out/image/disk2.img cap boot-mldisk-partlabel.log
res ub "8. hash bypass / PARTLABEL multi-disk (EVIL)"   results/boot-mldisk-partlabel.log "$EVIL"

fi  # end U-Boot group

########################## FIT (real RSA) ##########################
if want_grp fit; then
echo; echo "########## FIT group (building signed-boot artifacts) ##########"
[ -f "$FITUBOOT" ] || "${DRUN[@]}" scripts/build-uboot-fitverify.sh
if [ ! -f out/stage-b/live.dtb ]; then          # bootstrap a known-bootable control DTB
    qkill; "${DRUN[@]}" scripts/make-image.sh partuuid >/dev/null; cap boot-bootstrap.log
    "${DRUN[@]}" bash -c 'seek=$(sgdisk -i 1 out/image/disk.img|awk "/First sector/{print \$3}"); dd if=out/image/disk.img of=/tmp/p1.img bs=512 skip=$seek count=98304 status=none; debugfs -R "dump /live.dtb out/stage-b/live.dtb" /tmp/p1.img'
fi
"${DRUN[@]}" scripts/sign-fit.sh out/stage-b/live.dtb >/dev/null   # (re)sign over the current kernel + key the live dtb

# -- single disk --
qkill; "${DRUN[@]}" scripts/make-image.sh good-only fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB cap boot-fit-good-only.log
res fit "1. FIT good-only boots (GOOD)"            results/boot-fit-good-only.log "$GOOD" "$RSA" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-image.sh evil-only fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB cap boot-fit-evil-only.log
res fit "2. FIT evil-only refused (no boot)"       results/boot-fit-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-image.sh partuuid fit >/dev/null;  UBOOT=$FITUBOOT DTB=$KEYDTB cap boot-fit-partuuid.log
res fit "3. FIT bypass / PARTUUID (rsa OK + EVIL)" results/boot-fit-partuuid.log "$RSA" "$EVIL"
qkill; "${DRUN[@]}" scripts/make-image.sh partlabel fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB cap boot-fit-partlabel.log
res fit "4. FIT PARTLABEL single-disk: caught (no boot)" results/boot-fit-partlabel.log "$FAIL" "!ROOTFS IDENTITY :"
# -- multi disk (internal media + attacker USB) --
qkill; "${DRUN[@]}" scripts/make-multidisk.sh good-only fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB cap boot-fit-mldisk-good-only.log
res fit "5. FIT multi-disk internal-only boots (GOOD)"      results/boot-fit-mldisk-good-only.log "$GOOD" "$RSA" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh evil-only fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB cap boot-fit-mldisk-evil-only.log
res fit "6. FIT multi-disk internal-evil refused (no boot)" results/boot-fit-mldisk-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partuuid fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB DISK2=out/image/disk2.img cap boot-fit-mldisk-partuuid.log
res fit "7. FIT bypass / PARTUUID multi-disk (rsa OK + EVIL)"  results/boot-fit-mldisk-partuuid.log "$RSA" "$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partlabel fit >/dev/null; UBOOT=$FITUBOOT DTB=$KEYDTB DISK2=out/image/disk2.img cap boot-fit-mldisk-partlabel.log
res fit "8. FIT bypass / PARTLABEL multi-disk (rsa OK + EVIL)" results/boot-fit-mldisk-partlabel.log "$RSA" "$EVIL"

fi  # end FIT group

########################## DM-VERITY (mitigation) ##########################
if want_grp dv; then
echo; echo "########## DM-VERITY group ##########"
qkill; "${DRUN[@]}" scripts/make-verity-image.sh good >/dev/null;  cap boot-verity-good.log
res dv "1. verity PASSES good"                                 results/boot-verity-good.log "$GOOD" "!$PANIC"
qkill; "${DRUN[@]}" scripts/make-verity-image.sh evil >/dev/null;  cap boot-verity.log
res dv "2. verity bypass / PARTUUID BLOCKS evil (panic)"       results/boot-verity.log "$PANIC" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-verity-multidisk.sh >/dev/null;   DISK2=out/image/disk2.img cap boot-verity-mldisk.log
res dv "3. verity bypass / PARTLABEL multi-disk BLOCKS evil (panic)" results/boot-verity-mldisk.log "$PANIC" "!$EVIL"

fi  # end DM-VERITY group

qkill
echo; echo "==================== EXPERIMENT SUMMARY ===================="
if want_grp ub;  then echo "Hash";           for r in "${ROWS_UB[@]}";  do echo "  $r"; done; fi
if want_grp fit; then echo; echo "FIT";     for r in "${ROWS_FIT[@]}"; do echo "  $r"; done; fi
if want_grp dv;  then echo; echo "DM-VERITY"; for r in "${ROWS_DV[@]}"; do echo "  $r"; done; fi
echo "==========================================================="
[ "$RC" = 0 ] && echo "[exp] ALL PHASES MATCHED EXPECTATIONS" || echo "[exp] SOME PHASE FAILED"
exit "$RC"
