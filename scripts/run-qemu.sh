#!/usr/bin/env bash
# Boot the crafted disk on the HOST's qemu-system-aarch64 (not in the container).
#
#   run-qemu.sh             interactive serial console (quit: Ctrl-A x)
#   run-qemu.sh --capture   headless: run to guest poweroff (or TIMEOUT), tee to log
#
# The lab's init powers off after printing the rootfs identity, and the kernel
# cmdline has panic=-1; combined with -no-reboot, every terminal state exits QEMU,
# so --capture always returns instead of hanging.
set -euo pipefail
cd "$(dirname "$0")/.."

# UBOOT overridable so the FIT-verify build (out/uboot-fit/u-boot.bin) can be booted.
UBOOT="${UBOOT:-out/uboot/u-boot.bin}"
DISK=out/image/disk.img
LOG=out/boot.log
TIMEOUT="${TIMEOUT:-90}"

for f in "$UBOOT" "$DISK"; do
    [ -f "$f" ] || { echo "missing $f — run the build first (make all image)"; exit 1; }
done

QEMU=(qemu-system-aarch64
    -M virt -cpu cortex-a57 -m 512 -nographic -no-reboot
    -bios "$UBOOT"
    -drive if=none,file="$DISK",format=raw,id=hd0
    -device virtio-blk-device,drive=hd0)

# FIT-verify mode passes a key-bearing control DTB to QEMU (-> U-Boot's control FDT).
if [ -n "${DTB:-}" ]; then
    [ -f "$DTB" ] || { echo "missing DTB=$DTB"; exit 1; }
    QEMU+=(-dtb "$DTB")
    echo "[run] using control DTB: $DTB"
fi

# Optional second disk (multi-disk PARTLABEL demo). Added AFTER hd0 so it enumerates
# as virtio 1 in U-Boot / vdb in Linux, while $DISK is virtio 0 / vda.
if [ -n "${DISK2:-}" ]; then
    [ -f "$DISK2" ] || { echo "missing DISK2=$DISK2"; exit 1; }
    QEMU+=(-drive if=none,file="$DISK2",format=raw,id=hd1 -device virtio-blk-device,drive=hd1)
    echo "[run] second disk (virtio 1 / vdb): $DISK2"
fi

if [ "${1:-}" = "--capture" ]; then
    echo "[run] capture mode: <=${TIMEOUT}s, log -> $LOG  (guest auto-poweroff)"
    {
        echo "# partguid-confusion-lab capture"
        echo "# qemu      : $(qemu-system-aarch64 --version | head -1)"
        echo "# u-boot.bin: sha256 $(shasum -a 256 "$UBOOT" | awk '{print $1}')"
        echo "# disk.img  : sha256 $(shasum -a 256 "$DISK"  | awk '{print $1}')"
        [ -f out/image/EXPECT ] && echo "# expect    : $(cat out/image/EXPECT) rootfs mounted"
        echo "# ----------------------------------------------------------------"
    } > "$LOG"
    set +e
    # perl alarm gives a hard timeout without GNU timeout(1) (absent on macOS).
    perl -e 'alarm shift @ARGV; exec @ARGV or die $!' "$TIMEOUT" \
        "${QEMU[@]}" </dev/null 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    echo "[run] qemu exited (rc=$rc)"
    exit 0
fi

echo "[run] interactive serial console (quit: Ctrl-A x); log -> $LOG"
exec "${QEMU[@]}" 2>&1 | tee "$LOG"
