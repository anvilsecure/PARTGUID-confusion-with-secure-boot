#!/usr/bin/env bash
# PARTUUID/PARTLABEL confusion matrix, grouped by identifier type. The container crafts
# the artifacts; the host QEMU boots them. Each row asserts on its captured log
# (results/boot-*.log). QEMU enumeration is deterministic, so every row is single-shot.
#
#   BASELINE   verification works: accepts the golden rootfs, rejects an evil one
#              (single disk + realistic multi-disk device). Always runs.
#   PARTUUID   duplicate-PARTUUID bypass (single disk AND across two disks)
#   PARTLABEL  shared PARTLABEL: caught on one disk, bypassed across two disks
#   DM-VERITY  the mitigation: root bound to a hash, so the confused partition panics
#              (runs under `all` only)
set -uo pipefail   # NOT -e: a failing row must not abort the suite
cd "$(dirname "$0")/.."

# GROUP: all (default) | partuuid | partlabel. A confusion group always runs the shared
# BASELINE rows first (they give the accept-good / reject-evil context); the DM-VERITY
# mitigation group runs only under `all`.
GROUP="${1:-all}"
case "$GROUP" in all|partuuid|partlabel) ;; *) echo "usage: $0 [all|partuuid|partlabel]"; exit 2;; esac
want(){ [ "$GROUP" = all ] || [ "$GROUP" = "$1" ]; }

DRUN=(docker run --rm -t -v "$PWD":/work -w /work partguid-lab:latest)
RC=0
declare -a ROWS_BASE ROWS_PU ROWS_PL ROWS_DV
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
    case "$g" in base) ROWS_BASE+=("$tag $lab");; pu) ROWS_PU+=("$tag $lab");; pl) ROWS_PL+=("$tag $lab");; dv) ROWS_DV+=("$tag $lab");; esac
}
cap(){ TIMEOUT="${TIMEOUT:-90}" bash scripts/run-qemu.sh --capture >/dev/null 2>&1; cp out/boot.log "results/$1"; }

echo "[exp] rootfs ground-truth UUIDs:"; "${DRUN[@]}" bash -c '
  for f in good evil; do echo "  $f.img = $(dumpe2fs -h out/rootfs/$f.img 2>/dev/null | awk -F: "/Filesystem UUID/{gsub(/ /,\"\",\$2);print \$2}")"; done' | tee results/rootfs-uuids.txt

EVIL='ROOTFS IDENTITY : EVIL'; GOOD='ROOTFS IDENTITY : GOOD'; FAIL='ROOTFS VERIFICATION FAILED'
PANIC='dm-verity device corrupted'; RSA='rsa2048:dev\+ OK'; BADFIT='Bad Data Hash|can.t get kernel image'

########################## BASELINE (always) ##########################
echo; echo "########## BASELINE (verification accepts good, rejects evil) ##########"
# -- single disk --
qkill; "${DRUN[@]}" scripts/make-image.sh good-only >/dev/null;  cap boot-good-only.log
res base "1. good-only boots (GOOD)"                     results/boot-good-only.log "$GOOD" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-image.sh evil-only >/dev/null;  cap boot-evil-only.log
res base "2. evil-only refused (no boot)"                results/boot-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"
# -- multi disk (internal media + attacker USB) --
qkill; "${DRUN[@]}" scripts/make-multidisk.sh good-only >/dev/null; cap boot-mldisk-good-only.log
res base "5. multi-disk internal-only boots (GOOD)"      results/boot-mldisk-good-only.log "$GOOD" "!$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh evil-only >/dev/null; cap boot-mldisk-evil-only.log
res base "6. multi-disk internal-evil refused (no boot)" results/boot-mldisk-evil-only.log "$FAIL" "!ROOTFS IDENTITY :"

########################## PARTUUID ##########################
if want partuuid; then
echo; echo "########## PARTUUID (duplicate-PARTUUID bypass) ##########"
qkill; "${DRUN[@]}" scripts/make-image.sh partuuid >/dev/null; cap boot-partuuid.log
res pu "3. PARTUUID single-disk bypass (EVIL)"           results/boot-partuuid.log "$EVIL"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partuuid >/dev/null; DISK2=out/image/disk2.img cap boot-mldisk-partuuid.log
res pu "7. PARTUUID multi-disk bypass (EVIL)"            results/boot-mldisk-partuuid.log "$EVIL"
fi

########################## PARTLABEL ##########################
if want partlabel; then
echo; echo "########## PARTLABEL (caught single-disk, bypassed multi-disk) ##########"
qkill; "${DRUN[@]}" scripts/make-image.sh partlabel >/dev/null; cap boot-partlabel.log
res pl "4. PARTLABEL single-disk: U-Boot catches it (no boot)" results/boot-partlabel.log "$FAIL" "!ROOTFS IDENTITY :"
qkill; "${DRUN[@]}" scripts/make-multidisk.sh partlabel >/dev/null; DISK2=out/image/disk2.img cap boot-mldisk-partlabel.log
res pl "8. PARTLABEL multi-disk bypass (EVIL)"           results/boot-mldisk-partlabel.log "$EVIL"
fi

########################## DM-VERITY — signed FIT (mitigation, all only) ##########################
if [ "$GROUP" = all ]; then
echo; echo "########## DM-VERITY (root hash anchored in a signed FIT) ##########"
# verity-signed-demo.sh builds the FIT-signing U-Boot + bootstraps the control DTB, then
# boots good/evil/tamper (writes results/boot-vsigned-*.log). We re-assert on those logs.
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
