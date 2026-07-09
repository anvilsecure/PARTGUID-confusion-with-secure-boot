#!/bin/busybox sh
# Shared PID-1 for both rootfs images. Its whole job is to make it unambiguous
# *which* partition Linux actually mounted as root. It only reports what is true of
# THIS running rootfs — it never asserts anything about what U-Boot did (that
# evidence belongs to the U-Boot console, not to the partition under test).
/bin/busybox --install -s /bin 2>/dev/null

mount -t proc     proc /proc      2>/dev/null
mount -t sysfs    sys  /sys       2>/dev/null
mount -t devtmpfs dev  /dev       2>/dev/null

ID="$(cat /etc/rootfs-id 2>/dev/null)"
CMDLINE="$(cat /proc/cmdline)"
ROOTSRC="$(findmnt -no SOURCE / 2>/dev/null || awk '$2=="/"{print $1}' /proc/mounts)"
# Filesystem UUID of the mounted root — lets the operator cross-check which image
# this actually is (good.img vs evil.img), independent of the banner text.
ROOTFSUUID="$(blkid -o value -s UUID "$ROOTSRC" 2>/dev/null || \
              dumpe2fs -h "$ROOTSRC" 2>/dev/null | awk -F: '/Filesystem UUID/{gsub(/ /,"",$2);print $2}')"

echo
echo "########################################################################"
echo "#  ROOTFS IDENTITY : ${ID}"
echo "#  kernel cmdline  : ${CMDLINE}"
echo "#  mounted as /    : ${ROOTSRC}   (fs UUID ${ROOTFSUUID})"
echo "########################################################################"
echo

# Infra: save the live device tree QEMU+U-Boot handed this kernel. The signed-verity
# demo (make verity-signed) reuses it as the ~8KB known-bootable base for the FIT's fdt
# and for the key-bearing control DTB (the -machine dumpdtb blob won't boot the kernel).
cat /sys/firmware/fdt > /live.dtb 2>/dev/null; sync

case "$ID" in
  *EVIL*)
    echo "  *** ROOTFS VERIFICATION BYPASSED VIA PARTITION-ID CONFUSION ***"
    echo "  U-Boot verified the rootfs it selected BY NAME ('rootfs'), and that"
    echo "  check passed on the GOLDEN partition. Yet THIS partition is running:"
    echo "  Linux re-resolved the root identifier (PARTUUID/PARTLABEL) to a"
    echo "  different, attacker-controlled partition. The verified partition and"
    echo "  the mounted partition are not the same one."
    ;;
  *GOOD*)
    echo "  Golden rootfs is running — the intended partition was mounted this boot."
    ;;
esac
echo

# By default (automated/CI capture) print the verdict and power off so QEMU exits.
# Add `partguid.shell` to the kernel cmdline to stay in an interactive shell instead.
case " $CMDLINE " in
  *" partguid.shell "*)
    echo "  [partguid-lab] dropping to interactive shell"
    exec /bin/sh
    ;;
esac
echo "  [partguid-lab] powering off (pass 'partguid.shell' on cmdline for a shell)"
poweroff -f
